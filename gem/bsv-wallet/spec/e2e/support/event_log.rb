# frozen_string_literal: true

require 'fileutils'
require 'logger'
require 'time'

module E2E
  # Per-run structured logfile for the e2e harness, wrapping
  # +BSV::Wallet.event_log+ (the canonical event sink introduced in
  # #231 / PR #232).
  #
  # The logfile lives at +tmp/e2e-{timestamp}.log+ inside the gem
  # directory by default and is retained as a test artefact. The
  # caller (a spec) drives event emission by calling
  # +BSV::Wallet.emit(name, **payload)+; the configured event_log
  # writes ISO-8601 + +[event] name key=value+ lines per the
  # +EVENT_LOG_FORMATTER+ contract.
  #
  # This wraps harness-level events ONLY. Daemons running as
  # subprocesses emit to their own per-wallet stderr logfiles —
  # those are captured separately by the +DaemonSupervisor+.
  module EventLog
    DEFAULT_DIR = File.expand_path('../../../tmp', __dir__)

    module_function

    # Open a fresh per-run logfile under +dir+ and route
    # +BSV::Wallet.event_log+ to it. Returns the absolute path of the
    # file written so callers can stash it in the test summary.
    #
    # @param dir [String] target directory (created if missing)
    # @param prefix [String] filename prefix
    # @return [String] absolute path of the logfile
    def start(dir: DEFAULT_DIR, prefix: 'e2e')
      stop # idempotent — drop any prior sink before opening a new one
      FileUtils.mkdir_p(dir)
      # Millisecond + PID suffix so two starts within the same second
      # (back-to-back examples in one process) never collide on one file.
      stamp = Time.now.utc.strftime('%Y%m%dT%H%M%S.%LZ')
      path = File.join(dir, "#{prefix}-#{stamp}-#{Process.pid}.log")
      @file = File.open(path, 'a')
      @file.sync = true
      @logger = Logger.new(@file)
      BSV::Wallet.event_log = @logger
      path
    end

    # Detach the event sink and close the underlying file. Safe to call
    # when none was started. Logger#close closes the wrapped IO.
    def stop
      BSV::Wallet.event_log = nil
      @logger&.close
      @logger = nil
      @file = nil
    end
  end
end
