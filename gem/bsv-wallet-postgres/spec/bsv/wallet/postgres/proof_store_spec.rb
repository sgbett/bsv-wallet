# frozen_string_literal: true

RSpec.describe BSV::Wallet::Postgres::Store::ProofStore do
  subject(:proof_store) { described_class.new }

  let(:wtxid) { SecureRandom.random_bytes(32) }
  let(:proof_data) do
    {
      height: 800_000,
      block_index: 42,
      merkle_path: SecureRandom.random_bytes(64),
      raw_tx: SecureRandom.random_bytes(100),
      block_hash: SecureRandom.random_bytes(32),
      merkle_root: SecureRandom.random_bytes(32)
    }
  end

  describe 'interface conformance' do
    it 'includes BSV::Wallet::Interface::ProofStore' do
      expect(described_class.ancestors).to include(BSV::Wallet::Interface::ProofStore)
    end
  end

  describe '#save_proof' do
    it 'creates a new proof' do
      id = proof_store.save_proof(wtxid: wtxid, proof: proof_data)
      expect(id).to be_a(Integer)
    end

    it 'upserts an existing proof' do
      id1 = proof_store.save_proof(wtxid: wtxid, proof: proof_data)
      new_merkle_root = SecureRandom.random_bytes(32)
      id2 = proof_store.save_proof(wtxid: wtxid, proof: proof_data.merge(
        height: 800_001, merkle_root: new_merkle_root
      ))

      expect(id2).to eq(id1)
      record = BSV::Wallet::Postgres::Store::TxProof[id1]
      expect(record.block.height).to eq(800_001)
    end

    it 'preserves binary data' do
      proof_store.save_proof(wtxid: wtxid, proof: proof_data)
      record = BSV::Wallet::Postgres::Store::TxProof.first(wtxid: Sequel.blob(wtxid))

      expect(record.wtxid.encoding).to eq(Encoding::BINARY)
      expect(record.merkle_path.encoding).to eq(Encoding::BINARY)
      expect(record.block.block_hash.encoding).to eq(Encoding::BINARY)
      expect(record.merkle_path).to eq(proof_data[:merkle_path])
    end

    it 'reuses an existing block for proofs at the same height' do
      wtxid2 = SecureRandom.random_bytes(32)
      id1 = proof_store.save_proof(wtxid: wtxid, proof: proof_data)
      id2 = proof_store.save_proof(wtxid: wtxid2, proof: proof_data.merge(
        raw_tx: SecureRandom.random_bytes(100)
      ))

      proof1 = BSV::Wallet::Postgres::Store::TxProof[id1]
      proof2 = BSV::Wallet::Postgres::Store::TxProof[id2]
      expect(proof1.block_id).to eq(proof2.block_id)
      expect(BSV::Wallet::Postgres::Store::Block.where(height: 800_000).count).to eq(1)
    end

    it 'saves proof without block when merkle_root is absent' do
      proof_without_root = proof_data.reject { |k, _| %i[merkle_root block_hash].include?(k) }
      id = proof_store.save_proof(wtxid: wtxid, proof: proof_without_root)

      record = BSV::Wallet::Postgres::Store::TxProof[id]
      expect(record.block_id).to be_nil
    end
  end

  describe '#find_proof' do
    it 'returns the proof hash' do
      proof_store.save_proof(wtxid: wtxid, proof: proof_data)
      result = proof_store.find_proof(wtxid: wtxid)

      expect(result[:height]).to eq(800_000)
      expect(result[:block_index]).to eq(42)
      expect(result[:wtxid]).to eq(wtxid)
    end

    it 'returns nil when not found' do
      expect(proof_store.find_proof(wtxid: SecureRandom.random_bytes(32))).to be_nil
    end
  end

  describe '#proof_exists?' do
    it 'returns true when proof exists' do
      proof_store.save_proof(wtxid: wtxid, proof: proof_data)
      expect(proof_store.proof_exists?(wtxid: wtxid)).to be true
    end

    it 'returns false when no proof' do
      expect(proof_store.proof_exists?(wtxid: SecureRandom.random_bytes(32))).to be false
    end
  end

end
