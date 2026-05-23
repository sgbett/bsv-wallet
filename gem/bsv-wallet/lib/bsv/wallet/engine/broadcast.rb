# frozen_string_literal: true

require 'omq'

module BSV
  module Wallet
    class Engine
      # Background broadcast handler -- logical model for walletd.
      #
      # Owns OMQ sockets for background work (PULL) and inline
      # request-reply (REP). Processes pending broadcasts by calling
      # Services and recording results in Store.
      class Broadcast
        def initialize(store:, services:)
          @store = store
          @services = services
        end

        # Background queue -- fire-and-forget processing.
        # Binds a PULL socket; the Scheduler pushes action IDs here.
        def pull!(task:)
          task.async do
            pull = OMQ::PULL.bind('inproc://broadcasts.pull')
            while (msg = pull.receive)
              begin
                process(msg.first.to_i)
              rescue StandardError => e
                BSV.logger&.error { "[Engine::Broadcast] pull error: #{e.message}" }
              end
            end
          end
          self
        end

        # Inline request-reply -- caller sends action_id, gets tx_status back.
        def reply!(task:)
          task.async do
            rep = OMQ::REP.bind('inproc://broadcasts.rep')
            while (msg = rep.receive)
              begin
                result = process(msg.first.to_i)
                rep << (result ? result[:tx_status].to_s : 'error')
              rescue StandardError => e
                BSV.logger&.error { "[Engine::Broadcast] reply error: #{e.message}" }
                rep << 'error'
              end
            end
          end
          self
        end

        # Process a single broadcast -- look up action, call ARC, record result.
        def process(action_id)
          action = @store.find_action(id: action_id)
          return unless action && action[:raw_tx]

          response = @services.call(:broadcast, action[:raw_tx])
          if response.http_success?
            @store.record_broadcast_result(
              action_id: action_id,
              tx_status: response.data[:tx_status],
              arc_status: response.data[:status],
              block_hash: response.data[:block_hash],
              block_height: response.data[:block_height],
              merkle_path: response.data[:merkle_path],
              extra_info: response.data[:extra_info],
              competing_txs: response.data[:competing_txs]
            )
          else
            BSV.logger&.warn { "[Engine::Broadcast] failed for action #{action_id}: #{response.error_message}" }
          end

          @store.broadcast_status(action_id: action_id)
        end

        # Discovery query -- returns action IDs needing broadcast.
        def self.pending(store, limit: 10)
          store.pending_broadcasts(limit: limit).map { |b| b[:action_id] }
        end
      end
    end
  end
end
