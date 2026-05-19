# frozen_string_literal: true

module BSV
  module Wallet
    module Interface
      # Contract for async task scheduling.
      #
      # The scheduler owns the clock. Tasks own their behavior. The
      # scheduler dispatches; it does not retry, interpret outcomes,
      # or make decisions about what failed handlers mean.
      #
      # Two registration primitives map to three channel patterns:
      #
      # - +register_task+ (entity-driven) — discovery callable returns
      #   entities to process; handler invoked once per entity per cycle.
      #   Covers both fire-once (entity drops from discovery after
      #   handling) and repeat-until-state-change (entity stays until
      #   upstream state changes).
      #
      # - +register_periodic+ (schedule-driven) — handler invoked once
      #   per cycle with no discovery. Covers repeat-on-schedule tasks
      #   that run indefinitely.
      #
      # On handler failure the framework emits a +:failed+ lifecycle
      # event and continues to the next entity/task. It does NOT retry.
      # If the handler wants the entity retried, it leaves the entity's
      # state unchanged — the next discovery cycle will re-find it.
      #
      # Lifecycle events (enqueued, dispatched, succeeded, failed) are
      # emitted at the interface layer. Consumers (logging, test
      # assertions, observability) subscribe via +on_event+.
      #
      # Implementations: PollingScheduler (default), SolidQueue adapter,
      # Sidekiq adapter, ZeroMQ actor, etc.
      module Scheduler
        # Register an entity-driven task.
        #
        # @param name [Symbol] unique task identifier
        # @param discovery [#call] returns Array of entities to process
        # @param handler [#call] invoked with one entity argument
        def register_task(name:, discovery:, handler:)
          raise NotImplementedError
        end

        # Register a periodic task (runs once per cycle, no discovery).
        #
        # @param name [Symbol] unique task identifier
        # @param handler [#call] invoked with no arguments
        def register_periodic(name:, handler:)
          raise NotImplementedError
        end

        # Start the scheduler.
        def start
          raise NotImplementedError
        end

        # Signal the scheduler to stop after the current cycle.
        def stop
          raise NotImplementedError
        end

        # Whether the scheduler has no in-flight dispatches.
        #
        # @return [Boolean]
        def quiescent?
          raise NotImplementedError
        end

        # Block until all in-flight dispatches complete.
        #
        # @param timeout [Numeric, nil] max seconds to wait (nil = wait forever)
        # @return [Boolean] true if drained, false if timeout reached
        def drain(timeout: nil)
          raise NotImplementedError
        end

        # Subscribe to lifecycle events.
        #
        # Events: +:dispatched+, +:succeeded+, +:failed+
        #
        # Block receives a Hash:
        #   { event:, task:, entity: (nil for periodic), error: (nil unless failed), timestamp: }
        #
        # @yield [Hash] lifecycle event payload
        def on_event(&block)
          raise NotImplementedError
        end
      end
    end
  end
end
