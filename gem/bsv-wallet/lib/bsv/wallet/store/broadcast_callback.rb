# frozen_string_literal: true

require 'json'
require 'rack'

module BSV
  module Wallet
    class Store
      # Rack endpoint for ARC broadcast callbacks.
      #
      # Receives ARC TransactionStatus JSON, translates camelCase to
      # internal format, looks up the action by wtxid, and records the
      # result via Store#record_broadcast_result.
      class BroadcastCallback
        def initialize(store:)
          @store = store
        end

        def call(env)
          request = Rack::Request.new(env)
          body = JSON.parse(request.body.read, symbolize_names: true)
          event = decode_event(body)

          action = @store.find_action(wtxid: event[:wtxid])
          record(action, event) if action

          [200, { 'content-type' => 'text/plain' }, ['OK']]
        rescue JSON::ParserError
          [400, { 'content-type' => 'text/plain' }, ['Bad Request']]
        end

        private

        # Mirror the resolution-loop poll path: a definitive rejection
        # cascades through Store#reject_action (unwinding the speculative
        # promotion of this action and any descendants) instead of merely
        # recording a terminal status. Recording alone would strand the
        # rejection -- pending_resolutions excludes TERMINAL rows, so the
        # loop never rediscovers it and reject_action would never run.
        def record(action, event)
          if terminal_reject?(event[:tx_status], event[:extra_info])
            reject(action[:id])
          else
            @store.record_broadcast_result(
              action_id: action[:id],
              tx_status: event[:tx_status],
              arc_status: event[:status],
              block_hash: event[:block_hash],
              block_height: event[:block_height],
              merkle_path: event[:merkle_path],
              extra_info: event[:extra_info],
              competing_txs: event[:competing_txs]
            )
          end
        end

        # CannotRejectInternalActionError is the no_send-descendant invariant
        # guard -- bump retry_count and leave the row alive for the next pass,
        # matching Engine::Broadcast#poll_status.
        def reject(action_id)
          @store.reject_action(action_id: action_id)
        rescue BSV::Wallet::CannotRejectInternalActionError
          @store.increment_broadcast_retry(action_id: action_id)
        end

        # Definitive, non-recoverable rejection -- mirrors
        # Engine::Broadcast#terminal_status?.
        def terminal_reject?(tx_status, extra_info)
          status = tx_status.to_s.upcase
          return true if BSV::Wallet::ArcStatus::REJECTED.include?(status)

          info = extra_info.to_s.upcase
          status.include?('ORPHAN') || info.include?('ORPHAN')
        end

        def decode_event(body)
          BSV::Primitives::Hex.validate_dtxid_hex!(body[:txid], name: 'ARC callback txid') if body[:txid]
          {
            wtxid: decode_hex(body[:txid])&.reverse,
            tx_status: body[:txStatus],
            status: body[:status],
            block_hash: decode_hex(body[:blockHash]),
            block_height: body[:blockHeight],
            merkle_path: decode_hex(body[:merklePath]),
            extra_info: body[:extraInfo],
            competing_txs: body[:competingTxs]
          }
        end

        def decode_hex(hex)
          return unless hex

          [hex].pack('H*')
        end
      end
    end
  end
end
