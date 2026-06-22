# frozen_string_literal: true

require 'bsv-wallet'
require 'bsv/wallet/engine/transmission'

# Isolation specs for the Engine::Transmission domain (HLR #385 Task 2 / #387).
# Mock-pattern, mirroring tx_proof_spec.rb: Transmission's contract footprint
# is small (validate → hydrator → store record) so the spec drives mocks
# rather than a real Store, keeping the focus on the engine-boundary contract.
RSpec.describe BSV::Wallet::Engine::Transmission do
  subject(:transmission) { described_class.new(store: store, hydrator: hydrator) }

  let(:store) { double('Store') }
  let(:hydrator) { double('Hydrator') }
  # Compressed-prefix identity key hex (66 chars, BRC-43 shape).
  let(:counterparty) { "02#{'a' * 64}" }
  let(:other_counterparty) { "03#{'b' * 64}" }
  let(:sender_identity_key) { "02#{'c' * 64}" }
  let(:action_id) { 42 }
  let(:raw_tx) { "\x01\x00".b }
  let(:atomic_beef) { "\xef\xbe\xef\xfe".b }
  let(:transmission_id) { 99 }
  let(:action_hash) do
    { id: action_id, wtxid: SecureRandom.random_bytes(32), raw_tx: raw_tx, tx_proof_id: nil }
  end
  # BRC-29 envelope shape — what the peer needs to recover locking keys.
  let(:outputs) do
    [{ vout: 0, satoshis: 1_000, derivation_prefix: 'p', derivation_suffix: '1' }]
  end

  describe 'constructor (sibling-shape parity)' do
    it 'mirrors Broadcast/TxProof: explicit DI, no engine back-ref' do
      expect { described_class.new(store: store, hydrator: hydrator) }.not_to raise_error
    end

    it 'accepts a +delivery:+ kwarg (Phase-2 PeerDelivery seam — #390)' do
      delivery = double('PeerDelivery')
      instance = described_class.new(store: store, hydrator: hydrator, delivery: delivery)
      expect(instance.delivery).to be(delivery)
    end

    it 'defaults +delivery:+ to nil (unit-spec / pre-#390 contexts)' do
      expect(transmission.delivery).to be_nil
    end

    it 'is a background-worker sibling — no Interface::Transmission module exists' do
      # Mirrors Broadcast and TxProof shape: only shape-extracted services
      # consumed cross-sibling (Hydrator, BeefImporter) carry Interface
      # modules. AC refinement (HLR #385 specialist synthesis).
      expect(defined?(BSV::Wallet::Interface::Transmission)).to be_nil
    end
  end

  describe '#transmit (happy path)' do
    before do
      allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
      allow(hydrator).to receive(:build_atomic_beef).with(raw_tx, action_id).and_return(atomic_beef)
      allow(store).to receive(:record_transmission).with(
        action_id: action_id, counterparty: counterparty
      ).and_return(transmission_id)
    end

    it 'calls hydrator.build_atomic_beef with the action raw_tx + id' do
      transmission.transmit(counterparty: counterparty, action_id: action_id,
                            outputs: outputs, sender_identity_key: sender_identity_key)
      expect(hydrator).to have_received(:build_atomic_beef).with(raw_tx, action_id)
    end

    it 'records the transmission row at grain (action × counterparty)' do
      transmission.transmit(counterparty: counterparty, action_id: action_id,
                            outputs: outputs, sender_identity_key: sender_identity_key)
      expect(store).to have_received(:record_transmission).with(
        action_id: action_id, counterparty: counterparty
      )
    end

    it 'returns +{ transmission_id:, beef:, outputs:, sender_identity_key: }+' do
      result = transmission.transmit(counterparty: counterparty, action_id: action_id,
                                     outputs: outputs, sender_identity_key: sender_identity_key)
      expect(result).to eq(
        transmission_id: transmission_id,
        beef: atomic_beef,
        outputs: outputs,
        sender_identity_key: sender_identity_key
      )
    end
  end

  describe '#transmit (validation BEFORE any side effect)' do
    # AC: engine-boundary validation rejects bad counterparties BEFORE any
    # DB write or BEEF construction (HLR #385 crypto/security gate).

    before do
      # Tell mocks they should not be touched on a validation failure.
      allow(store).to receive(:find_action)
      allow(store).to receive(:record_transmission)
      allow(hydrator).to receive(:build_atomic_beef)
    end

    shared_examples 'rejects pre-side-effect' do
      it 'raises InvalidParameterError' do
        expect do
          transmission.transmit(counterparty: bad, action_id: action_id,
                                outputs: outputs, sender_identity_key: sender_identity_key)
        end.to raise_error(BSV::Wallet::InvalidParameterError)
      end

      it 'does not call store or hydrator' do
        expect do
          transmission.transmit(counterparty: bad, action_id: action_id,
                                outputs: outputs, sender_identity_key: sender_identity_key)
        end.to raise_error(BSV::Wallet::InvalidParameterError)
        expect(store).not_to have_received(:find_action)
        expect(store).not_to have_received(:record_transmission)
        expect(hydrator).not_to have_received(:build_atomic_beef)
      end
    end

    context 'with the "self" derivation sentinel' do
      let(:bad) { 'self' }

      it_behaves_like 'rejects pre-side-effect'
    end

    context 'with the "anyone" derivation sentinel' do
      let(:bad) { 'anyone' }

      it_behaves_like 'rejects pre-side-effect'
    end

    context 'with wrong-length hex' do
      let(:bad) { "02#{'a' * 60}" }

      it_behaves_like 'rejects pre-side-effect'
    end

    context 'with non-hex characters' do
      let(:bad) { "02#{'z' * 64}" }

      it_behaves_like 'rejects pre-side-effect'
    end

    context 'with wrong key prefix (not 02|03|04)' do
      let(:bad) { "01#{'a' * 64}" }

      it_behaves_like 'rejects pre-side-effect'
    end

    context 'with a non-string counterparty' do
      let(:bad) { 12_345 }

      it_behaves_like 'rejects pre-side-effect'
    end
  end

  describe '#transmit (action-state errors)' do
    it 'raises when the action is not found' do
      allow(store).to receive(:find_action).with(id: action_id).and_return(nil)

      expect do
        transmission.transmit(counterparty: counterparty, action_id: action_id,
                              outputs: outputs, sender_identity_key: sender_identity_key)
      end.to raise_error(BSV::Wallet::Error, /action not found/)
    end

    it 'raises when the action has no raw_tx (unsigned)' do
      allow(store).to receive(:find_action).with(id: action_id)
                                           .and_return(action_hash.merge(raw_tx: nil))

      expect do
        transmission.transmit(counterparty: counterparty, action_id: action_id,
                              outputs: outputs, sender_identity_key: sender_identity_key)
      end.to raise_error(BSV::Wallet::Error, /action not signed/)
    end
  end

  describe '#transmit (unproven subject — BEEF/SPV core case)' do
    # AC refinement: an action whose +tx_proof_id+ is nil but +raw_tx+ is
    # present (pure no_send → immediate transmit) must succeed. BEEF/SPV's
    # whole point is that the subject does not need to be mined for the
    # peer to verify; only ancestors do. (BSV domain.)
    let(:unproven_action) { action_hash.merge(tx_proof_id: nil) }

    before do
      allow(store).to receive(:find_action).with(id: action_id).and_return(unproven_action)
      allow(hydrator).to receive(:build_atomic_beef).with(raw_tx, action_id).and_return(atomic_beef)
      allow(store).to receive(:record_transmission).and_return(transmission_id)
    end

    it 'succeeds and returns the wire payload' do
      result = transmission.transmit(counterparty: counterparty, action_id: action_id,
                                     outputs: outputs, sender_identity_key: sender_identity_key)
      expect(result[:transmission_id]).to eq(transmission_id)
      expect(result[:beef]).to eq(atomic_beef)
    end
  end

  describe '#transmit (per-counterparty isolation)' do
    # AC: parallel transmits to two peers produce two distinct
    # +record_transmission+ calls. Mock-level proof of the
    # per-counterparty grain — the database-level UNIQUE
    # (action_id, counterparty) idempotency is covered by Task 1's
    # transmissions_spec.
    before do
      allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
      allow(hydrator).to receive(:build_atomic_beef).and_return(atomic_beef)
      allow(store).to receive(:record_transmission).and_return(transmission_id, transmission_id + 1)
    end

    it 'records a distinct row per counterparty' do
      transmission.transmit(counterparty: counterparty, action_id: action_id,
                            outputs: outputs, sender_identity_key: sender_identity_key)
      transmission.transmit(counterparty: other_counterparty, action_id: action_id,
                            outputs: outputs, sender_identity_key: sender_identity_key)

      expect(store).to have_received(:record_transmission).with(
        action_id: action_id, counterparty: counterparty
      )
      expect(store).to have_received(:record_transmission).with(
        action_id: action_id, counterparty: other_counterparty
      )
    end
  end
end
