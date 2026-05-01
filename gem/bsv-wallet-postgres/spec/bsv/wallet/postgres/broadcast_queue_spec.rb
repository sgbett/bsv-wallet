# frozen_string_literal: true

RSpec.describe BSV::Wallet::Postgres::BroadcastQueue do
  let(:arc_client) { nil }
  subject(:queue) { described_class.new(arc_client: arc_client) }

  let(:action) do
    BSV::Wallet::Postgres::Action.create(
      outgoing: true,
      txid: SecureRandom.random_bytes(32),
      raw_tx: SecureRandom.random_bytes(100)
    )
  end

  describe 'interface conformance' do
    it 'includes BSV::Wallet::Interface::BroadcastQueue' do
      expect(described_class.ancestors).to include(BSV::Wallet::Interface::BroadcastQueue)
    end
  end

  describe '#submit' do
    it 'creates a broadcast record (delayed)' do
      result = queue.submit(action_id: action.id, raw_tx: action.raw_tx, immediate: false)
      expect(result[:action_id]).to eq(action.id)
      expect(result[:tx_status]).to be_nil
      expect(result[:broadcast_at]).to be_nil
    end

    context 'with arc_client' do
      let(:arc_response) do
        double('Result', success?: true, data: {
          txStatus: 'SEEN_ON_NETWORK',
          status: 200,
          blockHash: nil,
          blockHeight: nil,
          merklePath: nil
        })
      end
      let(:arc_client) { double('ARC', call: arc_response) }

      it 'posts immediately and updates the record' do
        result = queue.submit(action_id: action.id, raw_tx: action.raw_tx, immediate: true)
        expect(result[:tx_status]).to eq('SEEN_ON_NETWORK')
        expect(result[:broadcast_at]).not_to be_nil
        expect(arc_client).to have_received(:call).with(:broadcast, action.raw_tx)
      end
    end

    context 'without arc_client (immediate)' do
      it 'creates the record but does not post' do
        result = queue.submit(action_id: action.id, raw_tx: action.raw_tx, immediate: true)
        expect(result[:action_id]).to eq(action.id)
        expect(result[:tx_status]).to be_nil
      end
    end
  end

  describe '#handle_event' do
    it 'updates broadcast record from an ARC event' do
      BSV::Wallet::Postgres::Broadcast.create(action_id: action.id)

      result = queue.handle_event(
        txid: action.txid,
        tx_status: 'MINED',
        status: 200,
        block_hash: SecureRandom.random_bytes(32),
        block_height: 800_000,
        merkle_path: SecureRandom.random_bytes(64),
        extra_info: nil,
        competing_txs: nil
      )

      expect(result[:action_id]).to eq(action.id)
      expect(result[:tx_status]).to eq('MINED')
      expect(result[:block_height]).to eq(800_000)
      expect(result[:block_hash].encoding).to eq(Encoding::BINARY)
    end

    it 'creates a broadcast record if none exists' do
      result = queue.handle_event(
        txid: action.txid,
        tx_status: 'SEEN_ON_NETWORK',
        status: 200,
        block_hash: nil, block_height: nil,
        merkle_path: nil, extra_info: nil, competing_txs: nil
      )

      expect(result[:action_id]).to eq(action.id)
      expect(BSV::Wallet::Postgres::Broadcast.where(action_id: action.id).count).to eq(1)
    end

    it 'returns nil for unknown txid' do
      result = queue.handle_event(
        txid: SecureRandom.random_bytes(32),
        tx_status: 'MINED', status: 200,
        block_hash: nil, block_height: nil,
        merkle_path: nil, extra_info: nil, competing_txs: nil
      )
      expect(result).to be_nil
    end
  end

  describe '#status' do
    it 'returns broadcast status for an action' do
      BSV::Wallet::Postgres::Broadcast.create(action_id: action.id, tx_status: 'SENDING')
      result = queue.status(action_id: action.id)
      expect(result[:tx_status]).to eq('SENDING')
    end

    it 'returns nil when no broadcast exists' do
      expect(queue.status(action_id: action.id)).to be_nil
    end
  end

  describe '#process_pending' do
    let(:arc_response) do
      double('Result', success?: true, data: {
        txStatus: 'MINED',
        status: 200,
        blockHash: SecureRandom.random_bytes(32).unpack1('H*'),
        blockHeight: 800_000,
        merklePath: nil
      })
    end
    let(:arc_client) { double('ARC', call: arc_response) }

    it 'polls ARC for stale broadcasts and updates them' do
      # Action must have txid for process_pending to poll ARC
      action.update(txid: Sequel.blob(SecureRandom.random_bytes(32))) unless action.txid

      broadcast = BSV::Wallet::Postgres::Broadcast.create(
        action_id: action.id,
        broadcast_at: Time.now - 60 # stale
      )

      results = queue.process_pending(limit: 10)
      expect(results.size).to eq(1)
      expect(results.first[:tx_status]).to eq('MINED')
    end

    it 'skips broadcasts with terminal status' do
      BSV::Wallet::Postgres::Broadcast.create(
        action_id: action.id,
        broadcast_at: Time.now - 60,
        tx_status: 'MINED'
      )

      results = queue.process_pending(limit: 10)
      expect(results).to be_empty
    end
  end
end
