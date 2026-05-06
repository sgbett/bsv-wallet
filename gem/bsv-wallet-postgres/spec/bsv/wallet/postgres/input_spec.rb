# frozen_string_literal: true

RSpec.describe BSV::Wallet::Postgres::Input do
  let(:source_action) { BSV::Wallet::Postgres::Action.create(outgoing: false, description: 'test action', wtxid: SecureRandom.random_bytes(32), raw_tx: SecureRandom.random_bytes(100)) }
  let(:output) { BSV::Wallet::Postgres::Output.create(action_id: source_action.id, satoshis: 1000, vout: 0, locking_script: SecureRandom.random_bytes(25), output_type: 'root') }
  let(:spending_action) { BSV::Wallet::Postgres::Action.create(outgoing: true, description: 'test action') }

  describe 'structural lock' do
    it 'claims an output (single-spend enforcement)' do
      input = described_class.create(action_id: spending_action.id, output_id: output.id, vin: 0)
      expect(input.output).to eq(output)
      expect(input.action).to eq(spending_action)
    end

    it 'prevents double-spend via UNIQUE on output_id' do
      described_class.create(action_id: spending_action.id, output_id: output.id, vin: 0)
      other_action = BSV::Wallet::Postgres::Action.create(outgoing: true, description: 'test action')
      expect { described_class.create(action_id: other_action.id, output_id: output.id, vin: 0) }
        .to raise_error(Sequel::UniqueConstraintViolation)
    end

    it 'enforces unique vin within an action' do
      output2 = BSV::Wallet::Postgres::Output.create(action_id: source_action.id, satoshis: 500, vout: 1, locking_script: SecureRandom.random_bytes(25), output_type: 'root')
      described_class.create(action_id: spending_action.id, output_id: output.id, vin: 0)
      expect { described_class.create(action_id: spending_action.id, output_id: output2.id, vin: 0) }
        .to raise_error(Sequel::UniqueConstraintViolation)
    end

    it 'releases on CASCADE delete of action' do
      described_class.create(action_id: spending_action.id, output_id: output.id, vin: 0)
      expect(described_class.where(action_id: spending_action.id).count).to eq(1)
      spending_action.destroy
      expect(described_class.where(action_id: spending_action.id).count).to eq(0)
    end

    it 'defaults nsequence to 0xFFFFFFFF' do
      input = described_class.create(action_id: spending_action.id, output_id: output.id, vin: 0)
      expect(input.nsequence).to eq(4_294_967_295)
    end
  end
end
