# frozen_string_literal: true

require 'async'
require 'omq'
# Load Engine first so its autoloads (InputSource, MerklePathNormaliser,
# HydratedTxCache) are installed before broadcast/tx_proof reopen the
# class — those modules are referenced unqualified inside the workers
# and would otherwise NameError if +daemon+ is loaded without a prior
# +require 'bsv-wallet'+.
require_relative 'engine'
require_relative 'engine/broadcast'
require_relative 'engine/tx_proof'
require_relative 'engine/reaper'
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

      attr_reader :scheduler, :watcher_thread

      # @param store        [BSV::Wallet::Store]
      # @param broadcaster  [BSV::Network::Broadcaster]
      # @param wallet       [String, nil]   wallet name for telemetry
      # @param network      [Symbol, nil]   :mainnet / :testnet for telemetry
      # @param callback_token [String, nil] Arcade callbackToken
      #   (typically derived via {BSV::Wallet::CallbackToken.derive}).
      #   When set, the daemon both boots the SSE listener fiber to
      #   consume the live status stream AND passes the token to
      #   Engine::Broadcast so every submit's POST carries a matching
      #   X-CallbackToken header -- the two halves of the same #251 push
      #   loop. When nil, the listener is skipped, submits go out without
      #   the header, and resolution falls back entirely to the poll loop.
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

          # Pass the callback_token into Engine::Broadcast so every submit
          # carries the X-CallbackToken header. The SSE listener subscribed
          # to the same token receives the resulting status frames; without
          # the header set, Arcade has nowhere to publish the event. See #266.
          broadcast = Engine::Broadcast.new(
            store: @store, broadcaster: @broadcaster,
            callback_token: @callback_token
          )
          broadcast.pull!(task: task)
          broadcast.reply!(task: task)
          broadcast.statuses_pull!(task: task)
          # Opt-in cross-process hint receiver: when configured, producers
          # (CLI / API / UI) push Atomic BEEF so the daemon's broadcast
          # skips the resolve_inputs_for_signing JOIN at submit time and
          # has the parents on hand for any future BEEF hand-off. #269.
          # Blank-or-unset normalises to nil so a set-but-empty env
          # doesn't try to bind on "" and crash the fiber.
          broadcast.hints_pull!(task: task, socket_path: hints_socket_path)

          tx_proof = Engine::TxProof.new(store: @store, broadcaster: @broadcaster)
          tx_proof.pull!(task: task)

          # Reaper — reclaims abandoned actions and releases their input locks.
          # Discovery loop lives in the Scheduler (below); this is the consumer.
          reaper = Engine::Reaper.new(store: @store)
          reaper.pull!(task: task)

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
          # without flipping @stop_requested). Exposed via attr_reader so
          # specs can deterministically join the thread before the example
          # ends — on Ruby 3.4 the thread occasionally lingers past the
          # example boundary, and any post-example +stop!+ call here hits
          # +@scheduler.shutdown+ on a now-orphaned verifying double
          # (+RSpec::Mocks::OutsideOfExampleError+).
          @watcher_thread = Thread.new do
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

      # +BSV_WALLET_HINTS_SOCKET+ value, blank-or-unset → nil
      # (handled by +BSV::Wallet::Config#initialize+). #269 / #277.
      def hints_socket_path
        BSV::Wallet.config.hints_socket
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
