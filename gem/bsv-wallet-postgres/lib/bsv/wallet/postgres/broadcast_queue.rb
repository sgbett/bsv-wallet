# frozen_string_literal: true

module BSV
  module Wallet
    module Postgres
      # Broadcast lifecycle manager backed by the broadcasts table.
      #
      # Owns ARC communication. The SDK provides the protocol
      # (BSV::Network::Protocols::ARC), this component decides
      # when and how to call it.
      class BroadcastQueue
        include BSV::Wallet::Interface::BroadcastQueue

        # Broadcasts with these statuses are considered terminal — no further polling.
        TERMINAL_STATUSES = %w[
          SEEN_ON_NETWORK MINED IMMUTABLE
          REJECTED DOUBLE_SPEND_ATTEMPTED
        ].freeze

        def initialize(db: nil, arc_client: nil)
          @db = db || BSV::Wallet::Postgres.db
          @arc_client = arc_client
        end

        def submit(action_id:, raw_tx:, immediate: false)
          BSV.logger&.debug { "[BroadcastQueue] submit: action_id=#{action_id} immediate=#{immediate}" }
          broadcast = Broadcast.create(action_id: action_id)

          if immediate && @arc_client
            post_and_update!(broadcast, raw_tx)
          end

          broadcast_to_hash(broadcast.reload)
        end

        def process_pending(limit: 100)
          stale = Broadcast
            .where { broadcast_at < Time.now - 30 }
            .where(Sequel.|({ tx_status: nil }, Sequel.~(tx_status: TERMINAL_STATUSES)))
            .limit(limit)
            .all

          stale.filter_map do |broadcast|
            action = broadcast.action
            next unless action&.wtxid && @arc_client

            result = @arc_client.call(:get_tx_status, txid: action.dtxid)
            next unless result.http_success?

            update_from_response!(broadcast, result.data)
            broadcast_to_hash(broadcast)
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
            tx_status:     event[:tx_status],
            arc_status:    event[:status],
            block_hash:    event[:block_hash] ? Sequel.blob(event[:block_hash]) : nil,
            block_height:  event[:block_height],
            merkle_path:   event[:merkle_path] ? Sequel.blob(event[:merkle_path]) : nil,
            extra_info:    event[:extra_info],
            competing_txs: event[:competing_txs] ? Sequel.pg_array(event[:competing_txs]) : nil
          )

          {
            action_id:    action.id,
            tx_status:    broadcast.tx_status,
            block_hash:   broadcast.block_hash,
            block_height: broadcast.block_height,
            merkle_path:  broadcast.merkle_path
          }
        end

        def status(action_id:)
          broadcast = Broadcast.first(action_id: action_id)
          return unless broadcast

          broadcast_to_hash(broadcast)
        end

        private

        def post_and_update!(broadcast, raw_tx)
          broadcast.update(broadcast_at: Time.now)
          result = @arc_client.call(:broadcast, raw_tx)
          return unless result.http_success?

          update_from_response!(broadcast, result.data)
        end

        def update_from_response!(broadcast, data)
          broadcast.update(
            tx_status:    data[:txStatus] || data[:tx_status],
            arc_status:   data[:status],
            block_hash:   decode_hex(data[:blockHash] || data[:block_hash]),
            block_height: data[:blockHeight] || data[:block_height],
            merkle_path:  decode_hex(data[:merklePath] || data[:merkle_path]),
            extra_info:   data[:extraInfo] || data[:extra_info]
          )
        end

        def decode_hex(hex)
          return unless hex
          return Sequel.blob(hex) if hex.encoding == Encoding::BINARY

          Sequel.blob([hex].pack('H*'))
        end

        def broadcast_to_hash(record)
          {
            action_id:    record.action_id,
            tx_status:    record.tx_status,
            arc_status:   record.arc_status,
            broadcast_at: record.broadcast_at,
            block_hash:   record.block_hash,
            block_height: record.block_height,
            merkle_path:  record.merkle_path
          }
        end
      end
    end
  end
end
