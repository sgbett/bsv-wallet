# frozen_string_literal: true

module BSV
  module Wallet
    # Default Scheduler implementation — a synchronous polling loop.
    #
    # Each cycle: run all registered entity-driven tasks (discovery →
    # handler per entity), then all periodic tasks (handler only).
    # Sleep for +interval+ seconds between cycles.
    #
    # Errors in handlers are caught per-entity — one failure does not
    # block others. The framework emits lifecycle events but does NOT
    # retry failed handlers.
    #
    # @example
    #   scheduler = PollingScheduler.new(interval: 30)
    #
    #   scheduler.register_task(
    #     name: :broadcast_push,
    #     discovery: -> { Broadcast.where(broadcast_at: nil).all.select(&:needs_push?) },
    #     handler: ->(entity) { services.push!(entity) }
    #   )
    #
    #   scheduler.register_periodic(
    #     name: :address_scan,
    #     handler: -> { engine.scan_receive_addresses }
    #   )
    #
    #   scheduler.on_event { |e| logger.info("[#{e[:task]}] #{e[:event]}") }
    #
    #   trap('INT') { scheduler.stop }
    #   scheduler.start
    class PollingScheduler
      include Interface::Scheduler

      # @param interval [Numeric] seconds to sleep between cycles (default 30)
      def initialize(interval: 30)
        @interval = interval
        @tasks = {}
        @periodics = {}
        @listeners = []
        @running = false
        @dispatching = false
      end

      def register_task(name:, discovery:, handler:)
        @tasks[name] = { discovery: discovery, handler: handler }
      end

      def register_periodic(name:, handler:)
        @periodics[name] = { handler: handler }
      end

      def start
        @running = true
        run_cycle while @running
      end

      def stop
        @running = false
      end

      def running?
        @running
      end

      def quiescent?
        !@dispatching
      end

      def drain(timeout: nil)
        deadline = timeout ? Time.now + timeout : nil
        loop do
          return true if quiescent?
          return false if deadline && Time.now >= deadline

          sleep 0.05
        end
      end

      def on_event(&block)
        @listeners << block
      end

      # Execute one polling cycle. Public for testability.
      def run_cycle
        @dispatching = true

        @tasks.each do |name, task|
          run_entity_task(name, task)
        end

        @periodics.each do |name, task|
          dispatch(name) { task[:handler].call }
        end

        @dispatching = false
        sleep @interval if @running
      rescue StandardError => e
        @dispatching = false
        BSV.logger&.error { "[Scheduler] cycle error: #{e.class}: #{e.message}" }
      end

      private

      def run_entity_task(name, task)
        entities = task[:discovery].call
        entities.each do |entity|
          dispatch(name, entity) { task[:handler].call(entity) }
        end
      rescue StandardError => e
        emit(:failed, name, error: e)
      end

      def dispatch(task_name, entity = nil)
        emit(:dispatched, task_name, entity: entity)
        yield
        emit(:succeeded, task_name, entity: entity)
      rescue StandardError => e
        emit(:failed, task_name, entity: entity, error: e)
      end

      def emit(event, task_name, entity: nil, error: nil)
        payload = { event: event, task: task_name, entity: entity, error: error, timestamp: Time.now }
        @listeners.each { |listener| listener.call(payload) }
      rescue StandardError => e
        BSV.logger&.error { "[Scheduler] listener error: #{e.class}: #{e.message}" }
      end
    end
  end
end
