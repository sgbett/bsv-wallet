# frozen_string_literal: true

require 'bsv/wallet/engine/tx_proof'

RSpec.describe BSV::Wallet::Engine::TxProof do
  subject(:tx_proof) { described_class.new(store: store, services: services) }

  let(:store) { double('Store') }
  let(:services) { double('Services') }

  let(:action_id) { 42 }
  let(:wtxid) { SecureRandom.random_bytes(32) }
  let(:dtxid) { wtxid.reverse.unpack1('H*') }
  let(:raw_tx) { "\x01\x00".b }
  let(:merkle_path_binary) { "\x01\x02\x03".b }
  let(:block_height) { 850_000 }
  let(:block_hash) { SecureRandom.random_bytes(32).unpack1('H*') }

  let(:action_hash) do
    { id: action_id, wtxid: wtxid, raw_tx: raw_tx }
  end

  describe '#process' do
    context 'when action is mined' do
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
        allow(services).to receive(:call).with(:get_tx_status, txid: dtxid).and_return(response)
        allow(store).to receive(:save_proof).and_return(99)
        allow(store).to receive(:link_proof)
      end

      it 'calls get_tx_status with display-order txid' do
        tx_proof.process(action_id)
        expect(services).to have_received(:call).with(:get_tx_status, txid: dtxid)
      end

      it 'saves the proof' do
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
    end

    context 'when action is not yet mined' do
      let(:response) do
        double('Response', http_success?: true, data: { merkle_path: nil, block_height: nil })
      end

      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
        allow(store).to receive(:save_proof)
        allow(services).to receive(:call).with(:get_tx_status, txid: dtxid).and_return(response)
      end

      it 'does not save a proof' do
        tx_proof.process(action_id)
        expect(store).not_to have_received(:save_proof)
      end
    end

    context 'when service call fails' do
      let(:response) do
        double('Response', http_success?: false)
      end

      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
        allow(store).to receive(:save_proof)
        allow(services).to receive(:call).with(:get_tx_status, txid: dtxid).and_return(response)
      end

      it 'does not save a proof' do
        tx_proof.process(action_id)
        expect(store).not_to have_received(:save_proof)
      end
    end

    context 'when action not found' do
      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return(nil)
        allow(services).to receive(:call)
      end

      it 'returns nil without calling services' do
        result = tx_proof.process(action_id)
        expect(result).to be_nil
        expect(services).not_to have_received(:call)
      end
    end

    context 'when action has no wtxid' do
      before do
        allow(store).to receive(:find_action).with(id: action_id).and_return({ id: action_id, wtxid: nil })
        allow(services).to receive(:call)
      end

      it 'returns nil without calling services' do
        result = tx_proof.process(action_id)
        expect(result).to be_nil
        expect(services).not_to have_received(:call)
      end
    end

    context 'when merkle_path is a hex string' do
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
        allow(services).to receive(:call).with(:get_tx_status, txid: dtxid).and_return(response)
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
end
