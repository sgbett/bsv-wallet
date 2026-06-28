# frozen_string_literal: true

require_relative '../shared_context'

RSpec.describe BSV::Wallet::Store::Models::Spendable, :store do
  # broadcast_intent: 'none' so the promotions row (intent='none', no
  # authorising status) satisfies promo_path; spendable.action_id is FK'd to
  # promotions(action_id) (#307), so the promotions row must precede it.
  let(:action) { BSV::Wallet::Store::Models::Action.create(description: 'test action', broadcast_intent: 'none', wtxid: SecureRandom.random_bytes(32), raw_tx: SecureRandom.random_bytes(100)) }
  let(:output) do
    BSV::Wallet::Store::Models::Output.create(
      action_id: action.id, satoshis: 1000, vout: 0,
      locking_script: TEST_ROOT_LOCKING_SCRIPT, spendable_intent: 'spendable'
    )
  end

  before { BSV::Wallet::Store::Models::Promotion.create(action_id: action.id, intent: 'none', authorising_status: nil) }

  it 'marks an output as spendable' do
    entry = described_class.create(output_id: output.id, action_id: action.id, spendable_intent: 'spendable')
    expect(entry.output).to eq(output)
  end

  it 'enforces one spendable entry per output' do
    described_class.create(output_id: output.id, action_id: action.id, spendable_intent: 'spendable')
    expect { described_class.create(output_id: output.id, action_id: action.id, spendable_intent: 'spendable') }
      .to raise_error(Sequel::UniqueConstraintViolation)
  end

  it 'uses the spendable table (singular)' do
    expect(described_class.table_name).to eq(:spendable)
  end
end
