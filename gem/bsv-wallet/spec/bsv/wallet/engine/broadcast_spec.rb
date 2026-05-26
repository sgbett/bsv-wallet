# frozen_string_literal: true

require 'bsv-wallet'
require 'bsv/wallet/engine/broadcast'
require 'logger'
require_relative '../../../support/console_helpers'

RSpec.describe BSV::Wallet::Engine::Broadcast do
  let(:store) { double('Store') }
  let(:services) { double('Services') }
  let(:broadcast) { described_class.new(store: store, services: services) }

  let(:action_id) { 42 }
  let(:raw_tx) { "\x01\x00".b }
  let(:action_hash) { { id: action_id, raw_tx: raw_tx } }
  # Success responses come through BSV::Network::Services which
  # normalizes to symbol + snake_case keys.
  let(:broadcast_data) do
    {
      txid: 'abc123',
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

  # Capture all emit calls for assertion.
  let(:emitted_events) { [] }

  before do
    allow(BSV::Wallet).to receive(:emit) { |name, **payload| emitted_events << { name: name, **payload } }
    allow(store).to receive(:mark_broadcast_attempted)
    # Phase 4 promote is triggered on accepted ARC responses; stub by default
    # so spec contexts that don't assert on it remain happy.
    allow(store).to receive(:promote_action_outputs).and_return([])
  end

  describe '#process' do
    context 'when action is not found' do
      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(nil)
        allow(services).to receive(:call)
      end

      it 'emits task.dispatched then task.skipped with reason action_not_found' do
        broadcast.process(action_id)

        expect(emitted_events.size).to eq(2)
        expect(emitted_events[0][:name]).to eq('task.dispatched')
        expect(emitted_events[1]).to include(name: 'task.skipped', reason: :action_not_found, id: action_id)
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

      it 'emits task.dispatched then task.skipped with reason no_raw_tx' do
        broadcast.process(action_id)

        expect(emitted_events.size).to eq(2)
        expect(emitted_events[0][:name]).to eq('task.dispatched')
        expect(emitted_events[1]).to include(name: 'task.skipped', reason: :no_raw_tx, id: action_id)
      end

      it 'returns nil without calling services' do
        result = broadcast.process(action_id)
        expect(result).to be_nil
        expect(services).not_to have_received(:call)
      end
    end

    # Submit path -- no prior broadcast (broadcast_status returns nil)
    context 'when accepted with SEEN_ON_NETWORK' do
      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
        allow(services).to receive(:call).with(:broadcast, raw_tx).and_return(success_response)
        allow(store).to receive(:record_broadcast_result).and_return(status_hash)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(nil)
      end

      it 'triggers Phase 4 (promote_action_outputs) on accepted ARC response' do
        broadcast.process(action_id)
        expect(store).to have_received(:promote_action_outputs).with(action_id: action_id)
      end

      it 'calls services.call(:broadcast) with the raw_tx' do
        broadcast.process(action_id)
        expect(services).to have_received(:call).with(:broadcast, raw_tx)
      end

      it 'records the broadcast result from normalized response data' do
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
      let(:broadcast_data) { super().merge(tx_status: 'MINED') }

      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
        allow(services).to receive(:call).with(:broadcast, raw_tx).and_return(success_response)
        allow(store).to receive(:record_broadcast_result).and_return(status_hash)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(nil)
      end

      it 'emits task.succeeded with outcome=accepted and integer latency_ms' do
        broadcast.process(action_id)
        succeeded = emitted_events.find { |e| e[:name] == 'task.succeeded' }
        expect(succeeded).to include(outcome: :accepted)
        expect(succeeded[:latency_ms]).to be_an(Integer)
      end
    end

    context 'when accepted with intermediate status (QUEUED)' do
      let(:broadcast_data) { super().merge(tx_status: 'QUEUED') }

      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
        allow(services).to receive(:call).with(:broadcast, raw_tx).and_return(success_response)
        allow(store).to receive(:record_broadcast_result).and_return(status_hash)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(nil)
      end

      it 'emits task.succeeded with outcome=pending' do
        broadcast.process(action_id)
        succeeded = emitted_events.find { |e| e[:name] == 'task.succeeded' }
        expect(succeeded).to include(outcome: :pending)
      end

      it 'does NOT trigger Phase 4 — intermediate status is not network acceptance' do
        broadcast.process(action_id)
        expect(store).not_to have_received(:promote_action_outputs)
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
        allow(store).to receive(:fail_broadcast_action)
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

      it 'calls fail_broadcast_action on the store (releases locked inputs)' do
        broadcast.process(action_id)
        expect(store).to have_received(:fail_broadcast_action).with(action_id: action_id)
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
        allow(store).to receive(:fail_broadcast_action)
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

      it 'calls fail_broadcast_action on the store (releases locked inputs)' do
        broadcast.process(action_id)
        expect(store).to have_received(:fail_broadcast_action).with(action_id: action_id)
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
        allow(store).to receive(:fail_broadcast_action)
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

      it 'calls fail_broadcast_action on the store (releases locked inputs)' do
        broadcast.process(action_id)
        expect(store).to have_received(:fail_broadcast_action).with(action_id: action_id)
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
        allow(store).to receive(:fail_broadcast_action)
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

      it 'calls fail_broadcast_action on the store (releases locked inputs)' do
        broadcast.process(action_id)
        expect(store).to have_received(:fail_broadcast_action).with(action_id: action_id)
      end
    end

    context 'when broadcast succeeds' do
      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
        allow(services).to receive(:call).with(:broadcast, raw_tx).and_return(success_response)
        allow(store).to receive(:record_broadcast_result).and_return(status_hash)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(nil)
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

    # Poll path -- already broadcast (broadcast_status has broadcast_at)
    context 'when status poll succeeds' do
      let(:wtxid) { SecureRandom.random_bytes(32) }
      let(:dtxid) { wtxid.reverse.unpack1('H*') }
      let(:action_with_wtxid) { { id: action_id, raw_tx: raw_tx, wtxid: wtxid } }
      let(:existing_status) do
        { action_id: action_id, broadcast_at: Time.now - 60, tx_status: 'ACCEPTED_BY_NETWORK' }
      end
      let(:poll_data) do
        {
          tx_status: 'SEEN_ON_NETWORK',
          status: 200,
          block_hash: 'aa' * 32,
          block_height: 100_000,
          merkle_path: nil,
          extra_info: nil,
          competing_txs: nil
        }
      end
      let(:poll_response) do
        BSV::Network::ProtocolResponse.new(nil, data: poll_data, http_success: true)
      end
      let(:updated_status) do
        { action_id: action_id, broadcast_at: existing_status[:broadcast_at], tx_status: 'SEEN_ON_NETWORK' }
      end

      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_with_wtxid)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(existing_status)
        allow(services).to receive(:call).with(:get_tx_status, txid: dtxid).and_return(poll_response)
        allow(store).to receive(:record_broadcast_result).and_return(updated_status)
      end

      it 'calls services.call(:get_tx_status) with the dtxid' do
        broadcast.process(action_id)
        expect(services).to have_received(:call).with(:get_tx_status, txid: dtxid)
      end

      it 'does not re-broadcast' do
        broadcast.process(action_id)
        expect(services).not_to have_received(:call).with(:broadcast, anything)
      end

      it 'records the updated broadcast result' do
        broadcast.process(action_id)
        expect(store).to have_received(:record_broadcast_result).with(
          action_id: action_id,
          tx_status: 'SEEN_ON_NETWORK',
          arc_status: 200,
          block_hash: 'aa' * 32,
          block_height: 100_000,
          merkle_path: nil,
          extra_info: nil,
          competing_txs: nil
        )
      end

      it 'returns the updated broadcast status' do
        result = broadcast.process(action_id)
        expect(result).to eq(updated_status)
      end

      it 'emits task.succeeded with outcome=accepted and integer latency_ms' do
        broadcast.process(action_id)
        succeeded = emitted_events.find { |e| e[:name] == 'task.succeeded' }
        expect(succeeded).to include(outcome: :accepted, task: 'broadcast_push', id: action_id)
        expect(succeeded[:latency_ms]).to be_an(Integer)
      end

      it 'triggers Phase 4 (promote_action_outputs) on accepted poll status' do
        broadcast.process(action_id)
        expect(store).to have_received(:promote_action_outputs).with(action_id: action_id)
      end
    end

    context 'when status poll returns REJECTED (terminal -- C-1 aborts via fail_broadcast_action)' do
      let(:wtxid) { SecureRandom.random_bytes(32) }
      let(:dtxid) { wtxid.reverse.unpack1('H*') }
      let(:action_with_wtxid) { { id: action_id, raw_tx: raw_tx, wtxid: wtxid } }
      let(:existing_status) do
        { action_id: action_id, broadcast_at: Time.now - 60, tx_status: 'ACCEPTED_BY_NETWORK' }
      end
      let(:rejected_data) do
        { tx_status: 'REJECTED', status: 200, block_hash: nil, block_height: nil,
          merkle_path: nil, extra_info: 'policy violation', competing_txs: nil }
      end
      let(:rejected_response) do
        BSV::Network::ProtocolResponse.new(nil, data: rejected_data, http_success: true)
      end

      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_with_wtxid)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(existing_status)
        allow(services).to receive(:call).with(:get_tx_status, txid: dtxid).and_return(rejected_response)
        allow(store).to receive(:record_broadcast_result)
        allow(store).to receive(:abort_action)
        allow(store).to receive(:fail_broadcast_action)
      end

      it 'calls fail_broadcast_action (releases locked inputs)' do
        broadcast.process(action_id)
        expect(store).to have_received(:fail_broadcast_action).with(action_id: action_id)
      end

      it 'does NOT call abort_action (pre-broadcast semantics, not applicable)' do
        broadcast.process(action_id)
        expect(store).not_to have_received(:abort_action)
      end

      it 'does NOT call record_broadcast_result (action is being torn down)' do
        broadcast.process(action_id)
        expect(store).not_to have_received(:record_broadcast_result)
      end

      it 'emits task.aborted with reason=:policy_violation and arc_status=REJECTED' do
        broadcast.process(action_id)
        aborted = emitted_events.find { |e| e[:name] == 'task.aborted' }
        expect(aborted).to include(
          reason: :policy_violation, arc_status: 'REJECTED',
          task: 'broadcast_push', id: action_id
        )
      end

      it 'returns nil (the action no longer exists)' do
        expect(broadcast.process(action_id)).to be_nil
      end
    end

    context 'when status poll returns DOUBLE_SPEND_ATTEMPTED (terminal)' do
      let(:wtxid) { SecureRandom.random_bytes(32) }
      let(:dtxid) { wtxid.reverse.unpack1('H*') }
      let(:action_with_wtxid) { { id: action_id, raw_tx: raw_tx, wtxid: wtxid } }
      let(:existing_status) do
        { action_id: action_id, broadcast_at: Time.now - 60, tx_status: 'ACCEPTED_BY_NETWORK' }
      end
      let(:double_spend_data) do
        { tx_status: 'DOUBLE_SPEND_ATTEMPTED', status: 200, block_hash: nil, block_height: nil,
          merkle_path: nil, extra_info: nil, competing_txs: nil }
      end
      let(:double_spend_response) do
        BSV::Network::ProtocolResponse.new(nil, data: double_spend_data, http_success: true)
      end

      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_with_wtxid)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(existing_status)
        allow(services).to receive(:call).with(:get_tx_status, txid: dtxid).and_return(double_spend_response)
        allow(store).to receive(:fail_broadcast_action)
      end

      it 'calls fail_broadcast_action' do
        broadcast.process(action_id)
        expect(store).to have_received(:fail_broadcast_action).with(action_id: action_id)
      end

      it 'emits task.aborted with reason=:double_spend' do
        broadcast.process(action_id)
        aborted = emitted_events.find { |e| e[:name] == 'task.aborted' }
        expect(aborted).to include(reason: :double_spend, arc_status: 'DOUBLE_SPEND_ATTEMPTED')
      end
    end

    context 'when status poll returns MALFORMED (terminal)' do
      let(:wtxid) { SecureRandom.random_bytes(32) }
      let(:dtxid) { wtxid.reverse.unpack1('H*') }
      let(:action_with_wtxid) { { id: action_id, raw_tx: raw_tx, wtxid: wtxid } }
      let(:existing_status) do
        { action_id: action_id, broadcast_at: Time.now - 60, tx_status: 'ACCEPTED_BY_NETWORK' }
      end
      let(:malformed_data) do
        { tx_status: 'MALFORMED', status: 200, block_hash: nil, block_height: nil,
          merkle_path: nil, extra_info: nil, competing_txs: nil }
      end
      let(:malformed_response) do
        BSV::Network::ProtocolResponse.new(nil, data: malformed_data, http_success: true)
      end

      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_with_wtxid)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(existing_status)
        allow(services).to receive(:call).with(:get_tx_status, txid: dtxid).and_return(malformed_response)
        allow(store).to receive(:fail_broadcast_action)
      end

      it 'calls fail_broadcast_action' do
        broadcast.process(action_id)
        expect(store).to have_received(:fail_broadcast_action).with(action_id: action_id)
      end

      it 'emits task.aborted with reason=:malformed' do
        broadcast.process(action_id)
        aborted = emitted_events.find { |e| e[:name] == 'task.aborted' }
        expect(aborted).to include(reason: :malformed, arc_status: 'MALFORMED')
      end
    end

    context 'when status poll returns ORPHAN in extraInfo (terminal)' do
      let(:wtxid) { SecureRandom.random_bytes(32) }
      let(:dtxid) { wtxid.reverse.unpack1('H*') }
      let(:action_with_wtxid) { { id: action_id, raw_tx: raw_tx, wtxid: wtxid } }
      let(:existing_status) do
        { action_id: action_id, broadcast_at: Time.now - 60, tx_status: 'ACCEPTED_BY_NETWORK' }
      end
      let(:orphan_data) do
        { tx_status: 'UNKNOWN', status: 200, block_hash: nil, block_height: nil,
          merkle_path: nil, extra_info: 'transaction is ORPHAN', competing_txs: nil }
      end
      let(:orphan_response) do
        BSV::Network::ProtocolResponse.new(nil, data: orphan_data, http_success: true)
      end

      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_with_wtxid)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(existing_status)
        allow(services).to receive(:call).with(:get_tx_status, txid: dtxid).and_return(orphan_response)
        allow(store).to receive(:fail_broadcast_action)
      end

      it 'calls fail_broadcast_action' do
        broadcast.process(action_id)
        expect(store).to have_received(:fail_broadcast_action).with(action_id: action_id)
      end

      it 'emits task.aborted with reason=:policy_violation' do
        broadcast.process(action_id)
        aborted = emitted_events.find { |e| e[:name] == 'task.aborted' }
        expect(aborted).to include(reason: :policy_violation, arc_status: 'UNKNOWN')
      end
    end

    context 'when status poll returns MINED with merkle_path' do
      let(:wtxid) { SecureRandom.random_bytes(32) }
      let(:dtxid) { wtxid.reverse.unpack1('H*') }
      let(:action_with_wtxid) { { id: action_id, raw_tx: raw_tx, wtxid: wtxid } }
      let(:existing_status) do
        { action_id: action_id, broadcast_at: Time.now - 60, tx_status: 'SEEN_ON_NETWORK' }
      end
      let(:merkle_path) { 'fe6800020001020304050607' }
      let(:mined_data) do
        { tx_status: 'MINED', status: 200, block_hash: 'bb' * 32, block_height: 100_001,
          merkle_path: merkle_path, extra_info: nil, competing_txs: nil }
      end
      let(:mined_response) do
        BSV::Network::ProtocolResponse.new(nil, data: mined_data, http_success: true)
      end

      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_with_wtxid)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(existing_status)
        allow(services).to receive(:call).with(:get_tx_status, txid: dtxid).and_return(mined_response)
        allow(store).to receive(:record_broadcast_result)
      end

      it 'persists merkle_path on the broadcast row' do
        broadcast.process(action_id)
        expect(store).to have_received(:record_broadcast_result).with(
          hash_including(
            tx_status: 'MINED',
            block_hash: 'bb' * 32,
            block_height: 100_001,
            merkle_path: merkle_path
          )
        )
      end

      it 'emits task.succeeded with outcome=accepted' do
        broadcast.process(action_id)
        succeeded = emitted_events.find { |e| e[:name] == 'task.succeeded' }
        expect(succeeded).to include(outcome: :accepted, task: 'broadcast_push', id: action_id)
      end
    end

    context 'with a known wtxid fixture (dtxid byte-reversal)' do
      # Static fixture: wire-order bytes != display-order hex (no palindrome).
      let(:wtxid) do
        ['cafebabedeadbeef0123456789abcdef0123456789abcdef0123456789abcdef'].pack('H*')
      end
      let(:expected_dtxid) do
        'efcdab8967452301efcdab8967452301efcdab8967452301efbeaddebebafeca'
      end
      let(:action_with_wtxid) { { id: action_id, raw_tx: raw_tx, wtxid: wtxid } }
      let(:existing_status) do
        { action_id: action_id, broadcast_at: Time.now - 60, tx_status: 'ACCEPTED_BY_NETWORK' }
      end
      let(:poll_response) do
        BSV::Network::ProtocolResponse.new(
          nil,
          data: { tx_status: 'SEEN_ON_NETWORK', status: 200, block_hash: nil, block_height: nil,
                  merkle_path: nil, extra_info: nil, competing_txs: nil },
          http_success: true
        )
      end

      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_with_wtxid)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(existing_status)
        allow(store).to receive(:record_broadcast_result)
        allow(services).to receive(:call).and_return(poll_response)
      end

      it 'sends the byte-reversed hex (display order) to :get_tx_status' do
        broadcast.process(action_id)
        expect(services).to have_received(:call).with(:get_tx_status, txid: expected_dtxid)
      end
    end

    context 'when status poll fails (503 transport error)' do
      let(:wtxid) { SecureRandom.random_bytes(32) }
      let(:dtxid) { wtxid.reverse.unpack1('H*') }
      let(:action_with_wtxid) { { id: action_id, raw_tx: raw_tx, wtxid: wtxid } }
      let(:existing_status) do
        { action_id: action_id, broadcast_at: Time.now - 60, tx_status: 'ACCEPTED_BY_NETWORK' }
      end
      let(:http_response) { instance_double(Net::HTTPServiceUnavailable, code: '503') }
      let(:error_response) do
        BSV::Network::ProtocolResponse.new(http_response, http_success: false, error_message: 'ARC unavailable')
      end

      before do
        allow(http_response).to receive(:is_a?).and_return(false)
        allow(http_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
        allow(http_response).to receive(:is_a?).with(Net::HTTPTooManyRequests).and_return(false)
        allow(http_response).to receive(:is_a?).with(Net::HTTPServerError).and_return(true)
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_with_wtxid)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(existing_status)
        allow(services).to receive(:call).with(:get_tx_status, txid: dtxid).and_return(error_response)
      end

      it 'does not call record_broadcast_result' do
        allow(store).to receive(:record_broadcast_result)
        broadcast.process(action_id)
        expect(store).not_to have_received(:record_broadcast_result)
      end

      it 'returns the existing broadcast status' do
        result = broadcast.process(action_id)
        expect(result).to eq(existing_status)
      end

      it 'emits task.failed with reason=transport_error and integer latency_ms' do
        broadcast.process(action_id)
        failed = emitted_events.find { |e| e[:name] == 'task.failed' }
        expect(failed).to include(reason: :transport_error, task: 'broadcast_push', id: action_id)
        expect(failed[:latency_ms]).to be_an(Integer)
      end
    end

    context 'when polling with no wtxid' do
      let(:existing_status) do
        { action_id: action_id, broadcast_at: Time.now - 60, tx_status: 'ACCEPTED_BY_NETWORK' }
      end

      before do
        allow(store).to receive(:find_action).with(id: action_id)
                                             .and_return({ id: action_id, raw_tx: raw_tx, wtxid: nil })
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(existing_status)
        allow(services).to receive(:call)
      end

      it 'returns the broadcast status without calling services' do
        result = broadcast.process(action_id)
        expect(result).to eq(existing_status)
        expect(services).not_to have_received(:call)
      end

      it 'emits task.skipped with reason=no_wtxid' do
        broadcast.process(action_id)
        skipped = emitted_events.find { |e| e[:name] == 'task.skipped' }
        expect(skipped).to include(reason: :no_wtxid, task: 'broadcast_push', id: action_id)
      end
    end
  end

  describe 'pre-POST broadcast_at stamp on submit path' do
    before do
      allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
      allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(nil)
      allow(store).to receive(:record_broadcast_result).and_return(status_hash)
    end

    it 'stamps broadcast_at before calling services.call(:broadcast)' do
      call_order = []
      allow(store).to receive(:mark_broadcast_attempted) do |**|
        call_order << :stamp
      end
      allow(services).to receive(:call).with(:broadcast, raw_tx) do
        call_order << :network
        success_response
      end

      broadcast.process(action_id)

      expect(call_order).to eq(%i[stamp network])
    end

    it 'stamps the broadcast row even when services.call raises' do
      allow(services).to receive(:call).with(:broadcast, raw_tx).and_raise(StandardError, 'boom')

      expect { broadcast.process(action_id) }.to raise_error(StandardError, 'boom')
      expect(store).to have_received(:mark_broadcast_attempted).with(action_id: action_id)
    end

    it 'does not call record_broadcast_result when services.call raises (crash-recovery state)' do
      allow(store).to receive(:record_broadcast_result)
      allow(services).to receive(:call).with(:broadcast, raw_tx).and_raise(StandardError, 'boom')

      expect { broadcast.process(action_id) }.to raise_error(StandardError, 'boom')
      expect(store).not_to have_received(:record_broadcast_result)
    end
  end

  describe '.pending_polls' do
    it 'delegates to store.pending_polls and maps to action IDs' do
      pending_records = [
        { action_id: 1, tx_status: nil },
        { action_id: 2, tx_status: 'UNKNOWN' }
      ]
      allow(store).to receive(:pending_polls).with(limit: 5).and_return(pending_records)

      result = described_class.pending_polls(store, limit: 5)
      expect(result).to eq([1, 2])
    end

    it 'uses default limit of 10' do
      allow(store).to receive(:pending_polls).with(limit: 10).and_return([])

      result = described_class.pending_polls(store)
      expect(result).to eq([])
    end
  end

  describe '.pending_pushes' do
    it 'delegates to store.pending_pushes and maps to action IDs' do
      pending_records = [
        { action_id: 7, broadcast_at: nil },
        { action_id: 9, broadcast_at: nil }
      ]
      allow(store).to receive(:pending_pushes).with(limit: 5).and_return(pending_records)

      result = described_class.pending_pushes(store, limit: 5)
      expect(result).to eq([7, 9])
    end

    it 'uses default limit of 10' do
      allow(store).to receive(:pending_pushes).with(limit: 10).and_return([])

      result = described_class.pending_pushes(store)
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

      it 'emits fiber.crashed when the bind fails' do
        # Pre-bind the endpoint so the engine's bind raises.
        OMQ::PULL.bind('inproc://broadcasts.pull')

        suppress_console_errors do
          Async do |task|
            broadcast.pull!(task: task)
            sleep 0.05
          ensure
            task.stop
          end
        end

        crashed = emitted_events.find { |e| e[:name] == 'fiber.crashed' }
        expect(crashed).not_to be_nil
        expect(crashed[:task]).to eq('broadcast_push')
        expect(crashed[:error]).to be_a(String)
        expect(crashed[:error]).not_to be_empty
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

      it 'emits fiber.crashed when the bind fails' do
        OMQ::REP.bind('inproc://broadcasts.rep')

        suppress_console_errors do
          Async do |task|
            broadcast.reply!(task: task)
            sleep 0.05
          ensure
            task.stop
          end
        end

        crashed = emitted_events.find { |e| e[:name] == 'fiber.crashed' }
        expect(crashed).not_to be_nil
        expect(crashed[:task]).to eq('broadcast_push')
        expect(crashed[:error]).to be_a(String)
        expect(crashed[:error]).not_to be_empty
      end
    end
  end

  include ConsoleHelpers
end
