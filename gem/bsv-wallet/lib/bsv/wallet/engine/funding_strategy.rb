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
            result = build.call

            return result.merge(total_input_satoshis: result[:tx].total_input_satoshis) unless result[:shortfall]

            # Caller-supplied inputs: no top-up — the caller picked these
            # specifically. Shortfall means the caller's set is
            # underspecified for the requested outputs.
            raise BSV::Wallet::InsufficientFundsError if caller_supplied_inputs

            locked_output_ids = top_up(
              action_id: action_id,
              shortfall: result[:shortfall],
              locked_output_ids: locked_output_ids
            )
          end

          raise BSV::Wallet::InsufficientFundsError
        end

        private

        # Initial input acquisition. Caller-supplied inputs lock as-is;
        # wallet-selected inputs select against +utxo_pool+ to cover the
        # sum of caller outputs (zero-output actions lock nothing).
        #
        # Returns the list of output_ids locked to the action. Re-vin
        # numbering on a subsequent top-up keys off this list's length
        # so vins stay contiguous on the inputs table.
        def lock_initial_inputs(action_id:, caller_outputs:,
                                caller_supplied_inputs:, caller_inputs:)
          initial_inputs =
            if caller_supplied_inputs
              Action.build_input_specs(caller_inputs)
            else
              output_total = caller_outputs.sum { |o| o[:satoshis] || 0 }
              output_total.positive? ? select_inputs(target_satoshis: output_total) : []
            end

          return [] if initial_inputs.empty?

          # The atomic Store#lock_inputs returns the count actually locked;
          # anything short of +initial_inputs.size+ means at least one
          # output was contended and the whole batch rolled back. #213's
          # bounded contention-retry (Task C) replaces this raise.
          locked = @store.lock_inputs(action_id: action_id, inputs: initial_inputs)
          raise BSV::Wallet::InsufficientFundsError unless locked == initial_inputs.size

          initial_inputs.map { |i| i[:output_id] }
        end

        # Top-up acquisition. Selects fresh inputs to cover +shortfall+
        # (excluding everything already locked), re-vins contiguous
        # against the current lock count, and locks. Returns the updated
        # locked-output-id list.
        def top_up(action_id:, shortfall:, locked_output_ids:)
          extra = begin
            select_inputs(target_satoshis: shortfall, exclude: locked_output_ids)
          rescue BSV::Wallet::PoolDepletedError
            raise BSV::Wallet::InsufficientFundsError
          end
          raise BSV::Wallet::InsufficientFundsError if extra.empty?

          base_vin = locked_output_ids.length
          top_up_specs = extra.each_with_index.map do |spec, i|
            { output_id: spec[:output_id], vin: base_vin + i }
          end

          # Anything less than top_up_specs.size means at least one row
          # was contended and the whole batch rolled back. Treat that as
          # a funding failure rather than silently advancing
          # locked_output_ids (which would desynchronise base_vin from
          # the real inputs table). #213's bounded retry replaces this
          # raise in Task C.
          locked = @store.lock_inputs(action_id: action_id, inputs: top_up_specs)
          raise BSV::Wallet::InsufficientFundsError unless locked == top_up_specs.size

          locked_output_ids + top_up_specs.map { |i| i[:output_id] }
        end

        # Selection helper — thin wrapper around +@utxo_pool.select+
        # that returns specs in the +{ output_id:, vin: }+ shape the
        # Store's lock primitives expect. Target zero yields an empty
        # set (no-fund path).
        #
        # @raise [BSV::Wallet::PoolDepletedError] when the pool cannot
        #   meet the target after applying +exclude:+.
        def select_inputs(target_satoshis:, exclude: [])
          return [] if target_satoshis.zero?

          candidates = @utxo_pool.select(satoshis: target_satoshis, exclude: exclude)
          candidates.each_with_index.map do |c, idx|
            { output_id: c[:id], vin: idx }
          end
        end
      end
    end
  end
end
