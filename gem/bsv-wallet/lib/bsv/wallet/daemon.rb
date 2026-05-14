# frozen_string_literal: true

module BSV
  module Wallet
    # Background polling loop for entity-driven network interactions.
    #
    # Periodically queries for entities needing push or fetch operations
    # and dispatches them through Services. Each entity is processed
    # independently -- one failure does not block others.
    #
    # The daemon does not import postgres models directly. Instead, it
    # accepts callable query objects (lambdas, procs, or anything
    # responding to +call+) that return arrays of Pushable/Fetchable
    # entities. This keeps the wallet gem free of postgres dependencies.
    #
    # @example
    #   daemon = BSV::Wallet::Daemon.new(
    #     services: services,
    #     pending_pushes: -> { Broadcast.where(broadcast_at: nil).exclude(raw_tx: nil).all },
    #     stale_fetches:  -> { Broadcast.where { broadcast_at < Time.now - 30 }.all },
    #     pending_proofs: -> { Action.where(outgoing: true).exclude(wtxid: nil).where(tx_proof_id: nil).all },
    #     interval: 30
    #   )
    #   daemon.start
    class Daemon
      # @param services [BSV::Network::Services] network routing layer
      # @param pending_pushes [#call] returns entities needing push
      # @param stale_fetches [#call] returns entities needing fetch (broadcast status)
      # @param pending_proofs [#call] returns entities needing fetch (proof acquisition)
      # @param interval [Numeric] seconds to sleep between cycles
      def initialize(services:, pending_pushes: -> { [] }, stale_fetches: -> { [] },
                     pending_proofs: -> { [] }, pending_scans: nil, interval: 30)
        @services = services
        @pending_pushes = pending_pushes
        @stale_fetches = stale_fetches
        @pending_proofs = pending_proofs
        @pending_scans = pending_scans
        @interval = interval
        @running = false
      end

      # Start the polling loop. Blocks until +stop+ is called.
      def start
        @running = true
        run_cycle while @running
      end

      # Signal the loop to exit after the current cycle completes.
      def stop
        @running = false
      end

      # Whether the daemon is currently running.
      def running?
        @running
      end

      # Execute one polling cycle. Public for testability.
      def run_cycle
        push_pending
        fetch_stale
        fetch_proofs
        run_scans if @pending_scans
        sleep @interval
      rescue StandardError => e
        BSV.logger&.error { "[Daemon] cycle error: #{e.class}: #{e.message}" }
      end

      private

      def push_pending
        @pending_pushes.call.each do |entity|
          @services.push!(entity)
        rescue StandardError => e
          BSV.logger&.error { "[Daemon] push error: #{e.class}: #{e.message}" }
        end
      end

      def fetch_stale
        @stale_fetches.call.each do |entity|
          @services.fetch!(entity)
        rescue StandardError => e
          BSV.logger&.error { "[Daemon] fetch error: #{e.class}: #{e.message}" }
        end
      end

      def fetch_proofs
        @pending_proofs.call.each do |entity|
          @services.fetch!(entity)
        rescue StandardError => e
          BSV.logger&.error { "[Daemon] proof fetch error: #{e.class}: #{e.message}" }
        end
      end

      def run_scans
        @pending_scans.call
      rescue StandardError => e
        BSV.logger&.error { "[Daemon] scan error: #{e.class}: #{e.message}" }
      end
    end
  end
end
