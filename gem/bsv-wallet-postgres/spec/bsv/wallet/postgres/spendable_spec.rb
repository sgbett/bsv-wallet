# frozen_string_literal: true

RSpec.describe BSV::Wallet::Postgres::Spendable do
  let(:action) { BSV::Wallet::Postgres::Action.create(outgoing: true, txid: SecureRandom.random_bytes(32)) }
  let(:output) { BSV::Wallet::Postgres::Output.create(action_id: action.id, satoshis: 1000, vout: 0) }

  it 'marks an output as spendable' do
    entry = described_class.create(output_id: output.id)
    expect(entry.output).to eq(output)
  end

  it 'enforces one spendable entry per output' do
    described_class.create(output_id: output.id)
    expect { described_class.create(output_id: output.id) }
      .to raise_error(Sequel::UniqueConstraintViolation)
  end

  it 'uses the spendable table (singular)' do
    expect(described_class.table_name).to eq(:spendable)
  end
end
