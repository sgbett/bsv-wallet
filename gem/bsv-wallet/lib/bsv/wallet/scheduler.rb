# frozen_string_literal: true

require 'omq'

module BSV
  module Wallet
    # Discovery loops for walletd background tasks.
    #
    # Each loop queries the Store for pending work and pushes IDs
    # to the appropriate logical model's PULL socket. Runs as fibers
    # inside the Daemon's Async reactor.
    class Scheduler
      def initialize(store:)
        @store = store
      end

      def run!(task:)
        # Broadcast retries — every 5 seconds
        schedule(task: task, endpoint: 'inproc://broadcasts.pull', interval: 5) do
          Engine::Broadcast.pending(@store, limit: 10)
        end

        # Proof acquisition — every 30 seconds
        schedule(task: task, endpoint: 'inproc://proofs.pull', interval: 30) do
          Engine::TxProof.pending(@store, limit: 10)
        end
      end

      private

      def schedule(task:, endpoint:, interval:, &discovery)
        task.async do
          push = OMQ::PUSH.connect(endpoint)
          loop do
            ids = discovery.call
            ids.each { |id| push << id.to_s }
            sleep interval
          rescue StandardError => e
            BSV.logger&.error { "[Scheduler] #{endpoint}: #{e.message}" }
          end
        end
      end
    end
  end
end
