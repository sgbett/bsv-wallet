# frozen_string_literal: true

require 'async'
require 'omq'
require_relative 'engine/broadcast'
require_relative 'engine/tx_proof'
require_relative 'scheduler'
require 'bsv/network/sse_listener'

module BSV
  module Wallet
    # Persistent process host for background wallet tasks.
    #
    # Boots logical models (Engine::Broadcast, Engine::TxProof) with
    # OMQ sockets and a Scheduler with discovery loops inside an
    # Async reactor. This is the runtime for walletd.
    #
    # Usage:
    #   daemon = BSV::Wallet::Daemon.new(store: store, broadcaster: broadcaster)
    #   daemon.run!  # blocks until stopped
    class Daemon
      # Default drain budget — see {Scheduler#shutdown}. Configurable
      # per-instance via the +shutdown_timeout+ constructor kwarg.
      DEFAULT_SHUTDOWN_TIMEOUT_S = Scheduler::DEFAULT_SHUTDOWN_TIMEOUT_S

      attr_reader :scheduler

      # @param store        [BSV::Wallet::Store]
      # @param broadcaster  [BSV::Network::Broadcaster]
      # @param wallet       [String, nil]   wallet name for telemetry
      # @param network      [Symbol, nil]   :mainnet / :testnet for telemetry
      # @param callback_token [String, nil] Arcade callbackToken (#265).
      #   When set, the daemon boots the SSE listener fiber to consume
      #   the live status stream. Token derivation lives in #266 -- this
      #   constructor just accepts the value. When nil, the listener is
      #   skipped and resolution falls back entirely to the poll loop.
      # @param shutdown_timeout [Numeric]
      def initialize(store:, broadcaster:, wallet: nil, network: nil,
                     callback_token: nil,
                     shutdown_timeout: DEFAULT_SHUTDOWN_TIMEOUT_S)
        @store = store
        @broadcaster = broadcaster
        @wallet_name = wallet
        @network = network
        @callback_token = callback_token
        @shutdown_timeout = shutdown_timeout
        @task = nil
        @scheduler = nil
        @sse_listener = nil
        @stop_requested = false
        @stopped = false
      end

      # Start the Async reactor. Blocks until stop! is called or interrupted.
      def run!
        Async do |task|
          @task = task

          setup_signal_traps

          broadcast = Engine::Broadcast.new(store: @store, broadcaster: @broadcaster)
          broadcast.pull!(task: task)
          broadcast.reply!(task: task)
          broadcast.statuses_pull!(task: task)

          tx_proof = Engine::TxProof.new(store: @store, broadcaster: @broadcaster)
          tx_proof.pull!(task: task)

          start_sse_listener(task: task) if @callback_token

          @scheduler = Scheduler.new(store: @store)
          @scheduler.run!(task: task)

          # Trap-safe shutdown watcher. The signal trap (see
          # {#setup_signal_traps}) can't call Mutex#synchronize or
          # Kernel#sleep, both of which Scheduler#shutdown does — so
          # the trap only flips @stop_requested and this thread
          # observes the flag and drives the cooperative drain. A
          # thread (not a reactor fiber) because a fiber's first
          # yield in an otherwise-idle reactor would suspend the
          # parent setup fiber with nothing to wake it.
          #
          # Self-terminates when @task is finished, so the thread does
          # not outlive the daemon's lifecycle (e.g. specs that exit
          # without flipping @stop_requested).
          Thread.new do
            sleep(SHUTDOWN_POLL_INTERVAL_S) until @stop_requested || @task.finished?
            stop! if @stop_requested
          end

          BSV::Wallet.emit('daemon.started', wallet: @wallet_name, network: @network)
        end
      end

      # Stop the reactor cooperatively: drain in-flight broadcasts and
      # proof acquisitions first, then halt the Async task. Drain
      # timeout is +@shutdown_timeout+; on timeout the reactor stops
      # anyway and any still-in-flight work is killed mid-fibre.
      #
      # Idempotent — repeat calls after the first are no-ops, so the
      # +daemon.stopped+ event fires exactly once even if the watcher
      # thread races a programmatic caller.
      #
      # Safe to call from any thread or fiber EXCEPT a signal trap —
      # Scheduler#shutdown uses Mutex and sleep, which raise
      # ThreadError in trap context. Signal traps must set
      # +@stop_requested+ instead; the watcher thread installed by
      # {#run!} picks it up and calls +stop!+ off-trap.
      def stop!
        return if @stopped

        @stopped = true
        @sse_listener&.stop!
        drained = @scheduler&.shutdown(timeout: @shutdown_timeout)
        BSV::Wallet.emit('daemon.stopped', reason: 'signal', drained: drained)
        @task&.stop
      end

      private

      SHUTDOWN_POLL_INTERVAL_S = 0.1
      private_constant :SHUTDOWN_POLL_INTERVAL_S

      def setup_signal_traps
        %w[INT TERM].each do |signal|
          Signal.trap(signal) { @stop_requested = true }
        end
      end

      # Construct the SSE listener and run it as a peer Async task.
      # The +on_event+ block is the seam between Network (Layer 1) and
      # the OMQ bus: each decoded event is Marshal-encoded and PUSHed to
      # +inproc://statuses.pull+, where +Engine::Broadcast#statuses_pull!+
      # (already booted in #run!) pulls and applies it. PUSH is opened
      # inside the listener fiber so its lifecycle is tied to the
      # listener; closure happens implicitly when the fiber unwinds on
      # +stop!+.
      def start_sse_listener(task:)
        task.async do |t|
          push = OMQ::PUSH.connect('inproc://statuses.pull')
          @sse_listener = BSV::Network::SSEListener.new(
            token: @callback_token, store: @store
          ) { |event| push << Marshal.dump(event) }
          @sse_listener.run!(task: t)
        end
      end
    end
  end
end
