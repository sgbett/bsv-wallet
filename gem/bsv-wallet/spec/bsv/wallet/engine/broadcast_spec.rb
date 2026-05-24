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
      'txid' => 'abc123',
      'txStatus' => 'SEEN_ON_NETWORK',
      'status' => 200,
      'blockHash' => nil,
      'blockHeight' => nil,
      'merklePath' => nil,
      'extraInfo' => nil,
      'competingTxs' => nil
    }
  end
  let(:success_response) do
    BSV::Network::ProtocolResponse.new(nil, data: broadcast_data, http_success: true)
  end
  let(:status_hash) { { action_id: action_id, tx_status: 'SEEN_ON_NETWORK' } }

  # Capture all emit calls for assertion.
  let(:emitted_events) { [] }

  before do
    allow(BSV::Wallet).to receive(:emit) { |name, **payload| emitted_events << { name: name, **payload } }
  end

  describe '#process' do
    context 'when action is not found' do
      before { allow(store).to receive(:find_action).with(id: action_id).and_return(nil) }

      it 'emits task.dispatched then task.skipped with reason action_not_found' do
        broadcast.process(action_id)

        expect(emitted_events.size).to eq(2)
        expect(emitted_events[0][:name]).to eq('task.dispatched')
        expect(emitted_events[1]).to include(name: 'task.skipped', reason: 'action_not_found', id: action_id)
      end

      it 'returns nil without calling services' do
        allow(services).to receive(:call)
        result = broadcast.process(action_id)
        expect(result).to be_nil
        expect(services).not_to have_received(:call)
      end
    end

    context 'when action has no raw_tx' do
      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return({ id: action_id, raw_tx: nil })
      end

      it 'emits task.dispatched then task.skipped with reason no_raw_tx' do
        broadcast.process(action_id)

        expect(emitted_events.size).to eq(2)
        expect(emitted_events[0][:name]).to eq('task.dispatched')
        expect(emitted_events[1]).to include(name: 'task.skipped', reason: 'no_raw_tx', id: action_id)
      end

      it 'returns nil without calling services' do
        allow(services).to receive(:call)
        result = broadcast.process(action_id)
        expect(result).to be_nil
        expect(services).not_to have_received(:call)
      end
    end

    context 'when accepted with SEEN_ON_NETWORK' do
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

      it 'records the broadcast result with string-keyed data' do
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

      it 'emits task.succeeded with outcome=accepted and integer latency_ms' do
        broadcast.process(action_id)

        expect(emitted_events.size).to eq(2)
        expect(emitted_events[0]).to include(name: 'task.dispatched', task: 'broadcast_push', id: action_id)
        succeeded = emitted_events[1]
        expect(succeeded).to include(name: 'task.succeeded', task: 'broadcast_push', id: action_id, outcome: :accepted)
        expect(succeeded[:latency_ms]).to be_an(Integer)
      end
    end

    context 'when accepted with MINED' do
      let(:broadcast_data) { super().merge('txStatus' => 'MINED') }

      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
        allow(services).to receive(:call).with(:broadcast, raw_tx).and_return(success_response)
        allow(store).to receive(:record_broadcast_result)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(status_hash)
      end

      it 'emits task.succeeded with outcome=accepted and integer latency_ms' do
        broadcast.process(action_id)
        succeeded = emitted_events.find { |e| e[:name] == 'task.succeeded' }
        expect(succeeded).to include(outcome: :accepted)
        expect(succeeded[:latency_ms]).to be_an(Integer)
      end
    end

    context 'when accepted with intermediate status (QUEUED)' do
      let(:broadcast_data) { super().merge('txStatus' => 'QUEUED') }

      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
        allow(services).to receive(:call).with(:broadcast, raw_tx).and_return(success_response)
        allow(store).to receive(:record_broadcast_result)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(status_hash)
      end

      it 'emits task.succeeded with outcome=pending' do
        broadcast.process(action_id)
        succeeded = emitted_events.find { |e| e[:name] == 'task.succeeded' }
        expect(succeeded).to include(outcome: :pending)
      end
    end

    context 'when 429 rate limited' do
      let(:http_response) { instance_double(Net::HTTPTooManyRequests, code: '429') }
      let(:error_response) do
        BSV::Network::ProtocolResponse.new(http_response, http_success: false, error_message: 'Too Many Requests')
      end

      before do
        allow(http_response).to receive(:is_a?).and_return(false)
        allow(http_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
        allow(http_response).to receive(:is_a?).with(Net::HTTPTooManyRequests).and_return(true)
        allow(http_response).to receive(:is_a?).with(Net::HTTPServerError).and_return(false)
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
        allow(services).to receive(:call).with(:broadcast, raw_tx).and_return(error_response)
        allow(store).to receive(:abort_action)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(nil)
      end

      it 'emits task.failed with reason=rate_limited and integer latency_ms' do
        broadcast.process(action_id)
        failed = emitted_events.find { |e| e[:name] == 'task.failed' }
        expect(failed).to include(reason: :rate_limited, task: 'broadcast_push', id: action_id)
        expect(failed[:latency_ms]).to be_an(Integer)
      end

      it 'does not call abort_action' do
        broadcast.process(action_id)
        expect(store).not_to have_received(:abort_action)
      end
    end

    context 'when 503 transport error' do
      let(:http_response) { instance_double(Net::HTTPServiceUnavailable, code: '503') }
      let(:error_response) do
        BSV::Network::ProtocolResponse.new(http_response, http_success: false, error_message: 'Service Unavailable')
      end

      before do
        allow(http_response).to receive(:is_a?).and_return(false)
        allow(http_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
        allow(http_response).to receive(:is_a?).with(Net::HTTPTooManyRequests).and_return(false)
        allow(http_response).to receive(:is_a?).with(Net::HTTPServerError).and_return(true)
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
        allow(services).to receive(:call).with(:broadcast, raw_tx).and_return(error_response)
        allow(store).to receive(:abort_action)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(nil)
      end

      it 'emits task.failed with reason=transport_error and integer latency_ms' do
        broadcast.process(action_id)
        failed = emitted_events.find { |e| e[:name] == 'task.failed' }
        expect(failed).to include(reason: :transport_error, task: 'broadcast_push', id: action_id)
        expect(failed[:latency_ms]).to be_an(Integer)
      end

      it 'does not call abort_action' do
        broadcast.process(action_id)
        expect(store).not_to have_received(:abort_action)
      end
    end

    context 'when MINED_IN_STALE_BLOCK (transient, not terminal)' do
      let(:stale_response) do
        BSV::Network::ProtocolResponse.new(
          nil,
          http_success: false,
          data: { 'txid' => 'abc123', 'txStatus' => 'MINED_IN_STALE_BLOCK', 'status' => 200 },
          error_message: 'MINED_IN_STALE_BLOCK'
        )
      end

      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
        allow(services).to receive(:call).with(:broadcast, raw_tx).and_return(stale_response)
        allow(store).to receive(:abort_action)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(nil)
      end

      it 'emits task.failed with reason=stale_beef and integer latency_ms' do
        broadcast.process(action_id)
        failed = emitted_events.find { |e| e[:name] == 'task.failed' }
        expect(failed).to include(reason: :stale_beef, task: 'broadcast_push', id: action_id)
        expect(failed[:latency_ms]).to be_an(Integer)
      end

      it 'does NOT call abort_action' do
        broadcast.process(action_id)
        expect(store).not_to have_received(:abort_action)
      end
    end

    context 'when malformed 2xx (no data)' do
      let(:malformed_response) do
        BSV::Network::ProtocolResponse.new(
          nil, http_success: false, error_message: 'ARC returned a malformed 2xx response'
        )
      end

      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
        allow(services).to receive(:call).with(:broadcast, raw_tx).and_return(malformed_response)
        allow(store).to receive(:abort_action)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(nil)
      end

      it 'emits task.failed with reason=malformed and integer latency_ms' do
        broadcast.process(action_id)
        failed = emitted_events.find { |e| e[:name] == 'task.failed' }
        expect(failed).to include(reason: :malformed, task: 'broadcast_push', id: action_id)
        expect(failed[:latency_ms]).to be_an(Integer)
      end

      it 'does not call abort_action (transient)' do
        broadcast.process(action_id)
        expect(store).not_to have_received(:abort_action)
      end
    end

    context 'when REJECTED on 2xx (terminal)' do
      let(:rejected_response) do
        BSV::Network::ProtocolResponse.new(
          nil,
          http_success: false,
          data: { 'txid' => 'abc123', 'txStatus' => 'REJECTED', 'status' => 200,
                  'extraInfo' => 'policy violation' },
          error_message: 'REJECTED'
        )
      end

      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
        allow(services).to receive(:call).with(:broadcast, raw_tx).and_return(rejected_response)
        allow(store).to receive(:abort_action)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(nil)
      end

      it 'emits task.aborted with reason=policy_violation and arc_status' do
        broadcast.process(action_id)
        aborted = emitted_events.find { |e| e[:name] == 'task.aborted' }
        expect(aborted).to include(
          reason: :policy_violation, arc_status: 'REJECTED',
          task: 'broadcast_push', id: action_id
        )
      end

      it 'calls abort_action on the store' do
        broadcast.process(action_id)
        expect(store).to have_received(:abort_action).with(action_id: action_id)
      end
    end

    context 'when DOUBLE_SPEND_ATTEMPTED on 2xx (terminal)' do
      let(:double_spend_response) do
        BSV::Network::ProtocolResponse.new(
          nil,
          http_success: false,
          data: { 'txid' => 'abc123', 'txStatus' => 'DOUBLE_SPEND_ATTEMPTED', 'status' => 200 },
          error_message: 'DOUBLE_SPEND_ATTEMPTED'
        )
      end

      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
        allow(services).to receive(:call).with(:broadcast, raw_tx).and_return(double_spend_response)
        allow(store).to receive(:abort_action)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(nil)
      end

      it 'emits task.aborted with reason=double_spend and arc_status' do
        broadcast.process(action_id)
        aborted = emitted_events.find { |e| e[:name] == 'task.aborted' }
        expect(aborted).to include(
          reason: :double_spend, arc_status: 'DOUBLE_SPEND_ATTEMPTED',
          task: 'broadcast_push', id: action_id
        )
      end

      it 'calls abort_action on the store' do
        broadcast.process(action_id)
        expect(store).to have_received(:abort_action).with(action_id: action_id)
      end
    end

    context 'when MALFORMED (terminal)' do
      let(:malformed_response) do
        BSV::Network::ProtocolResponse.new(
          nil,
          http_success: false,
          data: { 'txid' => 'abc123', 'txStatus' => 'MALFORMED', 'status' => 200 },
          error_message: 'MALFORMED'
        )
      end

      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
        allow(services).to receive(:call).with(:broadcast, raw_tx).and_return(malformed_response)
        allow(store).to receive(:abort_action)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(nil)
      end

      it 'emits task.aborted with reason=malformed and arc_status' do
        broadcast.process(action_id)
        aborted = emitted_events.find { |e| e[:name] == 'task.aborted' }
        expect(aborted).to include(
          reason: :malformed, arc_status: 'MALFORMED',
          task: 'broadcast_push', id: action_id
        )
      end

      it 'calls abort_action on the store' do
        broadcast.process(action_id)
        expect(store).to have_received(:abort_action).with(action_id: action_id)
      end
    end

    context 'when ORPHAN in extraInfo (terminal)' do
      let(:orphan_response) do
        BSV::Network::ProtocolResponse.new(
          nil,
          http_success: false,
          data: { 'txid' => 'abc123', 'txStatus' => 'UNKNOWN', 'status' => 200,
                  'extraInfo' => 'transaction is ORPHAN' },
          error_message: 'transaction is ORPHAN'
        )
      end

      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
        allow(services).to receive(:call).with(:broadcast, raw_tx).and_return(orphan_response)
        allow(store).to receive(:abort_action)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(nil)
      end

      it 'emits task.aborted with reason=policy_violation' do
        broadcast.process(action_id)
        aborted = emitted_events.find { |e| e[:name] == 'task.aborted' }
        expect(aborted).to include(
          reason: :policy_violation, arc_status: 'UNKNOWN',
          task: 'broadcast_push', id: action_id
        )
      end

      it 'calls abort_action on the store' do
        broadcast.process(action_id)
        expect(store).to have_received(:abort_action).with(action_id: action_id)
      end
    end

    context 'when broadcast succeeds' do
      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
        allow(services).to receive(:call).with(:broadcast, raw_tx).and_return(success_response)
        allow(store).to receive(:record_broadcast_result)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(status_hash)
      end

      it 'never emits binary data in event payloads' do
        broadcast.process(action_id)
        emitted_events.each do |event|
          event.each_value do |v|
            next unless v.is_a?(String)

            expect(v.encoding).not_to eq(Encoding::ASCII_8BIT),
                                      "Binary data leaked in event #{event[:name]}"
          end
        end
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
