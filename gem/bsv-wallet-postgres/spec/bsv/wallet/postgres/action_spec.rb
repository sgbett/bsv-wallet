# frozen_string_literal: true

RSpec.describe BSV::Wallet::Postgres::Action do
  let(:tx_proof) { BSV::Wallet::Postgres::TxProof.create(wtxid: SecureRandom.random_bytes(32)) }

  describe 'creation' do
    it 'creates with minimal fields' do
      action = described_class.create(outgoing: true)
      expect(action.id).to be_a(Integer)
      expect(action.reference).to be_a(String)
      expect(action.values[:broadcast]).to eq('delayed')
      expect(action.nlocktime).to eq(0)
    end

    it 'preserves binary wtxid' do
      wtxid = SecureRandom.random_bytes(32)
      action = described_class.create(outgoing: true, wtxid: wtxid)
      expect(action.reload.wtxid.encoding).to eq(Encoding::BINARY)
      expect(action.wtxid).to eq(wtxid)
    end

    it 'dtxid raises on corrupt wtxid (hex stored as binary)' do
      hex_value = 'a' * 64 # 64 chars, not 32 bytes
      action = described_class.create(outgoing: true, wtxid: Sequel.blob(hex_value))
      expect { action.dtxid }.to raise_error(ArgumentError, /dtxid/)
    end
  end

  describe 'associations' do
    it 'belongs to tx_proof' do
      action = described_class.create(outgoing: true, tx_proof_id: tx_proof.id)
      expect(action.tx_proof).to eq(tx_proof)
    end

    it 'has one broadcast_entry' do
      action = described_class.create(outgoing: true)
      broadcast = BSV::Wallet::Postgres::Broadcast.create(action_id: action.id)
      expect(action.reload.broadcast_entry).to eq(broadcast)
    end

    it 'has many outputs' do
      action = described_class.create(outgoing: true, wtxid: SecureRandom.random_bytes(32))
      BSV::Wallet::Postgres::Output.create(action_id: action.id, satoshis: 1000, vout: 0)
      BSV::Wallet::Postgres::Output.create(action_id: action.id, satoshis: 500, vout: 1)
      expect(action.reload.outputs.count).to eq(2)
    end

    it 'has many inputs' do
      source = described_class.create(outgoing: false, wtxid: SecureRandom.random_bytes(32))
      output = BSV::Wallet::Postgres::Output.create(action_id: source.id, satoshis: 1000, vout: 0)
      action = described_class.create(outgoing: true)
      BSV::Wallet::Postgres::Input.create(action_id: action.id, output_id: output.id, vin: 0)
      expect(action.reload.inputs.count).to eq(1)
    end

    it 'has many labels via action_labels' do
      action = described_class.create(outgoing: true)
      label = BSV::Wallet::Postgres::Label.create(label: 'payment')
      BSV::Wallet::Postgres::ActionLabel.create(action_id: action.id, label_id: label.id)
      expect(action.reload.labels.map(&:label)).to eq(['payment'])
    end
  end

  describe '#derived_status' do
    it 'returns :unsigned when wtxid is nil' do
      action = described_class.create(outgoing: true)
      expect(action.derived_status).to eq(:unsigned)
    end

    it 'returns :completed when tx_proof_id is set' do
      action = described_class.create(outgoing: true, wtxid: SecureRandom.random_bytes(32), tx_proof_id: tx_proof.id)
      expect(action.derived_status).to eq(:completed)
    end

    it 'returns :nosend when broadcast is none' do
      action = described_class.create(outgoing: true, wtxid: SecureRandom.random_bytes(32), broadcast: 'none')
      expect(action.derived_status).to eq(:nosend)
    end

    it 'returns :unproven when outputs exist but no proof' do
      action = described_class.create(outgoing: true, wtxid: SecureRandom.random_bytes(32))
      BSV::Wallet::Postgres::Output.create(action_id: action.id, satoshis: 1000, vout: 0)
      expect(action.reload.derived_status).to eq(:unproven)
    end

    it 'returns :failed when broadcast status is REJECTED' do
      action = described_class.create(outgoing: true, wtxid: SecureRandom.random_bytes(32))
      BSV::Wallet::Postgres::Broadcast.create(action_id: action.id, tx_status: 'REJECTED')
      expect(action.reload.derived_status).to eq(:failed)
    end

    it 'returns :sending when broadcast exists but no outputs' do
      action = described_class.create(outgoing: true, wtxid: SecureRandom.random_bytes(32))
      BSV::Wallet::Postgres::Broadcast.create(action_id: action.id, tx_status: 'SEEN_ON_NETWORK')
      expect(action.reload.derived_status).to eq(:sending)
    end

    it 'returns :unprocessed when wtxid set but nothing else' do
      action = described_class.create(outgoing: true, wtxid: SecureRandom.random_bytes(32))
      expect(action.derived_status).to eq(:unprocessed)
    end
  end
end
