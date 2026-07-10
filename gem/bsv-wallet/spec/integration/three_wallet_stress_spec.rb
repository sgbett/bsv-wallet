# frozen_string_literal: true

# HLR #516 Sub 6.3 — regression benchmark harness (co-releasing sub).
#
# This spec's job is a co-release guard: prove that Sub 6.1's per-verify
# anchor-liveness pass plus Sub 6.2's transitive descendant walk do not
# regress Sub 5's receive-path throughput. The Sub 5 workload — a
# streamed BEEF ingest over three wallets — has not yet landed. Once it
# does, the +three-wallet workload+ block below fills in around the
# instrumentation Sub 6.3 provides here.
#
# Until then, Sub 6.3 lands two things:
#
# 1. The harness *shape* — per-iteration timing plus counter snapshots
#    (+receive_ms+, +chain_tracker_calls+, +cache_hits+, +cache_misses+,
#    +invalidated_anchors+). Sub 5's developer fills the workload; the
#    metric surface stays stable.
# 2. A synthetic-loop test that drives +Engine::AnchorLivenessCache+
#    directly and asserts the AC #6 call-count ceiling
#    (+≤ 1 known_roots_for_heights invocation per verify-walk+) plus the
#    iter-100-within-2x-of-iter-10 growth shape Sub 5 will inherit. This
#    is enough to catch a Sub-6-side regression *before* Sub 5 wires the
#    real workload.
#
# Sub 5's forthcoming three-wallet workload should:
#
#   - drive N iterations of a receive path that walks +filter_trusted+ once per BEEF
#   - reuse the same +chain_tracker+ across iterations
#   - reuse per-iteration +AnchorLivenessCache+ instances (one per verify-walk)
#   - collect the per-iteration snapshot Hash below and compute the growth curve
#
# Runs only with +BSV_WALLET_VERIFY_TRACE=1+ set (the env-gated
# instrumentation Sub 6.3 provides on +AnchorLivenessCache#stats+);
# unset → the spec is a no-op skip so CI's default unit lane pays
# nothing.
#
# **How to run this suite.** +gem/bsv-wallet/.rspec+ excludes
# +spec/integration/**/*_spec.rb+ from the default lane, so an
# unqualified +bundle exec rspec+ will not touch this file. Invoke it
# explicitly:
#
#   BSV_WALLET_VERIFY_TRACE=1 bundle exec rspec spec/integration/three_wallet_stress_spec.rb
#
# CI runs a dedicated integration lane that clears the exclusion and
# sets the env var; the default unit lane skips this file entirely.

require 'securerandom'
require_relative '../bsv/wallet/store/shared_context'

RSpec.describe 'HLR #516 regression harness (Sub 6.3 co-release)', :store do # rubocop:disable RSpec/DescribeClass
  include_context 'store setup'

  let(:models) { BSV::Wallet::Store::Models }

  # Skip the whole suite unless the env-gated instrumentation is on —
  # counter reads need +BSV_WALLET_VERIFY_TRACE=1+ or +#stats+ returns
  # nil (deliberate zero-allocation hot path).
  before { skip 'requires BSV_WALLET_VERIFY_TRACE=1' unless ENV['BSV_WALLET_VERIFY_TRACE'] == '1' }

  # Persist a single-leaf-BUMP proof at +height+, then mark +'spv'+.
  # Returns the wtxid.
  def persist_anchored(height:, wtxid: SecureRandom.random_bytes(32))
    leaf = BSV::Transaction::MerklePath::PathElement.new(offset: 0, hash: wtxid, txid: true)
    bump = BSV::Transaction::MerklePath.new(block_height: height, path: [[leaf]])
    store.save_proof(wtxid: wtxid,
                     proof: { raw_tx: 'x'.b * 20, height: height,
                              merkle_root: wtxid, merkle_path: bump.to_binary })
    store.mark_verified(wtxid: wtxid, via: 'spv')
    wtxid
  end

  # Chain tracker double supporting +known_roots_for_heights+, records
  # each invocation so we can assert the call-count budget.
  def build_tracker(roots)
    tracker = instance_double(BSV::Network::ChainTracker)
    allow(tracker).to receive(:known_roots_for_heights) do |heights|
      heights.to_h { |h| [h, roots[h]] }
    end
    tracker
  end

  # Per-iteration snapshot Hash — the exact shape Sub 5 will collect.
  # Sub 5 wires the receive path; this method exists so the two subs
  # agree on the metric surface without either coding to a private
  # interface of the other.
  #
  # Each +cache+ is a per-verify-walk instance; +stats+ reports its
  # own counters. Sub 5's workload can accumulate the per-iteration
  # snapshots for its growth-shape assertion.
  def snapshot_for(cache:)
    stats = cache.stats || {}
    {
      receive_ms: 0.0, # populated by Sub 5's outer +Benchmark.realtime+
      chain_tracker_calls: stats[:chain_tracker_calls] || 0,
      cache_hits: stats[:cache_hits] || 0,
      cache_misses: stats[:cache_misses] || 0,
      invalidated_anchors: stats[:invalidated_anchors] || 0
    }
  end

  # HLR #516 Sub 5 — receive-path shape check via BeefImporter.
  #
  # The full three-wallet streamed workload (cross-wallet payment ping-pong,
  # cold-vs-warm timing separation per AC #5) is bigger than Sub 5's wiring
  # scope and moves to a follow-up integration HLR. This block covers the
  # shape guard that matters most for Sub 5: iterating +BeefImporter#import+
  # over unique subjects that all descend from the SAME proven ancestor
  # should show flat per-iteration receive_ms because +filter_trusted+
  # short-circuits the ancestor's subtree from the second iteration onwards.
  describe 'three-wallet workload' do
    it 'iter-100 receive_ms stays within 2x of iter-10 via BeefImporter' do
      chain_tracker = build_tracker({})
      allow(chain_tracker).to receive_messages(valid_root_for_height?: true, current_height: 900_000)
      hydrator = BSV::Wallet::Engine::Hydrator.new(store: store)
      importer = BSV::Wallet::Engine::BeefImporter.new(
        store: store, chain_tracker: chain_tracker, hydrator: hydrator
      )

      # Proven ancestor at a known height — shared across every iteration
      # so +filter_trusted+ has something to short-circuit.
      op_true = "\x51".b
      ancestor = BSV::Transaction::Tx.new(version: 1, lock_time: 0)
      ancestor.add_output(BSV::Transaction::TransactionOutput.new(
                            satoshis: 1_000_000,
                            locking_script: BSV::Script::Script.from_binary(op_true)
                          ))
      sibling = SecureRandom.random_bytes(32)
      ancestor.merkle_path = BSV::Transaction::MerklePath.new(
        block_height: 800_000,
        path: [[
          BSV::Transaction::MerklePath::PathElement.new(offset: 2, hash: ancestor.wtxid, txid: true),
          BSV::Transaction::MerklePath::PathElement.new(offset: 3, hash: sibling)
        ]]
      )

      # Build a unique BEEF per iteration — same ancestor, distinct
      # subject (varying lock_time keeps wtxids distinct so ingress
      # doesn't dedup).
      make_beef = lambda do |i|
        subject_tx = BSV::Transaction::Tx.new(version: 1, lock_time: i)
        subject_tx.add_input(BSV::Transaction::TransactionInput.new(
                               prev_wtxid: ancestor.wtxid,
                               prev_tx_out_index: 0,
                               sequence: 0xFFFFFFFF,
                               unlocking_script: BSV::Script::Script.from_binary(op_true)
                             ))
        subject_tx.inputs[0].source_transaction = ancestor
        subject_tx.add_output(BSV::Transaction::TransactionOutput.new(
                                satoshis: 500,
                                locking_script: BSV::Script::Script.from_binary(op_true)
                              ))
        beef = BSV::Transaction::Beef.new
        beef.merge_transaction(ancestor)
        beef.merge_transaction(subject_tx)
        [beef.to_atomic_binary(subject_tx.wtxid), subject_tx]
      end

      receive_ms = []
      100.times do |i|
        beef_binary, subject_tx = make_beef.call(i)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        importer.import(
          tx: beef_binary,
          description: "sub 5 iter #{i}",
          outputs: [{
            output_index: 0, protocol: :basket_insertion, satoshis: 500,
            insertion_remittance: {
              basket: 'sub five iter', derivation_prefix: 'test',
              derivation_suffix: subject_tx.wtxid.unpack1('H*')[0, 8],
              sender_identity_key: 'self'
            }
          }]
        )
        receive_ms << ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0)
      end

      # Iter-10 vs iter-100 shape. The 2x ceiling is a catastrophic-
      # regression guard, not a tight benchmark — CI noise floor
      # dominates a run of this size.
      expect(receive_ms[99]).to be < receive_ms[9] * 2.0
    end
  end

  # Sub-6-side guard: even without Sub 5's workload, we can already
  # assert the pieces that would regress independently. Runs +N+ small
  # verify-walks in a tight loop against a real +Store+ and a stub
  # +chain_tracker+; asserts the call-count ceiling (AC #6) and the
  # iter-100-within-2x-of-iter-10 growth shape.
  describe 'synthetic loop (Sub 6 co-release guard)' do
    it 'holds the AC #6 call-count budget: ≤ 1 known_roots_for_heights per verify-walk' do
      # Populate a small trust set at ten distinct heights so the
      # +known_roots_for_heights+ call has real work to do per walk.
      wtxids_by_height = 10.times.to_h { |i| [980_000 + i, persist_anchored(height: 980_000 + i)] }
      wtxids = wtxids_by_height.values
      tracker = build_tracker(wtxids_by_height)

      # 20 verify-walks. Each walk builds its own cache instance (the
      # per-verify contract) — the memo cannot leak across walks; the
      # ceiling has to hold per-instance regardless of how many walks
      # the workload runs.
      20.times do
        cache = BSV::Wallet::Engine::AnchorLivenessCache.new(store: store, chain_tracker: tracker)
        cache.filter_trusted(wtxids)
      end

      # Total tracker invocations equals number of walks — one per
      # walk. Exactly 20, not "at most" — the tighter assertion catches
      # regressions where +filter_trusted+ stops invoking the tracker
      # (e.g. an early return on empty heights). Copilot on #533.
      expect(tracker).to have_received(:known_roots_for_heights).exactly(20).times
    end

    it 'iter-100 receive_ms stays within 2x of iter-10 (growth shape)' do
      # Populate 30 heights of trust so the per-walk work is non-trivial.
      # Enough that the numbers move but not so many that the test
      # becomes flaky on slow CI runners.
      wtxids_by_height = 30.times.to_h { |i| [980_100 + i, persist_anchored(height: 980_100 + i)] }
      wtxids = wtxids_by_height.values
      tracker = build_tracker(wtxids_by_height)

      snapshots = []
      100.times do
        cache = BSV::Wallet::Engine::AnchorLivenessCache.new(store: store, chain_tracker: tracker)
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        cache.filter_trusted(wtxids)
        elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000.0
        snap = snapshot_for(cache: cache)
        snap[:receive_ms] = elapsed_ms
        snapshots << snap
      end

      # Per-verify-walk instances: chain_tracker_calls should be ≤ 1
      # for every iteration (AC #6 call-count budget).
      expect(snapshots.map { |s| s[:chain_tracker_calls] }).to all(be <= 1)

      iter10 = snapshots[9][:receive_ms]
      iter100 = snapshots[99][:receive_ms]
      # 2x ceiling — Sub 5's real workload will tighten this to
      # 15% (Postgres) / 25% (SQLite), but the synthetic loop's
      # per-iteration cost is dominated by test-harness noise, not
      # Sub-6's contribution. A 2x guard still surfaces catastrophic
      # regressions (e.g. an O(N²) walk landing in Sub-6-adjacent code).
      expect(iter100).to be < iter10 * 2.0
    end
  end
end
