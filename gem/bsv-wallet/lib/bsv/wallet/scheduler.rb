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
        # Broadcast submission — newly queued rows (broadcast_at IS NULL).
        # Single-table scan; the most responsive path for delayed sends.
        schedule(task: task, name: 'broadcast_push_submission',
                 endpoint: 'inproc://broadcasts.pull', interval: 5) do
          Engine::Broadcast.pending_pushes(@store, limit: 10)
        end

        # Broadcast retries — every 5 seconds
        schedule(task: task, name: 'broadcast_push', endpoint: 'inproc://broadcasts.pull', interval: 5) do
          Engine::Broadcast.pending(@store, limit: 10)
        end

        # Proof acquisition — every 30 seconds
        schedule(task: task, name: 'proof_acquisition', endpoint: 'inproc://proofs.pull', interval: 30) do
          Engine::TxProof.pending(@store, limit: 10)
        end
      end

      private

      def schedule(task:, name:, endpoint:, interval:, &discovery)
        task.async do
          push = OMQ::PUSH.connect(endpoint)
          loop do
            ids = discovery.call
            BSV::Wallet.emit('task.discovered', task: name, count: ids.size) if ids.any?
            ids.each do |id|
              push << id.to_s
              BSV::Wallet.emit('task.enqueued', task: name, id: id)
            end
            sleep interval
          rescue StandardError => e
            BSV::Wallet.emit('fiber.crashed', task: name, error: e.message.lines.first&.chomp)
          end
        end
      end
    end
  end
end
