# frozen_string_literal: true

require_relative '../store/shared_context'

# HLR #516 Sub 6.1 — orchestrator PORO covering the per-verify-walk
# anchor-liveness path: heights → tracker call → invalidation → pruned
# trust set. Chain tracker is mocked; the store is real (so we exercise
# the interaction between +invalidate_stale_anchors!+ and
# +verified_wtxids+).
RSpec.describe BSV::Wallet::Engine::AnchorLivenessCache, :store do
  let(:models) { BSV::Wallet::Store::Models }

  # A minimal chain tracker double supporting the batched interface.
  # +roots+ keyed by height mimics the real tracker's memo; +nil+ values
  # emulate "unknown" heights (tracker outage).
  def build_tracker(roots)
    tracker = instance_double(BSV::Network::ChainTracker)
    allow(tracker).to receive(:known_roots_for_heights) do |heights|
      heights.to_h { |h| [h, roots[h]] }
    end
    tracker
  end

  # Persist a proof at +height+ with a single-leaf BUMP so its computed
  # root equals the wtxid (SDK's short-circuit branch).
  def persist_anchored(height:, via: 'spv', wtxid: SecureRandom.random_bytes(32))
    leaf = BSV::Transaction::MerklePath::PathElement.new(offset: 0, hash: wtxid, txid: true)
    bump = BSV::Transaction::MerklePath.new(block_height: height, path: [[leaf]])
    store.save_proof(wtxid: wtxid,
                     proof: { raw_tx: 'x'.b * 20,
                              height: height,
                              merkle_root: wtxid, # single-leaf BUMP: root == wtxid
                              merkle_path: bump.to_binary })
    store.mark_verified(wtxid: wtxid, via: via) if via
    wtxid
  end

  # Two proofs at +height+ sharing a two-leaf BUMP → equal computed
  # root, one +blocks+ row. Returns +[wtxid_a, wtxid_b, shared_root]+.
  def persist_paired(height:, via: 'spv')
    wtxid_a = SecureRandom.random_bytes(32)
    wtxid_b = SecureRandom.random_bytes(32)
    leaf_a = BSV::Transaction::MerklePath::PathElement.new(offset: 0, hash: wtxid_a, txid: true)
    leaf_b = BSV::Transaction::MerklePath::PathElement.new(offset: 1, hash: wtxid_b, txid: true)
    bump = BSV::Transaction::MerklePath.new(block_height: height, path: [[leaf_a, leaf_b]])
    shared_root = bump.compute_root(wtxid_a)
    [wtxid_a, wtxid_b].each do |w|
      store.save_proof(wtxid: w,
                       proof: { raw_tx: 'x'.b * 20,
                                height: height,
                                merkle_root: shared_root,
                                merkle_path: bump.to_binary })
      store.mark_verified(wtxid: w, via: via) if via
    end
    [wtxid_a, wtxid_b, shared_root]
  end

  describe '#filter_trusted' do
    it 'returns an empty Set on empty input (no tracker call, no DB round-trip)' do
      tracker = build_tracker({})
      cache = described_class.new(store: store, chain_tracker: tracker)
      expect(cache.filter_trusted([])).to eq(Set.new)
      expect(tracker).not_to have_received(:known_roots_for_heights)
    end

    it 'passes the trust set through unchanged when every root matches' do
      height = 950_001
      wtxid = persist_anchored(height: height)
      tracker = build_tracker(height => wtxid) # tracker root == persisted root
      cache = described_class.new(store: store, chain_tracker: tracker)

      trusted = cache.filter_trusted([wtxid])
      expect(trusted).to include(wtxid)
      expect(store.verification_state(wtxid: wtxid)&.[](:verified_via)).to eq('spv')
    end

    it 'invalidates a stale anchor and drops the wtxid from the returned set' do
      height = 950_002
      wtxid = persist_anchored(height: height)
      tracker = build_tracker(height => SecureRandom.random_bytes(32)) # different root
      cache = described_class.new(store: store, chain_tracker: tracker)

      trusted = cache.filter_trusted([wtxid])
      expect(trusted).not_to include(wtxid)
      expect(store.verification_state(wtxid: wtxid)).to be_nil
    end

    it 'invokes known_roots_for_heights at most once per instance (AC #6 call-count budget)' do
      wtxids = 3.times.map { |i| persist_anchored(height: 950_010 + i) }
      tracker = build_tracker(wtxids.each_with_index.to_h { |w, i| [950_010 + i, w] })
      cache = described_class.new(store: store, chain_tracker: tracker)

      cache.filter_trusted(wtxids)
      expect(tracker).to have_received(:known_roots_for_heights).at_most(:once)
    end

    it 'does not invalidate on tracker outage (nil roots ≠ mismatch)' do
      height = 950_020
      wtxid = persist_anchored(height: height)
      # Tracker reports the height as unknown (returned nil).
      tracker = build_tracker(height => nil)
      cache = described_class.new(store: store, chain_tracker: tracker)

      trusted = cache.filter_trusted([wtxid])
      expect(trusted).to include(wtxid)
      expect(store.verification_state(wtxid: wtxid)&.[](:verified_via)).to eq('spv')
    end

    it 'does not invalidate when known_roots_for_heights raises (fail-closed on invalidation)' do
      height = 950_021
      wtxid = persist_anchored(height: height)
      tracker = instance_double(BSV::Network::ChainTracker)
      allow(tracker).to receive(:known_roots_for_heights).and_raise(StandardError, 'network boom')
      cache = described_class.new(store: store, chain_tracker: tracker)

      trusted = cache.filter_trusted([wtxid])
      expect(trusted).to include(wtxid)
      expect(store.verification_state(wtxid: wtxid)&.[](:verified_via)).to eq('spv')
    end

    it 'invalidates one row at height A while leaving a matching row at height B alone' do
      wtxid_a = persist_anchored(height: 950_030)
      wtxid_b = persist_anchored(height: 950_031)
      tracker = build_tracker(950_030 => SecureRandom.random_bytes(32), 950_031 => wtxid_b)
      cache = described_class.new(store: store, chain_tracker: tracker)

      trusted = cache.filter_trusted([wtxid_a, wtxid_b])
      expect(trusted).not_to include(wtxid_a)
      expect(trusted).to include(wtxid_b)
    end

    it 'excludes self_built (Sub 5 trust hierarchy — self_built never joins the trust set)' do
      wtxid = persist_anchored(height: 950_040, via: 'self_built')
      tracker = build_tracker(950_040 => wtxid) # root matches, but via is self_built
      cache = described_class.new(store: store, chain_tracker: tracker)

      expect(cache.filter_trusted([wtxid])).not_to include(wtxid)
    end

    # Two BUMPs with the same computed root, different persistence
    # bytes — the SDK's +compute_root+ folds encoding variability so
    # both yield the same 32-byte root. Two rows sharing that root at
    # the same height clear together on tracker disagreement; and
    # survive together when the tracker agrees.
    it 'BUMP-encoding evasion: paired proofs invalidate together on mismatch' do
      height = 950_050
      wtxid_a, wtxid_b, _shared = persist_paired(height: height)
      tracker = build_tracker(height => SecureRandom.random_bytes(32))
      cache = described_class.new(store: store, chain_tracker: tracker)

      trusted = cache.filter_trusted([wtxid_a, wtxid_b])
      expect(trusted).not_to include(wtxid_a)
      expect(trusted).not_to include(wtxid_b)
    end

    it 'BUMP-encoding evasion: paired proofs survive together on tracker agreement' do
      height = 950_051
      wtxid_a, wtxid_b, shared = persist_paired(height: height)
      tracker = build_tracker(height => shared)
      cache = described_class.new(store: store, chain_tracker: tracker)

      trusted = cache.filter_trusted([wtxid_a, wtxid_b])
      expect(trusted).to include(wtxid_a, wtxid_b)
    end
  end
end
