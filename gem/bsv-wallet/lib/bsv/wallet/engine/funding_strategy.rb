# frozen_string_literal: true

module BSV
  module Wallet
    class Engine
      # Input acquisition for outbound action construction.
      #
      # The quartermaster: borrows inputs from +utxo_pool+, externalises
      # the lease via +store.lock_inputs+, and drives the build
      # collaborator's fixpoint loop until the inputs cover the required
      # fee. See +Interface::FundingStrategy+ for the full contract.
      #
      # The strategy orchestrates atomic Store methods only — it never
      # opens a database transaction. The build collaborator is called
      # through a one-way seam: it reports done-or-shortfall by value,
      # never reaches down to fetch inputs.
      class FundingStrategy
        include BSV::Wallet::Interface::FundingStrategy

        # Bound on the bounded contention-retry primitive (#213). On a
        # short-count return from +store.lock_inputs+, the strategy
        # re-selects the contended candidates out of the pool and
        # retries up to this many times before raising
        # +InsufficientFundsError+. Retry is safe because the lock is a
        # *lease* — the batch rolls back atomically on contention, so
        # no canonical state is unwound by re-borrowing scratch.
        #
        # Pool depletion (selection cannot meet the target after
        # +exclude:+) still terminates immediately in
        # +InsufficientFundsError+; it is a distinct condition from
        # contention-retry exhaustion.
        MAX_LOCK_RETRIES = 5

        # Construct a funding strategy. Explicit DI: no engine
        # back-reference. The strategy reads +utxo_pool+ for selection
        # and calls atomic Store methods on +store+; nothing else.
        def initialize(store:, utxo_pool:)
          @store = store
          @utxo_pool = utxo_pool
        end

        # See +Interface::FundingStrategy#acquire+.
        def acquire(action_id:, caller_outputs:, caller_supplied_inputs:,
                    caller_inputs:, build:)
          locked_output_ids = lock_initial_inputs(
            action_id: action_id,
            caller_outputs: caller_outputs,
            caller_supplied_inputs: caller_supplied_inputs,
            caller_inputs: caller_inputs
          )

          # Iteration cap: at most one attempt per spendable output, plus
          # one for the initial selection. Floor of 2 covers the
          # zero-spendable / single-input edge cases.
          max_iterations = [@utxo_pool.spendable_count + 1, 2].max

          max_iterations.times do
            # Resolve the locked input set AFTER each lock (initial or
            # top-up) so the builder sees the grown set, not a stale
            # one. Exactly one resolve per build attempt — the "≤1
            # resolve per build attempt" property from #323 carried
            # forward across the store-free TxBuilder seam (#336).
            resolved = @store.resolve_inputs_for_signing(action_id: action_id)
            result = build.call(resolved)

            return result.merge(total_input_satoshis: result[:tx].total_input_satoshis) unless result[:shortfall]

            # Caller-supplied inputs: no top-up — the caller picked these
            # specifically. Shortfall means the caller's set is
            # underspecified for the requested outputs.
            raise BSV::Wallet::InsufficientFundsError if caller_supplied_inputs

            locked_output_ids = lock_with_retry(
              action_id: action_id,
              target_satoshis: result[:shortfall],
              already_locked_output_ids: locked_output_ids
            )
          end

          raise BSV::Wallet::InsufficientFundsError
        end

        private

        # Initial input acquisition.
        #
        # Caller-supplied inputs: lock once as-is — no retry, no
        # re-selection (the caller picked these specifically; any
        # contention means the caller raced themselves or another
        # wallet, and the right answer is to surface it).
        #
        # Wallet-selected inputs: route through the bounded lock-retry
        # primitive so initial-lock contention behaves the same as
        # top-up contention (#213's uniformity goal). Selection runs
        # inside the retry so contended candidates are re-selected on
        # the next attempt.
        #
        # Returns the list of output_ids locked to the action.
        def lock_initial_inputs(action_id:, caller_outputs:,
                                caller_supplied_inputs:, caller_inputs:)
          if caller_supplied_inputs
            specs = Action.build_input_specs(caller_inputs)
            return [] if specs.empty?

            locked = @store.lock_inputs(action_id: action_id, inputs: specs)
            raise BSV::Wallet::InsufficientFundsError unless locked == specs.size

            return specs.map { |s| s[:output_id] }
          end

          output_total = caller_outputs.sum { |o| o[:satoshis] || 0 }
          return [] unless output_total.positive?

          lock_with_retry(
            action_id: action_id,
            target_satoshis: output_total,
            already_locked_output_ids: []
          )
        end

        # Bounded contention-retry primitive (#213). Selects fresh
        # candidates to cover +target_satoshis+ (excluding everything
        # in +already_locked_output_ids+ *plus* anything contended on
        # prior attempts), re-vins contiguous against the existing
        # lock count, and locks atomically.
        #
        # Retry is safe because the lease is ephemeral: a short-count
        # from +store.lock_inputs+ rolls the whole batch back, so no
        # canonical state is unwound by re-borrowing scratch from the
        # pool. The retry bound (+MAX_LOCK_RETRIES+) is a deliberate
        # policy value, not unbounded.
        #
        # Distinguishes two failure modes:
        # * Pool depletion (selection cannot meet +target_satoshis+
        #   after exclusions) — terminates immediately.
        # * Contention-retry exhaustion (every attempt up to
        #   +MAX_LOCK_RETRIES+ short-counted) — terminates after the
        #   final attempt.
        # Both surface as +InsufficientFundsError+; the call site
        # treats them identically.
        #
        # @return [Array<Integer>] the new locked-output-id list
        #   (+already_locked_output_ids+ followed by the newly locked
        #   outputs, in vin order).
        def lock_with_retry(action_id:, target_satoshis:, already_locked_output_ids:)
          base_vin = already_locked_output_ids.length
          excluded = already_locked_output_ids.dup
          attempts = 0

          loop do
            candidates = begin
              select_candidates(target_satoshis: target_satoshis, exclude: excluded)
            rescue BSV::Wallet::PoolDepletedError
              raise BSV::Wallet::InsufficientFundsError
            end
            raise BSV::Wallet::InsufficientFundsError if candidates.empty?

            specs = candidates.each_with_index.map do |c, i|
              { output_id: c[:id], vin: base_vin + i }
            end

            locked = @store.lock_inputs(action_id: action_id, inputs: specs)
            return already_locked_output_ids + specs.map { |s| s[:output_id] } if locked == specs.size

            # Contention: the whole batch rolled back. Exclude these
            # candidates from the next selection and retry. The bound
            # is on retries, not iterations — an immediate success
            # after a single contention costs one attempt.
            attempts += 1
            raise BSV::Wallet::InsufficientFundsError if attempts > MAX_LOCK_RETRIES

            excluded.concat(candidates.map { |c| c[:id] })
          end
        end

        # Selection primitive — thin wrapper around +@utxo_pool.select+
        # that returns the pool's candidate hashes as-is. Target zero
        # yields an empty set (no-fund path).
        #
        # @raise [BSV::Wallet::PoolDepletedError] when the pool cannot
        #   meet the target after applying +exclude:+.
        def select_candidates(target_satoshis:, exclude: [])
          return [] if target_satoshis.zero?

          @utxo_pool.select(satoshis: target_satoshis, exclude: exclude)
        end
      end
    end
  end
end
