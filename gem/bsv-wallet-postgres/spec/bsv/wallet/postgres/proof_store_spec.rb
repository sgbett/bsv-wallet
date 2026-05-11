# frozen_string_literal: true

RSpec.describe BSV::Wallet::Postgres::ProofStore do
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
      record = BSV::Wallet::Postgres::TxProof[id1]
      expect(record.block.height).to eq(800_001)
    end

    it 'preserves binary data' do
      proof_store.save_proof(wtxid: wtxid, proof: proof_data)
      record = BSV::Wallet::Postgres::TxProof.first(wtxid: Sequel.blob(wtxid))

      expect(record.wtxid.encoding).to eq(Encoding::BINARY)
      expect(record.merkle_path.encoding).to eq(Encoding::BINARY)
      expect(record.block.block_hash.encoding).to eq(Encoding::BINARY)
      expect(record.merkle_path).to eq(proof_data[:merkle_path])
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

  describe '#request_proof' do
    it 'creates a tx_req entry' do
      proof_store.request_proof(wtxid: wtxid, raw_tx: SecureRandom.random_bytes(100))
      req = BSV::Wallet::Postgres::TxReq.first(wtxid: Sequel.blob(wtxid))

      expect(req).not_to be_nil
      expect(req.status).to eq('unmined')
      expect(req.attempts).to eq(0)
    end

    it 'is idempotent — duplicate wtxid is ignored' do
      proof_store.request_proof(wtxid: wtxid, raw_tx: SecureRandom.random_bytes(100))
      proof_store.request_proof(wtxid: wtxid, raw_tx: SecureRandom.random_bytes(100))

      expect(BSV::Wallet::Postgres::TxReq.where(wtxid: Sequel.blob(wtxid)).count).to eq(1)
    end

    it 'stores raw_tx and input_beef as binary' do
      raw_tx = SecureRandom.random_bytes(200)
      beef = SecureRandom.random_bytes(100)
      proof_store.request_proof(wtxid: wtxid, raw_tx: raw_tx, input_beef: beef)

      req = BSV::Wallet::Postgres::TxReq.first(wtxid: Sequel.blob(wtxid))
      expect(req.raw_tx).to eq(raw_tx)
      expect(req.input_beef).to eq(beef)
    end
  end

  describe '#process_pending' do
    context 'without arc_client' do
      it 'returns empty (no client to poll)' do
        proof_store.request_proof(wtxid: wtxid, raw_tx: SecureRandom.random_bytes(100))
        expect(proof_store.process_pending).to eq([])
      end
    end

    context 'with arc_client' do
      let(:arc_client) do
        double('ARC', call: double('Result', success?: true, data: {
          txStatus: 'MINED',
          blockHash: SecureRandom.random_bytes(32).unpack1('H*'),
          blockHeight: 800_000,
          merklePath: SecureRandom.random_bytes(64).unpack1('H*')
        }))
      end

      subject(:proof_store) { described_class.new(arc_client: arc_client) }

      it 'resolves pending requests and creates proofs' do
        proof_store.request_proof(wtxid: wtxid, raw_tx: SecureRandom.random_bytes(100))

        results = proof_store.process_pending(limit: 10)
        expect(results.size).to eq(1)
        expect(results.first[:wtxid]).to eq(wtxid)
        expect(results.first[:tx_proof_id]).to be_a(Integer)

        # The tx_req should be updated
        req = BSV::Wallet::Postgres::TxReq.first(wtxid: Sequel.blob(wtxid))
        expect(req.status).to eq('completed')
        expect(req.tx_proof_id).to eq(results.first[:tx_proof_id])
      end
    end

    context 'when ARC returns non-MINED status' do
      let(:arc_client) do
        double('ARC', call: double('Result', success?: true, data: {
          txStatus: 'SEEN_ON_NETWORK'
        }))
      end

      subject(:proof_store) { described_class.new(arc_client: arc_client) }

      it 'increments attempts but does not create a proof' do
        proof_store.request_proof(wtxid: wtxid, raw_tx: SecureRandom.random_bytes(100))
        results = proof_store.process_pending
        expect(results).to eq([])

        req = BSV::Wallet::Postgres::TxReq.first(wtxid: Sequel.blob(wtxid))
        expect(req.attempts).to eq(1)
        expect(req.status).to eq('unmined')
      end
    end
  end
end
