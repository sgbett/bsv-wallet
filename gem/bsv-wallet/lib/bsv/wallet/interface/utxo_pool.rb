# frozen_string_literal: true

module BSV
  module Wallet
    module Interface
      # UTXO selection strategy for transaction construction.
      #
      # The pool recommends which outputs to spend. The actual locking
      # happens in Store#create_action (Phase 1) via INSERT INTO inputs
      # with ON CONFLICT — the database enforces single-spend atomically.
      #
      # Three tiers of implementation, same interface:
      #
      # Tier 1 (default): delegates to Store#find_spendable — a database query
      # on every call. Fine for single-user, low-frequency use.
      #
      # Tier 2 (pre-split): selects from a dedicated basket. Still a database
      # query, but scoped to a smaller set with less contention.
      #
      # Tier 3 (TxCache): dequeues from a pre-warmed in-memory queue.
      # The hot path is pure memory — no database query, no lock contention,
      # sub-millisecond latency.
      module UTXOPool
        # Select candidate outputs for spending.
        #
        # Returns output data sufficient for transaction construction.
        # These candidates are NOT locked — locking happens when the
        # Store creates the action and its input rows.
        #
        # For tier 3, the dequeue IS the reservation — the output leaves
        # the in-memory queue and won't be offered to concurrent callers.
        #
        # @param satoshis [Integer] minimum total value needed
        # @param exclude [Array<Integer>] output IDs to skip (e.g. from a retry)
        # @return [Array<Hash>] candidates: :id, :satoshis, :vout,
        #   :locking_script, :action_id, :derivation_prefix, :derivation_suffix
        # @raise [PoolDepletedError] if insufficient outputs are available
        def select(satoshis:, exclude: [])
          raise NotImplementedError
        end

        # Release outputs back to the pool after a failed or aborted action.
        #
        # For tier 1/2: no-op — the Store's CASCADE delete on abort
        # frees the input rows, and the outputs were never reserved here.
        #
        # For tier 3: re-enqueues outputs into the in-memory queue.
        #
        # @param outputs [Array<Hash>] the outputs originally returned by {#select}
        def release(outputs:)
          raise NotImplementedError
        end

        # Total available (unreserved) balance in satoshis.
        #
        # @return [Integer]
        def balance
          raise NotImplementedError
        end
      end
    end
  end
end
