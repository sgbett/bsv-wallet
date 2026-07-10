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
          # HLR #516 Sub 6.3 — env-gated instrumentation. When
          # +BSV_WALLET_VERIFY_TRACE=1+ the +@stats+ Hash is
          # instantiated and per-step counters are incremented in the
          # hot path. When unset, +@stats+ stays +nil+ and every
          # counter site is a bare +if @stats+ short-circuit — no Hash
          # allocation, no fetch/store cost on the receive path.
          @stats = ENV['BSV_WALLET_VERIFY_TRACE'] == '1' ? new_stats_hash : nil
        end

        # Snapshot of per-instance counters. Returns +nil+ when
        # +BSV_WALLET_VERIFY_TRACE+ is not set — deliberate, so a
        # caller enabling instrumentation adds no allocation to the
        # default hot path.
        #
        # When set, the returned Hash carries:
        #   :chain_tracker_calls  — invocations of +known_roots_for_heights+
        #   :cache_hits           — heights answered from the per-walk memo
        #   :cache_misses         — heights that needed a fresh tracker call
        #   :invalidated_anchors  — action_ids the anchor UPDATE cleared
        #   :walked_descendants   — total ids the descent walk visited
        #
        # @return [Hash{Symbol => Integer}, nil]
        def stats
          return nil unless @stats

          @stats.dup
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
          # Resolve tracker roots BEFORE opening the DB transaction — the
          # chain_tracker's +known_roots_for_heights+ may perform network
          # I/O (SPV syncer sync, services HTTP fetch). Holding a wallet
          # DB tx across external I/O inflates lock time and turns any
          # tracker latency into a bottleneck. Copilot on #533.
          heights_to_roots = known_roots_for(heights)
          trusted = nil
          @store.db.transaction do
            invalidated = @store.invalidate_stale_anchors!(
              heights_to_roots: heights_to_roots
            )
            @stats[:invalidated_anchors] += invalidated.size if @stats
            expand_and_clear_descendants(invalidated) if invalidated.any?
            # Read the trust set INSIDE the same transaction so a
            # concurrent writer cannot mutate a row between invalidation
            # and the read — the returned Set reflects the state
            # committed by this walk, not some interleaving. Copilot on #533.
            trusted = @store.verified_wtxids(
              wtxids: wtxids,
              version_at_least: BSV::Wallet::VERIFIER_VERSION,
              via_in: BSV::Wallet::Store::Models::TxProof::VERIFIED_VIA_TRUSTED
            )
          end
          trusted
        end

        private

        # Collect the distinct block heights carrying a currently-verified
        # proof row for any of +wtxids+. Indexed read
        # (+idx_tx_proofs_verified_by_block+ partial index covers the
        # +verified_at IS NOT NULL AND block_id IS NOT NULL+ predicate).
        # Chunks the +wtxid IN (...)+ predicate at
        # +Store::VERIFY_BATCH_CHUNK+ to stay under SQLite's 32_766
        # bind-parameter ceiling and match the codebase-wide convention
        # for large wtxid-set reads. Copilot on #533.
        def heights_for_verified(wtxids)
          chunk = BSV::Wallet::Store::VERIFY_BATCH_CHUNK
          heights = Set.new
          wtxids.each_slice(chunk) do |slice|
            blobs = slice.map { |w| Sequel.blob(w) }
            heights.merge(
              BSV::Wallet::Store::Models::TxProof
                .join(:blocks, id: :block_id)
                .where(Sequel[:tx_proofs][:wtxid] => blobs)
                .exclude(Sequel[:tx_proofs][:verified_via] => nil)
                .distinct
                .select_map(Sequel[:blocks][:height])
            )
          end
          heights.to_a
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
        # Runs inside the +db.transaction+ opened by +filter_trusted+.
        # Sequel nests transactions via savepoints (spec DB uses
        # +auto_savepoint: true+); the invariant we rely on is that
        # nested +db.transaction+ blocks do NOT introduce extra commit
        # boundaries, and a failure at any step rolls back both the
        # anchor UPDATE and the descendant UPDATE via the outer
        # transaction. Copilot round-7 on #533.
        def expand_and_clear_descendants(seed_action_ids)
          descent = @store.descendant_action_ids_of(action_ids: seed_action_ids)
          @stats[:walked_descendants] += descent.size if @stats
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
          if @stats
            @stats[:cache_hits]   += (heights.size - missing.size)
            @stats[:cache_misses] += missing.size
          end
          if missing.any?
            @stats[:chain_tracker_calls] += 1 if @stats
            @known_roots.merge!(@chain_tracker.known_roots_for_heights(missing))
          end
          heights.to_h { |h| [h, @known_roots[h]] }
        rescue StandardError => e
          BSV.logger&.warn { "[AnchorLivenessCache] known_roots_for error: #{e.message}" }
          # Preserve trust on a transient outage for PARSEABLE rows —
          # the AC #4 "unknown ≠ mismatch" guarantee — while STILL
          # letting the store fail-closed clear structurally-unverifiable
          # rows (missing / unparseable +merkle_path+ with a trust mark).
          # Return +{ h => nil }+ for every requested height (not +{}+),
          # so +Store#invalidate_stale_anchors!+ scans each height's
          # candidates; parseable rows preserve trust via the per-row
          # +next if current_root_bytes.nil?+ guard, unverifiable rows
          # clear via the +computed_root_for_path+ nil-branch.
          # (Copilot round-3 established outage-preservation for
          # parseable rows; round-6 established fail-closed on
          # unverifiable rows; round-7 completes the story for the
          # full-outage path.)
          #
          # Populate +@known_roots+ so a repeat call in the same walk
          # honours the "don't re-fetch" invariant noted above — a
          # rescued outage stays rescued for the rest of the instance's
          # lifetime. Copilot round-8 on #533.
          @known_roots ||= {}
          heights.each { |h| @known_roots[h] = nil }
          heights.to_h { |h| [h, nil] }
        end

        # Zero-value counter Hash — instantiated only when
        # +BSV_WALLET_VERIFY_TRACE+ is set at construction time. Every
        # increment site short-circuits on +@stats.nil?+ so the hot
        # path pays neither the Hash allocation nor the per-step
        # +[]+/+[]=+ cost in the default (unset) mode.
        def new_stats_hash
          { chain_tracker_calls: 0,
            cache_hits: 0,
            cache_misses: 0,
            invalidated_anchors: 0,
            walked_descendants: 0 }
        end
      end
    end
  end
end
