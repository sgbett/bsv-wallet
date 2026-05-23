# frozen_string_literal: true

require_relative '../shared_context'

RSpec.describe BSV::Wallet::Store::Models::Action, :store do
  let(:raw_tx) { SecureRandom.random_bytes(100) }
  let(:tx_proof) { BSV::Wallet::Store::Models::TxProof.create(wtxid: SecureRandom.random_bytes(32), raw_tx: raw_tx) }

  describe 'creation' do
    it 'creates with minimal fields' do
      action = described_class.create(outgoing: false, description: 'test action')
      expect(action.id).to be_a(Integer)
      expect(action.reference).to be_a(String)
      expect(action.values[:broadcast]).to eq('delayed')
      expect(action.nlocktime).to be_nil
    end

    it 'auto-generates a UUID reference when none provided' do
      action = described_class.create(outgoing: false, description: 'test action')
      expect(action.reference).to match(/\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/)
    end

    it 'preserves an explicit reference' do
      explicit = SecureRandom.uuid
      action = described_class.create(outgoing: false, description: 'test action', reference: explicit)
      expect(action.reference).to eq(explicit)
    end

    it 'preserves binary wtxid' do
      wtxid = SecureRandom.random_bytes(32)
      action = described_class.create(outgoing: true, description: 'test action', nlocktime: 0, wtxid: wtxid, raw_tx: raw_tx)
      expect(action.reload.wtxid.encoding).to eq(Encoding::BINARY)
      expect(action.wtxid).to eq(wtxid)
    end

    it 'rejects corrupt wtxid (hex stored as binary) at database level', :postgres do
      hex_value = 'a' * 64 # 64 chars, not 32 bytes
      expect do
        described_class.create(outgoing: true, description: 'test action', nlocktime: 0, wtxid: Sequel.blob(hex_value), raw_tx: raw_tx)
      end.to raise_error(Sequel::CheckConstraintViolation, /wtxid_length/)
    end
  end

  describe 'associations' do
    it 'belongs to tx_proof' do
      action = described_class.create(outgoing: true, description: 'test action', nlocktime: 0, wtxid: SecureRandom.random_bytes(32), raw_tx: raw_tx, tx_proof_id: tx_proof.id)
      expect(action.tx_proof).to eq(tx_proof)
    end

    it 'has one broadcast_entry' do
      action = described_class.create(outgoing: true, description: 'test action', nlocktime: 0)
      broadcast = BSV::Wallet::Store::Models::Broadcast.create(action_id: action.id)
      expect(action.reload.broadcast_entry).to eq(broadcast)
    end

    it 'has many outputs' do
      action = described_class.create(outgoing: true, description: 'test action', nlocktime: 0, wtxid: SecureRandom.random_bytes(32), raw_tx: raw_tx)
      BSV::Wallet::Store::Models::Output.create(action_id: action.id, satoshis: 1000, vout: 0, locking_script: SecureRandom.random_bytes(25), output_type: 'root')
      BSV::Wallet::Store::Models::Output.create(action_id: action.id, satoshis: 500, vout: 1, locking_script: SecureRandom.random_bytes(25), output_type: 'root')
      expect(action.reload.outputs.count).to eq(2)
    end

    it 'has many inputs' do
      source = described_class.create(outgoing: false, description: 'test action', wtxid: SecureRandom.random_bytes(32), raw_tx: raw_tx)
      output = BSV::Wallet::Store::Models::Output.create(action_id: source.id, satoshis: 1000, vout: 0, locking_script: SecureRandom.random_bytes(25), output_type: 'root')
      action = described_class.create(outgoing: true, description: 'test action', nlocktime: 0)
      BSV::Wallet::Store::Models::Input.create(action_id: action.id, output_id: output.id, vin: 0)
      expect(action.reload.inputs.count).to eq(1)
    end

    it 'has many labels via action_labels' do
      action = described_class.create(outgoing: true, description: 'test action', nlocktime: 0)
      label = BSV::Wallet::Store::Models::Label.create(label: 'payment')
      BSV::Wallet::Store::Models::ActionLabel.create(action_id: action.id, label_id: label.id)
      expect(action.reload.labels.map(&:label)).to eq(['payment'])
    end
  end

  describe '#derived_status' do
    it 'returns :unsigned when wtxid is nil' do
      action = described_class.create(outgoing: true, description: 'test action', nlocktime: 0)
      expect(action.derived_status).to eq(:unsigned)
    end

    it 'returns :completed when tx_proof_id is set' do
      action = described_class.create(outgoing: true, description: 'test action', nlocktime: 0, wtxid: SecureRandom.random_bytes(32), raw_tx: raw_tx, tx_proof_id: tx_proof.id)
      expect(action.derived_status).to eq(:completed)
    end

    it 'returns :nosend when broadcast is none' do
      action = described_class.create(outgoing: true, description: 'test action', nlocktime: 0, wtxid: SecureRandom.random_bytes(32), raw_tx: raw_tx, broadcast: 'none')
      expect(action.derived_status).to eq(:nosend)
    end

    it 'returns :unproven when outputs exist but no proof' do
      action = described_class.create(outgoing: true, description: 'test action', nlocktime: 0, wtxid: SecureRandom.random_bytes(32), raw_tx: raw_tx)
      BSV::Wallet::Store::Models::Output.create(action_id: action.id, satoshis: 1000, vout: 0, locking_script: SecureRandom.random_bytes(25), output_type: 'root')
      expect(action.reload.derived_status).to eq(:unproven)
    end

    it 'returns :failed when broadcast status is REJECTED' do
      action = described_class.create(outgoing: true, description: 'test action', nlocktime: 0, wtxid: SecureRandom.random_bytes(32), raw_tx: raw_tx)
      BSV::Wallet::Store::Models::Broadcast.create(action_id: action.id, tx_status: 'REJECTED')
      expect(action.reload.derived_status).to eq(:failed)
    end

    it 'returns :sending when broadcast exists but no outputs' do
      action = described_class.create(outgoing: true, description: 'test action', nlocktime: 0, wtxid: SecureRandom.random_bytes(32), raw_tx: raw_tx)
      BSV::Wallet::Store::Models::Broadcast.create(action_id: action.id, tx_status: 'SEEN_ON_NETWORK')
      expect(action.reload.derived_status).to eq(:sending)
    end

    it 'returns :unprocessed when wtxid set but nothing else' do
      action = described_class.create(outgoing: true, description: 'test action', nlocktime: 0, wtxid: SecureRandom.random_bytes(32), raw_tx: raw_tx)
      expect(action.derived_status).to eq(:unprocessed)
    end
  end

  describe 'Fetchable' do
    it 'includes BSV::Wallet::Fetchable' do
      expect(described_class.ancestors).to include(BSV::Wallet::Fetchable)
    end

    describe '#fetch_command' do
      it 'returns :get_tx_status' do
        action = described_class.create(outgoing: true, description: 'test action', nlocktime: 0)
        expect(action.fetch_command).to eq(:get_tx_status)
      end
    end

    describe '#fetch_args' do
      it 'returns txid as display-order hex' do
        wtxid = SecureRandom.random_bytes(32)
        action = described_class.create(outgoing: true, description: 'test action', nlocktime: 0, wtxid: wtxid, raw_tx: raw_tx)
        expected_dtxid = wtxid.reverse.unpack1('H*')
        expect(action.fetch_args).to eq({ txid: expected_dtxid })
      end
    end

    describe '#needs_fetch?' do
      it 'returns true for outgoing action with wtxid and no proof' do
        action = described_class.create(outgoing: true, description: 'test action', nlocktime: 0, wtxid: SecureRandom.random_bytes(32), raw_tx: raw_tx)
        expect(action.needs_fetch?).to be true
      end

      it 'returns false for action without wtxid (unsigned)' do
        action = described_class.create(outgoing: true, description: 'test action', nlocktime: 0)
        expect(action.needs_fetch?).to be false
      end

      it 'returns false for action with tx_proof_id (already proven)' do
        action = described_class.create(outgoing: true, description: 'test action', nlocktime: 0, wtxid: SecureRandom.random_bytes(32), raw_tx: raw_tx, tx_proof_id: tx_proof.id)
        expect(action.needs_fetch?).to be false
      end

      it 'returns false for incoming action (outgoing: false)' do
        action = described_class.create(outgoing: false, description: 'test action', wtxid: SecureRandom.random_bytes(32), raw_tx: raw_tx)
        expect(action.needs_fetch?).to be false
      end

      it 'returns true for no-send outgoing action without proof' do
        action = described_class.create(outgoing: true, description: 'test action', nlocktime: 0, wtxid: SecureRandom.random_bytes(32), raw_tx: raw_tx, broadcast: 'none')
        expect(action.needs_fetch?).to be true
      end
    end

    describe '#write!' do
      let(:wtxid) { SecureRandom.random_bytes(32) }
      let(:action) do
        described_class.create(outgoing: true, description: 'test action', nlocktime: 0, wtxid: wtxid, raw_tx: raw_tx)
      end

      let(:mined_data) do
        {
          merkle_path: SecureRandom.random_bytes(64).unpack1('H*'),
          block_height: 800_000,
          block_hash: SecureRandom.random_bytes(32).unpack1('H*')
        }
      end

      def make_response(data)
        double('ProtocolResponse', data: data)
      end

      it 'creates TxProof and links to action when response has proof data' do
        action.write!(make_response(mined_data))
        action.reload

        expect(action.tx_proof_id).not_to be_nil
        proof = BSV::Wallet::Store::Models::TxProof[action.tx_proof_id]
        expect(proof.wtxid).to eq(wtxid)
        expect(proof.raw_tx).to eq(raw_tx)
      end

      it 'does not create proof when merkle_path is nil' do
        action.write!(make_response({ block_height: 800_000, merkle_path: nil }))
        expect(action.reload.tx_proof_id).to be_nil
      end

      it 'does not create proof when block_height is nil' do
        action.write!(make_response({ merkle_path: 'abcd', block_height: nil }))
        expect(action.reload.tx_proof_id).to be_nil
      end

      it 'does not create proof for non-MINED response (no proof fields)' do
        action.write!(make_response({ tx_status: 'SEEN_ON_NETWORK' }))
        expect(action.reload.tx_proof_id).to be_nil
      end

      it 'is idempotent — calling write! twice does not duplicate proofs' do
        response = make_response(mined_data)
        action.write!(response)
        first_proof_id = action.reload.tx_proof_id

        action.write!(response)
        expect(action.reload.tx_proof_id).to eq(first_proof_id)
        expect(BSV::Wallet::Store::Models::TxProof.where(wtxid: Sequel.blob(wtxid)).count).to eq(1)
      end

      it 'handles binary merkle_path and block_hash directly' do
        binary_data = {
          merkle_path: SecureRandom.random_bytes(64),
          block_height: 800_000,
          block_hash: SecureRandom.random_bytes(32)
        }
        action.write!(make_response(binary_data))
        action.reload

        expect(action.tx_proof_id).not_to be_nil
        proof = BSV::Wallet::Store::Models::TxProof[action.tx_proof_id]
        expect(proof.merkle_path).to eq(binary_data[:merkle_path])
      end
    end
  end
end
