# frozen_string_literal: true

require_relative '../shared_context'

RSpec.describe BSV::Wallet::Store::Broadcast, :store do
  let(:action) { BSV::Wallet::Store::Action.create(outgoing: true, description: 'test action', nlocktime: 0, wtxid: SecureRandom.random_bytes(32), raw_tx: SecureRandom.random_bytes(100)) }

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

  describe 'Pushable + Fetchable' do
    it 'includes Pushable and Fetchable' do
      expect(described_class.ancestors).to include(BSV::Wallet::Pushable)
      expect(described_class.ancestors).to include(BSV::Wallet::Fetchable)
    end
  end

  describe '#push_command' do
    it 'returns :broadcast' do
      broadcast = described_class.create(action_id: action.id)
      expect(broadcast.push_command).to eq(:broadcast)
    end
  end

  describe '#push_payload' do
    it 'returns the action raw_tx' do
      broadcast = described_class.create(action_id: action.id)
      expect(broadcast.push_payload).to eq(action.raw_tx)
    end
  end

  describe '#needs_push?' do
    it 'returns truthy for new broadcast (broadcast_at nil)' do
      broadcast = described_class.create(action_id: action.id)
      expect(broadcast.needs_push?).to be_truthy
    end

    it 'returns false after broadcast_at is set' do
      broadcast = described_class.create(action_id: action.id, broadcast_at: Time.now)
      expect(broadcast.needs_push?).to be false
    end

    it 'returns false when action has no raw_tx' do
      unsigned = BSV::Wallet::Store::Action.create(outgoing: true, description: 'unsigned', nlocktime: 0)
      broadcast = described_class.create(action_id: unsigned.id)
      expect(broadcast.needs_push?).to be_falsey
    end
  end

  describe '#fetch_command' do
    it 'returns :get_tx_status' do
      broadcast = described_class.create(action_id: action.id)
      expect(broadcast.fetch_command).to eq(:get_tx_status)
    end
  end

  describe '#fetch_args' do
    it 'returns txid as display-order hex' do
      broadcast = described_class.create(action_id: action.id)
      expected_dtxid = action.wtxid.reverse.unpack1('H*')
      expect(broadcast.fetch_args).to eq({ txid: expected_dtxid })
    end
  end

  describe '#needs_fetch?' do
    it 'returns false when broadcast_at is nil' do
      broadcast = described_class.create(action_id: action.id)
      expect(broadcast.needs_fetch?).to be false
    end

    it 'returns false for terminal statuses' do
      described_class::TERMINAL_STATUSES.each do |status|
        broadcast = described_class.create(action_id: action.id, broadcast_at: Time.now - 60, tx_status: status)
        expect(broadcast.needs_fetch?).to be(false), "expected false for #{status}"
        broadcast.delete # clean up for unique constraint
      end
    end

    it 'returns false when broadcast_at is recent (< 30s)' do
      broadcast = described_class.create(action_id: action.id, broadcast_at: Time.now)
      expect(broadcast.needs_fetch?).to be false
    end

    it 'returns true for stale non-terminal broadcast' do
      broadcast = described_class.create(action_id: action.id, broadcast_at: Time.now - 60)
      expect(broadcast.needs_fetch?).to be true
    end

    it 'returns true for stale broadcast with nil tx_status' do
      broadcast = described_class.create(action_id: action.id, broadcast_at: Time.now - 60, tx_status: nil)
      expect(broadcast.needs_fetch?).to be true
    end
  end

  describe '#write!' do
    let(:broadcast) { described_class.create(action_id: action.id) }
    let(:block_hash_hex) { SecureRandom.random_bytes(32).unpack1('H*') }
    let(:merkle_path_hex) { SecureRandom.random_bytes(64).unpack1('H*') }

    def make_response(data)
      double('ProtocolResponse', data: data)
    end

    it 'updates all columns from normalized response' do
      broadcast.write!(make_response({
        tx_status: 'MINED',
        status: 200,
        block_hash: block_hash_hex,
        block_height: 800_000,
        merkle_path: merkle_path_hex,
        extra_info: 'info',
        competing_txs: %w[abc def]
      }))

      broadcast.reload
      expect(broadcast.tx_status).to eq('MINED')
      expect(broadcast.arc_status).to eq(200)
      expect(broadcast.block_hash).to eq([block_hash_hex].pack('H*'))
      expect(broadcast.block_hash.encoding).to eq(Encoding::BINARY)
      expect(broadcast.block_height).to eq(800_000)
      expect(broadcast.merkle_path).to eq([merkle_path_hex].pack('H*'))
      expect(broadcast.extra_info).to eq('info')
      expect(broadcast.broadcast_at).not_to be_nil
    end

    it 'sets broadcast_at on first write' do
      expect(broadcast.broadcast_at).to be_nil
      broadcast.write!(make_response({ tx_status: 'SEEN_ON_NETWORK' }))
      expect(broadcast.reload.broadcast_at).not_to be_nil
    end

    it 'does not overwrite broadcast_at if already set' do
      original_time = Time.now - 3600
      broadcast.update(broadcast_at: original_time)

      broadcast.write!(make_response({ tx_status: 'MINED' }))
      expect(broadcast.reload.broadcast_at).to be_within(1).of(original_time)
    end

    it 'handles nil fields gracefully (partial response)' do
      broadcast.update(broadcast_at: Time.now, tx_status: 'SENDING', extra_info: 'old info')
      broadcast.write!(make_response({ tx_status: 'MINED' }))

      broadcast.reload
      expect(broadcast.tx_status).to eq('MINED')
      expect(broadcast.extra_info).to eq('old info') # not cleared
    end

    it 'decodes hex block_hash to binary' do
      broadcast.write!(make_response({ block_hash: block_hash_hex }))
      expect(broadcast.reload.block_hash.encoding).to eq(Encoding::BINARY)
      expect(broadcast.block_hash).to eq([block_hash_hex].pack('H*'))
    end

    it 'decodes hex merkle_path to binary' do
      broadcast.write!(make_response({ merkle_path: merkle_path_hex }))
      expect(broadcast.reload.merkle_path.encoding).to eq(Encoding::BINARY)
      expect(broadcast.merkle_path).to eq([merkle_path_hex].pack('H*'))
    end

    it 'passes through binary block_hash unchanged' do
      binary = SecureRandom.random_bytes(32)
      broadcast.write!(make_response({ block_hash: binary }))
      expect(broadcast.reload.block_hash).to eq(binary)
    end

    it 'stores competing_txs as JSON' do
      broadcast.write!(make_response({ competing_txs: %w[tx1 tx2] }))
      broadcast.reload
      expect(JSON.parse(broadcast.competing_txs)).to eq(%w[tx1 tx2])
    end

    it 'does nothing for empty data hash' do
      broadcast.update(broadcast_at: Time.now)
      expect { broadcast.write!(make_response({})) }.not_to(change { broadcast.reload.updated_at })
    end
  end
end
