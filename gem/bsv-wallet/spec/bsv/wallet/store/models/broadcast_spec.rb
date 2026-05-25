# frozen_string_literal: true

require_relative '../shared_context'

RSpec.describe BSV::Wallet::Store::Models::Broadcast, :store do
  let(:action) { BSV::Wallet::Store::Models::Action.create(outgoing: true, description: 'test action', nlocktime: 0, wtxid: SecureRandom.random_bytes(32), raw_tx: SecureRandom.random_bytes(100)) }

  it 'creates a broadcast record for an action' do
    broadcast = described_class.create(action_id: action.id)
    expect(broadcast.action).to eq(action)
    expect(broadcast.tx_status).to be_nil
  end

  it 'enforces one broadcast per action' do
    described_class.create(action_id: action.id)
    expect { described_class.create(action_id: action.id) }
      .to raise_error(Sequel::UniqueConstraintViolation)
  end

  it 'stores ARC lifecycle data' do
    broadcast = described_class.create(
      action_id: action.id,
      broadcast_at: Time.now,
      tx_status: 'SEEN_ON_NETWORK',
      arc_status: 200,
      block_hash: SecureRandom.random_bytes(32),
      block_height: 800_000
    )
    expect(broadcast.reload.tx_status).to eq('SEEN_ON_NETWORK')
    expect(broadcast.block_hash.encoding).to eq(Encoding::BINARY)
  end

  describe 'TERMINAL_STATUSES' do
    it 'includes expected terminal statuses' do
      expect(described_class::TERMINAL_STATUSES).to include('MINED', 'REJECTED')
    end

    it 'is frozen' do
      expect(described_class::TERMINAL_STATUSES).to be_frozen
    end

    # MINED_IN_STALE_BLOCK is transient: the tx is valid but on a fork, and
    # must continue to be re-polled until it lands on the main chain.
    # See docs/wallet-events.md and HLR #182.
    it 'excludes MINED_IN_STALE_BLOCK so stale-block rows keep being polled' do
      expect(described_class::TERMINAL_STATUSES).not_to include('MINED_IN_STALE_BLOCK')
    end
  end
end
