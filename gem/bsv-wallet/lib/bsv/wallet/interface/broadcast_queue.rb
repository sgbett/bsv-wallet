# frozen_string_literal: true

module BSV
  module Wallet
    module Interface
      # Transaction broadcast lifecycle management.
      #
      # The wallet owns broadcast — the SDK provides the protocol
      # (ARC message formatting/parsing), but the wallet decides
      # when and how to broadcast.
      #
      # Backed by the broadcasts table. Each action has at most one
      # broadcast record. The broadcast lifecycle follows ARC's
      # status progression:
      #
      #   UNKNOWN → RECEIVED → SENT_TO_NETWORK → ACCEPTED_BY_NETWORK
      #     → SEEN_ON_NETWORK → MINED → IMMUTABLE
      #
      # The wallet engine handles promotion (Phase 4) based on
      # broadcast results — the queue handles network I/O only.
      module BroadcastQueue
        # Submit a transaction for broadcast.
        #
        # Creates a broadcast record. If immediate, posts to the network
        # and returns the result. Otherwise, queues for background processing.
        #
        # @param action_id [Integer]
        # @param raw_tx [String] binary-encoded signed transaction
        # @param immediate [Boolean] broadcast synchronously if true
        # @return [Hash] :tx_status, :arc_status, and any proof data
        #   returned by the network
        def submit(action_id:, raw_tx:, immediate: false)
          raise NotImplementedError
        end

        # Post pending broadcasts to the network.
        #
        # Finds broadcast records without a response and posts them.
        # Returns results so the wallet engine can promote accepted actions.
        #
        # @param limit [Integer] maximum number to process
        # @return [Array<Hash>] per-broadcast results:
        #   :action_id, :tx_status, :block_hash, :block_height, :merkle_path
        def process_pending(limit: 100)
          raise NotImplementedError
        end

        # Query broadcast status for an action.
        #
        # @param action_id [Integer]
        # @return [Hash, nil] :tx_status, :arc_status, :broadcast_at, or nil if no broadcast
        def status(action_id:)
          raise NotImplementedError
        end
      end
    end
  end
end
