# frozen_string_literal: true

module BSV
  module Wallet
    module Interface
      # Input acquisition for outbound action construction.
      #
      # The funding strategy owns *all* input acquisition for a wallet-
      # selected +createAction+ — the initial lock and any subsequent
      # top-ups — and drives the build collaborator's fixpoint loop until
      # the inputs cover the required fee. Selection (read against the
      # injected +utxo_pool+) and locking (atomic +store.lock_inputs+)
      # remain on opposite sides of the Store boundary; the strategy
      # orchestrates them but never opens a database transaction itself.
      #
      # Conceptually the strategy is the *quartermaster*: it borrows
      # inputs from the pool, externalises the lease via input rows so
      # concurrent actions don't claim the same UTXO, and releases the
      # lease (via action cleanup) on failure. The build collaborator
      # (today +Engine::Action#generate_change+, tomorrow +TxBuilder+) is
      # the *scribe* — it works in pure scratch, attempting a build at the
      # current input set.
      #
      # ## The build seam (one-way, by value)
      #
      # The dependency direction is strict: +FundingStrategy+ calls the
      # builder; the builder never reaches down to fetch or lock inputs.
      # The builder reports *done-or-shortfall by value*, and the strategy
      # decides whether to acquire more input and retry. This keeps the
      # loop *temporal* rather than a structural cycle and is what lets
      # the later +TxBuilder+ extraction lift the build body without
      # re-cutting the seam.
      #
      # A build attempt returns one of:
      #
      # * Success — +{ wtxid:, raw_tx:, tx:, vout_mapping:, change_outputs: }+
      #   exactly as today's +generate_change+ returns it. +tx+ is the live
      #   +BSV::Transaction::Tx+ instance with +source_satoshis+ /
      #   +source_locking_script+ wired on every input.
      # * Shortfall — +{ shortfall: N }+, where +N+ is the positive deficit
      #   in satoshis (+required_fee - surplus+) needing to be covered by
      #   a top-up.
      #
      # The shape is the existing +generate_change+ contract; the strategy
      # documents it, it does not invent it.
      #
      # ## Acquisition ownership (option a)
      #
      # The strategy is handed a pre-existing +action_id+ pointing at an
      # *empty* action row created by the caller via
      # +store.create_action(action:, inputs: [])+. An input-less action
      # row is already routine (the deferred path and the no-output path
      # create one today). The strategy then performs both the *initial*
      # lock and any *top-up* locks through a single uniform path against
      # that +action_id+ — there is no longer a distinct Phase-1 atomic
      # lock retried differently from a top-up.
      #
      # On pool depletion the strategy raises +InsufficientFundsError+;
      # the caller is responsible for aborting the empty action row so no
      # orphan row is left behind.
      #
      # ## Two modes, one entry point
      #
      # The entry point handles both modes behind the same contract:
      #
      # * Wallet-selected — +caller_supplied_inputs: false+, +caller_inputs:
      #   nil+. The strategy selects inputs from the injected +utxo_pool+,
      #   locks the initial set, drives the fixpoint loop, and tops up on
      #   shortfall.
      # * Caller-supplied — +caller_supplied_inputs: true+,
      #   +caller_inputs:+ the caller-built input specs. The strategy locks
      #   the caller's inputs once and runs a single build attempt; a
      #   shortfall raises +InsufficientFundsError+ immediately, with no
      #   top-up.
      #
      # ## Fundable pool
      #
      # The source of fundable coin is the injected +utxo_pool+, never a
      # hardcoded "canonical spendable set". This leaves room for #192's
      # batch-awareness (where a future +utxo_pool+ implementation may
      # surface a batch's in-flight outputs) without building any of it
      # now.
      module FundingStrategy
        # Acquire inputs and drive the build collaborator to convergence.
        #
        # Locks the initial input set against +action_id+ (an empty action
        # row created by the caller), then calls +build+ repeatedly: on
        # +{ shortfall: N }+ it tops up against +utxo_pool+ (excluding the
        # already-locked outputs) and retries; on success it returns the
        # converged build result with the input-sat total attached.
        #
        # The strategy orchestrates atomic Store methods only — it never
        # opens a database transaction. Selection reads the pool, locking
        # invokes +store.lock_inputs+; both stay on opposite sides of the
        # Store boundary.
        #
        # @param action_id [Integer] target action — must already exist as
        #   an empty input-less row (the caller creates it via
        #   +store.create_action(action:, inputs: [])+).
        # @param caller_outputs [Array<Hash>] BRC-100 +outputs+ array,
        #   passed through to the builder unchanged. May be empty.
        # @param caller_supplied_inputs [Boolean] when +true+, the strategy
        #   uses +caller_inputs+ as-is, locks them once, and fails fast on
        #   shortfall (no top-up). When +false+, the strategy selects from
        #   +utxo_pool+ to cover +sum(caller_outputs)+ and tops up on
        #   shortfall.
        # @param caller_inputs [Array<Hash>, nil] caller-supplied input
        #   specs (raw BRC-100 input hashes including any custom
        #   +unlocking_script+ / +sequence_number+ overrides). +nil+ when
        #   the wallet selects inputs itself.
        # @param build [#call] the build collaborator. Called as
        #   +build.call+ on every fixpoint iteration. Must return either
        #   +{ wtxid:, raw_tx:, tx:, vout_mapping:, change_outputs: }+ on
        #   success or +{ shortfall: N }+ on deficit. The builder must
        #   *never* reach down to fetch or lock inputs — the seam is
        #   one-way.
        # @return [Hash] converged result with the build's success keys
        #   plus +:total_input_satoshis+ (read from +tx.total_input_satoshis+
        #   on the returned +tx+). The +:total_input_satoshis+ lets the
        #   caller's post-loop headroom check avoid a redundant
        #   +resolve_inputs_for_signing+ fetch (the "≤1 resolve per build
        #   attempt" acceptance criterion from #323).
        # @raise [BSV::Wallet::InsufficientFundsError] when the pool cannot
        #   meet the required fee — either because +caller_supplied_inputs+
        #   was +true+ and the caller's inputs fall short, or because the
        #   pool is exhausted after exclusion, or because the bounded
        #   contention-retry budget for #213 was exhausted without a
        #   successful lock.
        def acquire(action_id:, caller_outputs:, caller_supplied_inputs:,
                    caller_inputs:, build:)
          raise NotImplementedError
        end
      end
    end
  end
end
