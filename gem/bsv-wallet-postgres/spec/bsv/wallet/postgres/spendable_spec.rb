# frozen_string_literal: true

RSpec.describe BSV::Wallet::Postgres::Spendable do
  let(:action) { BSV::Wallet::Postgres::Action.create(outgoing: true, description: 'test action', wtxid: SecureRandom.random_bytes(32), raw_tx: SecureRandom.random_bytes(100)) }
  let(:output) { BSV::Wallet::Postgres::Output.create(action_id: action.id, satoshis: 1000, vout: 0, locking_script: SecureRandom.random_bytes(25)) }

  it 'marks an output as spendable' do
    entry = described_class.create(output_id: output.id, action_id: action.id, output_type: 'change')
    expect(entry.output).to eq(output)
  end

  it 'enforces one spendable entry per output' do
    described_class.create(output_id: output.id, action_id: action.id, output_type: 'change')
    expect { described_class.create(output_id: output.id, action_id: action.id, output_type: 'change') }
      .to raise_error(Sequel::UniqueConstraintViolation)
  end

  it 'uses the spendable table (singular)' do
    expect(described_class.table_name).to eq(:spendable)
  end
end
