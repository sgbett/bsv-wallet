# frozen_string_literal: true

require 'json'

module BSV
  module Wallet
    module Store
      class BroadcastQueue
        include BSV::Wallet::Interface::BroadcastQueue

        def initialize(db: nil, services: nil)
          @db = db || Connection.db
          @services = services
        end

        def submit(action_id:, raw_tx:, immediate: false)
          BSV.logger&.debug { "[BroadcastQueue] submit: action_id=#{action_id} immediate=#{immediate}" }
          broadcast = Broadcast.create(action_id: action_id)
          @services.push!(broadcast) if immediate && @services
          broadcast_to_hash(broadcast.reload)
        end

        def process_pending(limit: 100)
          stale = Broadcast
                  .where { broadcast_at < Time.now - Broadcast::FETCH_STALENESS }
                  .where(Sequel.|({ tx_status: nil }, Sequel.~(tx_status: Broadcast::TERMINAL_STATUSES)))
                  .limit(limit)
                  .all

          stale.filter_map do |broadcast|
            next unless broadcast.action&.wtxid && @services

            result = @services.fetch!(broadcast)
            next unless result.http_success?

            broadcast_to_hash(broadcast.reload)
          end
        end

        def handle_event(event)
          BSV::Primitives::Hex.validate_wtxid!(event[:wtxid], name: 'handle_event wtxid')
          BSV.logger&.debug { "[BroadcastQueue] handle_event: dtxid=#{event[:wtxid].reverse.unpack1('H*')} status=#{event[:tx_status]}" }
          action = Action.first(wtxid: Sequel.blob(event[:wtxid]))
          return unless action

          broadcast = Broadcast.first(action_id: action.id)
          broadcast ||= Broadcast.create(action_id: action.id)

          broadcast.update(
            tx_status: event[:tx_status],
            arc_status: event[:status],
            block_hash: event[:block_hash] ? Sequel.blob(event[:block_hash]) : nil,
            block_height: event[:block_height],
            merkle_path: event[:merkle_path] ? Sequel.blob(event[:merkle_path]) : nil,
            extra_info: event[:extra_info],
            competing_txs: event[:competing_txs] ? JSON.generate(event[:competing_txs]) : nil
          )

          {
            action_id: action.id, tx_status: broadcast.tx_status,
            block_hash: broadcast.block_hash, block_height: broadcast.block_height,
            merkle_path: broadcast.merkle_path
          }
        end

        def status(action_id:)
          broadcast = Broadcast.first(action_id: action_id)
          return unless broadcast

          broadcast_to_hash(broadcast)
        end

        private

        def broadcast_to_hash(record)
          {
            action_id: record.action_id, tx_status: record.tx_status,
            arc_status: record.arc_status, broadcast_at: record.broadcast_at,
            block_hash: record.block_hash, block_height: record.block_height,
            merkle_path: record.merkle_path
          }
        end
      end
    end
  end
end
