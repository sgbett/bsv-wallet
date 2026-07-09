# frozen_string_literal: true

using BSV::Wallet::Txid

module BSV
  module Wallet
    class Engine
      # Anchor-liveness orchestrator for the persistent verification
      # cache (HLR #516 Sub 6.1).
      #
      # Per-verify-walk collaborator: constructed fresh for each
      # +BeefImporter#import+ so the batched +known_roots_for_heights+
      # memo cannot leak across walks. The tick-scoped
      # +current_height+ memo lives elsewhere (chain-tracker instance);
      # this class only memoises the height→root map for the walk it
      # was built to serve — necessary for re-org safety, not merely
      # for throughput.
      #
      # Collaborators are supplied by the caller (explicit DI); no
      # engine back-reference.
      class AnchorLivenessCache
        # @param store [BSV::Wallet::Store]
        # @param chain_tracker [#known_roots_for_heights] a tracker that
        #   supports the batched merkle-root lookup — production
        #   choices are +BSV::Network::ChainTracker+ and
        #   +BSV::Network::SpvHeaderChainTracker+. Never wire
        #   +BSV::Wallet::TrustedSelfChainTracker+ here (it stubs every
        #   height to "unknown" — safe but useless).
        def initialize(store:, chain_tracker:)
          @store = store
          @chain_tracker = chain_tracker
        end

        # Filter +wtxids+ to the subset the wallet may still trust.
        #
        # Pipeline:
        #   1. Read the heights of the verified proofs backing this
        #      wtxid set (one indexed query, no anchor invalidation yet).
        #   2. Ask the chain_tracker for the current wire-order root at
        #      each height — one batched call, memoised for the life of
        #      this instance so the walk cannot double-fetch.
        #   3. Hand the +{ height => root }+ map to
        #      +Store#invalidate_stale_anchors!+ (pure writer). Returns
        #      the invalidated anchor +action_ids+.
        #   4. HLR #516 Sub 6.2 — walk the structural descent from those
        #      anchors via +Store#descendant_action_ids_of+ and coarse-
        #      clear all verified descendants via
        #      +Store#invalidate_verification+. The UPDATE inside the
        #      shared primitive is gated on +verified_via IS NOT NULL+,
        #      so unmarked structural descendants (adversarial or
        #      benign) are walked but never written. Steps 3 + 4 share
        #      one +db.transaction+ block: an anchor cleared while
        #      descendants remain +'spv'+ is the state the atomic
        #      combined invalidation exists to prevent.
        #   5. Re-query +Store#verified_wtxids+ so the caller receives a
        #      Set that already reflects both anchor and descendant
        #      invalidation. The read is trivially cheap under the
        #      covering index.
        #
        # Chain-tracker unreachable (network error, unknown height,
        # empty tracker) surfaces as +nil+ entries in the resolved map
        # and does NOT invalidate — only genuine root mismatches clear
        # rows. Transient outages leave the trust set intact, and the
        # descent walk is skipped when the anchor set is empty.
        #
        # @param wtxids [Array<String>] 32-byte binary wtxids
        # @return [Set<String>] the surviving trust set
        def filter_trusted(wtxids)
          return Set.new if wtxids.nil? || wtxids.empty?

          heights = heights_for_verified(wtxids)
          @store.db.transaction do
            invalidated = @store.invalidate_stale_anchors!(
              heights_to_roots: known_roots_for(heights)
            )
            expand_and_clear_descendants(invalidated) if invalidated.any?
          end
          @store.verified_wtxids(
            wtxids: wtxids,
            version_at_least: BSV::Wallet::VERIFIER_VERSION,
            via_in: BSV::Wallet::Store::Models::TxProof::VERIFIED_VIA_TRUSTED
          )
        end

        private

        # Collect the distinct block heights carrying a currently-verified
        # proof row for any of +wtxids+. One indexed read
        # (+idx_tx_proofs_verified_by_block+ partial index covers the
        # +verified_at IS NOT NULL AND block_id IS NOT NULL+ predicate).
        def heights_for_verified(wtxids)
          blobs = wtxids.map { |w| Sequel.blob(w) }
          BSV::Wallet::Store::Models::TxProof
            .join(:blocks, id: :block_id)
            .where(Sequel[:tx_proofs][:wtxid] => blobs)
            .exclude(Sequel[:tx_proofs][:verified_via] => nil)
            .distinct
            .select_map(Sequel[:blocks][:height])
        end

        # HLR #516 Sub 6.2 — expand the invalidated anchor set through
        # +Store#descendant_action_ids_of+ and coarse-clear via
        # +Store#invalidate_verification+. The seed anchors are the
        # +action_ids+ returned by +invalidate_stale_anchors!+ — actions
        # whose own proof rows have just been cleared. The descent walk
        # unifies them with all structural descendants (transitively via
        # +inputs → outputs → next actions+); the shared primitive's
        # +verified_via IS NOT NULL+ predicate gates the UPDATE to rows
        # that carry a trust mark.
        #
        # Coarse-clear rule (cryptography): every structural descendant
        # is walked regardless of whether its SPV proof went through the
        # invalidated anchor. Inferring the answer requires replaying
        # +Tx#verify+, which defeats the cache; wasted re-verify on next
        # reference is safe, missed clear opens a silent double-spend
        # window.
        #
        # Runs inside the +db.transaction+ opened by +filter_trusted+ —
        # Sequel flattens nested transactions, and a failure at any step
        # rolls back both the anchor UPDATE and the descendant UPDATE.
        def expand_and_clear_descendants(seed_action_ids)
          descent = @store.descendant_action_ids_of(action_ids: seed_action_ids)
          @store.invalidate_verification(action_ids: descent)
        end

        # Per-walk memo — collapse repeat descent through the same
        # instance to a single tracker round-trip (AC #6: call-count
        # budget). A tracker error propagates through
        # +known_roots_for_heights+ as +nil+ entries, still cached so we
        # don't re-fetch within the walk.
        def known_roots_for(heights)
          return {} if heights.empty?

          @known_roots ||= {}
          missing = heights - @known_roots.keys
          @known_roots.merge!(@chain_tracker.known_roots_for_heights(missing)) if missing.any?
          heights.to_h { |h| [h, @known_roots[h]] }
        rescue StandardError => e
          BSV.logger&.warn { "[AnchorLivenessCache] known_roots_for error: #{e.message}" }
          # Fail-closed on the invalidation side: an outage cannot decay
          # the trust set. Return an empty map so
          # +invalidate_stale_anchors!+ has nothing to clear.
          {}
        end
      end
    end
  end
end
