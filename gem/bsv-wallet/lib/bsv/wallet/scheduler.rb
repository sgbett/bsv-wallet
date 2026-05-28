# frozen_string_literal: true

require 'omq'

module BSV
  module Wallet
    # Discovery loops for walletd background tasks.
    #
    # Each loop queries the Store for pending work and pushes IDs to the
    # appropriate logical model's PULL socket. Runs as fibers inside the
    # Daemon's Async reactor.
    #
    # Provides a cooperative drain via {#shutdown} so the Daemon can wait
    # for in-flight broadcasts and proof acquisitions to settle before
    # the Async reactor exits. The drain is event-driven: an observer on
    # +BSV::Wallet.on_event+ tracks +task.dispatched+ minus the four
    # terminal events (+task.succeeded+ / +.failed+ / +.aborted+ /
    # +.skipped+). When the counter reaches zero the system is quiesced.
    class Scheduler
      TERMINAL_EVENTS = %w[task.succeeded task.failed task.aborted task.skipped].freeze

      DEFAULT_SHUTDOWN_TIMEOUT_S = 30.0
      SHUTDOWN_POLL_INTERVAL_S = 0.1

      def initialize(store:)
        @store = store
        @stopping = false
        @in_flight_mutex = Mutex.new
        @in_flight = 0
        @observer = nil
      end

      def run!(task:)
        @observer = BSV::Wallet.on_event { |name, _payload| record_lifecycle(name) }

        # Broadcast submission — newly queued rows (broadcast_at IS NULL).
        # Single-table scan; the most responsive path for delayed sends.
        schedule(task: task, name: 'broadcast_push_submission',
                 endpoint: 'inproc://broadcasts.pull', interval: 5) do
          Engine::Broadcast.pending_pushes(@store, limit: 10)
        end

        # Broadcast retries — every 5 seconds
        schedule(task: task, name: 'broadcast_push', endpoint: 'inproc://broadcasts.pull', interval: 5) do
          Engine::Broadcast.pending_polls(@store, limit: 10)
        end

        # Proof acquisition — every 30 seconds
        schedule(task: task, name: 'proof_acquisition', endpoint: 'inproc://proofs.pull', interval: 30) do
          Engine::TxProof.pending(@store, limit: 10)
        end
      end

      # Cooperative drain. Stops the discovery loops from enqueuing new
      # work and waits for in-flight tasks to reach a terminal lifecycle
      # event (+task.succeeded+ / +.failed+ / +.aborted+ / +.skipped+).
      #
      # Returns when the in-flight counter hits zero OR +timeout+
      # seconds elapse. Truthy return = clean drain; +false+ = timed out.
      #
      # Always idempotent — calling shutdown when already stopped returns
      # immediately with +true+.
      #
      # @param timeout [Float] seconds to wait for the drain to complete
      # @return [Boolean] true if drained cleanly, false on timeout
      def shutdown(timeout: DEFAULT_SHUTDOWN_TIMEOUT_S)
        @stopping = true
        deadline = monotonic_now + timeout

        sleep(SHUTDOWN_POLL_INTERVAL_S) while in_flight.positive? && monotonic_now < deadline

        drained = in_flight.zero?
        BSV::Wallet.off_event(@observer) if @observer
        @observer = nil
        drained
      end

      # Current count of dispatched-but-not-terminal tasks. Thread-safe.
      def in_flight
        @in_flight_mutex.synchronize { @in_flight }
      end

      # True once {#shutdown} has been called. Discovery loops check
      # this flag and exit when set.
      def stopping?
        @stopping
      end

      private

      def schedule(task:, name:, endpoint:, interval:, &discovery)
        task.async do
          push = OMQ::PUSH.connect(endpoint)
          until @stopping
            begin
              ids = discovery.call
              BSV::Wallet.emit('task.discovered', task: name, count: ids.size) if ids.any?
              ids.each do |id|
                break if @stopping

                push << id.to_s
                BSV::Wallet.emit('task.enqueued', task: name, id: id)
              end
            rescue StandardError => e
              BSV::Wallet.emit('fiber.crashed', task: name, error: e.message.lines.first&.chomp)
            end
            interruptible_sleep(interval)
          end
        end
      end

      # Sleep that yields early when shutdown is requested. Keeps the
      # discovery loop responsive to drain without polling the flag.
      def interruptible_sleep(seconds)
        deadline = monotonic_now + seconds
        sleep(SHUTDOWN_POLL_INTERVAL_S) while monotonic_now < deadline && !@stopping
      end

      def record_lifecycle(name)
        case name.to_s
        when 'task.dispatched'
          @in_flight_mutex.synchronize { @in_flight += 1 }
        when *TERMINAL_EVENTS
          @in_flight_mutex.synchronize { @in_flight -= 1 }
        end
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end
    end
  end
end
