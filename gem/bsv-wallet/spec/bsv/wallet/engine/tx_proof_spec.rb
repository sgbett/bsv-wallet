# frozen_string_literal: true

require 'bsv/wallet/engine/tx_proof'
require 'logger'
require_relative '../../../support/console_helpers'

RSpec.describe BSV::Wallet::Engine::TxProof do
  subject(:tx_proof) { described_class.new(store: store, broadcaster: broadcaster) }

  let(:store) { double('Store') }
  let(:broadcaster) { double('Broadcaster') }

  let(:action_id) { 42 }
  let(:wtxid) { SecureRandom.random_bytes(32) }
  let(:dtxid) { wtxid.reverse.unpack1('H*') }
  let(:raw_tx) { "\x01\x00".b }
  let(:merkle_path_binary) { "\x01\x02\x03".b }
  let(:block_height) { 850_000 }
  let(:block_hash) { SecureRandom.random_bytes(32).unpack1('H*') }

  let(:action_hash) do
    { id: action_id, wtxid: wtxid, raw_tx: raw_tx, tx_proof_id: nil }
  end

  # Capture all emit calls for assertion.
  let(:emitted_events) { [] }

  before do
    allow(BSV::Wallet).to receive(:emit) { |name, **payload| emitted_events << { name: name, **payload } }
  end

  describe '#process' do
    context 'when proof acquired (mined)' do
      # Success responses from Services are normalized to symbol + snake_case.
      let(:response) do
        double('Response', http_success?: true,
                           data: {
                             merkle_path: merkle_path_binary,
                             block_height: block_height,
                             block_hash: block_hash
                           })
      end

      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
        allow(broadcaster).to receive(:get_tx_status).with(wtxid: wtxid, dtxid: dtxid).and_return(response)
        allow(store).to receive(:save_proof).and_return(99)
        allow(store).to receive(:link_proof)
      end

      it 'calls broadcaster.get_tx_status with wtxid + display-order dtxid' do
        tx_proof.process(action_id)
        expect(broadcaster).to have_received(:get_tx_status).with(wtxid: wtxid, dtxid: dtxid)
      end

      it 'saves the proof with normalized response data' do
        tx_proof.process(action_id)
        expect(store).to have_received(:save_proof).with(
          wtxid: wtxid,
          proof: {
            height: block_height,
            block_hash: block_hash,
            merkle_path: merkle_path_binary,
            raw_tx: raw_tx
          }
        )
      end

      it 'links the proof to the action' do
        tx_proof.process(action_id)
        expect(store).to have_received(:link_proof).with(action_id: action_id, tx_proof_id: 99)
      end

      it 'notifies the injected hydrator of the new proof (#296 Phase D)' do
        hydrator = instance_double(BSV::Wallet::Engine::Hydrator, proof_arrived: nil)
        described_class.new(store: store, broadcaster: broadcaster, hydrator: hydrator).process(action_id)
        expect(hydrator).to have_received(:proof_arrived).with(
          wtxid: wtxid, raw_tx: raw_tx, merkle_path: merkle_path_binary
        )
      end

      it 'emits task.dispatched then task.succeeded with outcome=acquired and integer latency_ms' do
        tx_proof.process(action_id)

        expect(emitted_events.size).to eq(2)
        expect(emitted_events[0]).to include(name: 'task.dispatched', task: 'proof_acquisition', id: action_id)
        succeeded = emitted_events[1]
        expect(succeeded).to include(name: 'task.succeeded', task: 'proof_acquisition', id: action_id,
                                     outcome: :acquired)
        expect(succeeded[:latency_ms]).to be_an(Integer)
      end
    end

    context 'when not yet mined (nil merklePath)' do
      let(:response) do
        double('Response', http_success?: true,
                           data: { merkle_path: nil, block_height: nil })
      end

      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
        allow(store).to receive(:save_proof)
        allow(broadcaster).to receive(:get_tx_status).with(wtxid: wtxid, dtxid: dtxid).and_return(response)
      end

      it 'does not save a proof' do
        tx_proof.process(action_id)
        expect(store).not_to have_received(:save_proof)
      end

      it 'emits task.succeeded with outcome=not_yet_mined and integer latency_ms' do
        tx_proof.process(action_id)

        expect(emitted_events.size).to eq(2)
        expect(emitted_events[0]).to include(name: 'task.dispatched')
        succeeded = emitted_events[1]
        expect(succeeded).to include(name: 'task.succeeded', task: 'proof_acquisition', id: action_id,
                                     outcome: :not_yet_mined)
        expect(succeeded[:latency_ms]).to be_an(Integer)
      end
    end

    context 'when transport error (service call fails)' do
      let(:response) do
        double('Response', http_success?: false)
      end

      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
        allow(store).to receive(:save_proof)
        allow(broadcaster).to receive(:get_tx_status).with(wtxid: wtxid, dtxid: dtxid).and_return(response)
      end

      it 'does not save a proof' do
        tx_proof.process(action_id)
        expect(store).not_to have_received(:save_proof)
      end

      it 'emits task.failed with reason=transport_error and integer latency_ms' do
        tx_proof.process(action_id)

        expect(emitted_events.size).to eq(2)
        expect(emitted_events[0]).to include(name: 'task.dispatched')
        failed = emitted_events[1]
        expect(failed).to include(name: 'task.failed', task: 'proof_acquisition', id: action_id,
                                  reason: :transport_error)
        expect(failed[:latency_ms]).to be_an(Integer)
      end
    end

    context 'when action not found' do
      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(nil)
        allow(broadcaster).to receive(:get_tx_status)
      end

      it 'returns nil without calling the broadcaster' do
        result = tx_proof.process(action_id)
        expect(result).to be_nil
        expect(broadcaster).not_to have_received(:get_tx_status)
      end

      it 'emits task.dispatched then task.skipped with reason=action_not_found' do
        tx_proof.process(action_id)

        expect(emitted_events.size).to eq(2)
        expect(emitted_events[0]).to include(name: 'task.dispatched', task: 'proof_acquisition', id: action_id)
        expect(emitted_events[1]).to include(name: 'task.skipped', reason: :action_not_found, id: action_id)
      end
    end

    context 'when action has no wtxid' do
      before do
        allow(store).to receive(:find_action).with(id: action_id)
                                             .and_return({ id: action_id, wtxid: nil })
        allow(broadcaster).to receive(:get_tx_status)
      end

      it 'returns nil without calling the broadcaster' do
        result = tx_proof.process(action_id)
        expect(result).to be_nil
        expect(broadcaster).not_to have_received(:get_tx_status)
      end

      it 'emits task.dispatched then task.skipped with reason=no_wtxid' do
        tx_proof.process(action_id)

        expect(emitted_events.size).to eq(2)
        expect(emitted_events[0]).to include(name: 'task.dispatched', task: 'proof_acquisition', id: action_id)
        expect(emitted_events[1]).to include(name: 'task.skipped', reason: :no_wtxid, id: action_id)
      end
    end

    context 'when action already has tx_proof_id (race window between discovery and dispatch)' do
      before do
        allow(store).to receive(:find_action).with(id: action_id)
                                             .and_return(action_hash.merge(tx_proof_id: 99))
        allow(broadcaster).to receive(:get_tx_status)
      end

      it 'returns nil without calling the broadcaster' do
        result = tx_proof.process(action_id)
        expect(result).to be_nil
        expect(broadcaster).not_to have_received(:get_tx_status)
      end

      it 'emits task.dispatched then task.skipped with reason=already_proven' do
        tx_proof.process(action_id)

        expect(emitted_events.size).to eq(2)
        expect(emitted_events[0]).to include(name: 'task.dispatched', task: 'proof_acquisition', id: action_id)
        expect(emitted_events[1]).to include(name: 'task.skipped', reason: :already_proven, id: action_id)
      end
    end

    context 'when merklePath is a hex string' do
      let(:binary_data) { "\xab\xcd\xef".b }
      let(:hex_string) { 'abcdef' }
      let(:response) do
        double('Response', http_success?: true,
                           data: {
                             merkle_path: hex_string,
                             block_height: block_height,
                             block_hash: block_hash
                           })
      end

      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
        allow(broadcaster).to receive(:get_tx_status).with(wtxid: wtxid, dtxid: dtxid).and_return(response)
        allow(store).to receive(:save_proof).and_return(99)
        allow(store).to receive(:link_proof)
      end

      it 'decodes hex to binary' do
        tx_proof.process(action_id)
        expect(store).to have_received(:save_proof).with(
          wtxid: wtxid,
          proof: hash_including(merkle_path: binary_data)
        )
      end
    end
  end

  describe '#pull!' do
    it 'emits fiber.crashed when process raises' do
      allow(store).to receive(:find_action).and_raise(RuntimeError, "test error\nwith newline")

      Async do |task|
        tx_proof.pull!(task: task)

        push = OMQ::PUSH.connect('inproc://proofs.pull')
        push << action_id.to_s

        # Yield to let the pull fiber process the message.
        sleep 0.05

        crashed = emitted_events.find { |e| e[:name] == 'fiber.crashed' }
        expect(crashed).to include(task: 'proof_acquisition', error: 'test error')
      ensure
        task.stop
      end
    end

    it 'emits fiber.crashed when the bind fails' do
      # Pre-bind the endpoint so the engine's bind raises.
      OMQ::PULL.bind('inproc://proofs.pull')

      suppress_console_errors do
        Async do |task|
          tx_proof.pull!(task: task)
          sleep 0.05
        ensure
          task.stop
        end
      end

      crashed = emitted_events.find { |e| e[:name] == 'fiber.crashed' }
      expect(crashed).not_to be_nil
      expect(crashed[:task]).to eq('proof_acquisition')
      expect(crashed[:error]).to be_a(String)
      expect(crashed[:error]).not_to be_empty
    end
  end

  describe '.pending' do
    it 'delegates to store.pending_proofs and maps to IDs' do
      allow(store).to receive(:pending_proofs).with(limit: 5).and_return(
        [{ id: 1, wtxid: 'a' }, { id: 2, wtxid: 'b' }]
      )
      result = described_class.pending(store, limit: 5)
      expect(result).to eq([1, 2])
    end

    it 'returns empty array when no pending proofs' do
      allow(store).to receive(:pending_proofs).with(limit: 10).and_return([])
      result = described_class.pending(store)
      expect(result).to eq([])
    end
  end

  include ConsoleHelpers
end
