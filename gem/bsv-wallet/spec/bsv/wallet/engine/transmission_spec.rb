# frozen_string_literal: true

require 'bsv-wallet'
require 'bsv/wallet/engine/transmission'
require_relative '../store/shared_context'

# Isolation specs for the Engine::Transmission domain (HLR #385). The
# sender's Store is a double, keeping the focus on the engine-boundary
# contract. The Hydrator is real, with only +build_atomic_beef+ stubbed,
# so the egress check runs on every transmit: a blanket stub of
# +validate_for_handoff!+ is how #551 went unnoticed. Only the blocks that
# test the check's call order or failure propagation stub it.
RSpec.describe BSV::Wallet::Engine::Transmission do
  subject(:transmission) { described_class.new(store: store, hydrator: hydrator) }

  let(:store) { double('Store') }
  let(:hydrator) { BSV::Wallet::Engine::Hydrator.new(store: store) }
  # Compressed-prefix identity key hex (66 chars, BRC-43 shape).
  let(:counterparty) { "02#{'a' * 64}" }
  let(:other_counterparty) { "03#{'b' * 64}" }
  let(:sender_identity_key) { "02#{'c' * 64}" }
  let(:action_id) { 42 }
  let(:transmission_id) { 99 }
  # BRC-29 envelope shape — what the peer needs to recover locking keys.
  let(:outputs) do
    [{ vout: 0, satoshis: 1_000, derivation_prefix: 'p', derivation_suffix: '1' }]
  end
  # Hash of (subject_tx, ancestor, beef_binary, raw_tx) — the bits the
  # mocked +store.find_action+ + +hydrator.build_atomic_beef+ need.
  let(:built) { build_test_beef }
  let(:raw_tx) { built[:subject_tx].to_binary }
  let(:subject_wtxid) { built[:subject_tx].wtxid }
  let(:ancestor_wtxid) { built[:ancestor].wtxid }
  let(:atomic_beef_binary) { built[:beef_binary] }
  let(:action_hash) do
    { id: action_id, wtxid: subject_wtxid, raw_tx: raw_tx, tx_proof_id: nil }
  end

  # --- Helpers ---------------------------------------------------------

  # Build a tiny verifiable BEEF (proven ancestor + subject spending it).
  # Mirrors +beef_internalizer_spec.rb#build_verifiable_beef+ — kept local to
  # avoid coupling specs.
  def build_test_beef(satoshis: 500, ancestor_satoshis: 600)
    op_true = "\x51".b

    ancestor = BSV::Transaction::Tx.new(version: 1, lock_time: 0)
    ancestor.add_output(BSV::Transaction::TransactionOutput.new(
                          satoshis: ancestor_satoshis,
                          locking_script: BSV::Script::Script.from_binary(op_true)
                        ))
    ancestor.merkle_path = build_test_merkle_path(ancestor)

    subject_tx = BSV::Transaction::Tx.new(version: 1, lock_time: 0)
    subject_tx.add_input(BSV::Transaction::TransactionInput.new(
                           prev_wtxid: ancestor.wtxid,
                           prev_tx_out_index: 0,
                           sequence: 0xFFFFFFFF,
                           unlocking_script: BSV::Script::Script.from_binary(op_true)
                         ))
    subject_tx.inputs[0].source_transaction = ancestor
    subject_tx.add_output(BSV::Transaction::TransactionOutput.new(
                            satoshis: satoshis,
                            locking_script: BSV::Script::Script.from_binary(op_true)
                          ))

    beef = BSV::Transaction::Beef.new
    beef.merge_transaction(ancestor)
    beef.merge_transaction(subject_tx)
    {
      beef_binary: beef.to_atomic_binary(subject_tx.wtxid),
      subject_tx: subject_tx,
      ancestor: ancestor
    }
  end

  def build_test_merkle_path(tx)
    sibling_hash = ([0x42] * 32).pack('C*').b
    BSV::Transaction::MerklePath.new(
      block_height: 800_000,
      path: [[
        BSV::Transaction::MerklePath::PathElement.new(offset: 2, hash: tx.wtxid, txid: true),
        BSV::Transaction::MerklePath::PathElement.new(offset: 3, hash: sibling_hash)
      ]]
    )
  end

  # --- Constructor ----------------------------------------------------

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
      # consumed cross-sibling (Hydrator, BeefInternalizer) carry Interface
      # modules. AC refinement (HLR #385 specialist synthesis).
      expect(defined?(BSV::Wallet::Interface::Transmission)).to be_nil
    end
  end

  # --- #transmit happy path ------------------------------------------

  describe '#transmit (happy path)' do
    before do
      allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
      allow(hydrator).to receive(:build_atomic_beef)
        .with(raw_tx, action_id).and_return(atomic_beef_binary)
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

    it 'returns transmission_id + beef + sent_wtxids + outputs + sender_identity_key + delivery' do
      result = transmission.transmit(counterparty: counterparty, action_id: action_id,
                                     outputs: outputs, sender_identity_key: sender_identity_key)
      # +:delivery+ is nil here (no +endpoint:+ supplied and no
      # transport wired in this isolation spec); the key is still
      # present so callers can rely on the result-hash shape.
      expect(result.keys).to contain_exactly(
        :transmission_id, :beef, :sent_wtxids, :outputs, :sender_identity_key, :delivery
      )
      expect(result[:transmission_id]).to eq(transmission_id)
      expect(result[:outputs]).to eq(outputs)
      expect(result[:sender_identity_key]).to eq(sender_identity_key)
      expect(result[:delivery]).to be_nil
    end

    it 'returns a valid Atomic BEEF binary the peer can parse' do
      result = transmission.transmit(counterparty: counterparty, action_id: action_id,
                                     outputs: outputs, sender_identity_key: sender_identity_key)
      parsed = BSV::Transaction::Beef.from_binary(result[:beef])
      expect(parsed.subject_wtxid).to eq(subject_wtxid)
    end

    it 'ships the bundle build_atomic_beef returned, byte for byte' do
      result = transmission.transmit(counterparty: counterparty, action_id: action_id,
                                     outputs: outputs, sender_identity_key: sender_identity_key)
      expect(result[:beef]).to eq(atomic_beef_binary)
    end

    it 'returns every wtxid in the bundle as sent_wtxids' do
      result = transmission.transmit(counterparty: counterparty, action_id: action_id,
                                     outputs: outputs, sender_identity_key: sender_identity_key)
      expect(result[:sent_wtxids]).to contain_exactly(subject_wtxid, ancestor_wtxid)
    end
  end

  # --- #transmit (peer already holds an ancestor — #551) ---------------

  describe '#transmit (peer already holds an ancestor — #551)' do
    # Our records say the peer acknowledged the ancestor in an earlier
    # transmission (the known-set stub), so a trim that read them would
    # fail this block. It still travels in full: a txid-only entry resolves
    # only at a receiver that has agreed to trust its own store for it,
    # and none does by default (#552).
    before do
      allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
      allow(store).to receive(:transmission_known_wtxids)
        .with(counterparty: counterparty).and_return([ancestor_wtxid])
      allow(hydrator).to receive(:build_atomic_beef)
        .with(raw_tx, action_id).and_return(atomic_beef_binary)
      allow(store).to receive(:record_transmission).and_return(transmission_id)
    end

    it 'ships the ancestor in full and passes the strict egress check' do
      result = transmission.transmit(counterparty: counterparty, action_id: action_id,
                                     outputs: outputs, sender_identity_key: sender_identity_key)

      shipped = BSV::Transaction::Beef.from_binary(result[:beef])
      expect(shipped.transactions.grep(BSV::Transaction::Beef::TxidOnlyEntry)).to be_empty
      expect(shipped.find_transaction(ancestor_wtxid)).not_to be_nil
      expect(result[:sent_wtxids]).to contain_exactly(subject_wtxid, ancestor_wtxid)
    end

    context 'when the peer internalises it without opting into trust_self' do
      let(:receiver_store) { STORE_INSTANCE }
      let(:receiver) do
        BSV::Wallet::Engine::BeefInternalizer.new(
          store: receiver_store,
          chain_tracker: double('ChainTracker', valid_root_for_height?: true),
          hydrator: BSV::Wallet::Engine::Hydrator.new(store: receiver_store)
        )
      end

      around do |example|
        STORE_DB.transaction(rollback: :always, auto_savepoint: true) { example.run }
      end

      before do
        ancestor = built[:ancestor]
        receiver_store.save_proof(
          wtxid: ancestor_wtxid,
          proof: { raw_tx: ancestor.to_binary, height: ancestor.merkle_path.block_height,
                   merkle_path: ancestor.merkle_path.to_binary }
        )
      end

      it 'verifies and accepts the bundle' do
        result = transmission.transmit(counterparty: counterparty, action_id: action_id,
                                       outputs: outputs, sender_identity_key: sender_identity_key)

        internalized = receiver.internalize(
          tx: result[:beef],
          description: 'transmitted to a peer that holds the ancestor',
          outputs: [{
            output_index: 0, protocol: :basket_insertion, satoshis: 500,
            insertion_remittance: {
              basket: 'incoming', derivation_prefix: 'p',
              derivation_suffix: '1', sender_identity_key: 'self'
            }
          }]
        )

        expect(internalized).to eq(accepted: true)
      end
    end
  end

  # --- #transmit (re-send after ACK) ----------------------------------

  describe '#transmit (re-send after ACK)' do
    # After a delivered ACK the peer's known-set holds every wtxid the
    # first bundle carried, the subject included. A re-send must still
    # ship the same full bundle.
    before do
      allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
      allow(hydrator).to receive(:build_atomic_beef).and_return(atomic_beef_binary)
      allow(store).to receive(:record_transmission).and_return(transmission_id)
      allow(store).to receive(:transmission_known_wtxids)
        .with(counterparty: counterparty)
        .and_return([], [subject_wtxid, ancestor_wtxid])
    end

    it 'ships the same full bundle the first time and the second' do
      first  = transmission.transmit(counterparty: counterparty, action_id: action_id,
                                     outputs: outputs, sender_identity_key: sender_identity_key)
      second = transmission.transmit(counterparty: counterparty, action_id: action_id,
                                     outputs: outputs, sender_identity_key: sender_identity_key)

      expect(second[:beef]).to eq(first[:beef])
      expect(second[:sent_wtxids]).to contain_exactly(subject_wtxid, ancestor_wtxid)
    end
  end

  # --- #transmit (per-counterparty rows) ------------------------------

  describe '#transmit (per-counterparty rows)' do
    before do
      allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
      allow(hydrator).to receive(:build_atomic_beef).and_return(atomic_beef_binary)
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

  # --- #transmit (two-phase commit boundary — #388 AC) ----------------

  describe '#transmit (two-phase commit: never marks acked itself)' do
    before do
      allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
      allow(hydrator).to receive(:build_atomic_beef).and_return(atomic_beef_binary)
      allow(store).to receive(:record_transmission).and_return(transmission_id)
      allow(store).to receive(:mark_transmission_acked)
    end

    it 'does NOT call mark_transmission_acked (Task 5 / #390 owns ACK)' do
      transmission.transmit(counterparty: counterparty, action_id: action_id,
                            outputs: outputs, sender_identity_key: sender_identity_key)
      expect(store).not_to have_received(:mark_transmission_acked)
    end

    it 'returns sent_wtxids: the wtxids the eventual ACK handler will record' do
      result = transmission.transmit(counterparty: counterparty, action_id: action_id,
                                     outputs: outputs, sender_identity_key: sender_identity_key)
      # On ACK, #390 will pass these to mark_transmission_acked.
      expect(result[:sent_wtxids]).to all(be_a(String).and(have_attributes(bytesize: 32)))
      expect(result[:sent_wtxids]).to include(subject_wtxid)
    end
  end

  # --- #transmit validation BEFORE any side effect --------------------

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

      it 'does not call store (find/record) or hydrator' do
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

    context 'with wrong key prefix (not 02|03)' do
      let(:bad) { "01#{'a' * 64}" }

      it_behaves_like 'rejects pre-side-effect'
    end

    # Uncompressed (04) is BRC-43-legal for +KeyDeriver+, but the
    # Postgres CHECK in 001_create_schema.rb is compressed-only — same as the
    # engine-boundary check after H1.
    context 'with uncompressed (04) pubkey prefix — rejected at the transmission boundary' do
      let(:bad) { "04#{'a' * 64}" }

      it_behaves_like 'rejects pre-side-effect'
    end

    # H1 (Copilot security gate): uppercase hex passed
    # +KeyDeriver.validate_counterparty_hex!+ (which accepts
    # +[0-9a-fA-F]+), the engine wrote the row, and Postgres rejected
    # it with +Sequel::CheckConstraintViolation+ — a correctness drift
    # SQLite (length+prefix only) silently allowed. The engine
    # boundary now mirrors the Postgres CHECK exactly so the same
    # rejection shape applies on both backends.
    context 'with uppercase hex counterparty — H1 schema parity' do
      let(:bad) { "02#{'A' * 64}" }

      it_behaves_like 'rejects pre-side-effect'
    end

    context 'with mixed-case hex counterparty — H1 schema parity' do
      let(:bad) { "02#{'aBcD' * 16}" }

      it_behaves_like 'rejects pre-side-effect'
    end

    context 'with a non-string counterparty' do
      let(:bad) { 12_345 }

      it_behaves_like 'rejects pre-side-effect'
    end
  end

  # --- #transmit (action-state errors) --------------------------------

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

  # --- #transmit (egress validate_for_handoff! — #389 AC) -------------

  describe '#transmit (strict validate_for_handoff! — #389)' do
    # AC: before record_transmission, the bytes that ship go through
    # Hydrator#validate_for_handoff! with the default
    # allow_txid_only:false — a full bundle has no txid-only entry to
    # excuse. A failure must raise (no transmission row written).
    before do
      allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
      allow(hydrator).to receive(:build_atomic_beef)
        .with(raw_tx, action_id).and_return(atomic_beef_binary)
      allow(store).to receive(:record_transmission)
        .and_return(transmission_id)
      allow(hydrator).to receive(:validate_for_handoff!).and_call_original
    end

    it 'validates the SAME bytes returned in result[:beef], strictly' do
      result = transmission.transmit(counterparty: counterparty, action_id: action_id,
                                     outputs: outputs, sender_identity_key: sender_identity_key)
      expect(hydrator).to have_received(:validate_for_handoff!).with(result[:beef], subject_wtxid)
    end

    it 'validates BEFORE record_transmission (call order)' do
      # If validation runs before the row is written, a validation
      # failure must not leave a phantom row. Order is enforced by
      # placing the validate call ahead of record_transmission.
      call_order = []
      allow(hydrator).to receive(:validate_for_handoff!) { call_order << :validate }
      allow(store).to receive(:record_transmission) do
        call_order << :record
        transmission_id
      end

      transmission.transmit(counterparty: counterparty, action_id: action_id,
                            outputs: outputs, sender_identity_key: sender_identity_key)

      expect(call_order).to eq(%i[validate record])
    end
  end

  describe '#transmit (validate_for_handoff! failure propagation — #389)' do
    # AC: when validate_for_handoff! raises EgressBeefInvalidError,
    # #transmit must propagate AND must NOT write a transmissions row.
    # BEEF-construction failure means there is nothing to transmit.
    before do
      allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
      allow(hydrator).to receive(:build_atomic_beef)
        .with(raw_tx, action_id).and_return(atomic_beef_binary)
      allow(store).to receive(:record_transmission)
      allow(hydrator).to receive(:validate_for_handoff!)
        .and_raise(BSV::Wallet::EgressBeefInvalidError, 'fixture: structurally invalid')
    end

    it 'propagates EgressBeefInvalidError unchanged' do
      expect do
        transmission.transmit(counterparty: counterparty, action_id: action_id,
                              outputs: outputs, sender_identity_key: sender_identity_key)
      end.to raise_error(BSV::Wallet::EgressBeefInvalidError, /structurally invalid/)
    end

    it 'does NOT call record_transmission when validation fails' do
      expect do
        transmission.transmit(counterparty: counterparty, action_id: action_id,
                              outputs: outputs, sender_identity_key: sender_identity_key)
      end.to raise_error(BSV::Wallet::EgressBeefInvalidError)
      expect(store).not_to have_received(:record_transmission)
    end
  end

  # --- #transmit (delivery integration — Task 5 / #390) ----------------

  describe '#transmit (delivery integration — #390)' do
    # AC: when an +endpoint:+ is supplied and a delivery transport is
    # wired, +#transmit+ POSTs the BEEF via +@delivery+ AFTER
    # +record_transmission+ but BEFORE returning. ACK success drives
    # +mark_transmission_acked+ — the two-phase write boundary is
    # preserved (txid known-set persists only on confirmed delivery).
    subject(:transmission) do
      described_class.new(store: store, hydrator: hydrator, delivery: delivery)
    end

    let(:delivery) { instance_double(BSV::Network::PeerDelivery) }
    let(:endpoint) { 'https://peer.example.com/transmit' }
    let(:delivered) do
      BSV::Network::PeerDelivery::Result.new(
        outcome: :delivered, wtxid: subject_wtxid.reverse.unpack1('H*'), http_status: 200
      )
    end
    let(:failed_result) do
      BSV::Network::PeerDelivery::Result.new(
        outcome: :timeout, error_message: 'read timeout'
      )
    end

    before do
      allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
      allow(hydrator).to receive(:build_atomic_beef)
        .with(raw_tx, action_id).and_return(atomic_beef_binary)
      allow(store).to receive(:record_transmission).with(
        action_id: action_id, counterparty: counterparty
      ).and_return(transmission_id)
      allow(store).to receive(:mark_transmission_acked)
    end

    it 'calls @delivery.deliver with the wire envelope (beef, outputs, sender_identity_key, protocol_version: 1)' do
      allow(delivery).to receive(:deliver).and_return(delivered)

      transmission.transmit(counterparty: counterparty, action_id: action_id,
                            outputs: outputs, sender_identity_key: sender_identity_key,
                            endpoint: endpoint)

      expect(delivery).to have_received(:deliver) do |args|
        expect(args[:endpoint]).to eq(endpoint)
        expect(args[:subject_wtxid]).to eq(subject_wtxid)
        env = args[:envelope]
        expect(env).to be_a(Hash)
        expect(env.keys).to include(:beef, :outputs, :sender_identity_key, :protocol_version)
        expect(env[:outputs]).to eq(outputs)
        expect(env[:sender_identity_key]).to eq(sender_identity_key)
        expect(env[:protocol_version]).to eq(1)
        # +beef+ at this layer is still binary — PeerDelivery hex-encodes for wire.
        expect(env[:beef]).to be_a(String)
      end
    end

    it 'on delivered ACK fires mark_transmission_acked with the sent_wtxids' do
      allow(delivery).to receive(:deliver).and_return(delivered)

      result = transmission.transmit(counterparty: counterparty, action_id: action_id,
                                     outputs: outputs, sender_identity_key: sender_identity_key,
                                     endpoint: endpoint)

      expect(store).to have_received(:mark_transmission_acked).with(
        action_id: action_id, counterparty: counterparty, wtxids: result[:sent_wtxids]
      )
    end

    it 'on failed delivery does NOT fire mark_transmission_acked' do
      allow(delivery).to receive(:deliver).and_return(failed_result)

      transmission.transmit(counterparty: counterparty, action_id: action_id,
                            outputs: outputs, sender_identity_key: sender_identity_key,
                            endpoint: endpoint)

      expect(store).not_to have_received(:mark_transmission_acked)
    end

    it 'on wrong_acked_wtxid does NOT fire mark_transmission_acked (crypto gate)' do
      wrong = BSV::Network::PeerDelivery::Result.new(
        outcome: :wrong_acked_wtxid, http_status: 200, wtxid: 'dead' * 16
      )
      allow(delivery).to receive(:deliver).and_return(wrong)

      transmission.transmit(counterparty: counterparty, action_id: action_id,
                            outputs: outputs, sender_identity_key: sender_identity_key,
                            endpoint: endpoint)

      expect(store).not_to have_received(:mark_transmission_acked)
    end

    it 'returns the delivery Result alongside the transmission row + BEEF' do
      allow(delivery).to receive(:deliver).and_return(delivered)

      result = transmission.transmit(counterparty: counterparty, action_id: action_id,
                                     outputs: outputs, sender_identity_key: sender_identity_key,
                                     endpoint: endpoint)

      expect(result.keys).to include(:transmission_id, :beef, :sent_wtxids,
                                     :outputs, :sender_identity_key, :delivery)
      expect(result[:delivery]).to be(delivered)
    end

    it 'delivers AFTER record_transmission (row written before POST)' do
      call_order = []
      allow(store).to receive(:record_transmission) do
        call_order << :record
        transmission_id
      end
      allow(delivery).to receive(:deliver) do
        call_order << :deliver
        delivered
      end
      allow(store).to receive(:mark_transmission_acked) { call_order << :ack }

      transmission.transmit(counterparty: counterparty, action_id: action_id,
                            outputs: outputs, sender_identity_key: sender_identity_key,
                            endpoint: endpoint)

      expect(call_order).to eq(%i[record deliver ack])
    end

    it 'with endpoint nil (transmit intent none) does not invoke @delivery' do
      # Stub the spy before asserting +not_to have_received+ so the
      # double has the method to inspect even if it goes uncalled.
      allow(delivery).to receive(:deliver)

      transmission.transmit(counterparty: counterparty, action_id: action_id,
                            outputs: outputs, sender_identity_key: sender_identity_key)

      expect(delivery).not_to have_received(:deliver)
      expect(store).not_to have_received(:mark_transmission_acked)
    end
  end

  describe '#transmit (no delivery wired — backward-compat unit path)' do
    # When the engine constructs Transmission with delivery: nil (e.g.
    # historical unit-spec wiring), an endpoint: kwarg is allowed but
    # silently skipped — the row is still written; the caller takes
    # responsibility for moving bytes. Keeps the seam optional for the
    # unit tier without forcing every spec to wire a PeerDelivery.
    subject(:transmission) { described_class.new(store: store, hydrator: hydrator) }

    before do
      allow(store).to receive(:find_action).with(id: action_id).and_return(action_hash)
      allow(hydrator).to receive(:build_atomic_beef).and_return(atomic_beef_binary)
      allow(store).to receive(:record_transmission).and_return(transmission_id)
      allow(store).to receive(:mark_transmission_acked)
    end

    it 'returns delivery: nil and does not fire mark_transmission_acked' do
      result = transmission.transmit(counterparty: counterparty, action_id: action_id,
                                     outputs: outputs, sender_identity_key: sender_identity_key,
                                     endpoint: 'https://peer.example.com/')

      expect(result[:delivery]).to be_nil
      expect(store).not_to have_received(:mark_transmission_acked)
    end
  end

  # --- #transmit (unproven subject — BEEF/SPV core case) --------------

  describe '#transmit (unproven subject — BEEF/SPV core case)' do
    # AC refinement: an action whose +tx_proof_id+ is nil but +raw_tx+ is
    # present (pure no_send → immediate transmit) must succeed. BEEF/SPV's
    # whole point is that the subject does not need to be mined for the
    # peer to verify; only ancestors do. (BSV domain.)
    let(:unproven_action) { action_hash.merge(tx_proof_id: nil) }

    before do
      allow(store).to receive(:find_action).with(id: action_id).and_return(unproven_action)
      allow(hydrator).to receive(:build_atomic_beef).with(raw_tx, action_id).and_return(atomic_beef_binary)
      allow(store).to receive(:record_transmission).and_return(transmission_id)
    end

    it 'succeeds and returns the wire payload' do
      result = transmission.transmit(counterparty: counterparty, action_id: action_id,
                                     outputs: outputs, sender_identity_key: sender_identity_key)
      expect(result[:transmission_id]).to eq(transmission_id)
      expect(BSV::Transaction::Beef.from_binary(result[:beef]).subject_wtxid).to eq(subject_wtxid)
    end
  end
end
