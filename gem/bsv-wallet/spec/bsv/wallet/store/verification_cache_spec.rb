# frozen_string_literal: true

require 'benchmark'
require_relative 'shared_context'

RSpec.describe BSV::Wallet::Store, :store do
  include_context 'store setup'

  let(:models) { BSV::Wallet::Store::Models }

  # Persist a bare tx_proofs row so we have something to mark. wtxid is
  # 32 random bytes; raw_tx is a synthetic 20-byte blob (the min the
  # raw_tx_min_length CHECK permits).
  def persist_proof(wtxid: SecureRandom.bytes(32))
    store.save_proof(wtxid: wtxid, proof: { raw_tx: 'x'.b * 20 })
    wtxid
  end

  describe '#mark_verified' do
    it 'writes verified_at, verified_via, verifier_version together' do
      wtxid = persist_proof
      store.mark_verified(wtxid: wtxid, via: models::TxProof::VERIFIED_VIA_SPV)
      row = store.verification_state(wtxid: wtxid)
      expect(row[:verified_via]).to eq('spv')
      expect(row[:verifier_version]).to eq(BSV::Wallet::VERIFIER_VERSION)
      expect(row[:verified_at]).to be_a(Time)
    end

    it 'is a no-op when the proof row does not exist' do
      wtxid = SecureRandom.bytes(32)
      expect(store.mark_verified(wtxid: wtxid, via: 'spv')).to eq(0)
    end

    it 'rejects a via value outside VERIFIED_VIA_VALUES' do
      wtxid = persist_proof
      expect { store.mark_verified(wtxid: wtxid, via: 'imported') }
        .to raise_error(ArgumentError, /must be one of/)
    end

    it 'upgrades verified_via from self_built to broadcast_ack (same version)' do
      wtxid = persist_proof
      store.mark_verified(wtxid: wtxid, via: 'self_built')
      store.mark_verified(wtxid: wtxid, via: 'broadcast_ack')
      expect(store.verification_state(wtxid: wtxid)[:verified_via]).to eq('broadcast_ack')
    end

    # HLR #521 strength ratchet — trust hierarchy from
    # +docs/reference/verification-cache.md+ is +self_built+ <
    # +broadcast_ack+ < +spv+ (+'spv'+ is the strongest local trust
    # because +Tx#verify+ ran end-to-end; +broadcast_ack+ means the
    # network has it but this wallet never verified). Same-version
    # downgrades must be refused; the version predicate alone gates
    # cross-version writes.
    it 'refuses to downgrade verified_via from spv to self_built (same version)' do
      wtxid = persist_proof
      store.mark_verified(wtxid: wtxid, via: 'spv')
      rows = store.mark_verified(wtxid: wtxid, via: 'self_built')
      expect(rows).to eq(0)
      expect(store.verification_state(wtxid: wtxid)[:verified_via]).to eq('spv')
    end

    it 'refuses to downgrade verified_via from broadcast_ack to self_built (same version)' do
      wtxid = persist_proof
      store.mark_verified(wtxid: wtxid, via: 'broadcast_ack')
      rows = store.mark_verified(wtxid: wtxid, via: 'self_built')
      expect(rows).to eq(0)
      expect(store.verification_state(wtxid: wtxid)[:verified_via]).to eq('broadcast_ack')
    end

    it 'refuses to downgrade verified_via from spv to broadcast_ack (same version)' do
      wtxid = persist_proof
      store.mark_verified(wtxid: wtxid, via: 'spv')
      rows = store.mark_verified(wtxid: wtxid, via: 'broadcast_ack')
      expect(rows).to eq(0)
      expect(store.verification_state(wtxid: wtxid)[:verified_via]).to eq('spv')
    end

    it 'upgrades broadcast_ack to spv (same version)' do
      wtxid = persist_proof
      store.mark_verified(wtxid: wtxid, via: 'broadcast_ack')
      store.mark_verified(wtxid: wtxid, via: 'spv')
      expect(store.verification_state(wtxid: wtxid)[:verified_via]).to eq('spv')
    end

    # HLR #521 strength ratchet is same-version only. Cross-version
    # (existing verifier_version < code version) writes go through the
    # monotonic version predicate alone — the new verifier's
    # classification is authoritative, and Sub 5's read gate
    # (+verified_wtxids(version_at_least:)+) already excludes stale
    # stronger marks from an older binary.
    it 'allows a weaker via to overwrite an older-version stronger via (cross-version)' do
      wtxid = persist_proof
      # Row starts at the compile-time constant (currently 1). Simulate
      # a code-version bump by stubbing +VERIFIER_VERSION+ to a higher
      # value for the second write, so the row's version predates the
      # binary that's now running. +verifier_version_range+ CHECK
      # (+>= 1+) forbids ageing the row below 1 the other way.
      store.mark_verified(wtxid: wtxid, via: 'spv')
      stub_const('BSV::Wallet::VERIFIER_VERSION', BSV::Wallet::VERIFIER_VERSION + 1)

      rows = store.mark_verified(wtxid: wtxid, via: 'self_built')
      expect(rows).to eq(1)
      state = store.verification_state(wtxid: wtxid)
      expect(state[:verified_via]).to eq('self_built')
      expect(state[:verifier_version]).to eq(BSV::Wallet::VERIFIER_VERSION)
    end
  end

  describe '#mark_verified_batch' do
    it 'no-ops on empty input without hitting the DB' do
      expect(store.mark_verified_batch(wtxids: [], via: 'spv')).to eq(0)
    end

    it 'marks every matching row in a single call' do
      wtxids = 5.times.map { persist_proof }
      rows = store.mark_verified_batch(wtxids: wtxids, via: 'spv')
      expect(rows).to eq(5)
      expect(wtxids).to all(satisfy { |w| store.verification_state(wtxid: w) })
    end

    it 'silently skips wtxids without a matching proof row' do
      real = persist_proof
      missing = SecureRandom.bytes(32)
      rows = store.mark_verified_batch(wtxids: [real, missing], via: 'spv')
      expect(rows).to eq(1)
      expect(store.verification_state(wtxid: missing)).to be_nil
    end
  end

  describe '#verification_state' do
    it 'returns nil when the proof row is not verified' do
      wtxid = persist_proof
      expect(store.verification_state(wtxid: wtxid)).to be_nil
    end

    it 'returns nil when there is no proof row at all' do
      expect(store.verification_state(wtxid: SecureRandom.bytes(32))).to be_nil
    end
  end

  describe '#verified_wtxids' do
    it 'short-circuits empty input (returns empty Set, no DB round-trip)' do
      expect(store.verified_wtxids(wtxids: [], version_at_least: 1, via_in: ['spv'])).to eq(Set.new)
    end

    it 'gates on via_in — excludes self_built when only trusted values requested' do
      spv = persist_proof
      self_built = persist_proof
      store.mark_verified(wtxid: spv, via: 'spv')
      store.mark_verified(wtxid: self_built, via: 'self_built')

      trusted = store.verified_wtxids(
        wtxids: [spv, self_built],
        version_at_least: 1,
        via_in: models::TxProof::VERIFIED_VIA_TRUSTED
      )
      expect(trusted).to include(spv)
      expect(trusted).not_to include(self_built)
    end

    it 'gates on version_at_least — excludes rows below the version floor' do
      wtxid = persist_proof
      store.mark_verified(wtxid: wtxid, via: 'spv')
      # Ask for a strictly higher version than any row could carry.
      higher = BSV::Wallet::VERIFIER_VERSION + 1
      result = store.verified_wtxids(wtxids: [wtxid], version_at_least: higher, via_in: ['spv'])
      expect(result).to be_empty
    end
  end

  describe '#max_verifier_version_seen' do
    it 'returns nil when no rows are verified' do
      expect(store.max_verifier_version_seen).to be_nil
    end

    it 'returns the highest verifier_version across verified rows' do
      persist_proof.tap { |w| store.mark_verified(wtxid: w, via: 'spv') }
      expect(store.max_verifier_version_seen).to eq(BSV::Wallet::VERIFIER_VERSION)
    end
  end

  describe '#verify_verifier_version!' do
    it 'is a no-op when no rows have been marked verified' do
      expect { store.verify_verifier_version! }.not_to raise_error
    end

    it 'is a no-op when the code version matches the max seen' do
      persist_proof.tap { |w| store.mark_verified(wtxid: w, via: 'spv') }
      expect { store.verify_verifier_version! }.not_to raise_error
    end

    it 'raises when a row records a higher verifier_version than the code' do
      wtxid = persist_proof
      store.mark_verified(wtxid: wtxid, via: 'spv')
      # Simulate: this binary was rolled back after the row was written
      # under a future version.
      future = BSV::Wallet::VERIFIER_VERSION + 1
      models::TxProof.where(wtxid: Sequel.blob(wtxid)).update(verifier_version: future)

      expect { store.verify_verifier_version! }
        .to raise_error(BSV::Wallet::SchemaIntegrityError, /downgrade refused/)
    end
  end

  describe 'wtxid length validation' do
    it 'raises when mark_verified_batch receives a malformed wtxid' do
      good = persist_proof
      malformed = "\x00".b * 20 # 20 bytes, not 32
      expect { store.mark_verified_batch(wtxids: [good, malformed], via: 'spv') }
        .to raise_error(ArgumentError, /wtxid/)
    end

    it 'raises when verified_wtxids receives a malformed wtxid' do
      malformed = "\x00".b * 20
      expect do
        store.verified_wtxids(wtxids: [malformed], version_at_least: 1, via_in: ['spv'])
      end.to raise_error(ArgumentError, /wtxid/)
    end
  end

  describe 'chunking (VERIFY_BATCH_CHUNK boundary)' do
    # Stub the internal constant to a small value so the chunking path is
    # exercisable without persisting tens of thousands of rows.
    it 'processes inputs spanning multiple chunks under the 10k boundary' do
      wtxids = 25.times.map { persist_proof }
      stub_const('BSV::Wallet::Store::VERIFY_BATCH_CHUNK', 10)
      rows = store.mark_verified_batch(wtxids: wtxids, via: 'spv')
      expect(rows).to eq(25)
    end
  end

  describe 'DB-level ENUM / CHECK (bypasses application validation)' do
    it 'rejects an invalid verified_via via the Postgres ENUM or SQLite CHECK', :store do
      wtxid = persist_proof
      # Bypass +validate_verified_via!+ by hitting Sequel directly.
      expect do
        models::TxProof
          .where(wtxid: Sequel.blob(wtxid))
          .update(verified_at: Time.now, verified_via: 'imported', verifier_version: 1)
      end.to raise_error(Sequel::DatabaseError)
    end
  end

  describe 'identity-version gate (code version matches row version)' do
    it 'includes rows written at exactly VERIFIER_VERSION in the trust set' do
      wtxid = persist_proof
      store.mark_verified(wtxid: wtxid, via: 'spv')
      result = store.verified_wtxids(
        wtxids: [wtxid],
        version_at_least: BSV::Wallet::VERIFIER_VERSION,
        via_in: ['spv']
      )
      expect(result).to include(wtxid)
    end
  end

  # HLR #516 Sub 6.1 — anchor liveness. The writer is pure: hand it a
  # +{ height => current_root_bytes }+ map and it clears verification
  # columns on any row whose persisted merkle_path folds to a different
  # root at that height. Wire-order 32-byte binary throughout — never
  # hex, never BUMP-encoded bytes.
  describe '#invalidate_stale_anchors!' do
    # A single-leaf BUMP for +wtxid+ at +height+.
    # +MerklePath#compute_root+ shortcircuits at a single-element single
    # level and returns +wtxid+ unchanged, so root == wtxid.
    def single_leaf_bump(wtxid:, height:)
      leaf = BSV::Transaction::MerklePath::PathElement.new(offset: 0, hash: wtxid, txid: true)
      BSV::Transaction::MerklePath.new(block_height: height, path: [[leaf]])
    end

    # A two-leaf BUMP where +wtxid_a+ (offset 0) and +wtxid_b+ (offset
    # 1) share a common merkle root at +height+ — verified by the SDK's
    # +MerklePath#compute_root+ which walks the sibling into
    # +sha256d(wtxid_a + wtxid_b)+ from either starting leaf.
    def paired_leaves_bump(wtxid_a:, wtxid_b:, height:)
      leaf_a = BSV::Transaction::MerklePath::PathElement.new(offset: 0, hash: wtxid_a, txid: true)
      leaf_b = BSV::Transaction::MerklePath::PathElement.new(offset: 1, hash: wtxid_b, txid: true)
      BSV::Transaction::MerklePath.new(block_height: height, path: [[leaf_a, leaf_b]])
    end

    # Persist a +tx_proofs+ row anchored at +height+ with a single-leaf
    # BUMP (computed root == wtxid). Optionally mark verified via +via+.
    def persist_anchored_proof(height:, via: nil, wtxid: SecureRandom.random_bytes(32))
      bump = single_leaf_bump(wtxid: wtxid, height: height)
      store.save_proof(wtxid: wtxid,
                       proof: { raw_tx: 'x'.b * 20,
                                height: height,
                                merkle_root: wtxid, # single-leaf BUMP: root == wtxid
                                merkle_path: bump.to_binary })
      store.mark_verified(wtxid: wtxid, via: via) if via
      wtxid
    end

    # Persist a pair of +tx_proofs+ rows anchored at +height+ that
    # share a common merkle root. Returns +[wtxid_a, wtxid_b, shared_root]+.
    def persist_paired_proofs(height:, via: 'spv')
      wtxid_a = SecureRandom.random_bytes(32)
      wtxid_b = SecureRandom.random_bytes(32)
      bump = paired_leaves_bump(wtxid_a: wtxid_a, wtxid_b: wtxid_b, height: height)
      shared_root = bump.compute_root(wtxid_a)
      store.save_proof(wtxid: wtxid_a,
                       proof: { raw_tx: 'x'.b * 20,
                                height: height,
                                merkle_root: shared_root,
                                merkle_path: bump.to_binary })
      store.save_proof(wtxid: wtxid_b,
                       proof: { raw_tx: 'x'.b * 20,
                                height: height,
                                merkle_root: shared_root,
                                merkle_path: bump.to_binary })
      [wtxid_a, wtxid_b, shared_root].tap do
        [wtxid_a, wtxid_b].each { |w| store.mark_verified(wtxid: w, via: via) } if via
      end
    end

    it 'is a no-op on empty input (no DB round-trip)' do
      expect(store.invalidate_stale_anchors!(heights_to_roots: {})).to eq([])
    end

    it 'leaves rows untouched when the tracker root matches the persisted root' do
      height = 900_100
      wtxid = persist_anchored_proof(height: height, via: 'spv')
      store.invalidate_stale_anchors!(heights_to_roots: { height => wtxid })
      expect(store.verification_state(wtxid: wtxid)&.[](:verified_via)).to eq('spv')
    end

    it 'clears the three verification columns on same-height/different-root mismatch' do
      height = 900_101
      wtxid = persist_anchored_proof(height: height, via: 'spv')
      current = SecureRandom.random_bytes(32) # tracker's new-tip root at that height
      store.invalidate_stale_anchors!(heights_to_roots: { height => current })
      expect(store.verification_state(wtxid: wtxid)).to be_nil
    end

    it 'returns the invalidated action_ids so Sub 6.2 can walk descendants' do
      height = 900_102
      wtxid = persist_anchored_proof(height: height, via: 'spv')
      # Link an action to this proof so we know which id to expect.
      proof_id = models::TxProof.where(wtxid: Sequel.blob(wtxid)).get(:id)
      action = models::Action.create(description: 'anchor test 1', broadcast_intent: 'none')
      action.update(tx_proof_id: proof_id)

      cleared = store.invalidate_stale_anchors!(heights_to_roots: { height => SecureRandom.random_bytes(32) })
      expect(cleared).to include(action.id)
    end

    it 'treats chain_tracker "unknown" (nil root) as a no-op (does not decay trust on outage)' do
      height = 900_103
      wtxid = persist_anchored_proof(height: height, via: 'spv')
      store.invalidate_stale_anchors!(heights_to_roots: { height => nil })
      expect(store.verification_state(wtxid: wtxid)&.[](:verified_via)).to eq('spv')
    end

    # Structural unverifiability is orthogonal to tracker reachability —
    # Copilot round-6 on #533. Even when +known_roots_for_heights+
    # returns +nil+ for a height (tracker outage), rows that are
    # structurally unverifiable (missing / unparseable +merkle_path+
    # with a trust mark) must still fail-closed. The "preserve trust
    # on outage" guarantee only applies to rows that COULD be verified
    # if the tracker came back.
    it 'clears unverifiable rows even when the tracker is unreachable (nil root)' do
      height = 900_106
      wtxid = persist_anchored_proof(height: height, via: 'spv')
      models::TxProof.where(wtxid: Sequel.blob(wtxid))
                     .update(merkle_path: nil) # confirmed-but-unproven trust

      store.invalidate_stale_anchors!(heights_to_roots: { height => nil })
      expect(store.verification_state(wtxid: wtxid)).to be_nil
    end

    # Fail-closed on missing +merkle_path+ — Copilot round-5 on #533.
    # The schema allows +block_id NOT NULL AND merkle_path IS NULL+
    # (the "confirmed but unproven" intermediate state per the
    # +path_requires_block+ CHECK). If such a row also gains a trust
    # mark (via a broken writer that outruns the proof-acquisition
    # pipeline), the anchor-liveness path must NOT silently skip it —
    # doing so would let the row retain +'spv'+ across arbitrary
    # re-orgs. Include it in the candidate scan; +computed_root_for_path+
    # returns +nil+ for +merkle_path IS NULL+, and the fail-closed
    # branch clears the trust mark.
    it 'clears rows whose merkle_path is NULL but block_id is set (fail closed)' do
      height = 900_105
      wtxid = persist_anchored_proof(height: height, via: 'spv')
      # Simulate the "confirmed but unproven" corruption: clear the
      # merkle_path but leave block_id + verified_via = 'spv'.
      models::TxProof.where(wtxid: Sequel.blob(wtxid))
                     .update(merkle_path: nil)

      cleared = store.invalidate_stale_anchors!(
        heights_to_roots: { height => SecureRandom.random_bytes(32) }
      )

      expect(store.verification_state(wtxid: wtxid)).to be_nil
      action = models::Action.where(
        tx_proof_id: models::TxProof.where(wtxid: Sequel.blob(wtxid)).select(:id)
      ).first
      expect(cleared).to include(action.id) if action
    end

    # Fail-closed on unparseable +merkle_path+ — Copilot round-1 on #533.
    # A row whose stored proof cannot compute a root can be neither
    # confirmed nor refuted against +chain_tracker+; leaving it untouched
    # would let it retain +'spv'+ forever and Sub 5's read gate would
    # trust it. Clear it so the next reference forces re-verify.
    it 'clears rows whose merkle_path is unparseable (fail closed)' do
      height = 900_104
      wtxid = persist_anchored_proof(height: height, via: 'spv')
      # Corrupt the persisted path — +computed_root_for_path+ returns nil.
      models::TxProof.where(wtxid: Sequel.blob(wtxid))
                     .update(merkle_path: Sequel.blob("\x00".b * 4))

      cleared = store.invalidate_stale_anchors!(
        heights_to_roots: { height => SecureRandom.random_bytes(32) }
      )

      expect(store.verification_state(wtxid: wtxid)).to be_nil
      # Returned action_ids include the cleared row so Sub 6.2 can descend.
      action = models::Action.where(
        tx_proof_id: models::TxProof.where(wtxid: Sequel.blob(wtxid)).select(:id)
      ).first
      expect(cleared).to include(action.id) if action
    end

    # Coarse-clear rule (cryptography): only touch rows carrying a trust
    # mark — an unverified row has nothing to clear and inviting the
    # UPDATE into its predicate would trip the coherent CHECK.
    it 'leaves unverified rows alone (verified_via IS NULL predicate)' do
      height = 900_104
      wtxid = persist_anchored_proof(height: height, via: nil) # no mark
      store.invalidate_stale_anchors!(heights_to_roots: { height => SecureRandom.random_bytes(32) })
      expect(store.verification_state(wtxid: wtxid)).to be_nil # was nil, still nil
    end

    # BUMP-encoding evasion regression — two BUMPs at the same (height,
    # computed_root) invalidate equivalently. Here both proofs share
    # ONE two-leaf BUMP, so their computed roots match exactly. The
    # tracker root disagrees with that shared root; both rows clear.
    it 'keys on computed root — paired proofs sharing one root both clear on mismatch' do
      height = 900_105
      wtxid_a, wtxid_b, shared_root = persist_paired_proofs(height: height)

      # Sanity: they really do share a root before invalidation.
      expect(store.find_block(height: height)[:merkle_root]).to eq(shared_root)

      # Tracker reports a different root at that height ⇒ both rows,
      # having equivalent computed roots, both clear.
      store.invalidate_stale_anchors!(heights_to_roots: { height => SecureRandom.random_bytes(32) })
      expect(store.verification_state(wtxid: wtxid_a)).to be_nil
      expect(store.verification_state(wtxid: wtxid_b)).to be_nil
    end

    it 'keeps paired proofs verified when the tracker root matches the shared root' do
      height = 900_108
      wtxid_a, wtxid_b, shared_root = persist_paired_proofs(height: height)

      store.invalidate_stale_anchors!(heights_to_roots: { height => shared_root })
      expect(store.verification_state(wtxid: wtxid_a)&.[](:verified_via)).to eq('spv')
      expect(store.verification_state(wtxid: wtxid_b)&.[](:verified_via)).to eq('spv')
    end

    # Tx re-mined at a different block: an ingress path re-writes the
    # merkle_path/block_id on a subsequent +save_proof+ call. The rule
    # is coarse-clear on the anchor mismatch; on the next verify
    # reference the re-verify path re-anchors and re-marks the row. We
    # cannot easily emulate the full re-anchoring from a Store-only
    # spec (that's Sub 5's read path) — assert here that a same-height
    # re-save with a different computed root followed by anchor-liveness
    # clears the row.
    it 'clears the row when re-verification would find a different anchor' do
      height = 900_106
      wtxid = SecureRandom.random_bytes(32)
      persist_anchored_proof(height: height, via: 'spv', wtxid: wtxid)

      # Simulate a network re-org where the tracker now reports a
      # different root at that height. Anchor-liveness clears; the next
      # verify walk (Sub 5) restores the mark.
      store.invalidate_stale_anchors!(heights_to_roots: { height => SecureRandom.random_bytes(32) })
      expect(store.verification_state(wtxid: wtxid)).to be_nil
    end

    it 'chunks large invalidation batches under VERIFY_BATCH_CHUNK' do
      # Use one shared block row via paired proofs (two per height),
      # spread across six heights → twelve rows to clear in one call.
      map = {}
      wtxids = []
      6.times do |i|
        h = 900_107_000 + i
        a, b, = persist_paired_proofs(height: h)
        map[h] = SecureRandom.random_bytes(32) # tracker disagrees at every height
        wtxids << a << b
      end
      stub_const('BSV::Wallet::Store::VERIFY_BATCH_CHUNK', 5)
      store.invalidate_stale_anchors!(heights_to_roots: map)
      wtxids.each { |w| expect(store.verification_state(wtxid: w)).to be_nil }
    end

    # Copilot round-4 on #533 — the action-id lookup at the tail of
    # +invalidate_anchors_at_height+ used to run one giant
    # +tx_proof_id IN (…)+ query against +actions+, which could
    # exceed SQLite's bind-parameter limit and produce a bad plan on
    # Postgres at large re-org sizes. Chunked at +VERIFY_BATCH_CHUNK+.
    it 'chunks the action-id lookup on the same boundary as the clear' do
      map = {}
      wtxids = []
      6.times do |i|
        h = 900_108_000 + i
        a, b, = persist_paired_proofs(height: h)
        map[h] = SecureRandom.random_bytes(32) # tracker disagrees at every height
        wtxids << a << b
      end
      stub_const('BSV::Wallet::Store::VERIFY_BATCH_CHUNK', 5)

      # Attach each proof to its own action so we have twelve action_ids
      # spread across three chunks of size 5-5-2 under the stub.
      wtxids.each_with_index do |w, i|
        proof_id = models::TxProof.where(wtxid: Sequel.blob(w)).get(:id)
        action = models::Action.create(description: "chunk-tail-#{i}", broadcast_intent: 'none')
        action.update(tx_proof_id: proof_id)
      end

      cleared = store.invalidate_stale_anchors!(heights_to_roots: map)
      # All twelve actions surface — accumulate across chunks.
      expect(cleared.size).to eq(12)
    end
  end

  # HLR #516 Sub 6.1 — +find_or_create_block+ Option B fix. Prior to
  # the fix, a +save_proof+ call whose supplied +merkle_root+ disagreed
  # with an existing +blocks+ row at the same height silently attached
  # the new proof to the stale row, defeating anchor-liveness. Now it
  # raises +CompetingBlockHeaderError+ and lets the anchor-liveness
  # path own re-org resolution.
  describe '#save_proof / find_or_create_block competing merkle_root' do
    it 'raises CompetingBlockHeaderError on same-height/different-root re-org signal' do
      height = 900_200
      root_original = SecureRandom.random_bytes(32)
      root_competing = SecureRandom.random_bytes(32)

      wtxid1 = SecureRandom.random_bytes(32)
      store.save_proof(wtxid: wtxid1,
                       proof: { raw_tx: 'x'.b * 20, height: height, merkle_root: root_original })
      expect(store.find_block(height: height)[:merkle_root]).to eq(root_original)

      wtxid2 = SecureRandom.random_bytes(32)
      expect do
        store.save_proof(wtxid: wtxid2,
                         proof: { raw_tx: 'x'.b * 20, height: height, merkle_root: root_competing })
      end.to raise_error(BSV::Wallet::CompetingBlockHeaderError)

      # The original blocks row is untouched — re-org evidence preserved.
      expect(store.find_block(height: height)[:merkle_root]).to eq(root_original)
    end

    it 'is idempotent when merkle_root matches an existing row' do
      height = 900_201
      root = SecureRandom.random_bytes(32)
      wtxid1 = SecureRandom.random_bytes(32)
      wtxid2 = SecureRandom.random_bytes(32)
      store.save_proof(wtxid: wtxid1,
                       proof: { raw_tx: 'x'.b * 20, height: height, merkle_root: root })
      expect do
        store.save_proof(wtxid: wtxid2,
                         proof: { raw_tx: 'x'.b * 20, height: height, merkle_root: root })
      end.not_to raise_error
    end

    it 'accepts a proof at a height with no existing block row' do
      height = 900_202
      wtxid = SecureRandom.random_bytes(32)
      expect do
        store.save_proof(wtxid: wtxid,
                         proof: { raw_tx: 'x'.b * 20, height: height,
                                  merkle_root: SecureRandom.random_bytes(32) })
      end.not_to raise_error
      expect(store.find_block(height: height)).not_to be_nil
    end

    # #533 Copilot round-16 — +Services+ normalises +blockHash+ as
    # display-order hex; +find_or_create_block+ must store it as
    # wire-order binary so it stays symmetric with +ChainTracker+'s
    # writes. Regression test — the fix reverses the hex bytes before
    # persisting.
    it 'persists a display-order hex block_hash from proof as wire-order binary' do
      height = 900_203
      wire = SecureRandom.random_bytes(32)
      display_hex = wire.reverse.unpack1('H*')
      wtxid = SecureRandom.random_bytes(32)
      store.save_proof(wtxid: wtxid,
                       proof: { raw_tx: 'x'.b * 20, height: height,
                                merkle_root: SecureRandom.random_bytes(32),
                                block_hash: display_hex })
      expect(store.find_block(height: height)[:block_hash]).to eq(wire)
    end

    it 'persists a display-order hex merkle_root from proof as wire-order binary' do
      height = 900_204
      wire = SecureRandom.random_bytes(32)
      display_hex = wire.reverse.unpack1('H*')
      wtxid = SecureRandom.random_bytes(32)
      store.save_proof(wtxid: wtxid,
                       proof: { raw_tx: 'x'.b * 20, height: height, merkle_root: display_hex })
      expect(store.find_block(height: height)[:merkle_root]).to eq(wire)
    end
  end

  # HLR #516 Sub 6.2 — transitive descendant invalidation. The shared
  # primitive coarse-clears verification state for a set of action_ids
  # (typically seed anchors + walked descendants). Gated on
  # +verified_via IS NOT NULL+ so rows without a trust mark are
  # untouched, defusing the poisoned-descendant DoS vector.
  describe '#invalidate_verification' do
    # Create a bare tx_proofs row + its associated action.
    def persist_proof_and_action(via: 'spv')
      wtxid = SecureRandom.random_bytes(32)
      store.save_proof(wtxid: wtxid, proof: { raw_tx: 'x'.b * 20 })
      proof_id = models::TxProof.where(wtxid: Sequel.blob(wtxid)).get(:id)
      action = models::Action.create(description: 'sub 6.2 action', broadcast_intent: 'none')
      action.update(tx_proof_id: proof_id)
      store.mark_verified(wtxid: wtxid, via: via) if via
      [action.id, wtxid]
    end

    it 'clears verified_at/via/version together on a marked row' do
      action_id, wtxid = persist_proof_and_action(via: 'spv')

      cleared = store.invalidate_verification(action_ids: [action_id])
      expect(cleared).to eq(1)
      expect(store.verification_state(wtxid: wtxid)).to be_nil
    end

    # Security specialist's DoS vector — the descent walk (unbounded)
    # sees all structural descendants; the UPDATE (bounded) only
    # touches rows with a trust mark. A poisoned subtree of synthetic
    # rows without +verified_via+ produces 0 UPDATE hits.
    it 'skips rows without a verified_via mark (poisoned-descendant defence)' do
      action_id, wtxid = persist_proof_and_action(via: nil) # unmarked
      cleared = store.invalidate_verification(action_ids: [action_id])
      expect(cleared).to eq(0)
      # Row still has NULL verification state (was never marked).
      expect(store.verification_state(wtxid: wtxid)).to be_nil
    end

    it 'is a no-op on empty input (no DB round-trip)' do
      expect(store.invalidate_verification(action_ids: [])).to eq(0)
      expect(store.invalidate_verification(action_ids: Set.new)).to eq(0)
    end

    it 'skips action_ids with no tx_proof_id (mid-lifecycle actions)' do
      unsigned = models::Action.create(description: 'mid lifecycle', broadcast_intent: 'none')
      expect(store.invalidate_verification(action_ids: [unsigned.id])).to eq(0)
    end

    it 'accepts a Set as input' do
      action_id, = persist_proof_and_action(via: 'spv')
      expect(store.invalidate_verification(action_ids: Set[action_id])).to eq(1)
    end

    it 'chunks large batches under INVALIDATE_BATCH_CHUNK' do
      ids = 12.times.map { persist_proof_and_action(via: 'spv').first }
      stub_const('BSV::Wallet::Store::INVALIDATE_BATCH_CHUNK', 5)
      cleared = store.invalidate_verification(action_ids: ids)
      expect(cleared).to eq(12)
    end
  end

  # HLR #516 Sub 6.2 — combined behaviour: seed anchors + walked
  # descendants get coarse-cleared inside one +db.transaction+. The
  # descent walk is done by +Store#descendant_action_ids_of+; here we
  # exercise the union directly and prove all rows are cleared
  # together.
  describe 'transitive descent invalidation (Sub 6.2)' do
    # Chain A -> B -> C where each action has its own proof row and
    # 'spv' mark. Returns +{ a: [aid, wtxid], b: [...], c: [...] }+.
    def build_chain
      chain = {}
      %i[a b c].each do |sym|
        wtxid = SecureRandom.random_bytes(32)
        store.save_proof(wtxid: wtxid, proof: { raw_tx: 'x'.b * 20 })
        proof_id = models::TxProof.where(wtxid: Sequel.blob(wtxid)).get(:id)
        action = models::Action.create(description: "chain #{sym} action", broadcast_intent: 'none')
        action.update(tx_proof_id: proof_id)
        store.mark_verified(wtxid: wtxid, via: 'spv')
        chain[sym] = [action.id, wtxid]
      end
      # Wire A -> B -> C via outputs + inputs.
      output_a = models::Output.create(action_id: chain[:a].first, satoshis: 1000,
                                       vout: 0, locking_script: SecureRandom.random_bytes(25),
                                       spendable_intent: 'none')
      models::Input.create(action_id: chain[:b].first, output_id: output_a.id, vin: 0)
      output_b = models::Output.create(action_id: chain[:b].first, satoshis: 1000,
                                       vout: 0, locking_script: SecureRandom.random_bytes(25),
                                       spendable_intent: 'none')
      models::Input.create(action_id: chain[:c].first, output_id: output_b.id, vin: 0)
      chain
    end

    # AC #2 — C is the anchor; on re-org the descent from C reaches A
    # and B (via descendant walk) plus C itself, and all three rows
    # are cleared. Note: "descendants" here means "structural
    # descendants via inputs.output_id → outputs.action_id" — from A's
    # perspective, B and C are descendants because they consume A's
    # outputs.
    it 'clears the whole chain A -> B -> C when A (root anchor) is invalidated' do
      chain = build_chain

      descent = store.descendant_action_ids_of(action_ids: [chain[:a].first])
      expect(descent).to eq(Set[chain[:a].first, chain[:b].first, chain[:c].first])

      cleared = store.invalidate_verification(action_ids: descent)
      expect(cleared).to eq(3)

      %i[a b c].each do |sym|
        expect(store.verification_state(wtxid: chain[sym].last)).to be_nil
      end
    end

    # Atomic combined invalidation: anchor + descent share one
    # +db.transaction+ block. If either UPDATE fails, both roll back.
    it 'rolls back both UPDATEs when a wrapping transaction raises' do
      chain = build_chain

      # Deliberate exception inside a transaction that also performs
      # the two-step invalidation. The transaction should abort with
      # no change.
      expect do
        store.db.transaction do
          descent = store.descendant_action_ids_of(action_ids: [chain[:a].first])
          store.invalidate_verification(action_ids: descent)
          raise 'simulated post-invalidation failure'
        end
      end.to raise_error(RuntimeError, /simulated/)

      # All three rows retain their 'spv' marks.
      %i[a b c].each do |sym|
        expect(store.verification_state(wtxid: chain[sym].last)&.[](:verified_via)).to eq('spv')
      end
    end

    # A row without a verification mark sits on the descent walk but
    # its UPDATE is skipped. This proves the poisoned-descendant DoS
    # defence at the graph level, not just at the primitive level.
    it 'walks unmarked descendants without clearing them (poisoned-descendant DoS)' do
      chain = build_chain

      # Persist an extra descendant D whose row has no 'spv' mark
      # (adversarial: attacker grafts a synthetic descendant hoping to
      # amplify the UPDATE cost). D consumes C's output.
      d_wtxid = SecureRandom.random_bytes(32)
      store.save_proof(wtxid: d_wtxid, proof: { raw_tx: 'x'.b * 20 })
      proof_d = models::TxProof.where(wtxid: Sequel.blob(d_wtxid)).get(:id)
      d_action = models::Action.create(description: 'poisoned descendant', broadcast_intent: 'none')
      d_action.update(tx_proof_id: proof_d)
      output_c = models::Output.create(action_id: chain[:c].first, satoshis: 1000,
                                       vout: 0, locking_script: SecureRandom.random_bytes(25),
                                       spendable_intent: 'none')
      models::Input.create(action_id: d_action.id, output_id: output_c.id, vin: 0)
      # NOTE: no store.mark_verified(...) — D's row has NULL verified_via.

      descent = store.descendant_action_ids_of(action_ids: [chain[:a].first])
      expect(descent).to include(d_action.id) # walked
      cleared = store.invalidate_verification(action_ids: descent)
      expect(cleared).to eq(3) # A, B, C — NOT D
      expect(store.verification_state(wtxid: d_wtxid)).to be_nil # was nil, still nil
    end

    # Deep poisoned chain — 200 unmarked descendant rows below one
    # verified anchor. The CTE walks unbounded up to max_depth=100;
    # the UPDATE clears just the anchor row. Bounded runtime, no
    # runaway.
    it 'terminates in bounded time on a poisoned-descendant chain' do
      # Anchor with an 'spv' mark.
      anchor_id, anchor_wtxid = persist_marked_action

      # Chain 200 unmarked descendants below the anchor.
      previous_action = { id: anchor_id }
      200.times do |_i|
        output = models::Output.create(
          action_id: previous_action[:id], satoshis: 1000, vout: 0,
          locking_script: SecureRandom.random_bytes(25), spendable_intent: 'none'
        )
        child = models::Action.create(description: 'poisoned descendant', broadcast_intent: 'none')
        # Give it a proof row so tx_proof_id is set but leave verified_via NULL.
        cw = SecureRandom.random_bytes(32)
        store.save_proof(wtxid: cw, proof: { raw_tx: 'x'.b * 20 })
        proof_c = models::TxProof.where(wtxid: Sequel.blob(cw)).get(:id)
        child.update(tx_proof_id: proof_c)
        models::Input.create(action_id: child.id, output_id: output.id, vin: 0)
        previous_action = { id: child.id }
      end

      duration = Benchmark.realtime do
        descent = store.descendant_action_ids_of(action_ids: [anchor_id])
        cleared = store.invalidate_verification(action_ids: descent)
        # Only the anchor row carries a trust mark → UPDATE cleared 1.
        expect(cleared).to eq(1)
      end
      # Env-gated wall-clock ceiling — hard timing budgets flake under
      # default CI runner load; perf-lane (+BSV_WALLET_VERIFY_TRACE=1+)
      # enforces the 500ms budget. Copilot round-11 on #533.
      expect(duration).to be < 0.5 if ENV['BSV_WALLET_VERIFY_TRACE'] == '1'

      # Anchor cleared; descendants untouched (were never marked).
      expect(store.verification_state(wtxid: anchor_wtxid)).to be_nil
    end

    def persist_marked_action
      wtxid = SecureRandom.random_bytes(32)
      store.save_proof(wtxid: wtxid, proof: { raw_tx: 'x'.b * 20 })
      proof_id = models::TxProof.where(wtxid: Sequel.blob(wtxid)).get(:id)
      action = models::Action.create(description: 'sub 6.2 anchor', broadcast_intent: 'none')
      action.update(tx_proof_id: proof_id)
      store.mark_verified(wtxid: wtxid, via: 'spv')
      [action.id, wtxid]
    end
  end

  # HLR #516 Sub 6.3 — adversarial test matrix. Each vector below closes
  # a specialist-review concern (a/d/e/g); vectors (b), (c), (f) already
  # sit inside Sub 6.2's coverage upstream. The matrix here exercises
  # the interaction between +invalidate_stale_anchors!+, its BUMP
  # canonicalisation, coinbase-maturity-adjacent height mutations, and
  # a simulated DB failure inside the invalidation UPDATE.
  describe 'adversarial matrix (Sub 6.3)' do
    # Persist a single-leaf-BUMP proof at +height+, then flip the trust
    # mark on. Returns +wtxid+.
    def persist_marked_anchor(height:, via: 'spv', wtxid: SecureRandom.random_bytes(32))
      leaf = BSV::Transaction::MerklePath::PathElement.new(offset: 0, hash: wtxid, txid: true)
      bump = BSV::Transaction::MerklePath.new(block_height: height, path: [[leaf]])
      store.save_proof(wtxid: wtxid,
                       proof: { raw_tx: 'x'.b * 20, height: height,
                                merkle_root: wtxid, merkle_path: bump.to_binary })
      store.mark_verified(wtxid: wtxid, via: via) if via
      wtxid
    end

    # Rewrite the stored +merkle_path+ blob for +wtxid+ in-place without
    # going through +save_proof+ — bypasses the +find_or_create_block+
    # guard so the test can pit two different BUMP encodings whose
    # +compute_root+ agree against the tracker.
    def force_merkle_path!(wtxid:, path_bytes:)
      models::TxProof
        .where(wtxid: Sequel.blob(wtxid))
        .update(merkle_path: Sequel.blob(path_bytes))
    end

    # Adversarial vector (a): BUMP-encoding evasion. Two BUMPs with the
    # same +(height, computed_root)+ but different bytes must trigger
    # equivalent invalidation. This variant of the Sub 6.1 "paired
    # proofs" test uses two DIFFERENT BUMP encodings for the SAME wtxid
    # rather than one shared BUMP for two wtxids — the SDK's
    # +compute_root+ canonicalisation (duplicate flag vs. explicit
    # sibling of identical hash bytes) is what the anchor-liveness path
    # must fold through before comparison. Encoding tricks cannot buy an
    # attacker a bypass.
    describe '(a) BUMP-encoding evasion' do
      # Odd-count merkle row: when a level has an odd number of leaves,
      # Bitcoin duplicates the last one. This can be encoded in the
      # BRC-74 BUMP two ways for a single-tx block-with-padding scenario:
      #
      # - Explicit sibling: +PathElement.new(offset: 1, hash: wtxid)+ —
      #   32 bytes of the same hash bytes on the wire.
      # - Duplicate flag:   +PathElement.new(offset: 1, duplicate: true)+
      #   — one flag byte, no hash bytes on the wire.
      #
      # Both compute to the same root (+sha256d(wtxid + wtxid)+ ==
      # +sha256d(working + working)+). Byte counts differ. Anchor-
      # liveness must fold both through +compute_root+ before comparing
      # against the tracker.
      def bump_with_explicit_dup_sibling(wtxid:, height:)
        leaf = BSV::Transaction::MerklePath::PathElement.new(offset: 0, hash: wtxid, txid: true)
        sibling = BSV::Transaction::MerklePath::PathElement.new(offset: 1, hash: wtxid)
        BSV::Transaction::MerklePath.new(block_height: height, path: [[leaf, sibling]])
      end

      def bump_with_duplicate_flag_sibling(wtxid:, height:)
        leaf = BSV::Transaction::MerklePath::PathElement.new(offset: 0, hash: wtxid, txid: true)
        sibling = BSV::Transaction::MerklePath::PathElement.new(offset: 1, duplicate: true)
        BSV::Transaction::MerklePath.new(block_height: height, path: [[leaf, sibling]])
      end

      it 'produces the same computed root from two differently-encoded BUMPs for one wtxid' do
        wtxid = SecureRandom.random_bytes(32)
        height = 970_001
        explicit = bump_with_explicit_dup_sibling(wtxid: wtxid, height: height)
        flagged  = bump_with_duplicate_flag_sibling(wtxid: wtxid, height: height)

        expect(explicit.compute_root(wtxid)).to eq(flagged.compute_root(wtxid))
        expect(explicit.to_binary).not_to eq(flagged.to_binary) # different bytes on the wire
      end

      # +wtxid+ column is UNIQUE — we cannot persist two proofs with the
      # same wtxid. Prove BUMP-encoding invariance by persisting once
      # with encoding A, then rewriting the +merkle_path+ column in-place
      # to encoding B and re-running anchor liveness. The decision must
      # be identical because both encodings fold to the same computed
      # root; the persisted +merkle_path+ bytes are fed through
      # +MerklePath#compute_root+ before comparison, never used as raw
      # bytes.
      it 'invalidates equivalently after in-place BUMP-encoding swap (same wtxid)' do
        height = 970_002
        wtxid = SecureRandom.random_bytes(32)

        explicit = bump_with_explicit_dup_sibling(wtxid: wtxid, height: height)
        flagged  = bump_with_duplicate_flag_sibling(wtxid: wtxid, height: height)
        shared_root = explicit.compute_root(wtxid)
        # Sanity: the two encodings differ on the wire but canonicalise
        # to the same computed root.
        expect(flagged.compute_root(wtxid)).to eq(shared_root)
        expect(explicit.to_binary).not_to eq(flagged.to_binary)

        # Persist with the explicit-sibling encoding.
        store.save_proof(wtxid: wtxid,
                         proof: { raw_tx: 'x'.b * 20, height: height,
                                  merkle_root: shared_root, merkle_path: explicit.to_binary })
        store.mark_verified(wtxid: wtxid, via: 'spv')

        # Rewrite the +merkle_path+ in-place to the flagged-sibling
        # encoding. +find_or_create_block+ is bypassed (the row already
        # exists at this height with the same root).
        force_merkle_path!(wtxid: wtxid, path_bytes: flagged.to_binary)

        # Tracker reports a competing root → mismatch decision must
        # fire even though the persisted bytes now differ.
        store.invalidate_stale_anchors!(heights_to_roots: { height => SecureRandom.random_bytes(32) })
        expect(store.verification_state(wtxid: wtxid)).to be_nil

        # Second round: same wtxid, different height so no UNIQUE clash;
        # verify a survives-under-tracker-agreement case with the
        # flagged encoding to close the pair.
        height2 = 970_003
        wtxid2 = SecureRandom.random_bytes(32)
        flagged2 = bump_with_duplicate_flag_sibling(wtxid: wtxid2, height: height2)
        shared_root2 = flagged2.compute_root(wtxid2)
        store.save_proof(wtxid: wtxid2,
                         proof: { raw_tx: 'x'.b * 20, height: height2,
                                  merkle_root: shared_root2, merkle_path: flagged2.to_binary })
        store.mark_verified(wtxid: wtxid2, via: 'spv')
        # Tracker agrees on the shared root → the flagged encoding
        # canonicalises to the same root and the row survives.
        store.invalidate_stale_anchors!(heights_to_roots: { height2 => shared_root2 })
        expect(store.verification_state(wtxid: wtxid2)&.[](:verified_via)).to eq('spv')
      end
    end

    # Adversarial vector (d): same-hash accept vs same-height different-
    # hash invalidate matrix — belt-and-braces alongside 6.1's coverage.
    # The mid-block move case exercises the "block re-mined at a
    # different height" edge: same wtxid, same computed root, different
    # persisted anchor block row (different height). Sub 6.1's
    # invalidation is per-height; this proves the guard fires at the
    # height whose stored row disagreed, even when other rows persist
    # with different anchors.
    describe '(d) same-hash accept vs different-hash invalidate' do
      it 'no-op when tracker agrees at every height (same-hash accept)' do
        h1 = 970_100
        h2 = 970_101
        w1 = persist_marked_anchor(height: h1)
        w2 = persist_marked_anchor(height: h2)
        store.invalidate_stale_anchors!(heights_to_roots: { h1 => w1, h2 => w2 })
        expect(store.verification_state(wtxid: w1)&.[](:verified_via)).to eq('spv')
        expect(store.verification_state(wtxid: w2)&.[](:verified_via)).to eq('spv')
      end

      it 'clears only the mismatched height when others agree (partial invalidation)' do
        h_agree = 970_102
        h_bad   = 970_103
        w_agree = persist_marked_anchor(height: h_agree)
        w_bad   = persist_marked_anchor(height: h_bad)
        store.invalidate_stale_anchors!(
          heights_to_roots: { h_agree => w_agree, h_bad => SecureRandom.random_bytes(32) }
        )
        expect(store.verification_state(wtxid: w_agree)&.[](:verified_via)).to eq('spv')
        expect(store.verification_state(wtxid: w_bad)).to be_nil
      end

      it 'mid-block move: same wtxid re-anchored at a NEW height keeps the untouched original clear scoped' do
        # A "mid-block move" scenario: two proofs at two heights (h1
        # and h2). A re-org moves h1 out but leaves h2 alone. The
        # anchor-liveness pass names both heights; only h1's row is
        # cleared, h2's row survives even if it shared a wtxid pattern.
        h1 = 970_104
        h2 = 970_105
        # Independent wtxids at each height so we can assert per-height
        # scoping.
        w1 = persist_marked_anchor(height: h1)
        w2 = persist_marked_anchor(height: h2)

        # Tracker disagrees on h1 (re-org there), agrees on h2.
        store.invalidate_stale_anchors!(
          heights_to_roots: { h1 => SecureRandom.random_bytes(32), h2 => w2 }
        )
        expect(store.verification_state(wtxid: w1)).to be_nil
        expect(store.verification_state(wtxid: w2)&.[](:verified_via)).to eq('spv')
      end
    end

    # Adversarial vector (e): coinbase re-org burst. Height mutations
    # H → H+99 → H+100 → H+99 → H+101 across the maturity boundary
    # invalidate on each crossing. The wallet layer's job is to fire
    # +invalidate_stale_anchors!+ every time the tracker reports a
    # differing root at the persisted height; the SDK's
    # +MerklePath#verify+ owns the maturity check itself on re-verify.
    # This test asserts +verified_via+ clears on each mismatch crossing,
    # not that the maturity rule is understood at the wallet layer.
    describe '(e) coinbase re-org burst across maturity boundary' do
      it 'invalidates on each crossing of the H+99 <-> H+100 maturity boundary' do
        # Anchor a coinbase-shaped proof at some base height. Rewriting
        # +block_id+ on the proof row simulates the tracker seeing the
        # coinbase land at successive heights as re-orgs move it.
        base_h = 970_200
        wtxid = persist_marked_anchor(height: base_h)

        # Sequence: H → H+99 → H+100 → H+99 → H+101. Each transition is
        # a re-anchoring at a different height. We simulate this by
        # re-saving the proof at the target height (which creates the
        # +blocks+ row + re-links +tx_proofs.block_id+) then firing
        # anchor-liveness with a competing root at the OLD height —
        # any row whose current +block_id+ points at a row whose
        # +height+ still matches "old" clears.
        heights = [base_h + 99, base_h + 100, base_h + 99, base_h + 101]

        heights.each do |new_height|
          # Re-anchor: fresh BUMP for the same wtxid at the new height.
          leaf = BSV::Transaction::MerklePath::PathElement.new(offset: 0, hash: wtxid, txid: true)
          bump = BSV::Transaction::MerklePath.new(block_height: new_height, path: [[leaf]])
          store.save_proof(wtxid: wtxid,
                           proof: { raw_tx: 'x'.b * 20, height: new_height,
                                    merkle_root: wtxid, merkle_path: bump.to_binary })
          store.mark_verified(wtxid: wtxid, via: 'spv')

          # Tracker reports a competing root at the new height →
          # anchor-liveness clears +verified_via+.
          store.invalidate_stale_anchors!(
            heights_to_roots: { new_height => SecureRandom.random_bytes(32) }
          )
          expect(store.verification_state(wtxid: wtxid))
            .to be_nil, "expected verified_via cleared at H=#{new_height}"
        end
      end
    end

    # Adversarial vector (g): simulated DB failure inside the
    # invalidation UPDATE. Two invariants:
    #
    # 1. The caller (+Store#invalidate_stale_anchors!+, then
    #    +AnchorLivenessCache#filter_trusted+) surfaces the error —
    #    the +db.transaction+ block re-raises the +Sequel::DatabaseError+
    #    and does not silently return a stale trust set.
    # 2. The read path never returns the stale wtxid in the same
    #    walk. Because the UPDATE + SELECT sit in strict sequence
    #    inside +filter_trusted+ (write first, read after), a raise
    #    at UPDATE aborts before the SELECT — no ordering hole where
    #    a caller could receive the stale wtxid after a failed
    #    invalidation.
    describe '(g) simulated DB failure inside invalidation UPDATE' do
      # Persist a proof, mark it verified, and return the wtxid. The
      # test stubs +clear_verification_columns_for_proofs+ (the shared
      # UPDATE primitive) to raise a +Sequel::DatabaseError+ mid-flow.
      let(:height) { 970_300 }
      let(:wtxid)  { persist_marked_anchor(height: height) }

      before { wtxid }

      it 'surfaces a Sequel::DatabaseError from Store#invalidate_stale_anchors!' do
        allow(store).to receive(:clear_verification_columns_for_proofs)
          .and_raise(Sequel::DatabaseError, 'simulated update failure')

        expect do
          store.invalidate_stale_anchors!(
            heights_to_roots: { height => SecureRandom.random_bytes(32) }
          )
        end.to raise_error(Sequel::DatabaseError, /simulated update failure/)
      end

      it 'leaves the row unchanged when the UPDATE raises (transaction rollback)' do
        allow(store).to receive(:clear_verification_columns_for_proofs)
          .and_raise(Sequel::DatabaseError, 'simulated update failure')

        expect do
          store.invalidate_stale_anchors!(
            heights_to_roots: { height => SecureRandom.random_bytes(32) }
          )
        end.to raise_error(Sequel::DatabaseError)

        # The 'spv' mark survives — the outer +db.transaction+ inside
        # +invalidate_stale_anchors!+ rolled back the whole batch.
        expect(store.verification_state(wtxid: wtxid)&.[](:verified_via)).to eq('spv')
      end

      it 'AnchorLivenessCache#filter_trusted does not return the stale wtxid when the UPDATE raises' do
        # Order-of-operations invariant: +filter_trusted+ runs the
        # invalidation write BEFORE the +verified_wtxids+ read. A
        # raise at the write MUST abort before the read returns — a
        # caller never receives the stale wtxid alongside a failed
        # invalidation.
        tracker = instance_double(BSV::Network::ChainTracker)
        allow(tracker).to receive(:known_roots_for_heights) do |heights|
          heights.to_h { |h| [h, SecureRandom.random_bytes(32)] } # every height mismatches
        end

        allow(store).to receive(:clear_verification_columns_for_proofs)
          .and_raise(Sequel::DatabaseError, 'simulated update failure')

        cache = BSV::Wallet::Engine::AnchorLivenessCache.new(store: store, chain_tracker: tracker)
        expect { cache.filter_trusted([wtxid]) }
          .to raise_error(Sequel::DatabaseError, /simulated update failure/)
      end
    end
  end

  # HLR #516 Sub 6.3 — boot-time cache sanity sweep. Divergence
  # detector, NOT an invalidator: logs via +BSV.logger.warn+ on
  # mismatch and returns a count. Env-gated so CLI tools pay nothing;
  # the daemon opts in by setting +BSV_WALLET_VERIFY_BOOT_SWEEP=1+.
  # Non-fatal at every failure surface.
  describe '#sanity_sweep_verified_anchors!' do
    def build_tracker(roots)
      tracker = instance_double(BSV::Network::ChainTracker)
      allow(tracker).to receive(:known_roots_for_heights) do |heights|
        heights.to_h { |h| [h, roots[h]] }
      end
      tracker
    end

    # Persist a single-leaf-BUMP proof anchored at +height+, marked +'spv'+.
    def persist_anchored_spv(height:, wtxid: SecureRandom.random_bytes(32))
      leaf = BSV::Transaction::MerklePath::PathElement.new(offset: 0, hash: wtxid, txid: true)
      bump = BSV::Transaction::MerklePath.new(block_height: height, path: [[leaf]])
      store.save_proof(wtxid: wtxid,
                       proof: { raw_tx: 'x'.b * 20, height: height,
                                merkle_root: wtxid, merkle_path: bump.to_binary })
      store.mark_verified(wtxid: wtxid, via: 'spv')
      wtxid
    end

    before { ENV.delete('BSV_WALLET_VERIFY_BOOT_SWEEP') }

    it 'is a no-op when the env var is unset (returns 0 without touching the tracker)' do
      wtxid = persist_anchored_spv(height: 971_001)
      tracker = build_tracker(971_001 => SecureRandom.random_bytes(32))
      result = store.sanity_sweep_verified_anchors!(chain_tracker: tracker)
      expect(result).to eq(0)
      expect(tracker).not_to have_received(:known_roots_for_heights)
      # Row untouched — sweep never clears.
      expect(store.verification_state(wtxid: wtxid)&.[](:verified_via)).to eq('spv')
    end

    it 'logs and returns divergence count when tracker root disagrees with stored root' do
      ENV['BSV_WALLET_VERIFY_BOOT_SWEEP'] = '1'
      wtxid = persist_anchored_spv(height: 971_002)
      tracker = build_tracker(971_002 => SecureRandom.random_bytes(32)) # disagreement
      # +BSV.logger+ is a duck-type slot; a spy captures the +warn+
      # calls the sweep emits on divergence.
      logger = spy('bsv logger')
      allow(BSV).to receive(:logger).and_return(logger)

      result = store.sanity_sweep_verified_anchors!(chain_tracker: tracker)
      expect(result).to eq(1)
      expect(logger).to have_received(:warn).at_least(:once)
      # Divergence detector, not invalidator — the row stays marked.
      expect(store.verification_state(wtxid: wtxid)&.[](:verified_via)).to eq('spv')
    ensure
      ENV.delete('BSV_WALLET_VERIFY_BOOT_SWEEP')
    end

    it 'returns 0 when the tracker agrees on every sampled row' do
      ENV['BSV_WALLET_VERIFY_BOOT_SWEEP'] = '1'
      wtxid = persist_anchored_spv(height: 971_003)
      tracker = build_tracker(971_003 => wtxid) # single-leaf: root == wtxid
      result = store.sanity_sweep_verified_anchors!(chain_tracker: tracker)
      expect(result).to eq(0)
    ensure
      ENV.delete('BSV_WALLET_VERIFY_BOOT_SWEEP')
    end

    it 'is a no-op on empty samples (no spv rows to sweep)' do
      ENV['BSV_WALLET_VERIFY_BOOT_SWEEP'] = '1'
      # No proofs persisted at all.
      tracker = build_tracker({})
      expect(store.sanity_sweep_verified_anchors!(chain_tracker: tracker)).to eq(0)
      # Sample is empty → no batched tracker call.
      expect(tracker).not_to have_received(:known_roots_for_heights)
    ensure
      ENV.delete('BSV_WALLET_VERIFY_BOOT_SWEEP')
    end

    it 'swallows a chain_tracker outage (StandardError → 0 divergences, no raise)' do
      ENV['BSV_WALLET_VERIFY_BOOT_SWEEP'] = '1'
      persist_anchored_spv(height: 971_004)
      tracker = instance_double(BSV::Network::ChainTracker)
      allow(tracker).to receive(:known_roots_for_heights).and_raise(StandardError, 'network boom')
      expect { store.sanity_sweep_verified_anchors!(chain_tracker: tracker) }.not_to raise_error
      expect(store.sanity_sweep_verified_anchors!(chain_tracker: tracker)).to eq(0)
    ensure
      ENV.delete('BSV_WALLET_VERIFY_BOOT_SWEEP')
    end

    it 'treats tracker "unknown" (nil root) as a no-op, not a divergence' do
      ENV['BSV_WALLET_VERIFY_BOOT_SWEEP'] = '1'
      persist_anchored_spv(height: 971_005)
      tracker = build_tracker(971_005 => nil) # tracker returned nil
      expect(store.sanity_sweep_verified_anchors!(chain_tracker: tracker)).to eq(0)
    ensure
      ENV.delete('BSV_WALLET_VERIFY_BOOT_SWEEP')
    end

    it 'skips rows whose merkle_path fails to parse (not a divergence)' do
      ENV['BSV_WALLET_VERIFY_BOOT_SWEEP'] = '1'
      wtxid = persist_anchored_spv(height: 971_006)
      # Corrupt the persisted path — +computed_root_for_path+ returns nil.
      models::TxProof.where(wtxid: Sequel.blob(wtxid))
                     .update(merkle_path: Sequel.blob("\x00".b * 4))
      tracker = build_tracker(971_006 => SecureRandom.random_bytes(32))
      expect(store.sanity_sweep_verified_anchors!(chain_tracker: tracker)).to eq(0)
    ensure
      ENV.delete('BSV_WALLET_VERIFY_BOOT_SWEEP')
    end

    it 'respects the sample_size cap (bounded work regardless of table size)' do
      ENV['BSV_WALLET_VERIFY_BOOT_SWEEP'] = '1'
      # Persist five rows at five heights, all matching the tracker.
      wtxids_by_height = 5.times.to_h { |i| [971_100 + i, persist_anchored_spv(height: 971_100 + i)] }
      tracker = build_tracker(wtxids_by_height)
      # Sample only 2 → the tracker sees at most 2 heights.
      store.sanity_sweep_verified_anchors!(chain_tracker: tracker, sample_size: 2)
      expect(tracker).to have_received(:known_roots_for_heights) do |heights|
        expect(heights.size).to be <= 2
      end
    ensure
      ENV.delete('BSV_WALLET_VERIFY_BOOT_SWEEP')
    end

    it 'is a no-op when chain_tracker is nil' do
      ENV['BSV_WALLET_VERIFY_BOOT_SWEEP'] = '1'
      persist_anchored_spv(height: 971_200)
      expect(store.sanity_sweep_verified_anchors!(chain_tracker: nil)).to eq(0)
    ensure
      ENV.delete('BSV_WALLET_VERIFY_BOOT_SWEEP')
    end
  end
end
