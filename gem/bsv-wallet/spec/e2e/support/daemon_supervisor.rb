# frozen_string_literal: true

require 'fileutils'
require 'open3'
require 'timeout'

module E2E
  # Boots one +bin/walletd+ subprocess per wallet for the e2e harness
  # (HLR #126).
  #
  # Each daemon inherits the parent env (DATABASE_URL_*, BSV_WALLET_WIF_*)
  # so it talks to the same per-wallet Postgres DB the harness's CLI
  # invocations target. Stderr is redirected to a per-wallet logfile
  # so the daemon's structured event output can be inspected post-run
  # (and grep'd alongside the harness-level event log).
  #
  # Lifecycle:
  #   sup = E2E::DaemonSupervisor.new(wallet_names: %w[w1 w2], network: :mainnet)
  #   sup.start_all
  #   ...                       # test body — daemons running in background
  #   sup.stop_all              # SIGTERM, cooperative drain via the
  #                             # Scheduler#shutdown landed in PR #233
  #
  # On +stop_all+ each daemon receives SIGTERM and is given up to
  # +shutdown_timeout+ seconds to drain in-flight tasks. If it does not
  # exit within the budget it is killed with SIGKILL.
  class DaemonSupervisor
    DEFAULT_SHUTDOWN_TIMEOUT_S = 45.0

    attr_reader :log_dir, :log_paths

    def initialize(wallet_names:, network: :mainnet,
                   log_dir: E2E::EventLog::DEFAULT_DIR,
                   shutdown_timeout: DEFAULT_SHUTDOWN_TIMEOUT_S)
      @wallet_names = wallet_names
      @network = network
      @log_dir = log_dir
      @shutdown_timeout = shutdown_timeout
      @pids = {}
      @log_paths = {}
      @log_files = {}
      @bin = File.expand_path('../../../bin/walletd', __dir__)
    end

    # Spawn one walletd per wallet. Returns when each daemon's process
    # is known to be running; does not wait for the daemon's
    # +daemon.started+ event (callers that need that should grep the
    # log file).
    def start_all
      FileUtils.mkdir_p(@log_dir)
      timestamp = Time.now.utc.strftime('%Y%m%dT%H%M%SZ')

      @wallet_names.each do |wallet|
        log_path = File.join(@log_dir, "walletd-#{wallet}-#{timestamp}.log")
        # Long-lived FD: held for the duration of the supervised daemon
        # subprocess (it inherits the FD as its out/err). Closed in
        # +stop_all+. The block form would close it immediately and
        # the subprocess would lose its log sink.
        log_file = File.open(log_path, 'a') # rubocop:disable Style/FileOpen
        log_file.sync = true
        # +bin/walletd <wallet_name> <network>+ — see bin/walletd L10.
        pid = Process.spawn(@bin, wallet, @network.to_s, out: log_file, err: log_file)
        @pids[wallet] = pid
        @log_paths[wallet] = log_path
        @log_files[wallet] = log_file
      end
      @pids.dup
    end

    # Send SIGTERM to every daemon, then wait up to +shutdown_timeout+
    # seconds for each to exit cleanly. Daemons that don't exit in time
    # are killed with SIGKILL.
    #
    # Returns a hash +{ wallet => :drained | :killed }+ summarising what
    # happened to each daemon.
    def stop_all
      results = {}

      @pids.each do |wallet, pid|
        signal_safely(pid, 'TERM')
        results[wallet] = await_exit?(pid, @shutdown_timeout) ? :drained : :killed
        signal_safely(pid, 'KILL') if results[wallet] == :killed
      ensure
        @log_files[wallet]&.close
      end

      @pids.clear
      @log_files.clear
      results
    end

    # True when every supervised process is still alive.
    def all_alive?
      @pids.all? { |_, pid| process_alive?(pid) }
    end

    private

    def signal_safely(pid, signal)
      Process.kill(signal, pid)
    rescue Errno::ESRCH
      # already gone
    end

    def await_exit?(pid, timeout)
      deadline = monotonic_now + timeout
      while monotonic_now < deadline
        return true if reaped?(pid)

        sleep 0.1
      end
      false
    end

    def reaped?(pid)
      _, status = Process.waitpid2(pid, Process::WNOHANG)
      !status.nil?
    rescue Errno::ECHILD
      true
    end

    def process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH, Errno::EPERM
      false
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
