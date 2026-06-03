# frozen_string_literal: true

require_relative '../shared_context'

RSpec.describe BSV::Wallet::Store::Models::Broadcast, :store do
  let(:action) { BSV::Wallet::Store::Models::Action.create(outgoing: true, description: 'test action', nlocktime: 0, wtxid: SecureRandom.random_bytes(32), raw_tx: SecureRandom.random_bytes(100)) }

  it 'creates a broadcast record for an action' do
    broadcast = described_class.create(action_id: action.id, intent: 'delayed')
    expect(broadcast.action).to eq(action)
    expect(broadcast.tx_status).to be_nil
  end

  it 'enforces one broadcast per action' do
    described_class.create(action_id: action.id, intent: 'delayed')
    expect { described_class.create(action_id: action.id, intent: 'delayed') }
      .to raise_error(Sequel::UniqueConstraintViolation)
  end

  it 'stores ARC lifecycle data' do
    broadcast = described_class.create(
      action_id: action.id,
      intent: 'delayed',
      broadcast_at: Time.now,
      tx_status: 'SEEN_ON_NETWORK',
      arc_status: 200,
      block_hash: SecureRandom.random_bytes(32),
      block_height: 800_000
    )
    expect(broadcast.reload.tx_status).to eq('SEEN_ON_NETWORK')
    expect(broadcast.block_hash.encoding).to eq(Encoding::BINARY)
  end
end
