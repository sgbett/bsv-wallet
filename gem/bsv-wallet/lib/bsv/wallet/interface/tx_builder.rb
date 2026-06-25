# frozen_string_literal: true

module BSV
  module Wallet
    module Interface
      # Transaction construction for outbound actions.
      #
      # The builder owns transaction *construction* — given a resolved
      # input set, caller outputs, and an injected key deriver, it
      # assembles +TransactionInput+ / +TransactionOutput+ objects,
      # derives BRC-42 change keys, runs the fee fixpoint, optionally
      # shuffles outputs, and signs P2PKH inputs the wallet owns. It
      # works in pure, private scratch: no Store, no lock lifecycle, no
      # clock.
      #
      # Conceptually the builder is the *scribe* from the #323
      # quartermaster/scribe model (ADR-018): the *stateless* half of
      # the build. The quartermaster (+FundingStrategy+) owns the
      # contended lease and hands the scribe a resolved input set *by
      # value*; the scribe attempts a build and reports
      # *done-or-shortfall by value*; the quartermaster decides whether
      # to lease more.
      #
      # ## The resolve seam (store-free, by value)
      #
      # The builder takes +resolved_inputs+ as an argument. It does not
      # call +store.resolve_inputs_for_signing+ — that responsibility
      # sits with the caller (today: +FundingStrategy#acquire+ inside
      # the fixpoint loop after each lock, and the
      # deferred / +skip_change+ branches of +Engine#build_action+ inline).
      # This keeps the builder a pure function and preserves the "≤1
      # resolve per build attempt" property the funding seam was cut to
      # enable.
      #
      # ## The build seam (one-way, by value)
      #
      # The dependency direction is strict: the builder returns
      # done-or-shortfall by value; it never reaches back to fetch or
      # lock inputs. A change-build attempt returns one of:
      #
      # * Success — +{ wtxid:, raw_tx:, tx:, vout_mapping:, change_outputs: }+.
      #   +tx+ is the live +BSV::Transaction::Tx+ with +source_satoshis+ /
      #   +source_locking_script+ wired on every input;
      #   +FundingStrategy+ reads +tx.total_input_satoshis+ off this
      #   instance for its by-value sat total.
      # * Shortfall — +{ shortfall: N }+, where +N+ is the positive
      #   deficit in satoshis (+required_fee - surplus+) needing to be
      #   covered by a top-up.
      #
      # The no-change +#build+ method always returns the success shape;
      # there is no fee fixpoint, so no shortfall report.
      #
      # ## DI
      #
      # The builder is constructed with an injected +key_deriver+ (the
      # only collaborator the build needs beyond +resolved_inputs+ and
      # caller arguments) and an injected fee model. There is no
      # +engine+ back-reference and no +.send(:private)+ reach-through.
      # The +require_key_deriver!+-style guard becomes a builder
      # concern over its own injected deriver.
      #
      # ## Not the builder's concern
      #
      # BEEF assembly / egress (+build_atomic_beef+, +wire_ancestor+,
      # +validate_for_handoff!+) is hydration over the ProofStore — a
      # separate concern owned by +Interface::Hydrator+
      # (+Engine::Hydrator+). The Hydrator is store-reading, in deliberate
      # contrast with this builder's store-free shape.
      module TxBuilder
        # Assemble (and optionally sign) a transaction over the given
        # resolved input set. The no-change build — used by the deferred
        # path (which staged an unsigned tx) and the +skip_change+ path
        # (zero-output / OP_RETURN-only).
        #
        # @param resolved_inputs [Array<Hash>] resolved input data as
        #   returned by +Store#resolve_inputs_for_signing+. The builder
        #   never calls that method itself; the caller is responsible.
        #   May be empty (no-fund OP_RETURN path).
        # @param caller_outputs [Array<Hash>, nil] BRC-100 +outputs+
        #   array. May be +nil+ or empty.
        # @param caller_inputs [Array<Hash>, nil] caller-supplied input
        #   specs (used by the builder to honour caller-provided
        #   +unlocking_script+ / +sequence_number+ overrides). +nil+
        #   when the wallet selected inputs itself.
        # @param lock_time [Integer, nil] nLockTime.
        # @param version [Integer, nil] transaction version.
        # @param randomize [Boolean] whether to shuffle output order
        #   for privacy.
        # @param sign [Boolean] whether to sign wallet-owned P2PKH
        #   inputs. +false+ leaves them with empty unlocking scripts
        #   (the deferred path serialises an unsigned tx for the caller
        #   to sign later).
        # @return [Hash] +{ wtxid:, raw_tx:, vout_mapping:, tx: }+.
        #   +tx+ is the live +Transaction::Tx+ (signed iff +sign:+).
        def build(resolved_inputs:, caller_outputs:, caller_inputs:,
                  lock_time:, version:, randomize:, sign:)
          raise NotImplementedError
        end

        # Run a fee-fixpoint build over the given resolved input set:
        # derive BRC-42 change outputs, attach P2PKH templates for fee
        # estimation, compare required fee against the input surplus,
        # and either distribute change + sign + return the converged
        # build, or report a shortfall back to the caller.
        #
        # @param resolved_inputs [Array<Hash>] resolved input data as
        #   returned by +Store#resolve_inputs_for_signing+ — taken by
        #   value, never re-fetched.
        # @param caller_outputs [Array<Hash>] BRC-100 +outputs+ array.
        #   May be empty.
        # @param caller_inputs [Array<Hash>, nil] caller-supplied input
        #   specs for custom +unlocking_script+ / +sequence_number+
        #   overrides. +nil+ when the wallet selected inputs itself.
        # @param lock_time [Integer, nil] nLockTime.
        # @param version [Integer, nil] transaction version.
        # @param randomize [Boolean] whether to shuffle output order.
        # @param change_count [Integer] number of BRC-42 change
        #   outputs to derive. Must be >= 1.
        # @param change_basket [String, nil] optional basket name to
        #   stamp on every surviving change output spec (HLR #436).
        #   When set, the Store side writes an +output_baskets+ row per
        #   change output, routing the change into the named basket
        #   (used by +Engine#import_utxo(basket:)+ for tracked imports).
        #   When +nil+ (default), change outputs land unbasketed in the
        #   wallet's pool — the canonical auto-fund behaviour.
        # @return [Hash] one of:
        #   * +{ wtxid:, raw_tx:, tx:, vout_mapping:, change_outputs: }+
        #     on success. +tx+ is the live +Transaction::Tx+;
        #     +change_outputs+ lists only the change rows that survived
        #     SDK +distribute_change+ (possibly empty). Each spec carries
        #     +:basket+ when +change_basket+ was supplied; absent
        #     otherwise.
        #   * +{ shortfall: N }+ when the input surplus does not cover
        #     the required fee — +N+ is the positive deficit
        #     (+required_fee - surplus+) the caller needs to top up.
        def build_change(resolved_inputs:, caller_outputs:, caller_inputs:,
                         lock_time:, version:, randomize:, change_count:,
                         change_basket: nil)
          raise NotImplementedError
        end

        # Finalise the deferred-signing path: apply caller-provided
        # unlocking scripts from +spends+ over the unsigned transaction
        # and sign any remaining wallet-owned P2PKH inputs.
        # *The transaction builder signs.*
        #
        # Store-free: receives the previously-deserialised unsigned tx
        # and the same +resolved_inputs+ shape used by +#build+ /
        # +#build_change+. Validation of +spends+' vins and Store
        # interaction (loading the unsigned raw tx, persisting the
        # signed result) remains on the +Action+ orchestrator.
        #
        # @param tx [BSV::Transaction::Tx] the unsigned transaction
        #   loaded from the staged action row, with one input per
        #   resolved row.
        # @param resolved_inputs [Array<Hash>] resolved input data —
        #   same shape +#build+ / +#build_change+ consume.
        # @param spends [Hash{Integer => Hash}] vin =>
        #   +{ unlocking_script:, sequence_number: }+ — caller-provided
        #   spend overrides.
        # @return [Array(String, String, BSV::Transaction::Tx)]
        #   +[wtxid, raw_tx, tx]+ — +tx+ is the signed
        #   +Transaction::Tx+ with source data wired in (needed
        #   downstream for EF serialisation).
        def apply_spends(tx:, resolved_inputs:, spends:)
          raise NotImplementedError
        end
      end
    end
  end
end
