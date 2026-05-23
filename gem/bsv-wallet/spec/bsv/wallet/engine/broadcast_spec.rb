# frozen_string_literal: true

require 'bsv-wallet'
require 'bsv/wallet/engine/broadcast'

RSpec.describe BSV::Wallet::Engine::Broadcast do
  let(:store) { double('Store') }
  let(:services) { double('Services') }
  let(:broadcast) { described_class.new(store: store, services: services) }

  let(:action_id) { 42 }
  let(:raw_tx) { "\x01\x00".b }
  let(:action_hash) { { id: action_id, raw_tx: raw_tx } }
  let(:broadcast_data) do
    {
      tx_status: 'SEEN_ON_NETWORK',
      status: 200,
      block_hash: nil,
      block_height: nil,
      merkle_path: nil,
      extra_info: nil,
      competing_txs: nil
    }
  end
  let(:success_response) do
    BSV::Network::ProtocolResponse.new(nil, data: broadcast_data, http_success: true)
  end
  let(:status_hash) { { action_id: action_id, tx_status: 'SEEN_ON_NETWORK' } }

  describe '#process' do
    context 'when broadcast succeeds' do
      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
        allow(services).to receive(:call).with(:broadcast, raw_tx).and_return(success_response)
        allow(store).to receive(:record_broadcast_result)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(status_hash)
      end

      it 'calls services.call(:broadcast) with the raw_tx' do
        broadcast.process(action_id)
        expect(services).to have_received(:call).with(:broadcast, raw_tx)
      end

      it 'records the broadcast result in the store' do
        broadcast.process(action_id)
        expect(store).to have_received(:record_broadcast_result).with(
          action_id: action_id,
          tx_status: 'SEEN_ON_NETWORK',
          arc_status: 200,
          block_hash: nil,
          block_height: nil,
          merkle_path: nil,
          extra_info: nil,
          competing_txs: nil
        )
      end

      it 'returns the broadcast status' do
        result = broadcast.process(action_id)
        expect(result).to eq(status_hash)
      end
    end

    context 'when broadcast fails' do
      let(:error_response) do
        BSV::Network::ProtocolResponse.new(nil, http_success: false, error_message: 'ARC rejected')
      end

      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
        allow(services).to receive(:call).with(:broadcast, raw_tx).and_return(error_response)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(nil)
      end

      it 'does not call record_broadcast_result' do
        allow(store).to receive(:record_broadcast_result)
        broadcast.process(action_id)
        expect(store).not_to have_received(:record_broadcast_result)
      end

      it 'returns the broadcast status' do
        result = broadcast.process(action_id)
        expect(result).to be_nil
      end
    end

    context 'when action is not found' do
      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(nil)
        allow(services).to receive(:call)
      end

      it 'returns nil without calling services' do
        result = broadcast.process(action_id)
        expect(result).to be_nil
        expect(services).not_to have_received(:call)
      end
    end

    context 'when action has no raw_tx' do
      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return({ id: action_id, raw_tx: nil })
        allow(services).to receive(:call)
      end

      it 'returns nil without calling services' do
        result = broadcast.process(action_id)
        expect(result).to be_nil
        expect(services).not_to have_received(:call)
      end
    end
  end

  describe '.pending' do
    it 'delegates to store.pending_broadcasts and maps to action IDs' do
      pending_records = [
        { action_id: 1, tx_status: nil },
        { action_id: 2, tx_status: 'UNKNOWN' }
      ]
      allow(store).to receive(:pending_broadcasts).with(limit: 5).and_return(pending_records)

      result = described_class.pending(store, limit: 5)
      expect(result).to eq([1, 2])
    end

    it 'uses default limit of 10' do
      allow(store).to receive(:pending_broadcasts).with(limit: 10).and_return([])

      result = described_class.pending(store)
      expect(result).to eq([])
    end
  end

  describe 'OMQ sockets', :omq do
    before do
      allow(store).to receive_messages(find_action: action_hash,
                                       record_broadcast_result: nil,
                                       broadcast_status: status_hash)
      allow(services).to receive(:call).and_return(success_response)
    end

    describe '#pull!' do
      it 'processes messages pushed to the PULL socket' do
        Async do |task|
          broadcast.pull!(task: task)

          push = OMQ::PUSH.connect('inproc://broadcasts.pull')
          push << action_id.to_s

          # Yield to let the pull fiber process the message.
          sleep 0.05

          expect(store).to have_received(:find_action).with(id: action_id)
        ensure
          task.stop
        end
      end
    end

    describe '#reply!' do
      it 'replies with tx_status after processing' do
        Async do |task|
          broadcast.reply!(task: task)

          req = OMQ::REQ.connect('inproc://broadcasts.rep')
          req << action_id.to_s

          reply = req.receive
          expect(reply.first).to eq('SEEN_ON_NETWORK')
        ensure
          task.stop
        end
      end
    end
  end
end
