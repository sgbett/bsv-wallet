# frozen_string_literal: true

using BSV::Wallet::Txid

module BSV
  module Wallet
    class Store
      # Transport-agnostic core that applies a decoded broadcast-status
      # event to the Store. The Rack callback (BroadcastCallback) and the
      # SSE listener (#264) both decode their incoming wire format into a
      # uniform internal hash, then hand it here.
      #
      # The +event+ hash uses the internal shape:
      #
      #   { wtxid:, tx_status:, status:, block_hash:, block_height:,
      #     merkle_path:, extra_info:, competing_txs: }
      #
      # +wtxid+ is wire-order binary (32 bytes); +block_hash+ /
      # +merkle_path+ are binary; everything else is whatever the
      # adapter parsed out of the wire body.
      class EventApplicator
        def initialize(store:)
          @store = store
        end

        # Apply one decoded event. Idempotent on current state: replaying
        # a terminal event after the cascade has already run is a no-op
        # (find_action returns nil for the deleted row, which is the
        # unknown-wtxid path).
        def apply(event)
          wtxid = event[:wtxid]
          action = @store.find_action(wtxid: wtxid)
          return log_unknown(wtxid, event[:tx_status]) unless action

          if terminal_reject?(event[:tx_status], event[:extra_info])
            reject(action[:id], event[:tx_status])
          else
            record(action[:id], event)
          end
        end

        private

        # Mirror the resolution-loop poll path: a definitive rejection
        # cascades through Store#reject_action (unwinding the speculative
        # promotion of this action and any descendants) instead of merely
        # recording a terminal status. Recording alone would strand the
        # rejection -- pending_resolutions excludes TERMINAL rows, so the
        # loop never rediscovers it and reject_action would never run.
        def record(action_id, event)
          @store.record_broadcast_result(
            action_id: action_id,
            tx_status: event[:tx_status],
            arc_status: event[:status],
            block_hash: event[:block_hash],
            block_height: event[:block_height],
            merkle_path: event[:merkle_path],
            extra_info: event[:extra_info],
            competing_txs: event[:competing_txs]
          )
        end

        # Two invariant guards from Store#reject_action:
        #
        # CannotRejectInternalActionError is the no_send-descendant guard --
        # transient, so bump retry_count and leave the row alive for the
        # next pass, matching Engine::Broadcast#poll_status.
        #
        # CannotRejectAcceptedActionError means a descendant is network-
        # accepted; unwinding would compound a wallet-vs-chain divergence
        # (see Store#do_reject). That is NOT transient -- retrying never
        # helps -- so don't bump retry_count. Log for operator
        # investigation and return so the adapter still ACKs the event
        # (ARC stops re-delivering; SSE cursor advances).
        #
        # The tx_status arg is logged so DOUBLE_SPEND_ATTEMPTED stays
        # distinct from generic REJECTED in telemetry, even though the
        # cascade deletes the broadcasts row that would otherwise carry
        # the distinction.
        def reject(action_id, tx_status)
          BSV.logger&.info do
            "[EventApplicator] rejecting action_id=#{action_id} tx_status=#{tx_status}"
          end
          @store.reject_action(action_id: action_id)
        rescue BSV::Wallet::CannotRejectInternalActionError
          @store.increment_broadcast_retry(action_id: action_id)
        rescue BSV::Wallet::CannotRejectAcceptedActionError => e
          BSV.logger&.error do
            "[EventApplicator] cannot reject accepted action #{action_id}: #{e.message}"
          end
        end

        # Definitive, non-recoverable rejection -- mirrors
        # Engine::Broadcast#terminal_status?.
        def terminal_reject?(tx_status, extra_info)
          status = tx_status.to_s.upcase
          return true if BSV::Wallet::ArcStatus::REJECTED.include?(status)

          info = extra_info.to_s.upcase
          status.include?('ORPHAN') || info.include?('ORPHAN')
        end

        def log_unknown(wtxid, tx_status)
          BSV.logger&.warn do
            dtxid = wtxid ? wtxid.to_dtxid : '(missing)'
            "[EventApplicator] unknown wtxid dtxid=#{dtxid} tx_status=#{tx_status}; skipping"
          end
          nil
        end
      end
    end
  end
end
