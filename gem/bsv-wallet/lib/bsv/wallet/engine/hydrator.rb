# frozen_string_literal: true

using BSV::Wallet::Txid

module BSV
  module Wallet
    class Engine
      # Hydration over the persisted proof store.
      #
      # Given a signed transaction and the action it belongs to, the
      # Hydrator walks the ProofStore recursively until every input's
      # +source_transaction+ graph terminates at a merkle-proven leaf,
      # then assembles the Atomic BEEF the wallet ships to its peer and
      # proves it structurally valid before handoff. See
      # +Interface::Hydrator+ for the full contract.
      #
      # Store-reading (in deliberate contrast with +TxBuilder+'s
      # store-free shape): the +store:+ handle is the only dependency.
      # +validate_for_handoff!+ self-constructs its own
      # +TrustedSelfChainTracker+ — the egress self-trust model the
      # Hydrator owns, not an engine dependency.
      #
      # +wire_ancestor+ is public — the one-way primitive the later
      # BeefImporter (ingress) extraction consumes for trustSelf
      # hydration of incoming BEEFs.
      class Hydrator
        include BSV::Wallet::Interface::Hydrator

        # Construct a hydrator. Explicit DI: no engine back-reference,
        # no +chain_tracker+ injection. The hydrator reads the store via
        # +find_proof+ (during +wire_ancestor+) and
        # +resolve_inputs_for_signing+ (during +build_atomic_beef+).
        def initialize(store:)
          @store = store
        end

        # See +Interface::Hydrator#wire_ancestor+.
        def wire_ancestor(wtxid, visited: Set.new)
          return if visited.include?(wtxid)

          visited.add(wtxid)

          proof = @store.find_proof(wtxid: wtxid)
          return unless proof && proof[:raw_tx] && proof[:raw_tx].bytesize >= 10

          tx = BSV::Transaction::Tx.from_binary(proof[:raw_tx])

          if proof[:merkle_path]
            tx.merkle_path = BSV::Transaction::MerklePath.from_binary(proof[:merkle_path]).first
            return tx # Proven terminal — no need to recurse
          end

          # Unconfirmed: wire each input's source recursively
          tx.inputs.each do |input|
            ancestor = wire_ancestor(input.prev_wtxid, visited: visited)
            input.source_transaction = ancestor if ancestor
          end

          tx
        end

        # See +Interface::Hydrator#build_atomic_beef+.
        #
        # Outgoing BEEF: constructed from our own ProofStore —
        # verification is for incoming untrusted data only (see
        # +Action#verify_incoming_transaction!+).
        def build_atomic_beef(raw_tx, action_id)
          tx = BSV::Transaction::Tx.from_binary(raw_tx)
          resolved_inputs = @store.resolve_inputs_for_signing(action_id: action_id)

          resolved_inputs.each_with_index do |resolved, idx|
            input = tx.inputs[idx]
            next unless input

            input.source_transaction = wire_ancestor(resolved[:source_wtxid])
          end

          beef = BSV::Transaction::Beef.new
          beef.merge_transaction(tx)

          # Count parity: the assembled BEEF must hold exactly the
          # transactions reachable through the in-memory source_transaction
          # graph we just wired — nothing silently dropped during merge.
          # (Proof closure — every leaf terminating at a merkle_path — is a
          # separate concern, enforced by validate_for_handoff!.)
          walked = count_wired_transactions(tx)
          if beef.transactions.length != walked
            raise BSV::Wallet::EgressBeefInvalidError,
                  'egress assembly count parity: wired ancestry holds ' \
                  "#{walked} transaction(s) but the BEEF holds " \
                  "#{beef.transactions.length} " \
                  "(subject dtxid=#{tx.wtxid.to_dtxid})"
          end

          beef.to_atomic_binary(tx.wtxid)
        end

        # See +Interface::Hydrator#validate_for_handoff!+.
        #
        # The wallet trusts its own persisted proofs (those were
        # validated against a real chain_tracker at proof-arrival time),
        # so a structural-only verify with +TrustedSelfChainTracker+ is
        # sufficient and correct here: pass iff every leaf in the BEEF
        # terminates at a +merkle_path+ or wires through to one. Failure
        # means the wallet's state cannot produce a valid handoff BEEF —
        # almost always an upstream proof-closure gap that should have
        # been caught at import or +save_beef_proofs+ time.
        def validate_for_handoff!(atomic_beef, subject_wtxid)
          # Deliberate: re-parse the serialised bytes rather than verifying
          # the in-memory tx build_atomic_beef already wired. This checks
          # exactly what a peer receives over the wire — the SPV-honesty
          # contract — not just our in-memory graph. The duplicate parse +
          # walk stays below broadcast latency, so the correctness assurance
          # is well worth the cost; do NOT rewrite this to verify the
          # in-memory object without re-opening that trade-off (#299).
          beef = BSV::Transaction::Beef.from_binary(atomic_beef)
          subject_entry = beef.transactions.find { |e| e.wtxid == subject_wtxid }
          unless subject_entry&.transaction
            raise BSV::Wallet::EgressBeefInvalidError,
                  "egress validation: subject dtxid=#{subject_wtxid.to_dtxid} " \
                  'missing from constructed BEEF (internal inconsistency)'
          end

          subject_entry.transaction.verify(chain_tracker: BSV::Wallet::TrustedSelfChainTracker.new)
        rescue BSV::Transaction::VerificationError => e
          raise BSV::Wallet::EgressBeefInvalidError,
                'wallet refuses to ship structurally invalid BEEF: ' \
                "#{e.code} — #{e.message}. Upstream proof closure is incomplete " \
                '(likely an ancestor missing merkle_path); investigate import / ' \
                'save_beef_proofs path.'
        end

        private

        # Distinct transactions reachable through the in-memory
        # +source_transaction+ graph rooted at +tx+ (the subject counted).
        # Deduplicated by wtxid so a diamond ancestry counts once, matching
        # how +Beef#merge_transaction+ deduplicates its entries.
        def count_wired_transactions(tx, seen = Set.new)
          return 0 if seen.include?(tx.wtxid)

          seen.add(tx.wtxid)
          1 + tx.inputs.sum do |input|
            input.source_transaction ? count_wired_transactions(input.source_transaction, seen) : 0
          end
        end
      end
    end
  end
end
