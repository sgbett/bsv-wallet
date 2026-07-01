# frozen_string_literal: true

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
end
