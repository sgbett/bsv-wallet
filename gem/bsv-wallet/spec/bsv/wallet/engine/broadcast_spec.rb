# frozen_string_literal: true

require 'bsv-wallet'
require 'bsv/wallet/engine/broadcast'
require 'logger'
require_relative '../../../support/console_helpers'

RSpec.describe BSV::Wallet::Engine::Broadcast do
  let(:store) { double('Store') }
  let(:broadcaster) { double('Broadcaster') }
  let(:broadcast) { described_class.new(store: store, broadcaster: broadcaster) }

  let(:action_id) { 42 }
  # Real signed P2PKH transaction — parseable by Transaction.from_binary so
  # the daemon submit path's EF reconstruction (#252) can hydrate from it.
  # The wtxid below is the SDK's hash of this raw_tx, but most specs use a
  # distinct +submit_wtxid+ for the action's stored wtxid to keep the
  # broadcast-affinity / kwarg-forwarding assertions clear.
  let(:raw_tx) do
    ['01000000016ce7229f014164e254aad172b1f8b40d496942ad7e323b47e0424c2b2e2e3772010000006a47' \
     '30440220463fcf8f57a61c4f8ede208773db8732bf3a0757d929a8cbbe29bf4905fe5ef6022005d74398fa' \
     'f5b24912821836171af44f55f89858f3edf92863cde4823da11d4641210362f5fb9274834bb0cd0376a8d5' \
     'd02bdbf459a37a62c5baef3fb06d1159b55597ffffffff01f0991600000000001976a9141f36a49fcf6ada' \
     '1f74f82377b33b17b68f7a016188acd3740e00'].pack('H*')
  end
  let(:submit_wtxid) { SecureRandom.random_bytes(32) }
  let(:action_hash) { { id: action_id, raw_tx: raw_tx, wtxid: submit_wtxid } }
  # Per-input source data that #hydrated_transaction_for attaches to the
  # parsed Transaction. Matches the single input in +raw_tx+.
  let(:resolved_inputs) do
    [{ source_satoshis: 1_500_000, source_locking_script: ["76a914#{'a' * 40}88ac"].pack('H*') }]
  end
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
    # EF reconstruction (#252) calls into the Store at submit time to hydrate
    # per-input source data. Stubbed by default so submission specs do not
    # have to wire it per-context.
    allow(store).to receive(:resolve_inputs_for_signing).with(action_id: action_id).and_return(resolved_inputs)
    # Eager proof linking (#271) — submit calls these only when the response
    # carries merkle material; spec contexts that don't supply it just need
    # the stubs in place so the assertions can verify "was/wasn't called".
    allow(store).to receive_messages(promote_action_outputs: [], save_proof: nil)
    allow(store).to receive(:link_proof)
  end

  describe '#process' do
    context 'when action is not found' do
      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(nil)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(nil)
        allow(broadcaster).to receive(:broadcast)
        allow(broadcaster).to receive(:get_tx_status)
      end

      it 'emits task.dispatched then task.skipped with reason action_not_found' do
        broadcast.process(action_id)

        expect(emitted_events.size).to eq(2)
        expect(emitted_events[0][:name]).to eq('task.dispatched')
        expect(emitted_events[1]).to include(name: 'task.skipped', reason: :action_not_found, id: action_id)
      end

      it 'returns nil without calling the broadcaster' do
        result = broadcast.process(action_id)
        expect(result).to be_nil
        expect(broadcaster).not_to have_received(:broadcast)
        expect(broadcaster).not_to have_received(:get_tx_status)
      end
    end

    context 'when action has no raw_tx' do
      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return({ id: action_id, raw_tx: nil })
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(nil)
        allow(broadcaster).to receive(:broadcast)
        allow(broadcaster).to receive(:get_tx_status)
      end

      it 'emits task.dispatched then task.skipped with reason no_raw_tx' do
        broadcast.process(action_id)

        expect(emitted_events.size).to eq(2)
        expect(emitted_events[0][:name]).to eq('task.dispatched')
        expect(emitted_events[1]).to include(name: 'task.skipped', reason: :no_raw_tx, id: action_id)
      end

      it 'returns nil without calling the broadcaster' do
        result = broadcast.process(action_id)
        expect(result).to be_nil
        expect(broadcaster).not_to have_received(:broadcast)
        expect(broadcaster).not_to have_received(:get_tx_status)
      end
    end

    # Submit path -- no prior broadcast (broadcast_status returns nil)
    context 'when accepted with SEEN_ON_NETWORK' do
      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
        allow(broadcaster).to receive(:broadcast).with(kind_of(BSV::Transaction::Transaction), wtxid: submit_wtxid).and_return(success_response)
        allow(store).to receive(:record_broadcast_result).and_return(status_hash)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(nil)
      end

      it 'records the broadcast result (which atomically promotes outputs)' do
        broadcast.process(action_id)
        # Phase 4 is atomic with record_broadcast_result inside the Store
        # transaction when tx_status is accepted. The engine doesn't call
        # promote_action_outputs directly anymore.
        expect(store).to have_received(:record_broadcast_result).with(
          hash_including(action_id: action_id, tx_status: 'SEEN_ON_NETWORK')
        )
      end

      it 'calls broadcaster.broadcast with a hydrated Transaction and submit wtxid' do
        broadcast.process(action_id)
        expect(broadcaster).to have_received(:broadcast).with(kind_of(BSV::Transaction::Transaction), wtxid: submit_wtxid)
      end

      it 'hydrates each input with source_satoshis and source_locking_script for EF (#252)' do
        captured_tx = nil
        allow(broadcaster).to receive(:broadcast) { |tx, **|
          captured_tx = tx
          success_response
        }

        broadcast.process(action_id)

        expect(captured_tx.inputs.length).to eq(resolved_inputs.length)
        captured_tx.inputs.each_with_index do |input, idx|
          expect(input.source_satoshis).to eq(resolved_inputs[idx][:source_satoshis])
          expect(input.source_locking_script.to_binary).to eq(resolved_inputs[idx][:source_locking_script])
        end
      end

      it 'short-circuits reconstruction when the EF cache has the action (#269 hit)' do
        cached_tx = BSV::Transaction::Transaction.from_binary(raw_tx)
        broadcast.hydrated_tx_cache.put(action_id, cached_tx)
        captured_tx = nil
        allow(broadcaster).to receive(:broadcast) { |tx, **|
          captured_tx = tx
          success_response
        }

        broadcast.process(action_id)

        expect(captured_tx).to equal(cached_tx)
        # Cache hit means no JOIN on the broadcast path — the DB-side
        # resolve call must not fire.
        expect(store).not_to have_received(:resolve_inputs_for_signing)
      end

      it 'evicts the action from the EF cache after terminal success (#269)' do
        broadcast.hydrated_tx_cache.put(action_id, BSV::Transaction::Transaction.from_binary(raw_tx))
        expect(broadcast.hydrated_tx_cache.get(action_id)).not_to be_nil

        broadcast.process(action_id)

        expect(broadcast.hydrated_tx_cache.get(action_id)).to be_nil
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

      it 'does not link a proof when the response carries no merkle_path' do
        broadcast.process(action_id)
        expect(store).not_to have_received(:save_proof)
        expect(store).not_to have_received(:link_proof)
      end

      it 'eagerly saves the proof and links to the action when response carries merkle material (#271)' do
        mp = BSV::Transaction::MerklePath.new(
          block_height: 850_000,
          path: [[
            BSV::Transaction::MerklePath::PathElement.new(offset: 0, hash: submit_wtxid, txid: true),
            BSV::Transaction::MerklePath::PathElement.new(offset: 1, hash: SecureRandom.random_bytes(32))
          ]]
        )
        merkle_path_binary = mp.to_binary
        proof_data = broadcast_data.merge(merkle_path: merkle_path_binary, block_height: 850_000, block_hash: SecureRandom.random_bytes(32))
        proof_response = BSV::Network::ProtocolResponse.new(nil, data: proof_data, http_success: true)
        allow(broadcaster).to receive(:broadcast).with(kind_of(BSV::Transaction::Transaction), wtxid: submit_wtxid).and_return(proof_response)
        allow(store).to receive(:save_proof).and_return(777)

        broadcast.process(action_id)

        expect(store).to have_received(:save_proof).with(
          wtxid: submit_wtxid,
          proof: hash_including(height: 850_000, merkle_path: kind_of(String), raw_tx: raw_tx)
        )
        expect(store).to have_received(:link_proof).with(action_id: action_id, tx_proof_id: 777)
      end

      it 'returns the broadcast status' do
        result = broadcast.process(action_id)
        expect(result).to eq(status_hash)
      end

      it 'emits task.succeeded with outcome=accepted and integer latency_ms' do
        broadcast.process(action_id)

        expect(emitted_events.size).to eq(2)
        expect(emitted_events[0]).to include(name: 'task.dispatched', task: 'broadcast_submission', id: action_id)
        succeeded = emitted_events[1]
        expect(succeeded).to include(name: 'task.succeeded', task: 'broadcast_submission', id: action_id, outcome: :accepted)
        expect(succeeded[:latency_ms]).to be_an(Integer)
      end
    end

    context 'when accepted with MINED' do
      let(:broadcast_data) { super().merge(tx_status: 'MINED') }

      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
        allow(broadcaster).to receive(:broadcast).with(kind_of(BSV::Transaction::Transaction), wtxid: submit_wtxid).and_return(success_response)
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
        allow(broadcaster).to receive(:broadcast).with(kind_of(BSV::Transaction::Transaction), wtxid: submit_wtxid).and_return(success_response)
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
        allow(broadcaster).to receive(:broadcast).with(kind_of(BSV::Transaction::Transaction), wtxid: submit_wtxid).and_return(error_response)
        allow(store).to receive(:abort_action)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(nil)
      end

      it 'emits task.failed with reason=rate_limited and integer latency_ms' do
        broadcast.process(action_id)
        failed = emitted_events.find { |e| e[:name] == 'task.failed' }
        expect(failed).to include(reason: :rate_limited, task: 'broadcast_submission', id: action_id)
        expect(failed[:latency_ms]).to be_an(Integer)
      end

      it 'does not call abort_action' do
        broadcast.process(action_id)
        expect(store).not_to have_received(:abort_action)
      end
    end

    context 'when 503 backpressure (Arcade validator-queue full)' do
      let(:http_response) { instance_double(Net::HTTPServiceUnavailable, code: '503') }
      let(:error_response) do
        BSV::Network::ProtocolResponse.new(http_response, http_success: false, error_message: 'Arcade backpressure')
      end

      before do
        allow(http_response).to receive(:is_a?).and_return(false)
        allow(http_response).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
        allow(http_response).to receive(:is_a?).with(Net::HTTPTooManyRequests).and_return(false)
        allow(http_response).to receive(:is_a?).with(Net::HTTPServerError).and_return(true)
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
        allow(broadcaster).to receive(:broadcast).with(kind_of(BSV::Transaction::Transaction), wtxid: submit_wtxid).and_return(error_response)
        allow(store).to receive(:abort_action)
        allow(store).to receive(:clear_broadcast_attempted)
        allow(store).to receive(:reject_action)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(nil)
      end

      it 'emits task.failed with reason=backpressure and integer latency_ms' do
        broadcast.process(action_id)
        failed = emitted_events.find { |e| e[:name] == 'task.failed' }
        expect(failed).to include(reason: :backpressure, task: 'broadcast_submission', id: action_id)
        expect(failed[:latency_ms]).to be_an(Integer)
      end

      it 'calls clear_broadcast_attempted so the row re-enters the queued set' do
        broadcast.process(action_id)
        expect(store).to have_received(:clear_broadcast_attempted).with(action_id: action_id)
      end

      it 'does not call reject_action (503 is transient, not terminal)' do
        broadcast.process(action_id)
        expect(store).not_to have_received(:reject_action)
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
        allow(broadcaster).to receive(:broadcast).with(kind_of(BSV::Transaction::Transaction), wtxid: submit_wtxid).and_return(stale_response)
        allow(store).to receive(:abort_action)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(nil)
      end

      it 'emits task.failed with reason=stale_beef and integer latency_ms' do
        broadcast.process(action_id)
        failed = emitted_events.find { |e| e[:name] == 'task.failed' }
        expect(failed).to include(reason: :stale_beef, task: 'broadcast_submission', id: action_id)
        expect(failed[:latency_ms]).to be_an(Integer)
      end

      it 'does NOT call abort_action' do
        broadcast.process(action_id)
        expect(store).not_to have_received(:abort_action)
      end
    end

    context 'when DB input count disagrees with parsed tx (#252 defensive guard)' do
      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(nil)
        # raw_tx parses to 1 input; return 2 source rows to provoke the
        # mismatch raise.
        allow(store).to receive(:resolve_inputs_for_signing).with(action_id: action_id).and_return(resolved_inputs * 2)
        allow(broadcaster).to receive(:broadcast)
      end

      it 'raises BSV::Wallet::Error with action_id and counts' do
        expect { broadcast.process(action_id) }
          .to raise_error(BSV::Wallet::Error, /input count mismatch action_id=#{action_id} tx=1 db=2/)
      end

      it 'does not call broadcaster.broadcast' do
        broadcast.process(action_id)
      rescue BSV::Wallet::Error
        expect(broadcaster).not_to have_received(:broadcast)
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
        allow(broadcaster).to receive(:broadcast).with(kind_of(BSV::Transaction::Transaction), wtxid: submit_wtxid).and_return(malformed_response)
        allow(store).to receive(:abort_action)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(nil)
      end

      it 'emits task.failed with reason=malformed and integer latency_ms' do
        broadcast.process(action_id)
        failed = emitted_events.find { |e| e[:name] == 'task.failed' }
        expect(failed).to include(reason: :malformed, task: 'broadcast_submission', id: action_id)
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
        allow(broadcaster).to receive(:broadcast).with(kind_of(BSV::Transaction::Transaction), wtxid: submit_wtxid).and_return(rejected_response)
        allow(store).to receive(:reject_action)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(nil)
      end

      it 'emits task.aborted with reason=policy_violation and arc_status' do
        broadcast.process(action_id)
        aborted = emitted_events.find { |e| e[:name] == 'task.aborted' }
        expect(aborted).to include(
          reason: :policy_violation, arc_status: 'REJECTED',
          task: 'broadcast_submission', id: action_id
        )
        # The {txStatus, extraInfo} shape carries no reason; key omitted.
        expect(aborted).not_to have_key(:arc_reason)
      end

      it 'calls reject_action on the store (releases locked inputs)' do
        broadcast.process(action_id)
        expect(store).to have_received(:reject_action).with(action_id: action_id)
      end

      it 'evicts the action from the EF cache after terminal rejection (#269)' do
        broadcast.hydrated_tx_cache.put(action_id, BSV::Transaction::Transaction.from_binary(raw_tx))
        broadcast.process(action_id)
        expect(broadcast.hydrated_tx_cache.get(action_id)).to be_nil
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
        allow(broadcaster).to receive(:broadcast).with(kind_of(BSV::Transaction::Transaction), wtxid: submit_wtxid).and_return(double_spend_response)
        allow(store).to receive(:reject_action)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(nil)
      end

      it 'emits task.aborted with reason=double_spend and arc_status' do
        broadcast.process(action_id)
        aborted = emitted_events.find { |e| e[:name] == 'task.aborted' }
        expect(aborted).to include(
          reason: :double_spend, arc_status: 'DOUBLE_SPEND_ATTEMPTED',
          task: 'broadcast_submission', id: action_id
        )
      end

      it 'calls reject_action on the store (releases locked inputs)' do
        broadcast.process(action_id)
        expect(store).to have_received(:reject_action).with(action_id: action_id)
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
        allow(broadcaster).to receive(:broadcast).with(kind_of(BSV::Transaction::Transaction), wtxid: submit_wtxid).and_return(orphan_response)
        allow(store).to receive(:reject_action)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(nil)
      end

      it 'emits task.aborted with reason=policy_violation' do
        broadcast.process(action_id)
        aborted = emitted_events.find { |e| e[:name] == 'task.aborted' }
        expect(aborted).to include(
          reason: :policy_violation, arc_status: 'UNKNOWN',
          task: 'broadcast_submission', id: action_id
        )
      end

      it 'calls reject_action on the store (releases locked inputs)' do
        broadcast.process(action_id)
        expect(store).to have_received(:reject_action).with(action_id: action_id)
      end
    end

    # #270 — Arcade's synchronous broadcast 4xx body shape carries
    # {error, reason} rather than {txStatus, extraInfo}. Pre-#270 this
    # landed as task.failed reason=:unknown (or :malformed pre-SDK-0.23.1)
    # and the action stayed alive on the synchronous path, relying on
    # SSE to eventually cascade. Post-#270 both paths agree: the
    # synchronous response triggers reject_action immediately, and the
    # 'reason' diagnostic is preserved on the event payload.
    context "when 4xx with Arcade's broadcast-rejection shape (#270)" do
      let(:broadcast_rejection_response) do
        BSV::Network::ProtocolResponse.new(
          nil,
          http_success: false,
          data: { 'error' => 'transaction failed validation',
                  'reason' => "'PreviousTx' not supplied" },
          error_message: "'PreviousTx' not supplied"
        )
      end

      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
        allow(broadcaster).to receive(:broadcast)
          .with(kind_of(BSV::Transaction::Transaction), wtxid: submit_wtxid)
          .and_return(broadcast_rejection_response)
        allow(store).to receive(:reject_action)
        allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(nil)
      end

      it 'calls reject_action on the store (releases locked inputs)' do
        broadcast.process(action_id)
        expect(store).to have_received(:reject_action).with(action_id: action_id)
      end

      it 'emits task.aborted with reason=policy_violation and arc_reason carrying the diagnostic' do
        broadcast.process(action_id)
        aborted = emitted_events.find { |e| e[:name] == 'task.aborted' }
        expect(aborted).to include(
          reason: :policy_violation,
          arc_reason: "'PreviousTx' not supplied",
          task: 'broadcast_submission', id: action_id
        )
        # The {error, reason} 4xx shape carries no txStatus; the key is
        # omitted from the event rather than emitted as nil.
        expect(aborted).not_to have_key(:arc_status)
      end

      it 'does not emit task.failed reason=:unknown (regression guard against the pre-#270 categorisation gap)' do
        broadcast.process(action_id)
        failed = emitted_events.find { |e| e[:name] == 'task.failed' }
        expect(failed).to be_nil
      end
    end

    context 'when broadcast succeeds' do
      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
        allow(broadcaster).to receive(:broadcast).with(kind_of(BSV::Transaction::Transaction), wtxid: submit_wtxid).and_return(success_response)
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
        allow(broadcaster).to receive(:get_tx_status)
          .with(wtxid: wtxid, dtxid: dtxid).and_return(poll_response)
        allow(store).to receive(:record_broadcast_result).and_return(updated_status)
        allow(broadcaster).to receive(:broadcast)
      end

      it 'calls broadcaster.get_tx_status with the wtxid + dtxid' do
        broadcast.process(action_id)
        expect(broadcaster).to have_received(:get_tx_status).with(wtxid: wtxid, dtxid: dtxid)
      end

      it 'does not re-broadcast' do
        broadcast.process(action_id)
        expect(broadcaster).not_to have_received(:broadcast)
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
        expect(succeeded).to include(outcome: :accepted, task: 'broadcast_resolution', id: action_id)
        expect(succeeded[:latency_ms]).to be_an(Integer)
      end

      it 'records the broadcast result (which atomically promotes outputs)' do
        broadcast.process(action_id)
        # Phase 4 is atomic with record_broadcast_result inside the Store
        # transaction when tx_status is accepted. The engine doesn't call
        # promote_action_outputs directly anymore.
        expect(store).to have_received(:record_broadcast_result).with(
          hash_including(action_id: action_id, tx_status: 'SEEN_ON_NETWORK')
        )
      end
    end

    context 'when status poll returns REJECTED (terminal -- C-1 aborts via reject_action)' do
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
        allow(broadcaster).to receive(:get_tx_status)
          .with(wtxid: wtxid, dtxid: dtxid).and_return(rejected_response)
        allow(store).to receive(:record_broadcast_result)
        allow(store).to receive(:abort_action)
        allow(store).to receive(:reject_action)
      end

      it 'calls reject_action (releases locked inputs)' do
        broadcast.process(action_id)
        expect(store).to have_received(:reject_action).with(action_id: action_id)
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
          task: 'broadcast_resolution', id: action_id
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
        allow(broadcaster).to receive(:get_tx_status)
          .with(wtxid: wtxid, dtxid: dtxid).and_return(double_spend_response)
        allow(store).to receive(:reject_action)
      end

      it 'calls reject_action' do
        broadcast.process(action_id)
        expect(store).to have_received(:reject_action).with(action_id: action_id)
      end

      it 'emits task.aborted with reason=:double_spend' do
        broadcast.process(action_id)
        aborted = emitted_events.find { |e| e[:name] == 'task.aborted' }
        expect(aborted).to include(reason: :double_spend, arc_status: 'DOUBLE_SPEND_ATTEMPTED')
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
        allow(broadcaster).to receive(:get_tx_status)
          .with(wtxid: wtxid, dtxid: dtxid).and_return(orphan_response)
        allow(store).to receive(:reject_action)
      end

      it 'calls reject_action' do
        broadcast.process(action_id)
        expect(store).to have_received(:reject_action).with(action_id: action_id)
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
        allow(broadcaster).to receive(:get_tx_status)
          .with(wtxid: wtxid, dtxid: dtxid).and_return(mined_response)
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
        expect(succeeded).to include(outcome: :accepted, task: 'broadcast_resolution', id: action_id)
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
        allow(broadcaster).to receive(:get_tx_status).and_return(poll_response)
      end

      it 'sends the byte-reversed hex (display order) to broadcaster.get_tx_status' do
        broadcast.process(action_id)
        expect(broadcaster).to have_received(:get_tx_status).with(wtxid: wtxid, dtxid: expected_dtxid)
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
        allow(broadcaster).to receive(:get_tx_status)
          .with(wtxid: wtxid, dtxid: dtxid).and_return(error_response)
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
        expect(failed).to include(reason: :transport_error, task: 'broadcast_resolution', id: action_id)
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
        allow(broadcaster).to receive(:get_tx_status)
      end

      it 'returns the broadcast status without calling the broadcaster' do
        result = broadcast.process(action_id)
        expect(result).to eq(existing_status)
        expect(broadcaster).not_to have_received(:get_tx_status)
      end

      it 'emits task.skipped with reason=no_wtxid' do
        broadcast.process(action_id)
        skipped = emitted_events.find { |e| e[:name] == 'task.skipped' }
        expect(skipped).to include(reason: :no_wtxid, task: 'broadcast_resolution', id: action_id)
      end
    end
  end

  describe 'pre-POST broadcast_at stamp on submit path' do
    before do
      allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
      allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(nil)
      allow(store).to receive(:record_broadcast_result).and_return(status_hash)
    end

    it 'stamps broadcast_at before calling broadcaster.broadcast' do
      call_order = []
      allow(store).to receive(:mark_broadcast_attempted) do |**|
        call_order << :stamp
      end
      allow(broadcaster).to receive(:broadcast).with(kind_of(BSV::Transaction::Transaction), wtxid: submit_wtxid) do
        call_order << :network
        success_response
      end

      broadcast.process(action_id)

      expect(call_order).to eq(%i[stamp network])
    end

    it 'stamps the broadcast row even when broadcaster.broadcast raises' do
      allow(broadcaster).to receive(:broadcast).with(kind_of(BSV::Transaction::Transaction), wtxid: submit_wtxid).and_raise(StandardError, 'boom')

      expect { broadcast.process(action_id) }.to raise_error(StandardError, 'boom')
      expect(store).to have_received(:mark_broadcast_attempted).with(action_id: action_id)
    end

    it 'does not call record_broadcast_result when broadcaster.broadcast raises (crash-recovery state)' do
      allow(store).to receive(:record_broadcast_result)
      allow(broadcaster).to receive(:broadcast).with(kind_of(BSV::Transaction::Transaction), wtxid: submit_wtxid).and_raise(StandardError, 'boom')

      expect { broadcast.process(action_id) }.to raise_error(StandardError, 'boom')
      expect(store).not_to have_received(:record_broadcast_result)
    end
  end

  describe 'X-CallbackToken plumbing on submit path' do
    let(:callback_token) { 'tok-abc123' }
    let(:broadcast_with_token) do
      described_class.new(store: store, broadcaster: broadcaster, callback_token: callback_token)
    end

    before do
      allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
      allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(nil)
      allow(store).to receive(:record_broadcast_result).and_return(status_hash)
    end

    it 'forwards the configured callback_token to broadcaster.broadcast' do
      allow(broadcaster).to receive(:broadcast)
        .with(kind_of(BSV::Transaction::Transaction), wtxid: submit_wtxid, callback_token: callback_token)
        .and_return(success_response)

      broadcast_with_token.process(action_id)

      expect(broadcaster).to have_received(:broadcast)
        .with(kind_of(BSV::Transaction::Transaction), wtxid: submit_wtxid, callback_token: callback_token)
    end

    it 'omits callback_token kwarg when not configured (lenient default)' do
      # Default constructor — no callback_token. The broadcaster call
      # carries only the wtxid kwarg.
      allow(broadcaster).to receive(:broadcast).with(kind_of(BSV::Transaction::Transaction), wtxid: submit_wtxid).and_return(success_response)

      broadcast.process(action_id)

      expect(broadcaster).to have_received(:broadcast).with(kind_of(BSV::Transaction::Transaction), wtxid: submit_wtxid)
    end
  end

  describe 'submit-path HTTP-status dispatch (#266)' do
    # 400 with a body carrying a terminal txStatus -- preserves today's
    # behaviour (reject_action cascade). 400 without txStatus exercises the
    # subtlety in #266's edge-case list (non-cascade transient).
    let(:http_400) { instance_double(Net::HTTPBadRequest, code: '400') }

    before do
      allow(http_400).to receive(:is_a?).and_return(false)
      allow(http_400).to receive(:is_a?).with(Net::HTTPSuccess).and_return(false)
      allow(http_400).to receive(:is_a?).with(Net::HTTPTooManyRequests).and_return(false)
      allow(http_400).to receive(:is_a?).with(Net::HTTPServerError).and_return(false)
      allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
      allow(store).to receive(:broadcast_status).with(action_id: action_id).and_return(nil)
      allow(store).to receive(:reject_action)
      allow(store).to receive(:clear_broadcast_attempted)
    end

    context 'when 400 carries a terminal txStatus (REJECTED)' do
      let(:rejected_400) do
        BSV::Network::ProtocolResponse.new(
          http_400, http_success: false,
                    data: { 'txid' => 'abc', 'txStatus' => 'REJECTED' },
                    error_message: 'REJECTED'
        )
      end

      it 'calls reject_action (cascade unwind)' do
        allow(broadcaster).to receive(:broadcast).with(kind_of(BSV::Transaction::Transaction), wtxid: submit_wtxid).and_return(rejected_400)
        broadcast.process(action_id)
        expect(store).to have_received(:reject_action).with(action_id: action_id)
      end

      it 'does not call clear_broadcast_attempted (terminal, not transient)' do
        allow(broadcaster).to receive(:broadcast).with(kind_of(BSV::Transaction::Transaction), wtxid: submit_wtxid).and_return(rejected_400)
        broadcast.process(action_id)
        expect(store).not_to have_received(:clear_broadcast_attempted)
      end
    end

    context 'when 400 carries no txStatus (non-terminal failure)' do
      # Mirrors the #266 edge case: some ARC 400s are retryable. They must
      # not auto-cascade into reject_action -- the row stays alive for the
      # resolution loop / poll path to converge.
      let(:non_terminal_400) do
        BSV::Network::ProtocolResponse.new(
          http_400, http_success: false,
                    data: { 'detail' => 'rate limit', 'title' => 'Bad Request' },
                    error_message: 'Bad Request'
        )
      end

      it 'does not call reject_action' do
        allow(broadcaster).to receive(:broadcast).with(kind_of(BSV::Transaction::Transaction), wtxid: submit_wtxid).and_return(non_terminal_400)
        broadcast.process(action_id)
        expect(store).not_to have_received(:reject_action)
      end

      it 'does not call clear_broadcast_attempted (row stays stamped for poll path)' do
        allow(broadcaster).to receive(:broadcast).with(kind_of(BSV::Transaction::Transaction), wtxid: submit_wtxid).and_return(non_terminal_400)
        broadcast.process(action_id)
        expect(store).not_to have_received(:clear_broadcast_attempted)
      end
    end
  end

  describe '.pending_resolutions' do
    it 'delegates to store.pending_resolutions and maps to action IDs' do
      pending_records = [
        { action_id: 1, tx_status: nil },
        { action_id: 2, tx_status: 'UNKNOWN' }
      ]
      allow(store).to receive(:pending_resolutions).with(limit: 5).and_return(pending_records)

      result = described_class.pending_resolutions(store, limit: 5)
      expect(result).to eq([1, 2])
    end

    it 'uses default limit of 10' do
      allow(store).to receive(:pending_resolutions).with(limit: 10).and_return([])

      result = described_class.pending_resolutions(store)
      expect(result).to eq([])
    end
  end

  describe '.pending_submissions' do
    it 'delegates to store.pending_submissions and maps to action IDs' do
      pending_records = [
        { action_id: 7, broadcast_at: nil },
        { action_id: 9, broadcast_at: nil }
      ]
      allow(store).to receive(:pending_submissions).with(limit: 5).and_return(pending_records)

      result = described_class.pending_submissions(store, limit: 5)
      expect(result).to eq([7, 9])
    end

    it 'uses default limit of 10' do
      allow(store).to receive(:pending_submissions).with(limit: 10).and_return([])

      result = described_class.pending_submissions(store)
      expect(result).to eq([])
    end
  end

  describe 'OMQ sockets', :omq do
    before do
      allow(store).to receive_messages(find_action: action_hash,
                                       record_broadcast_result: nil,
                                       broadcast_status: status_hash)
      allow(broadcaster).to receive(:broadcast).and_return(success_response)
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
        expect(crashed[:task]).to eq('broadcast_worker')
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
        expect(crashed[:task]).to eq('broadcast_worker')
        expect(crashed[:error]).to be_a(String)
        expect(crashed[:error]).not_to be_empty
      end
    end

    describe '#statuses_pull!' do
      # Capture calls in an array so the test can poll until N applied
      # without reaching into RSpec internals.
      let(:applied) { [] }
      let(:applicator) do
        Class.new do
          def initialize(applied) = (@applied = applied)
          def apply(event) = @applied << event
        end.new(applied)
      end
      let(:broadcast) do
        described_class.new(store: store, broadcaster: broadcaster, applicator: applicator)
      end
      let(:event) do
        {
          wtxid: SecureRandom.random_bytes(32),
          tx_status: 'SEEN_ON_NETWORK',
          status: 200,
          block_hash: nil,
          block_height: nil,
          merkle_path: nil,
          extra_info: nil,
          competing_txs: nil
        }
      end

      it 'applies events PUSHed to inproc://statuses.pull' do
        Async do |task|
          broadcast.statuses_pull!(task: task)

          push = OMQ::PUSH.connect('inproc://statuses.pull')
          push << Marshal.dump(event)

          deadline = Time.now + 1.0
          sleep 0.01 until applied.any? || Time.now > deadline

          expect(applied).to contain_exactly(event)
        ensure
          task.stop
        end
      end

      it 'survives a malformed message and continues processing' do
        suppress_console_errors do
          Async do |task|
            broadcast.statuses_pull!(task: task)

            push = OMQ::PUSH.connect('inproc://statuses.pull')
            push << "not valid marshal\x00\xff".b
            push << Marshal.dump(event)

            deadline = Time.now + 1.0
            sleep 0.01 until applied.any? || Time.now > deadline

            expect(applied).to contain_exactly(event)
          ensure
            task.stop
          end
        end
      end

      it 'continues when the applicator raises' do
        raising = Object.new
        call_count = 0
        raising.define_singleton_method(:apply) do |_event|
          call_count += 1
          raise StandardError, 'apply boom' if call_count == 1
        end
        broadcast = described_class.new(store: store, broadcaster: broadcaster, applicator: raising)

        suppress_console_errors do
          Async do |task|
            broadcast.statuses_pull!(task: task)

            push = OMQ::PUSH.connect('inproc://statuses.pull')
            push << Marshal.dump(event)
            push << Marshal.dump(event)

            deadline = Time.now + 1.0
            sleep 0.01 until call_count >= 2 || Time.now > deadline
          ensure
            task.stop
          end
        end

        expect(call_count).to be >= 2
      end

      it 'emits fiber.crashed when the bind fails' do
        OMQ::PULL.bind('inproc://statuses.pull')

        suppress_console_errors do
          Async do |task|
            broadcast.statuses_pull!(task: task)
            sleep 0.05
          ensure
            task.stop
          end
        end

        crashed = emitted_events.find { |e| e[:name] == 'fiber.crashed' && e[:task] == 'statuses_worker' }
        expect(crashed).not_to be_nil
        expect(crashed[:error]).to be_a(String)
        expect(crashed[:error]).not_to be_empty
      end
    end

    # Backpressure / fairness check: the broadcasts.pull and
    # statuses.pull sockets live in separate Async tasks (each pull!
    # spawns its own +task.async+ fiber), so a load burst on one must
    # not block the other. Pushes are interleaved; both queues must
    # drain to completion within the test window.
    describe 'concurrent pulls' do
      let(:applied) { [] }
      let(:applicator) do
        Class.new do
          def initialize(applied) = (@applied = applied)
          def apply(event) = @applied << event
        end.new(applied)
      end
      let(:processed_ids) { [] }
      let(:broadcast) do
        described_class.new(store: store, broadcaster: broadcaster, applicator: applicator)
      end
      let(:event) do
        {
          wtxid: SecureRandom.random_bytes(32),
          tx_status: 'SEEN_ON_NETWORK',
          status: 200,
          block_hash: nil, block_height: nil, merkle_path: nil,
          extra_info: nil, competing_txs: nil
        }
      end

      before do
        # Track which broadcasts.pull IDs reached process. Use the
        # action_not_found fast path -- find_action returns nil so
        # process emits task.skipped and exits without touching
        # broadcaster, keeping the test focused on socket fairness.
        ids = processed_ids
        allow(store).to receive(:find_action) do |id:|
          ids << id
          nil
        end
        allow(store).to receive(:broadcast_status).and_return(nil)
      end

      it 'drains broadcasts.pull and statuses.pull concurrently without starvation' do
        message_count = 25

        Async do |task|
          broadcast.pull!(task: task)
          broadcast.statuses_pull!(task: task)

          broadcasts_push = OMQ::PUSH.connect('inproc://broadcasts.pull')
          statuses_push   = OMQ::PUSH.connect('inproc://statuses.pull')

          message_count.times do |i|
            broadcasts_push << (i + 1).to_s
            statuses_push   << Marshal.dump(event)
          end

          deadline = Time.now + 5.0
          loop do
            break if applied.size >= message_count && processed_ids.size >= message_count
            break if Time.now > deadline

            sleep 0.02
          end

          expect(applied.size).to eq(message_count)
          expect(processed_ids.size).to eq(message_count)
        ensure
          task.stop
        end
      end
    end

    describe '#hints_pull! (#269)' do
      let(:hints_socket) { 'inproc://hints-test' }
      # Synthesize a hint payload carrying an opaque BEEF blob. BEEF
      # encoding correctness is the SDK's concern; the receiver's job is
      # to decode -> extract subject_tx -> put. Stub Beef.from_binary so
      # the spec stays focused on the wrapping behaviour.
      let(:subject_tx) { BSV::Transaction::Transaction.from_binary(raw_tx) }
      let(:fake_beef) do
        double('Beef', subject_wtxid: subject_tx.wtxid).tap do |b|
          allow(b).to receive(:find_atomic_transaction).with(subject_tx.wtxid).and_return(subject_tx)
        end
      end
      let(:hint_payload) { { action_id: 7, beef: 'FAKE_BEEF_BYTES' } }

      before do
        allow(BSV::Transaction::Beef).to receive(:from_binary).with('FAKE_BEEF_BYTES').and_return(fake_beef)
      end

      it 'is a no-op when socket_path: nil (no fiber bound, cache stays empty)' do
        Async do |task|
          broadcast.hints_pull!(task: task, socket_path: nil)
          sleep 0.05
          expect(broadcast.hydrated_tx_cache).to be_empty
        ensure
          task.stop
        end
      end

      it 'pulls a hint, parses BEEF, extracts subject_tx, primes the cache' do
        Async do |task|
          broadcast.hints_pull!(task: task, socket_path: hints_socket)

          push = OMQ::PUSH.connect(hints_socket)
          push << Marshal.dump(hint_payload)

          deadline = Time.now + 1.0
          sleep 0.01 until broadcast.hydrated_tx_cache.get(7) || Time.now > deadline

          cached = broadcast.hydrated_tx_cache.get(7)
          expect(cached).to equal(subject_tx)
        ensure
          task.stop
        end
      end

      it 'survives a malformed message and keeps the fiber alive' do
        suppress_console_errors do
          Async do |task|
            broadcast.hints_pull!(task: task, socket_path: hints_socket)

            push = OMQ::PUSH.connect(hints_socket)
            push << "not valid marshal\x00\xff".b
            push << Marshal.dump(hint_payload)

            deadline = Time.now + 1.0
            sleep 0.01 until broadcast.hydrated_tx_cache.get(7) || Time.now > deadline

            expect(broadcast.hydrated_tx_cache.get(7)).to equal(subject_tx)
          ensure
            task.stop
          end
        end
      end
    end
  end

  describe '#initialize' do
    it 'does not eagerly construct the default applicator (avoids autoloading Sequel-coupled Store::Models)' do
      # Stubbed double('Store') would crash the Sequel-coupled autoload
      # chain inside Store::EventApplicator's load if construction were
      # eager. The applicator is built lazily on first call to
      # +applicator+.
      expect { described_class.new(store: store, broadcaster: broadcaster) }
        .not_to raise_error
    end

    it 'accepts an applicator: kwarg' do
      custom = double('Applicator')
      instance = described_class.new(store: store, broadcaster: broadcaster, applicator: custom)
      expect(instance.applicator).to be(custom)
    end
  end

  include ConsoleHelpers
end
