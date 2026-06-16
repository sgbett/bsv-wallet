# frozen_string_literal: true

require_relative 'shared_context'

# Engine::Action class-level smoke specs (#284).
#
# Exhaustive behavioural coverage stays in engine_spec.rb — those tests
# exercise the public Engine surface, which delegates here. This file
# proves the class methods are callable in their own right (the round-trip
# through Engine is exercised by every existing create_action spec).
RSpec.describe BSV::Wallet::Engine::Action do
  include_context 'engine setup'

  # The shared context's +subject(:engine)+ uses +described_class.new+, which
  # resolves to +Engine::Action.new+ here. Override so +engine+ in this file
  # is a real +Engine+, matching how the production code calls Action.
  # Subject must come after include_context so this declaration wins.
  subject(:engine) do # rubocop:disable RSpec/LeadingSubject
    BSV::Wallet::Engine.new(
      store: store, utxo_pool: utxo_pool, broadcaster: broadcaster, network: :mainnet
    )
  end

  let(:engine_with_keys) do
    BSV::Wallet::Engine.new(
      store: store, utxo_pool: utxo_pool, broadcaster: broadcaster,
      key_deriver: key_deriver, network: :mainnet
    )
  end

  describe '.create' do
    it 'returns the BRC-100 hash shape with txid + tx for a normal action' do
      fund_wallet(satoshis: 100_000, basket: 'default', suffix: 'a')

      result = described_class.create(
        engine: engine_with_keys,
        description: 'unit smoke',
        outputs: [{ satoshis: 10_000, locking_script: OP_TRUE }],
        accept_delayed_broadcast: true # delayed → no inline broadcaster needed
      )

      expect(result).to include(:txid, :tx)
      expect(result[:txid]).to be_a(String).and(have_attributes(bytesize: 32))
      expect(result[:tx]).to be_a(String).and(satisfy { |b| !b.empty? })
    end

    it 'is the entry point Engine#create_action delegates to' do
      fund_wallet(satoshis: 100_000, basket: 'default', suffix: 'b')

      delegator_result = engine_with_keys.create_action(
        description: 'delegator smoke',
        outputs: [{ satoshis: 10_000, locking_script: OP_TRUE }]
      )
      expect(delegator_result).to include(:txid, :tx)
      expect(delegator_result[:txid].bytesize).to eq(32)
    end
  end

  describe '.build_input_specs' do
    it 'returns [] for nil inputs' do
      expect(described_class.build_input_specs(nil)).to eq([])
    end

    it 'maps caller inputs onto Store input specs with default vin numbering' do
      specs = described_class.build_input_specs([
                                                  { output_id: 7 },
                                                  { output_id: 9, vin: 5, sequence_number: 0xABCD, input_description: 'ok' }
                                                ])
      expect(specs).to eq([
                            { output_id: 7, vin: 0, nsequence: nil, description: nil },
                            { output_id: 9, vin: 5, nsequence: 0xABCD, description: 'ok' }
                          ])
    end
  end

  describe '.build_output_specs' do
    it 'marks outputs without derivation data as outbound' do
      specs = described_class.build_output_specs([
                                                   { satoshis: 100, locking_script: OP_TRUE }
                                                 ])
      expect(specs.first).to include(satoshis: 100, vout: 0, output_type: 'outbound')
    end

    it 'leaves output_type nil when derivation_prefix is present (BRC-100 normal)' do
      specs = described_class.build_output_specs([
                                                   { satoshis: 100, locking_script: OP_TRUE,
                                                     derivation_prefix: 'p', derivation_suffix: 's' }
                                                 ])
      expect(specs.first).to include(output_type: nil, derivation_prefix: 'p', derivation_suffix: 's')
    end

    it 'honours an explicit vout mapping' do
      specs = described_class.build_output_specs(
        [{ satoshis: 100, locking_script: OP_TRUE }, { satoshis: 200, locking_script: OP_TRUE }],
        { 0 => 3, 1 => 2 }
      )
      expect(specs.map { |s| s[:vout] }).to eq([3, 2])
    end
  end

  describe '#sign!' do
    it 'completes a deferred-signing flow when invoked directly on an Action instance' do
      # Deferred create: outputs only, no inputs to sign — exercises the
      # sign! lifecycle method without needing wallet-owned P2PKH inputs.
      create_result = engine.create_action(
        description: 'action sign! smoke',
        inputs: [],
        sign_and_process: false,
        outputs: [
          # 0 satoshis: exercises the deferred-sign lifecycle without
          # creating value-from-nothing (which strict validate_for_handoff!
          # would reject in #296 Phase B).
          { satoshis: 0, locking_script: OP_TRUE,
            derivation_prefix: SecureRandom.uuid, derivation_suffix: '1',
            sender_identity_key: 'self' }
        ]
      )
      reference = create_result[:signable_transaction][:reference]
      row = store.find_action(reference: reference)

      result = described_class.new(engine: engine, row: row).sign!(
        spends: {}, no_send: false,
        accept_delayed_broadcast: true, return_txid_only: false
      )

      expect(result).to include(:txid, :tx)
      expect(result[:txid].bytesize).to eq(32)
      expect(result[:tx]).to be_a(String)
    end

    it 'is the entry point Engine#sign_action delegates to' do
      create_result = engine.create_action(
        description: 'sign delegator',
        inputs: [],
        sign_and_process: false,
        outputs: [
          # 0 satoshis: exercises the deferred-sign lifecycle without
          # creating value-from-nothing (which strict validate_for_handoff!
          # would reject in #296 Phase B).
          { satoshis: 0, locking_script: OP_TRUE,
            derivation_prefix: SecureRandom.uuid, derivation_suffix: '1',
            sender_identity_key: 'self' }
        ]
      )
      reference = create_result[:signable_transaction][:reference]

      result = engine.sign_action(spends: {}, reference: reference)

      expect(result).to include(:txid, :tx)
      expect(result[:txid].bytesize).to eq(32)
    end

    it 'rejects no_send when the underlying action was not created with broadcast_intent: none' do
      # Deferred path defaults to broadcast_intent: :delayed — no_send: true
      # at sign time is a runtime override the base wallet does not support.
      create_result = engine.create_action(
        description: 'no_send guard',
        inputs: [],
        sign_and_process: false,
        outputs: [
          # 0 satoshis: exercises the deferred-sign lifecycle without
          # creating value-from-nothing (which strict validate_for_handoff!
          # would reject in #296 Phase B).
          { satoshis: 0, locking_script: OP_TRUE,
            derivation_prefix: SecureRandom.uuid, derivation_suffix: '1',
            sender_identity_key: 'self' }
        ]
      )
      row = store.find_action(reference: create_result[:signable_transaction][:reference])
      action = described_class.new(engine: engine, row: row)

      expect do
        action.sign!(
          spends: {}, no_send: true,
          accept_delayed_broadcast: true, return_txid_only: false
        )
      end.to raise_error(BSV::Wallet::UnsupportedActionError, /signAction\(no_send: true\)/)
    end
  end

  describe '#abort!' do
    it 'aborts an unsigned action when invoked directly on an Action instance' do
      create_result = engine.create_action(
        description: 'action abort! smoke',
        inputs: [],
        sign_and_process: false,
        outputs: [
          { satoshis: 500, locking_script: OP_TRUE,
            output_description: 'output' }
        ]
      )
      reference = create_result[:signable_transaction][:reference]
      row = store.find_action(reference: reference)

      result = described_class.new(engine: engine, row: row).abort!

      expect(result).to eq({ aborted: true })
      expect(store.find_action(reference: reference)).to be_nil
    end

    it 'is the entry point Engine#abort_action delegates to' do
      create_result = engine.create_action(
        description: 'abort delegator',
        inputs: [],
        sign_and_process: false,
        outputs: [
          { satoshis: 500, locking_script: OP_TRUE,
            output_description: 'output' }
        ]
      )
      reference = create_result[:signable_transaction][:reference]

      expect(engine.abort_action(reference: reference)).to eq({ aborted: true })
      expect(store.find_action(reference: reference)).to be_nil
    end
  end

  describe '.internalize' do
    # Action.internalize requires a chain_tracker for SPV verification.
    let(:chain_tracker_mock) do
      tracker = double('ChainTracker')
      allow(tracker).to receive_messages(valid_root_for_height?: true, current_height: 900_000)
      tracker
    end

    let(:engine_with_tracker) do
      BSV::Wallet::Engine.new(
        store: store, utxo_pool: utxo_pool, broadcaster: broadcaster,
        chain_tracker: chain_tracker_mock, network: :mainnet
      )
    end

    def build_internalize_beef(satoshis: 500)
      ancestor = BSV::Transaction::Tx.new(version: 1, lock_time: 0)
      ancestor.add_output(BSV::Transaction::TransactionOutput.new(
                            satoshis: satoshis + 100,
                            locking_script: BSV::Script::Script.from_binary(OP_TRUE)
                          ))
      sibling = SecureRandom.random_bytes(32)
      ancestor.merkle_path = BSV::Transaction::MerklePath.new(
        block_height: 800_000,
        path: [[
          BSV::Transaction::MerklePath::PathElement.new(offset: 2, hash: ancestor.wtxid, txid: true),
          BSV::Transaction::MerklePath::PathElement.new(offset: 3, hash: sibling)
        ]]
      )

      subject_tx = BSV::Transaction::Tx.new(version: 1, lock_time: 0)
      subject_tx.add_input(BSV::Transaction::TransactionInput.new(
                             prev_wtxid: ancestor.wtxid,
                             prev_tx_out_index: 0,
                             sequence: 0xFFFFFFFF,
                             unlocking_script: BSV::Script::Script.from_binary(OP_TRUE)
                           ))
      subject_tx.inputs[0].source_transaction = ancestor
      subject_tx.add_output(BSV::Transaction::TransactionOutput.new(
                              satoshis: satoshis,
                              locking_script: BSV::Script::Script.from_binary(OP_TRUE)
                            ))

      beef = BSV::Transaction::Beef.new
      beef.merge_transaction(ancestor)
      beef.merge_transaction(subject_tx)
      [beef.to_atomic_binary(subject_tx.wtxid), subject_tx]
    end

    it 'returns BRC-100 { accepted: true } and persists the incoming action' do
      beef_data, subject_tx = build_internalize_beef(satoshis: 500)

      result = described_class.internalize(
        engine: engine_with_tracker,
        tx: beef_data,
        description: 'action internalize smoke',
        labels: ['incoming'],
        outputs: [
          {
            output_index: 0, protocol: :basket_insertion, satoshis: 500,
            insertion_remittance: {
              basket: 'smoke', derivation_prefix: 'test',
              derivation_suffix: '1', sender_identity_key: 'self'
            }
          }
        ]
      )

      expect(result).to eq({ accepted: true })

      # Output landed in the basket
      listed = engine_with_tracker.list_outputs(basket: 'smoke')
      expect(listed[:total_outputs]).to eq(1)

      # Action row was persisted with the subject tx's wtxid
      action = store.find_action(wtxid: subject_tx.wtxid)
      expect(action).not_to be_nil
      expect(action[:broadcast_intent]).to eq('none')
      expect(action[:outgoing]).to be(false)
    end

    it 'is the entry point Engine#internalize_action delegates to' do
      beef_data, = build_internalize_beef(satoshis: 700)

      result = engine_with_tracker.internalize_action(
        tx: beef_data,
        description: 'internalize delegator smoke',
        outputs: [
          {
            output_index: 0, protocol: :basket_insertion, satoshis: 700,
            insertion_remittance: {
              basket: 'delegator', derivation_prefix: 'test',
              derivation_suffix: '1', sender_identity_key: 'self'
            }
          }
        ]
      )

      expect(result).to eq({ accepted: true })
    end
  end

  describe '.list' do
    it 'returns the BRC-100 { total_actions:, actions: } hash shape' do
      store.create_action(action: { description: 'list smoke other', broadcast_intent: :none, outgoing: false })
      action = store.create_action(action: { description: 'list smoke target', broadcast_intent: :none, outgoing: false })
      described_class.attach_labels(engine: engine, action_id: action[:id], labels: ['list-smoke'])

      result = described_class.list(engine: engine, labels: ['list-smoke'])

      expect(result).to include(:total_actions, :actions)
      expect(result[:total_actions]).to eq(1)
      expect(result[:actions].first[:description]).to eq('list smoke target')
    end

    it 'is the entry point Engine#list_actions delegates to' do
      action = store.create_action(action: { description: 'list delegator smoke', broadcast_intent: :none, outgoing: false })
      described_class.attach_labels(engine: engine, action_id: action[:id], labels: ['list-delegator'])

      expect(engine.list_actions(labels: ['list-delegator'])).to include(total_actions: 1)
    end
  end

  describe '.find' do
    it 'returns an Action when a row exists for the reference' do
      row = store.create_action(action: { description: 'findable smoke', broadcast_intent: :none, outgoing: false })

      found = described_class.find(engine: engine, reference: row[:reference])

      expect(found).to be_a(described_class)
      expect(found.id).to eq(row[:id])
    end

    it 'returns nil when no row exists for the reference' do
      expect(described_class.find(engine: engine, reference: SecureRandom.uuid)).to be_nil
    end
  end

  describe '.find_by_id' do
    it 'returns an Action when a row exists for the id' do
      row = store.create_action(action: { description: 'findable by id smoke', broadcast_intent: :none, outgoing: false })

      found = described_class.find_by_id(engine: engine, id: row[:id])

      expect(found).to be_a(described_class)
      expect(found.id).to eq(row[:id])
    end

    it 'returns nil when no row exists for the id' do
      expect(described_class.find_by_id(engine: engine, id: 999_999_999)).to be_nil
    end
  end

  describe '.attach_labels' do
    it 'is a no-op for nil labels' do
      action = store.create_action(action: { description: 'no labels', broadcast_intent: :none, outgoing: false })
      expect do
        described_class.attach_labels(engine: engine, action_id: action[:id], labels: nil)
      end.not_to(change { store.query_actions(labels: ['anything'])[:total] })
    end

    it 'creates labels and links them to the action' do
      action = store.create_action(action: { description: 'with labels', broadcast_intent: :none, outgoing: false })
      described_class.attach_labels(engine: engine, action_id: action[:id], labels: %w[smoke unit])

      result = store.query_actions(labels: ['smoke'], label_query_mode: :any, include_labels: true)
      expect(result[:actions].first[:labels]).to include('smoke')
    end
  end

  # wire_ancestor specs migrated to engine/hydrator_spec.rb in #345 along
  # with the method itself.

  # --- verify_incoming_transaction!: SPV verification wrapper (#286) ---

  describe '#verify_incoming_transaction! (private)' do
    let(:chain_tracker_mock) do
      tracker = double('ChainTracker')
      allow(tracker).to receive_messages(valid_root_for_height?: true, current_height: 900_000)
      tracker
    end

    let(:engine_with_tracker) do
      BSV::Wallet::Engine.new(
        store: store, utxo_pool: utxo_pool, broadcaster: broadcaster,
        chain_tracker: chain_tracker_mock, network: :mainnet
      )
    end

    def verify_incoming(engine_arg, subject_tx)
      described_class.new(engine: engine_arg, row: { id: nil }).send(
        :verify_incoming_transaction!, subject_tx
      )
    end

    it 'raises InvalidBeefError when chain_tracker is nil' do
      subject_tx = instance_double(BSV::Transaction::Tx)
      expect do
        verify_incoming(engine, subject_tx)
      end.to raise_error(BSV::Wallet::InvalidBeefError, /chain_tracker required/)
    end

    it 'delegates to Transaction::Tx#verify on success' do
      subject_tx = instance_double(BSV::Transaction::Tx)
      allow(subject_tx).to receive(:verify).with(chain_tracker: chain_tracker_mock).and_return(true)

      expect(verify_incoming(engine_with_tracker, subject_tx)).to be true
      expect(subject_tx).to have_received(:verify).with(chain_tracker: chain_tracker_mock)
    end

    it 'wraps VerificationError(:invalid_merkle_proof) into InvalidBeefError' do
      subject_tx = instance_double(BSV::Transaction::Tx)
      allow(subject_tx).to receive(:verify).and_raise(
        BSV::Transaction::VerificationError.new(:invalid_merkle_proof, 'bad proof')
      )

      expect do
        verify_incoming(engine_with_tracker, subject_tx)
      end.to raise_error(BSV::Wallet::InvalidBeefError, /SPV verification failed.*bad proof.*invalid_merkle_proof/)
    end

    it 'wraps VerificationError(:script_failure) into InvalidBeefError' do
      subject_tx = instance_double(BSV::Transaction::Tx)
      allow(subject_tx).to receive(:verify).and_raise(
        BSV::Transaction::VerificationError.new(:script_failure, 'script failed')
      )

      expect do
        verify_incoming(engine_with_tracker, subject_tx)
      end.to raise_error(BSV::Wallet::InvalidBeefError, /SPV verification failed.*script failed.*script_failure/)
    end

    it 'wraps VerificationError(:output_overflow) into InvalidBeefError' do
      subject_tx = instance_double(BSV::Transaction::Tx)
      allow(subject_tx).to receive(:verify).and_raise(
        BSV::Transaction::VerificationError.new(:output_overflow, 'outputs exceed inputs')
      )

      expect do
        verify_incoming(engine_with_tracker, subject_tx)
      end.to raise_error(BSV::Wallet::InvalidBeefError, /SPV verification failed.*outputs exceed inputs.*output_overflow/)
    end

    it 'wraps VerificationError(:missing_source) into InvalidBeefError' do
      subject_tx = instance_double(BSV::Transaction::Tx)
      allow(subject_tx).to receive(:verify).and_raise(
        BSV::Transaction::VerificationError.new(:missing_source, 'no source data')
      )

      expect do
        verify_incoming(engine_with_tracker, subject_tx)
      end.to raise_error(BSV::Wallet::InvalidBeefError, /SPV verification failed.*no source data.*missing_source/)
    end
  end

  # --- TXID-only + verify integration (parse_beef + replace_known_ancestors!) ---

  describe 'TXID-only + verify integration' do
    # This validates the highest-risk assumption in the chain tracker pivot:
    # that make_txid_only (which mutates the BEEF's @transactions list)
    # does NOT invalidate in-memory source_transaction pointers wired by
    # Beef.from_binary. Transaction::Tx#verify walks via input.source_transaction,
    # not the BEEF list, so verification must succeed after TXID-only conversion.

    let(:chain_tracker_mock) do
      tracker = double('ChainTracker')
      allow(tracker).to receive_messages(valid_root_for_height?: true, current_height: 900_000)
      tracker
    end

    let(:engine_with_tracker) do
      BSV::Wallet::Engine.new(
        store: store, utxo_pool: utxo_pool, broadcaster: broadcaster,
        chain_tracker: chain_tracker_mock, network: :mainnet
      )
    end

    def build_merkle_path(tx, block_height)
      sibling_hash = SecureRandom.random_bytes(32)
      # Offset 2 (not 0) to avoid the coinbase maturity check —
      # offset 0 is the coinbase position and requires 100-block depth.
      BSV::Transaction::MerklePath.new(
        block_height: block_height,
        path: [[
          BSV::Transaction::MerklePath::PathElement.new(offset: 2, hash: tx.wtxid, txid: true),
          BSV::Transaction::MerklePath::PathElement.new(offset: 3, hash: sibling_hash)
        ]]
      )
    end

    it 'verify succeeds after replace_known_ancestors! converts ancestors to TXID-only' do
      # Build a BEEF with a proven ancestor that the subject spends
      ancestor = BSV::Transaction::Tx.new(version: 1, lock_time: 0)
      ancestor.add_output(BSV::Transaction::TransactionOutput.new(
                            satoshis: 1000,
                            locking_script: BSV::Script::Script.from_binary(OP_TRUE)
                          ))
      ancestor.merkle_path = build_merkle_path(ancestor, 800_000)

      subject_tx = BSV::Transaction::Tx.new(version: 1, lock_time: 0)
      subject_tx.add_input(BSV::Transaction::TransactionInput.new(
                             prev_wtxid: ancestor.wtxid,
                             prev_tx_out_index: 0,
                             sequence: 0xFFFFFFFF,
                             unlocking_script: BSV::Script::Script.from_binary(OP_TRUE)
                           ))
      subject_tx.inputs[0].source_transaction = ancestor
      subject_tx.add_output(BSV::Transaction::TransactionOutput.new(
                              satoshis: 900,
                              locking_script: BSV::Script::Script.from_binary(OP_TRUE)
                            ))

      beef = BSV::Transaction::Beef.new
      beef.merge_transaction(ancestor)
      beef.merge_transaction(subject_tx)
      beef_data = beef.to_atomic_binary(subject_tx.wtxid)

      helper = described_class.new(engine: engine_with_tracker, row: { id: nil })

      # Step 1: Parse BEEF (wires source_transaction pointers)
      parsed_beef, parsed_subject = helper.send(:parse_beef, beef_data)

      # Verify the source_transaction pointer is wired
      expect(parsed_subject.inputs[0].source_transaction).not_to be_nil
      expect(parsed_subject.inputs[0].source_transaction.merkle_path).not_to be_nil

      # Step 2: Replace known ancestors with TXID-only
      # Pre-populate ProofStore so the ancestor is "known"
      proof_store.save_proof(
        wtxid: ancestor.wtxid,
        proof: { raw_tx: ancestor.to_binary, merkle_path: ancestor.merkle_path.to_binary, height: 800_000 }
      )
      helper.send(:replace_known_ancestors!, parsed_beef, parsed_subject.wtxid, nil)

      # Verify the BEEF entry was replaced with TXID-only
      replaced = parsed_beef.transactions.find { |bt| bt.wtxid == ancestor.wtxid }
      expect(replaced).to be_a(BSV::Transaction::Beef::TxidOnlyEntry)

      # Verify the in-memory source_transaction pointer SURVIVES the BEEF list mutation
      expect(parsed_subject.inputs[0].source_transaction).not_to be_nil
      expect(parsed_subject.inputs[0].source_transaction.merkle_path).not_to be_nil

      # Step 3: verify SUCCEEDS — the critical assertion
      expect(parsed_subject.verify(chain_tracker: chain_tracker_mock)).to be true
    end
  end
end
