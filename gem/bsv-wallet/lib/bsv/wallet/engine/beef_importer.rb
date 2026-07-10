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
                   trust_self: nil, known_txids: nil)
          # Parse tx: as Atomic BEEF (BRC-95)
          beef, subject_tx = parse_beef(tx)

          # trustSelf: the sender may have included TXID-only entries for ancestors
          # they know we have. from_binary can't wire those (no Transaction::Tx object),
          # so hydrate any unresolved inputs from our ProofStore before verification.
          hydrate_known_sources!(subject_tx) if trust_self == 'known'

          # HLR #516 Sub 5 — read path. Pre-seed the SDK's +verified:+
          # accumulator with wtxids the wallet has already verified in an
          # earlier walk AND whose anchors are still live under the
          # current chain view. +AnchorLivenessCache+ owns re-org
          # invalidation before returning the trust set (Sub 6), so a
          # cache-hit that would be stale by the time we consume it is
          # already cleared. +TrustedSelfChainTracker+ can't detect
          # re-orgs (every height stubs to +unknown+), so its trust set
          # would be silently stale — skip the short-circuit in that
          # configuration and pay for the full walk. Sub 5.
          trusted = pre_seed_trust_set(beef)
          verified_wtxids = trusted.to_h { |w| [w, true] }
          verify_incoming_transaction!(subject_tx, verified: verified_wtxids)

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
          #
          # +CompetingBlockHeaderError+ (raised by +find_or_create_block+ when
          # an ancestor's BUMP disagrees with the persisted +blocks+ row) is
          # translated to +InvalidBeefError+ at this boundary so the
          # +Interface::BeefImporter#import+ contract stays honest — every
          # ingress failure surfaces as +InvalidBeefError+; consumers don't
          # need to know a new error type exists. The re-org signal is not
          # lost: the message carries the +competing_header+ tag, and
          # anchor-liveness (once Sub 5 wires it) runs at ingress top before
          # the ancestor loop, so a genuine re-org invalidates the stale
          # +blocks+ row before we get here. #533 code-review.
          pending_hydrator_enrichments = []
          @store.db.transaction do
            action_result = @store.create_action(
              action: { description: description, broadcast_intent: :none }
            )
            @store.sign_action(
              action_id: action_result[:id], wtxid: subject_tx.wtxid, raw_tx: subject_tx.to_binary
            )
            @store.save_proof(wtxid: subject_tx.wtxid, proof: { raw_tx: subject_tx.to_binary })
            BSV.logger&.debug { "[Engine::BeefImporter] import: subject=#{subject_tx.dtxid}" }

            # HLR #521 — trust claim: ingress-path lifecycle annotation. The
            # subject tx was externally built (BEEF came from a caller), so
            # +self_built+ names the wallet's ingress-completion pattern here,
            # not construction of the tx bytes. Sub 2's SPV mark below runs in
            # the SAME atomic transaction and upgrades the subject's
            # verified_via to +'spv'+ (stronger); this ordering matters because
            # +mark_verified+'s monotonic predicate is on +verifier_version+
            # only — a self_built write AFTER the SPV mark would silently
            # downgrade. Sub 5 excludes +self_built+ from the trust set anyway,
            # but keep the ordering explicit for future audits.
            @store.mark_verified(
              wtxid: subject_tx.wtxid,
              via: BSV::Wallet::Store::Models::TxProof::VERIFIED_VIA_SELF_BUILT
            )

            attach_labels(action_result[:id], labels)

            # Save ancestor proofs BEFORE replacing known ancestors with TXID-only.
            # save_beef_proofs iterates beef.transactions and skips TxidOnlyEntry —
            # if we replaced first, ancestors listed in known_txids but not yet in
            # ProofStore would be converted to TXID-only and their proofs lost.
            # Returns pending Hydrator enrichments — flushed AFTER the outer
            # transaction commits so a rollback doesn't leave ghost anchors in
            # the in-memory cache. #533 code-review.
            pending_hydrator_enrichments.concat(
              save_beef_proofs(beef, subject_tx.wtxid, action_result[:id])
            )

            # Phase C ingress invariant (#296): assert the proof closure
            # save_beef_proofs was supposed to land actually landed, BEFORE
            # replace_known_ancestors! mutates the BEEF to TXID-only. A miss
            # rolls the whole ingress back (principle of state — never a
            # half-imported action whose ancestry can't be reproduced).
            assert_proofs_complete!(beef)

            # HLR #516 Sub 2 — populate the verification cache. Trust claim:
            # every wtxid in +newly_walked+ is a tx that +Tx#verify+ itself
            # walked and validated in the call above, including the merkle-
            # path short-circuit at proven leaves (SDK-owned; the wallet
            # does not re-implement the walk — an earlier revision tried
            # and the white-hat review caught the drift).
            #
            # Sub 5 subtracts +trusted+ (pre-seeded wtxids) from the SDK
            # accumulator's key set before marking. Without this,
            # pre-seeded rows carrying +'broadcast_ack'+ would be silently
            # upgraded to +'spv'+ under +mark_verified_batch+'s monotonic
            # ladder — the merkle proof was NOT re-run for a seeded
            # ancestor, so the SPV claim would be a lie. Newly walked
            # rows carry a legitimate SPV mark; pre-seeded rows keep
            # their prior +verified_via+ (already at least as strong as
            # what they're being asked to survive).
            #
            # Non-atomic BEEF (BRC-62) sibling entries not reached by
            # +Tx#verify+ stay uncached — the accumulator only captures
            # nodes the SDK actually visited.
            #
            # Cache write joins this same +db.transaction+ block; a
            # downstream failure (promote_action) rolls back the marks
            # alongside the proof/action rows (ADR-033).
            newly_walked = verified_wtxids.keys - trusted.to_a
            @store.mark_verified_batch(
              wtxids: newly_walked,
              via: BSV::Wallet::Store::Models::TxProof::VERIFIED_VIA_SPV
            )

            # trustSelf: replace known ancestors with TXID-only entries.
            # This runs AFTER save_beef_proofs so no proof data is lost, and
            # AFTER verify so the full graph was already validated.
            # make_txid_only replaces entries in the BEEF's @transactions list but
            # does NOT invalidate in-memory source_transaction pointers wired by
            # from_binary — verify already walked those pointers successfully above.
            replace_known_ancestors!(beef, subject_tx.wtxid, known_txids) if trust_self == 'known'

            @store.promote_action(action_id: action_result[:id], outputs: output_specs)
          end

          # Post-commit — the transaction succeeded, so the Hydrator
          # can now safely be told about the proofs we persisted.
          # A pre-commit failure would have raised out of the block
          # above without reaching this point, so ghost anchors are
          # impossible.
          flush_hydrator_enrichments(pending_hydrator_enrichments)

          { accepted: true }
        rescue BSV::Wallet::CompetingBlockHeaderError => e
          raise BSV::Wallet::InvalidBeefError,
                "BEEF ancestor at height #{e.height} conflicts with persisted block header " \
                '(cause=competing_header — likely re-org or torn BEEF)'
        end

        # Resolve the merkle path a BEEF entry carries, whether wired directly
        # onto the transaction or referenced indirectly via its BUMP index.
        # Public class method so every BEEF traversal that needs "which
        # entries are merkle-bearing" funnels through one definition —
        # save_beef_proofs (what to persist), assert_proofs_complete! (what
        # should have persisted), and Broadcast#cache_beef_transactions
        # (what to cache as terminal) all share the answer.
        def self.merkle_path_for(beef, beef_tx)
          return beef_tx.transaction.merkle_path if beef_tx.transaction.merkle_path
          return nil unless beef_tx.respond_to?(:bump_index) && beef_tx.bump_index

          beef.bumps[beef_tx.bump_index]
        end

        private

        # HLR #516 Sub 5 — compute the read-path trust set for this
        # BEEF's ancestor graph. Returns an empty Set when the wallet
        # cannot verify anchor liveness; otherwise delegates to a
        # per-walk +AnchorLivenessCache+ that resolves fresh roots,
        # invalidates stale anchors + their structural descendants, and
        # returns the surviving trust set.
        #
        # +chain_tracker_supports_liveness?+ combines a positive
        # capability check (does the tracker implement
        # +known_roots_for_heights+ at all?) with an explicit exclusion
        # for +TrustedSelfChainTracker+ (implements the method but
        # returns +nil+ for every height — "safe but useless" per its
        # own docstring). Missing method would surface as
        # +NoMethodError+ inside +AnchorLivenessCache#known_roots_for+,
        # swallowed by the broad rescue in +filter_trusted+ as
        # "unknown" → +invalidate_stale_anchors!+ preserves the full
        # trust set → every previously-verified wtxid remains "trusted"
        # regardless of the actual chain state. Fail closed on both
        # variants: pay for the full walk instead. White-hat on #537.
        def pre_seed_trust_set(beef)
          return Set.new unless chain_tracker_supports_liveness?

          wtxids = beef.transactions.filter_map do |beef_tx|
            next if beef_tx.is_a?(BSV::Transaction::Beef::TxidOnlyEntry)

            beef_tx.transaction&.wtxid
          end
          return Set.new if wtxids.empty?

          AnchorLivenessCache.new(store: @store, chain_tracker: @chain_tracker)
                             .filter_trusted(wtxids)
        end

        def chain_tracker_supports_liveness?
          return false unless @chain_tracker.respond_to?(:known_roots_for_heights)
          return false if @chain_tracker.is_a?(BSV::Wallet::TrustedSelfChainTracker)

          true
        end

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
        def verify_incoming_transaction!(subject_tx, verified: nil)
          raise BSV::Wallet::InvalidBeefError, 'chain_tracker required for SPV verification' unless @chain_tracker

          # +verified:+ (bsv-sdk 0.26+) is a caller-supplied accumulator the
          # SDK writes into as it walks the ancestor graph. Callers who want
          # the walked wtxid set (HLR #516 Sub 2 — persistent verification
          # cache write) pass a mutable Hash; the SDK owns the walk, we read
          # +verified.keys+ after verify returns.
          subject_tx.verify(chain_tracker: @chain_tracker, verified: verified)
        rescue BSV::Transaction::VerificationError => e
          raise BSV::Wallet::InvalidBeefError, "SPV verification failed: #{e.message} (#{e.code})"
        end

        # Save merkle proofs from a parsed BEEF to ProofStore.
        # Links the subject transaction's proof to the action when present.
        #
        # @param beef [Transaction::Beef] parsed BEEF bundle
        # @param subject_wtxid [String] 32-byte wtxid of the subject transaction (wire order)
        # @param action_id [Integer] the action to link the subject proof to
        # Persists each BEEF ancestor's proof via +Store#save_proof+ and
        # accumulates a list of Hydrator-enrichment records for the
        # caller to flush AFTER the outer +db.transaction+ commits.
        #
        # Why accumulate rather than call +proof_arrived+ inline: the
        # Hydrator is an in-memory cache with no rollback hook. If a
        # later step in the outer transaction (or a subsequent ancestor
        # in this loop) raises, the +db.transaction+ rolls back every
        # +tx_proofs+ row — but any +proof_arrived+ side-effects
        # already applied to the Hydrator survive, poisoning the cache
        # with terminals that don't exist in the DB. Returning the
        # enrichments lets +#import+ flush them post-commit, so
        # rollback leaves the Hydrator untouched. #533 code-review.
        def save_beef_proofs(beef, subject_wtxid, action_id)
          BSV::Primitives::Hex.validate_wtxid!(subject_wtxid, name: 'save_beef_proofs subject_wtxid')
          subject_proof_id = nil
          pending_enrichments = []

          beef.transactions.each do |beef_tx|
            next if beef_tx.is_a?(BSV::Transaction::Beef::TxidOnlyEntry)
            next unless beef_tx.transaction

            wtxid = beef_tx.transaction.wtxid
            merkle_path = self.class.merkle_path_for(beef, beef_tx)

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
            # Accumulate for post-commit flush — see method docstring.
            # Without post-commit flushing, a mid-transaction raise would
            # leave the Hydrator with ghost anchors the DB doesn't back.
            # The former #296 Phase D monotonic enrichment invariant still
            # holds: every save_proof site still informs the substrate; the
            # substrate call just happens AFTER commit.
            #
            # Only enqueue when a Hydrator is attached, and reuse the
            # bytes already computed for +proof+ — a large BEEF's
            # multi-MB +raw_tx+ shouldn't be re-serialised into a
            # discard hash. Copilot on #533.
            next unless @hydrator

            pending_enrichments << {
              wtxid: wtxid,
              raw_tx: proof[:raw_tx],
              merkle_path: proof[:merkle_path]
            }
          end

          @store.link_proof(action_id: action_id, tx_proof_id: subject_proof_id) if subject_proof_id
          pending_enrichments
        end

        # Post-commit flush of the Hydrator enrichments accumulated
        # during +save_beef_proofs+. Runs OUTSIDE the outer
        # +db.transaction+ so a rollback leaves the Hydrator cache
        # untouched. #533 code-review.
        def flush_hydrator_enrichments(enrichments)
          return unless @hydrator

          # The ingress transaction has already committed. Hydrator
          # enrichment is an in-memory hot-path optimisation — losing
          # an update means the next +wire_ancestor+ walk will re-fetch
          # from +tx_proofs+, which is correct fallback behaviour. Any
          # exception here (a runaway cache, an OOM on +put+) must NOT
          # surface as an ingress failure, because the ingress SUCCEEDED.
          # Rescue and log at +warn+. Copilot on #533.
          enrichments.each do |enrichment|
            @hydrator.proof_arrived(**enrichment)
          rescue StandardError => e
            BSV.logger&.warn do
              '[Engine::BeefImporter] hydrator enrichment failed post-commit ' \
                "wtxid=#{enrichment[:wtxid].to_dtxid} error=#{e.message}"
            end
          end
        end

        # Phase C ingress completeness invariant (#296). Post-condition over
        # save_beef_proofs: walk the same entries under the same skip rules and
        # assert each was actually persisted — raw_tx present, and any
        # merkle-bearing entry kept its merkle_path. A failure means
        # save_beef_proofs silently dropped a proof, leaving an action whose
        # ancestry the wallet could not later reproduce for egress; raising
        # rolls the ingress transaction back.
        #
        # Always-on, mirroring the egress validate_for_handoff! check — the
        # cost is a find_proof read per entry, far below the egress re-parse +
        # structural SPV walk that already runs unconditionally.
        def assert_proofs_complete!(beef)
          beef.transactions.each do |beef_tx|
            next if beef_tx.is_a?(BSV::Transaction::Beef::TxidOnlyEntry)
            next unless beef_tx.transaction

            wtxid = beef_tx.transaction.wtxid
            stored = @store.find_proof(wtxid: wtxid)

            if stored.nil? || stored[:raw_tx].nil?
              raise BSV::Wallet::InvalidBeefError,
                    "ingress proof closure: dtxid=#{wtxid.to_dtxid} was not " \
                    'persisted by save_beef_proofs'
            end

            next unless self.class.merkle_path_for(beef, beef_tx) && stored[:merkle_path].nil?

            raise BSV::Wallet::InvalidBeefError,
                  "ingress proof closure: dtxid=#{wtxid.to_dtxid} carried a " \
                  'merkle_path but the persisted proof has none'
          end
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
        #
        # Both protocols ingest wallet-bound outputs (the whole point of
        # +internalizeAction+), so +spendable_intent+ is set to +'spendable'+
        # explicitly per HLR #467 / +docs/reference/intent-and-outcomes.md+ —
        # never inferred from the presence of derivation fields downstream.
        def resolve_internalize_output(out)
          spec = { satoshis: out[:satoshis] || 0, vout: out[:output_index] || 0,
                   spendable_intent: 'spendable' }

          case out[:protocol]
          when :wallet_payment, 'wallet payment'
            rem = out[:payment_remittance] || {}
            spec[:derivation_prefix]  = rem[:derivation_prefix]
            spec[:derivation_suffix]  = rem[:derivation_suffix]
            spec[:sender_identity_key] = rem[:sender_identity_key]
            # BRC-29 wallet payment carries no basket on the wire (the
            # spec's +paymentRemittance+ is the derivation triple only).
            # The wallet's own CLI can supply a basket as a top-level
            # sibling of +:protocol+ — used by +bin/wallet receive
            # --basket=<name>+ to route incoming BRC-29 funds. Engine
            # consumers that don't need a basket simply omit the key.
            spec[:basket] = out[:basket] if out[:basket]
          when :basket_insertion, 'basket insertion'
            rem = out[:insertion_remittance] || {}
            spec[:basket]              = rem[:basket]
            spec[:custom_instructions] = rem[:custom_instructions]
            spec[:tags]                = rem[:tags]
            spec[:derivation_prefix]   = rem[:derivation_prefix]
            spec[:derivation_suffix]   = rem[:derivation_suffix]
            spec[:sender_identity_key] = rem[:sender_identity_key]
            # Basket insertion: no derivation triple → root-key ownership
            # (locking script matches the wallet's per-instance root P2PKH;
            # enforced declaratively by +outputs.spendable_recoverable+).
            # The +spendable_intent: 'spendable'+ above already encodes the
            # ownership — no separate marker required.
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
