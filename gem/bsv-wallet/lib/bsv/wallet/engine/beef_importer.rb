# frozen_string_literal: true

using BSV::Wallet::Txid

module BSV
  module Wallet
    class Engine
      # Ingress of an incoming BEEF.
      #
      # Given a binary Atomic BEEF (BRC-95), this class parses the
      # bundle, runs full SPV verification of the subject transaction,
      # persists the subject as an incoming +broadcast_intent 'none'+
      # action row, saves every ancestor's merkle proof, optionally
      # trims known ancestors back to TXID-only, and promotes the
      # caller-named outputs into the canonical UTXO set. See
      # +Interface::BeefImporter+ for the full contract.
      #
      # Store-reading by design (the +store:+ handle is read and
      # written), with two further dependencies attached: a
      # +chain_tracker:+ for SPV verification — the incoming graph is
      # untrusted, so a real tracker is required — and a +hydrator:+
      # consumed one-way for trustSelf hydration of TXID-only entries
      # the sender skipped.
      #
      # No +key_deriver+ — ingress derives nothing. Output derivation
      # params are caller-supplied via the +outputs+ array and flow
      # through +resolve_internalize_output+ as-is.
      class BeefImporter
        include BSV::Wallet::Interface::BeefImporter

        # Construct a BeefImporter. Explicit DI: no engine
        # back-reference. The +chain_tracker+ may be +nil+ at
        # construction time (some engine configurations omit it) —
        # +#import+ raises +InvalidBeefError+ at the SPV step in that
        # case, mirroring the previous +Action.internalize+ guard.
        def initialize(store:, chain_tracker:, hydrator:)
          @store = store
          @chain_tracker = chain_tracker
          @hydrator = hydrator
        end

        # See +Interface::BeefImporter#import+.
        def import(tx:, outputs:, description:, labels: nil,
                   trust_self: nil, known_txids: nil,
                   seek_permission: true, originator: nil)
          # Parse tx: as Atomic BEEF (BRC-95)
          beef, subject_tx = parse_beef(tx)

          # trustSelf: the sender may have included TXID-only entries for ancestors
          # they know we have. from_binary can't wire those (no Transaction::Tx object),
          # so hydrate any unresolved inputs from our ProofStore before verification.
          hydrate_known_sources!(subject_tx) if trust_self == 'known'

          # Full SPV verification: scripts, merkle proofs, and fee adequacy
          # (output <= input). Replaces the former validate_beef! +
          # validate_fee_adequacy! two-step.
          verify_incoming_transaction!(subject_tx)

          # Resolve + validate the caller's outputs against the parsed subject
          # tx BEFORE any persistence (#362). A malformed request — non-Array
          # outputs, a vout the subject lacks, a declared-satoshis mismatch —
          # fails with InvalidParameterError without leaving a created+signed
          # action that was never promoted.
          output_specs = resolve_output_specs(subject_tx, outputs)

          # Single transaction: a failure anywhere in the ingress (proof save,
          # promotion) rolls the whole thing back — no dangling internal action
          # (#327 / #362). There is no broadcast to wait for, so the entire
          # incoming-BEEF ingress commits atomically.
          @store.db.transaction do
            action_result = @store.create_action(
              action: { description: description, broadcast_intent: :none }
            )
            @store.sign_action(
              action_id: action_result[:id], wtxid: subject_tx.wtxid, raw_tx: subject_tx.to_binary
            )
            @store.save_proof(wtxid: subject_tx.wtxid, proof: { raw_tx: subject_tx.to_binary })
            BSV.logger&.debug { "[Engine::BeefImporter] import: subject=#{subject_tx.dtxid}" }

            attach_labels(action_result[:id], labels)

            # Save ancestor proofs BEFORE replacing known ancestors with TXID-only.
            # save_beef_proofs iterates beef.transactions and skips TxidOnlyEntry —
            # if we replaced first, ancestors listed in known_txids but not yet in
            # ProofStore would be converted to TXID-only and their proofs lost.
            save_beef_proofs(beef, subject_tx.wtxid, action_result[:id])

            # trustSelf: replace known ancestors with TXID-only entries.
            # This runs AFTER save_beef_proofs so no proof data is lost, and
            # AFTER verify so the full graph was already validated.
            # make_txid_only replaces entries in the BEEF's @transactions list but
            # does NOT invalidate in-memory source_transaction pointers wired by
            # from_binary — verify already walked those pointers successfully above.
            replace_known_ancestors!(beef, subject_tx.wtxid, known_txids) if trust_self == 'known'

            @store.promote_action(action_id: action_result[:id], outputs: output_specs)
          end

          { accepted: true }
        end

        private

        # Attach labels to the action via Store primitives. Two-call
        # mirror of +Action.attach_labels+ inlined here so BeefImporter
        # has zero engine coupling; the porcelain class method on
        # +Action+ is unchanged.
        def attach_labels(action_id, labels)
          return unless labels&.any?

          label_ids = @store.find_or_create_labels(names: labels)
          @store.label_action(action_id: action_id, label_ids: label_ids)
        end

        # Parse the +tx:+ parameter as BEEF and extract the subject transaction.
        #
        # @param data [String] binary BEEF data (Atomic, V1, or V2)
        # @return [Array(Transaction::Beef, Transaction::Tx)]
        # @raise [InvalidBeefError] if the data is invalid or the subject tx
        #   is missing.
        def parse_beef(data)
          beef = BSV::Transaction::Beef.from_binary(data)

          raise BSV::Wallet::InvalidBeefError, 'BEEF contains no transactions' if beef.transactions.empty?

          subject_wtxid = beef.subject_wtxid
          subject_tx = if subject_wtxid
                         beef.find_atomic_transaction(subject_wtxid)
                       else
                         # Non-atomic BEEF: the last transaction is the subject
                         beef.transactions.last&.transaction
                       end

          raise BSV::Wallet::InvalidBeefError, 'subject transaction not found in BEEF' unless subject_tx

          [beef, subject_tx]
        rescue ArgumentError => e
          raise BSV::Wallet::InvalidBeefError, e.message
        end

        # Hydrate inputs whose source_transaction is nil from ProofStore.
        #
        # Used by trustSelf: the sender may include TXID-only entries for ancestors
        # they know we have. from_binary can't wire those (no Transaction::Tx object).
        # This fills the gaps from local storage so verify can walk the full graph.
        #
        # @param tx [Transaction::Tx] transaction to hydrate
        def hydrate_known_sources!(tx)
          tx.inputs.each do |input|
            next if input.source_transaction

            input.source_transaction = @hydrator.wire_ancestor(input.prev_wtxid)
          end
        end

        # Full SPV verification of an incoming transaction via the SDK.
        #
        # Replaces validate_beef! + validate_fee_adequacy! with a single
        # Transaction::Tx#verify call that checks scripts, merkle proofs, and
        # fee adequacy (output <= input).
        #
        # @param subject_tx [Transaction::Tx]
        # @raise [InvalidBeefError] wrapping SDK VerificationError
        def verify_incoming_transaction!(subject_tx)
          raise BSV::Wallet::InvalidBeefError, 'chain_tracker required for SPV verification' unless @chain_tracker

          subject_tx.verify(chain_tracker: @chain_tracker)
        rescue BSV::Transaction::VerificationError => e
          raise BSV::Wallet::InvalidBeefError, "SPV verification failed: #{e.message} (#{e.code})"
        end

        # Save merkle proofs from a parsed BEEF to ProofStore.
        # Links the subject transaction's proof to the action when present.
        #
        # @param beef [Transaction::Beef] parsed BEEF bundle
        # @param subject_wtxid [String] 32-byte wtxid of the subject transaction (wire order)
        # @param action_id [Integer] the action to link the subject proof to
        def save_beef_proofs(beef, subject_wtxid, action_id)
          BSV::Primitives::Hex.validate_wtxid!(subject_wtxid, name: 'save_beef_proofs subject_wtxid')
          subject_proof_id = nil

          beef.transactions.each do |beef_tx|
            next if beef_tx.is_a?(BSV::Transaction::Beef::TxidOnlyEntry)
            next unless beef_tx.transaction

            wtxid = beef_tx.transaction.wtxid
            merkle_path = beef_tx.transaction.merkle_path ||
                          (beef_tx.respond_to?(:bump_index) && beef_tx.bump_index &&
                           beef.bumps[beef_tx.bump_index])

            proof = { raw_tx: beef_tx.transaction.to_binary }
            if merkle_path
              proof[:height] = merkle_path.block_height
              proof[:merkle_path] = merkle_path.to_binary
            end

            proof_id = @store.save_proof(wtxid: wtxid, proof: proof)
            # Only capture the subject's proof_id when it actually carries a
            # merkle_path. Without this guard, an incoming BEEF whose subject
            # has no BUMP (raw_tx-only) would link the action to a placeholder
            # proof row with no chain anchor, making the action falsely appear
            # "proven". Acquisition of the real proof happens later via the
            # daemon's proof-acquisition task (#167). Per #177.
            subject_proof_id = proof_id if wtxid == subject_wtxid && merkle_path
          end

          @store.link_proof(action_id: action_id, tx_proof_id: subject_proof_id) if subject_proof_id
        end

        # Replace known ancestor transactions with TXID-only entries in the BEEF.
        #
        # An ancestor is "known" if it has a proof in ProofStore or its wtxid
        # appears in the known_wtxids array. The subject transaction is never
        # replaced.
        #
        # @param beef [Transaction::Beef] the BEEF bundle to modify
        # @param subject_wtxid [String] 32-byte subject wtxid (wire order, never replaced)
        # @param known_wtxids [Array<String>, nil] additional known wtxids (wire order binary)
        # @return [Boolean] true if any entries were replaced
        def replace_known_ancestors!(beef, subject_wtxid, known_wtxids)
          known_set = Set.new(known_wtxids || [])
          replaced_count = 0

          beef.transactions.each do |beef_tx|
            wtxid = beef_tx.wtxid
            next if wtxid == subject_wtxid
            next if beef_tx.is_a?(BSV::Transaction::Beef::TxidOnlyEntry)

            next unless known_set.include?(wtxid) || @store.proof_exists?(wtxid: wtxid)

            BSV.logger&.debug { "[Engine::BeefImporter] replace_known_ancestors!: replacing dtxid=#{wtxid.to_dtxid}" }
            beef.make_txid_only(wtxid)
            replaced_count += 1
          end

          BSV.logger&.debug { "[Engine::BeefImporter] replace_known_ancestors!: replaced_count=#{replaced_count}" }
          replaced_count.positive?
        end

        # Translate a BRC-100 internalize output spec into a Store output spec.
        #
        # Branches on +out[:protocol]+: +:wallet_payment+ carries derivation
        # under +:payment_remittance+; +:basket_insertion+ under
        # +:insertion_remittance+ (with the basket-insertion "no derivation
        # means root-key ownership" convention).
        def resolve_internalize_output(out)
          spec = { satoshis: out[:satoshis] || 0, vout: out[:output_index] || 0 }

          case out[:protocol]
          when :wallet_payment, 'wallet payment'
            rem = out[:payment_remittance] || {}
            spec[:derivation_prefix]  = rem[:derivation_prefix]
            spec[:derivation_suffix]  = rem[:derivation_suffix]
            spec[:sender_identity_key] = rem[:sender_identity_key]
          when :basket_insertion, 'basket insertion'
            rem = out[:insertion_remittance] || {}
            spec[:basket]              = rem[:basket]
            spec[:custom_instructions] = rem[:custom_instructions]
            spec[:tags]                = rem[:tags]
            spec[:derivation_prefix]   = rem[:derivation_prefix]
            spec[:derivation_suffix]   = rem[:derivation_suffix]
            spec[:sender_identity_key] = rem[:sender_identity_key]
            # Basket insertion protocol: no derivation fields means root-key
            # ownership — a protocol-level semantic, not a guess from a missing
            # column. The 'root' output_type shim is retained verbatim here
            # pending #60 (which replaces the inference with explicit typing).
            spec[:output_type] = 'root' unless rem[:derivation_prefix]
          end

          spec
        end

        # Resolve every caller output into a promotable Store spec, validating
        # against the parsed subject tx. Pure (no persistence) so it runs before
        # the ingress transaction opens — a bad request fails clean (#362).
        def resolve_output_specs(subject_tx, outputs)
          raise BSV::Wallet::InvalidParameterError.new('outputs', "expected an array, got #{outputs.class}") unless outputs.is_a?(Array)

          outputs.map do |out|
            spec = resolve_internalize_output(out)
            tx_out = subject_tx.outputs[spec[:vout]]
            unless tx_out
              raise BSV::Wallet::InvalidParameterError.new(
                'output_index',
                "vout #{spec[:vout]} does not exist in subject transaction (#{subject_tx.outputs.length} outputs)"
              )
            end
            spec[:locking_script] = tx_out.locking_script.to_binary
            if spec[:satoshis]&.positive? && spec[:satoshis] != tx_out.satoshis
              raise BSV::Wallet::InvalidParameterError.new(
                'satoshis',
                "declared satoshis #{spec[:satoshis]} != transaction output #{tx_out.satoshis} at vout #{spec[:vout]}"
              )
            end
            spec[:satoshis] = tx_out.satoshis
            spec
          end
        end
      end
    end
  end
end
