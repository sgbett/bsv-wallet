# frozen_string_literal: true

require_relative 'shared_context'

RSpec.describe BSV::Wallet::Store::BroadcastQueue, :store do
  subject(:queue) { described_class.new(services: services) }

  let(:services) { nil }
  let(:action) do
    BSV::Wallet::Store::Models::Action.create(
      outgoing: true,
      description: 'test action',
      nlocktime: 0,
      wtxid: SecureRandom.random_bytes(32),
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

    context 'with services' do
      let(:push_response) do
        double('ProtocolResponse', http_success?: true, data: {
                 tx_status: 'SEEN_ON_NETWORK',
                 status: 200
               })
      end
      let(:services) { double('Services') }

      before do
        allow(services).to receive(:push!) do |broadcast|
          broadcast.write!(push_response)
          push_response
        end
      end

      it 'pushes immediately through services' do
        result = queue.submit(action_id: action.id, raw_tx: action.raw_tx, immediate: true)
        expect(result[:tx_status]).to eq('SEEN_ON_NETWORK')
        expect(result[:broadcast_at]).not_to be_nil
        expect(services).to have_received(:push!)
      end
    end

    context 'without services (immediate)' do
      it 'creates the record but does not push' do
        result = queue.submit(action_id: action.id, raw_tx: action.raw_tx, immediate: true)
        expect(result[:action_id]).to eq(action.id)
        expect(result[:tx_status]).to be_nil
      end
    end
  end

  describe '#handle_event' do
    it 'updates broadcast record from an ARC event' do
      BSV::Wallet::Store::Models::Broadcast.create(action_id: action.id)

      result = queue.handle_event(
        wtxid: action.wtxid,
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
        wtxid: action.wtxid,
        tx_status: 'SEEN_ON_NETWORK',
        status: 200,
        block_hash: nil, block_height: nil,
        merkle_path: nil, extra_info: nil, competing_txs: nil
      )

      expect(result[:action_id]).to eq(action.id)
      expect(BSV::Wallet::Store::Models::Broadcast.where(action_id: action.id).count).to eq(1)
    end

    it 'returns nil for unknown wtxid' do
      result = queue.handle_event(
        wtxid: SecureRandom.random_bytes(32),
        tx_status: 'MINED', status: 200,
        block_hash: nil, block_height: nil,
        merkle_path: nil, extra_info: nil, competing_txs: nil
      )
      expect(result).to be_nil
    end
  end

  describe '#status' do
    it 'returns broadcast status for an action' do
      BSV::Wallet::Store::Models::Broadcast.create(action_id: action.id, tx_status: 'SENDING')
      result = queue.status(action_id: action.id)
      expect(result[:tx_status]).to eq('SENDING')
    end

    it 'returns nil when no broadcast exists' do
      expect(queue.status(action_id: action.id)).to be_nil
    end
  end

  describe '#process_pending' do
    let(:fetch_response) do
      double('ProtocolResponse', http_success?: true, data: {
               tx_status: 'MINED',
               status: 200,
               block_hash: SecureRandom.random_bytes(32).unpack1('H*'),
               block_height: 800_000,
               merkle_path: nil
             })
    end
    let(:services) { double('Services') }

    before do
      allow(services).to receive(:fetch!) do |broadcast|
        broadcast.write!(fetch_response)
        fetch_response
      end
    end

    it 'fetches status for stale broadcasts through services' do
      action.update(wtxid: Sequel.blob(SecureRandom.random_bytes(32))) unless action.wtxid

      BSV::Wallet::Store::Models::Broadcast.create(
        action_id: action.id,
        broadcast_at: Time.now - 60
      )

      results = queue.process_pending(limit: 10)
      expect(results.size).to eq(1)
      expect(results.first[:tx_status]).to eq('MINED')
      expect(services).to have_received(:fetch!)
    end

    it 'skips broadcasts with terminal status' do
      BSV::Wallet::Store::Models::Broadcast.create(
        action_id: action.id,
        broadcast_at: Time.now - 60,
        tx_status: 'MINED'
      )

      results = queue.process_pending(limit: 10)
      expect(results).to be_empty
    end

    it 'skips broadcasts without services' do
      no_services_queue = described_class.new
      BSV::Wallet::Store::Models::Broadcast.create(
        action_id: action.id,
        broadcast_at: Time.now - 60
      )

      results = no_services_queue.process_pending(limit: 10)
      expect(results).to be_empty
    end
  end
end
