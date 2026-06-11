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

  # --- Output Construction and Randomization (#21) ---

  describe '#build_outputs (private)' do
    # Reach the private instance method through a row-less helper. The
    # method has no row dependency — it constructs TransactionOutput
    # objects from caller specs and returns the shuffled mapping.
    def build_outputs(outputs, randomize)
      described_class.new(engine: engine, row: { id: nil }).send(:build_outputs, outputs, randomize)
    end

    it 'returns empty array and empty mapping for nil outputs' do
      tx_outputs, vout_mapping = build_outputs(nil, false)
      expect(tx_outputs).to eq([])
      expect(vout_mapping).to eq({})
    end

    it 'returns empty array and empty mapping for empty outputs' do
      tx_outputs, vout_mapping = build_outputs([], false)
      expect(tx_outputs).to eq([])
      expect(vout_mapping).to eq({})
    end

    it 'builds TransactionOutput objects from binary locking scripts' do
      script_bytes = "\x76\xa9\x14".b + ("\x00" * 20).b + "\x88\xac".b # P2PKH pattern
      outputs = [
        { satoshis: 1000, locking_script: script_bytes },
        { satoshis: 2000, locking_script: "\x6a\x05hello".b } # OP_RETURN
      ]

      tx_outputs, vout_mapping = build_outputs(outputs, false)

      expect(tx_outputs.length).to eq(2)
      expect(tx_outputs[0]).to be_a(BSV::Transaction::TransactionOutput)
      expect(tx_outputs[0].satoshis).to eq(1000)
      expect(tx_outputs[0].locking_script.to_binary).to eq(script_bytes)
      expect(tx_outputs[1].satoshis).to eq(2000)
      expect(vout_mapping).to eq({ 0 => 0, 1 => 1 })
    end

    it 'builds TransactionOutput objects from hex locking scripts' do
      hex_script = "76a914#{'00' * 20}88ac"
      outputs = [{ satoshis: 500, locking_script: hex_script }]

      tx_outputs, _vout_mapping = build_outputs(outputs, false)

      expect(tx_outputs.length).to eq(1)
      expect(tx_outputs[0].locking_script.p2pkh?).to be true
    end

    it 'defaults satoshis to 0 when not specified' do
      outputs = [{ locking_script: "\x6a".b }]

      tx_outputs, _vout_mapping = build_outputs(outputs, false)

      expect(tx_outputs[0].satoshis).to eq(0)
    end

    it 'preserves OP_RETURN scripts without modification' do
      op_return_script = "\x00\x6a\x05hello".b # OP_FALSE OP_RETURN <data>
      outputs = [{ satoshis: 0, locking_script: op_return_script }]

      tx_outputs, _vout_mapping = build_outputs(outputs, false)

      expect(tx_outputs[0].locking_script.to_binary).to eq(op_return_script)
      expect(tx_outputs[0].locking_script.op_return?).to be true
    end

    context 'with randomization disabled' do
      it 'preserves original output order' do
        outputs = 5.times.map do |i|
          { satoshis: (i + 1) * 100, locking_script: "\x6a#{[i].pack('C')}".b }
        end

        tx_outputs, vout_mapping = build_outputs(outputs, false)

        expect(tx_outputs.map(&:satoshis)).to eq([100, 200, 300, 400, 500])
        expect(vout_mapping).to eq({ 0 => 0, 1 => 1, 2 => 2, 3 => 3, 4 => 4 })
      end
    end

    context 'with randomization enabled' do
      it 'shuffles output order (statistical)' do
        outputs = 10.times.map do |i|
          { satoshis: (i + 1) * 100, locking_script: OP_TRUE }
        end

        original_order = outputs.map { |o| o[:satoshis] }

        # Run multiple times — at least one should differ from original order
        shuffled = false
        20.times do
          tx_outputs, _vout_mapping = build_outputs(outputs, true)
          if tx_outputs.map(&:satoshis) != original_order
            shuffled = true
            break
          end
        end

        expect(shuffled).to be(true), 'Expected shuffle to change order at least once in 20 attempts'
      end

      it 'preserves all outputs (no data loss)' do
        outputs = 5.times.map do |i|
          { satoshis: (i + 1) * 100, locking_script: OP_TRUE }
        end

        tx_outputs, _vout_mapping = build_outputs(outputs, true)

        expect(tx_outputs.map(&:satoshis).sort).to eq([100, 200, 300, 400, 500])
      end

      it 'produces correct vout mapping' do
        outputs = 5.times.map do |i|
          { satoshis: (i + 1) * 100, locking_script: OP_TRUE }
        end

        tx_outputs, vout_mapping = build_outputs(outputs, true)

        # Every original index should map to exactly one new position
        expect(vout_mapping.keys.sort).to eq([0, 1, 2, 3, 4])
        expect(vout_mapping.values.sort).to eq([0, 1, 2, 3, 4])

        # Verify the mapping is consistent: the output at vout_mapping[i]
        # should have the satoshis of the original output at index i
        outputs.each_with_index do |out, orig_idx|
          new_vout = vout_mapping[orig_idx]
          expect(tx_outputs[new_vout].satoshis).to eq(out[:satoshis])
        end
      end

      it 'is a no-op for a single output' do
        outputs = [{ satoshis: 1000, locking_script: OP_TRUE }]

        tx_outputs, vout_mapping = build_outputs(outputs, true)

        expect(tx_outputs.length).to eq(1)
        expect(tx_outputs[0].satoshis).to eq(1000)
        expect(vout_mapping).to eq({ 0 => 0 })
      end
    end
  end

  # --- generate_change: explicit fee detection + shortfall reporting (#209) ---

  describe '#generate_change (private)' do
    # Funds a single P2PKH UTXO and locks it to a fresh action. Returns the
    # action_id so the test can call generate_change against it.
    def fund_and_lock(satoshis:)
      derived_key = key_deriver.derive_private_key(
        protocol_id: [2, 'wallet payment'], key_id: 'gc', counterparty: 'self'
      )
      pubkey_hash = BSV::Primitives::Digest.hash160(derived_key.public_key.compressed)
      script = BSV::Script::Script.p2pkh_lock(pubkey_hash).to_binary

      source = store.create_action(
        action: { description: 'gc funding', broadcast_intent: :none, outgoing: false }
      )
      store.sign_action(action_id: source[:id], wtxid: SecureRandom.random_bytes(32), raw_tx: DUMMY_RAW_TX)
      store.promote_action(
        action_id: source[:id],
        outputs: [{
          satoshis: satoshis, vout: 0, locking_script: script, basket: 'gc',
          derivation_prefix: 'wallet payment', derivation_suffix: 'gc',
          sender_identity_key: 'self'
        }]
      )

      funded_output_id = BSV::Wallet::Store::Models::Output
                         .where(action_id: source[:id]).first.id

      action = store.create_action(
        action: { description: 'gc target', broadcast_intent: :none, outgoing: true, nlocktime: 0 },
        inputs: [{ output_id: funded_output_id, vin: 0 }]
      )
      action[:id]
    end

    def generate_change(action_id:, caller_outputs:, change_count: 1,
                        lock_time: 0, version: 1, randomize: false)
      described_class.new(engine: engine_with_keys, row: { id: action_id }).send(
        :generate_change,
        action_id: action_id, caller_outputs: caller_outputs,
        lock_time: lock_time, version: version, randomize: randomize,
        change_count: change_count
      )
    end

    it 'returns the funded tuple as a hash when surplus covers the fee' do
      action_id = fund_and_lock(satoshis: 10_000)
      payment_script = SecureRandom.random_bytes(25)

      result = generate_change(
        action_id: action_id,
        caller_outputs: [{ satoshis: 4_000, locking_script: payment_script }]
      )

      expect(result.keys).to contain_exactly(:wtxid, :raw_tx, :tx, :vout_mapping, :change_outputs)
      expect(result[:wtxid].bytesize).to eq(32)
      expect(result[:raw_tx]).to be_a(String)
      expect(result[:tx]).to be_a(BSV::Transaction::Tx)
      expect(result[:vout_mapping]).to eq(0 => 0) # randomize: false, caller out first
      expect(result[:change_outputs].length).to eq(1)
      expect(result[:change_outputs].first[:satoshis]).to be > 0
    end

    it 'returns { shortfall: N } when inputs fall short of outputs + fee' do
      action_id = fund_and_lock(satoshis: 5_000)
      payment_script = SecureRandom.random_bytes(25)

      result = generate_change(
        action_id: action_id,
        # Deliberately overspend: 5_000 input vs 5_000 output means surplus = 0,
        # but a 1-input/2-output P2PKH tx still needs a positive fee.
        caller_outputs: [{ satoshis: 5_000, locking_script: payment_script }]
      )

      expect(result).to match(shortfall: a_value > 0)
      expect(result[:shortfall]).to be_a(Integer)
    end

    it 'reports the exact deficit as required_fee - surplus' do
      action_id = fund_and_lock(satoshis: 10_000)
      payment_script = SecureRandom.random_bytes(25)

      # First call: succeed and learn the required fee. Surplus on this run
      # is 10_000 - 4_000 = 6_000; sum of change outputs equals surplus - fee.
      ok = generate_change(
        action_id: action_id,
        caller_outputs: [{ satoshis: 4_000, locking_script: payment_script }]
      )
      change_total = ok[:change_outputs].sum { |c| c[:satoshis] }
      required_fee = (10_000 - 4_000) - change_total

      # Second action with inputs that fall short by 1 sat.
      short_action_id = fund_and_lock(satoshis: required_fee + 4_000 - 1)
      result = generate_change(
        action_id: short_action_id,
        caller_outputs: [{ satoshis: 4_000, locking_script: payment_script }]
      )

      # Shortfall should be exactly 1 sat (within size estimate variance).
      # The two transactions have the same shape, so the required_fee is
      # identical and the surplus differs by 1.
      expect(result[:shortfall]).to eq(1)
    end

    it 'raises ArgumentError when change_count is zero' do
      action_id = fund_and_lock(satoshis: 10_000)
      expect do
        generate_change(
          action_id: action_id,
          caller_outputs: [{ satoshis: 100, locking_script: SecureRandom.random_bytes(25) }],
          change_count: 0
        )
      end.to raise_error(ArgumentError, /change_count must be >= 1/)
    end

    it 'derives BRC-42 change outputs the wallet can re-derive' do
      action_id = fund_and_lock(satoshis: 10_000)

      result = generate_change(
        action_id: action_id,
        caller_outputs: [{ satoshis: 4_000, locking_script: SecureRandom.random_bytes(25) }]
      )

      change = result[:change_outputs].first
      derived = key_deriver.derive_private_key(
        protocol_id: [2, change[:derivation_prefix]],
        key_id: change[:derivation_suffix],
        counterparty: 'self'
      )
      pubkey_hash = BSV::Primitives::Digest.hash160(derived.public_key.compressed)
      expected_script = BSV::Script::Script.p2pkh_lock(pubkey_hash).to_binary
      expect(change[:locking_script]).to eq(expected_script)
    end
  end

  # --- Input Resolution and P2PKH Signing (#22) ---

  describe '#build_inputs (private)' do
    # Use engine_with_keys for key derivation. Reach the private instance
    # method through a row-less helper — the method has no row dependency.
    def build_inputs(resolved_inputs, caller_inputs)
      described_class.new(engine: engine_with_keys, row: { id: nil }).send(
        :build_inputs, resolved_inputs, caller_inputs
      )
    end

    # Helper: generate a P2PKH locking script for a derived key
    def p2pkh_locking_script_for(private_key)
      pubkey_hash = BSV::Primitives::Digest.hash160(private_key.public_key.compressed)
      BSV::Script::Script.p2pkh_lock(pubkey_hash)
    end

    # Helper: build a resolved input hash matching Store#resolve_inputs_for_signing output
    def make_resolved_input(vin:, private_key: nil, locking_script: nil,
                            satoshis: 1000, sender_identity_key: nil,
                            derivation_prefix: 'wallet payment',
                            derivation_suffix: 'suffix1')
      script = if locking_script
                 locking_script
               elsif private_key
                 p2pkh_locking_script_for(private_key).to_binary
               else
                 OP_TRUE
               end

      {
        vin: vin,
        sequence: 0xFFFFFFFF,
        source_wtxid: SecureRandom.random_bytes(32),
        source_vout: 0,
        source_satoshis: satoshis,
        source_locking_script: script,
        derivation_prefix: derivation_prefix,
        derivation_suffix: derivation_suffix,
        sender_identity_key: sender_identity_key
      }
    end

    it 'returns empty arrays for nil inputs' do
      tx_inputs, signing_keys = build_inputs(nil, nil)
      expect(tx_inputs).to eq([])
      expect(signing_keys).to eq({})
    end

    it 'returns empty arrays for empty inputs' do
      tx_inputs, signing_keys = build_inputs([], [])
      expect(tx_inputs).to eq([])
      expect(signing_keys).to eq({})
    end

    it 'builds TransactionInput with correct outpoint' do
      source_wtxid = SecureRandom.random_bytes(32)
      # Derive the key the same way the engine will
      derived_key = key_deriver.derive_private_key(
        protocol_id: [2, 'wallet payment'], key_id: 'suffix1', counterparty: 'self'
      )
      resolved = [make_resolved_input(vin: 0, private_key: derived_key).merge(source_wtxid: source_wtxid, source_vout: 2)]

      tx_inputs, _signing_keys = build_inputs(resolved, nil)

      expect(tx_inputs.length).to eq(1)
      expect(tx_inputs[0]).to be_a(BSV::Transaction::TransactionInput)
      expect(tx_inputs[0].prev_wtxid).to eq(source_wtxid)
      expect(tx_inputs[0].prev_tx_out_index).to eq(2)
      expect(tx_inputs[0].sequence).to eq(0xFFFFFFFF)
    end

    it 'sets source_satoshis and source_locking_script for sighash' do
      derived_key = key_deriver.derive_private_key(
        protocol_id: [2, 'wallet payment'], key_id: 'suffix1', counterparty: 'self'
      )
      p2pkh_locking_script_for(derived_key)
      resolved = [make_resolved_input(vin: 0, private_key: derived_key, satoshis: 5000)]

      tx_inputs, _signing_keys = build_inputs(resolved, nil)

      expect(tx_inputs[0].source_satoshis).to eq(5000)
      expect(tx_inputs[0].source_locking_script).to be_a(BSV::Script::Script)
      expect(tx_inputs[0].source_locking_script.p2pkh?).to be true
    end

    it 'derives signing key for P2PKH inputs' do
      derived_key = key_deriver.derive_private_key(
        protocol_id: [2, 'wallet payment'], key_id: 'suffix1', counterparty: 'self'
      )
      resolved = [make_resolved_input(vin: 0, private_key: derived_key)]

      _tx_inputs, signing_keys = build_inputs(resolved, nil)

      expect(signing_keys[0]).to be_a(BSV::Primitives::PrivateKey)
      # The derived key should produce the same public key
      expect(signing_keys[0].public_key.compressed).to eq(derived_key.public_key.compressed)
    end

    it 'signs a P2PKH input that verifies correctly' do
      derived_key = key_deriver.derive_private_key(
        protocol_id: [2, 'wallet payment'], key_id: 'suffix1', counterparty: 'self'
      )
      script = p2pkh_locking_script_for(derived_key)
      resolved = [make_resolved_input(vin: 0, private_key: derived_key, satoshis: 1000)]

      tx_inputs, signing_keys = build_inputs(resolved, nil)

      # Build a minimal transaction to verify signing works end-to-end
      tx = BSV::Transaction::Tx.new
      tx.add_input(tx_inputs[0])
      tx.add_output(BSV::Transaction::TransactionOutput.new(satoshis: 900, locking_script: script))

      # Sign with the derived key
      tx.sign(0, signing_keys[0])

      expect(tx_inputs[0].unlocking_script).not_to be_nil
      expect(tx.verify_input(0)).to be true
    end

    it 'applies caller-provided unlocking script for custom inputs' do
      custom_unlock = "\x01\x02\x03".b
      custom_lock = "\x04\x05\x06".b # Non-P2PKH locking script
      resolved = [make_resolved_input(vin: 0, locking_script: custom_lock)]
      caller_inputs = [{ vin: 0, unlocking_script: custom_unlock }]

      tx_inputs, signing_keys = build_inputs(resolved, caller_inputs)

      expect(tx_inputs[0].unlocking_script).to be_a(BSV::Script::Script)
      expect(tx_inputs[0].unlocking_script.to_binary).to eq(custom_unlock)
      expect(signing_keys).to be_empty
    end

    it 'uses counterparty self for nil sender_identity_key' do
      # Derive a key as self-payment
      self_key = key_deriver.derive_private_key(
        protocol_id: [2, 'wallet payment'], key_id: 'self-suffix', counterparty: 'self'
      )
      resolved = [make_resolved_input(
        vin: 0, private_key: self_key,
        sender_identity_key: nil,
        derivation_suffix: 'self-suffix'
      )]

      _tx_inputs, signing_keys = build_inputs(resolved, nil)

      # The derived key should match the self-payment derivation
      expect(signing_keys[0].public_key.compressed).to eq(self_key.public_key.compressed)
    end

    it 'uses sender_identity_key as counterparty when present' do
      sender_key = BSV::Primitives::PrivateKey.generate
      sender_hex = sender_key.public_key.to_hex

      # Derive a key with the sender as counterparty
      derived_key = key_deriver.derive_private_key(
        protocol_id: [2, 'wallet payment'], key_id: 'from-sender',
        counterparty: sender_hex
      )
      resolved = [make_resolved_input(
        vin: 0, private_key: derived_key,
        sender_identity_key: sender_hex,
        derivation_suffix: 'from-sender'
      )]

      _tx_inputs, signing_keys = build_inputs(resolved, nil)

      expect(signing_keys[0].public_key.compressed).to eq(derived_key.public_key.compressed)
    end

    it 'raises for non-P2PKH input without unlocking_script' do
      custom_lock = "\x04\x05\x06".b # Non-P2PKH
      resolved = [make_resolved_input(vin: 0, locking_script: custom_lock)]

      expect do
        build_inputs(resolved, nil)
      end.to raise_error(BSV::Wallet::Error, /non-P2PKH.*no unlocking_script/)
    end

    it 'handles multiple inputs with mixed types' do
      # Input 0: P2PKH
      derived_key = key_deriver.derive_private_key(
        protocol_id: [2, 'wallet payment'], key_id: 'suffix1', counterparty: 'self'
      )
      # Input 1: custom script
      custom_lock = "\x04\x05\x06".b
      custom_unlock = "\x07\x08\x09".b

      resolved = [
        make_resolved_input(vin: 0, private_key: derived_key),
        make_resolved_input(vin: 1, locking_script: custom_lock)
      ]
      caller_inputs = [
        { vin: 0 },
        { vin: 1, unlocking_script: custom_unlock }
      ]

      tx_inputs, signing_keys = build_inputs(resolved, caller_inputs)

      expect(tx_inputs.length).to eq(2)
      expect(signing_keys).to have_key(0)
      expect(signing_keys).not_to have_key(1)
      expect(tx_inputs[1].unlocking_script.to_binary).to eq(custom_unlock)
    end

    it 'raises without key_deriver for P2PKH input' do
      derived_key = BSV::Primitives::PrivateKey.generate
      resolved = [make_resolved_input(vin: 0, private_key: derived_key)]

      expect do
        described_class.new(engine: engine, row: { id: nil }).send(:build_inputs, resolved, nil)
      end.to raise_error(BSV::Wallet::Error, /key deriver/)
    end
  end

  # --- Transaction Assembly, Serialization, and Txid (#23) ---

  describe '#build_transaction (private)' do
    # Helper: generate a P2PKH locking script for a derived key
    def p2pkh_locking_script_for(private_key)
      pubkey_hash = BSV::Primitives::Digest.hash160(private_key.public_key.compressed)
      BSV::Script::Script.p2pkh_lock(pubkey_hash)
    end

    # Helper: derive a key the same way the engine will
    def derive_key(prefix: 'wallet payment', suffix: 'suffix1', counterparty: 'self')
      key_deriver.derive_private_key(
        protocol_id: [2, prefix], key_id: suffix, counterparty: counterparty
      )
    end

    # Helper: build a resolved input hash
    def make_resolved_input(vin:, private_key:, satoshis: 1000, source_vout: 0)
      {
        vin: vin,
        sequence: 0xFFFFFFFF,
        source_wtxid: SecureRandom.random_bytes(32),
        source_vout: source_vout,
        source_satoshis: satoshis,
        source_locking_script: p2pkh_locking_script_for(private_key).to_binary,
        derivation_prefix: 'wallet payment',
        derivation_suffix: 'suffix1',
        sender_identity_key: nil
      }
    end

    let(:derived_key) { derive_key }
    let(:resolved_inputs) { [make_resolved_input(vin: 0, private_key: derived_key)] }
    let(:output_script) { p2pkh_locking_script_for(derived_key).to_binary }
    let(:caller_outputs) { [{ satoshis: 900, locking_script: output_script }] }

    before do
      allow(store).to receive(:resolve_inputs_for_signing).and_return(resolved_inputs)
    end

    def build_transaction(action_id, inputs, outputs, lock_time, version, randomize)
      described_class.new(engine: engine_with_keys, row: { id: action_id }).send(
        :build_transaction, action_id, inputs, outputs, lock_time, version, randomize
      )
    end

    it 'assembles a transaction and returns wtxid, raw_tx, and vout_mapping' do
      wtxid, raw_tx, vout_mapping = build_transaction(1, nil, caller_outputs, nil, nil, false)

      expect(wtxid).to be_a(String)
      expect(wtxid.bytesize).to eq(32)
      expect(raw_tx).to be_a(String)
      expect(raw_tx.bytesize).to be > 10
      expect(vout_mapping).to eq({ 0 => 0 })
    end

    it 'produces a wtxid that is the double-SHA-256 of serialized tx (wire order)' do
      wtxid, raw_tx, _vout_mapping = build_transaction(1, nil, caller_outputs, nil, nil, false)

      expected_wtxid = BSV::Primitives::Digest.sha256d(raw_tx)
      expect(wtxid).to eq(expected_wtxid)
    end

    it 'produces a serialized tx that can be deserialized back' do
      _txid, raw_tx, _vout_mapping = build_transaction(1, nil, caller_outputs, nil, nil, false)

      parsed = BSV::Transaction::Tx.from_binary(raw_tx)
      expect(parsed.inputs.length).to eq(1)
      expect(parsed.outputs.length).to eq(1)
      expect(parsed.outputs[0].satoshis).to eq(900)
    end

    it 'round-trips: serialize -> deserialize -> re-serialize produces identical bytes' do
      _txid, raw_tx, _vout_mapping = build_transaction(1, nil, caller_outputs, nil, nil, false)

      parsed = BSV::Transaction::Tx.from_binary(raw_tx)
      expect(parsed.to_binary).to eq(raw_tx)
    end

    it 'sets version and lock_time correctly' do
      _txid, raw_tx, _vout_mapping = build_transaction(1, nil, caller_outputs, 500, 2, false)

      parsed = BSV::Transaction::Tx.from_binary(raw_tx)
      expect(parsed.version).to eq(2)
      expect(parsed.lock_time).to eq(500)
    end

    it 'defaults version to 1 and lock_time to 0' do
      _txid, raw_tx, _vout_mapping = build_transaction(1, nil, caller_outputs, nil, nil, false)

      parsed = BSV::Transaction::Tx.from_binary(raw_tx)
      expect(parsed.version).to eq(1)
      expect(parsed.lock_time).to eq(0)
    end

    it 'signs P2PKH inputs that pass verify_input' do
      _, raw_tx, _vout_mapping = build_transaction(1, nil, caller_outputs, nil, nil, false)

      # Reconstruct the transaction with source data for verification
      parsed = BSV::Transaction::Tx.from_binary(raw_tx)
      parsed.inputs[0].source_satoshis = resolved_inputs[0][:source_satoshis]
      parsed.inputs[0].source_locking_script = BSV::Script::Script.from_binary(
        resolved_inputs[0][:source_locking_script]
      )

      expect(parsed.inputs[0].unlocking_script).not_to be_nil
      expect(parsed.verify_input(0)).to be true
    end

    it 'handles outputs-only transaction (no inputs)' do
      allow(store).to receive(:resolve_inputs_for_signing).and_return([])

      _, raw_tx, vout_mapping = build_transaction(1, nil, caller_outputs, nil, nil, false)

      parsed = BSV::Transaction::Tx.from_binary(raw_tx)
      expect(parsed.inputs.length).to eq(0)
      expect(parsed.outputs.length).to eq(1)
      expect(vout_mapping).to eq({ 0 => 0 })
    end

    it 'handles multiple inputs and outputs' do
      derived_key2 = derive_key(suffix: 'suffix2')
      multi_resolved = [
        make_resolved_input(vin: 0, private_key: derived_key),
        make_resolved_input(vin: 1, private_key: derived_key2,
                            satoshis: 2000, source_vout: 1).merge(
                              derivation_suffix: 'suffix2'
                            )
      ]
      allow(store).to receive(:resolve_inputs_for_signing).and_return(multi_resolved)

      script2 = p2pkh_locking_script_for(derived_key2).to_binary
      multi_outputs = [
        { satoshis: 800, locking_script: output_script },
        { satoshis: 1500, locking_script: script2 }
      ]

      _, raw_tx, = build_transaction(1, nil, multi_outputs, nil, nil, false)

      parsed = BSV::Transaction::Tx.from_binary(raw_tx)
      expect(parsed.inputs.length).to eq(2)
      expect(parsed.outputs.length).to eq(2)

      # Verify both inputs are signed
      multi_resolved.each_with_index do |resolved, idx|
        parsed.inputs[idx].source_satoshis = resolved[:source_satoshis]
        parsed.inputs[idx].source_locking_script = BSV::Script::Script.from_binary(
          resolved[:source_locking_script]
        )
      end
      expect(parsed.verify_input(0)).to be true
      expect(parsed.verify_input(1)).to be true
    end

    it 'resolves inputs from the store using the action_id' do
      build_transaction(42, nil, caller_outputs, nil, nil, false)

      expect(store).to have_received(:resolve_inputs_for_signing).with(action_id: 42)
    end

    it 'passes vout_mapping through from build_outputs' do
      multi_outputs = 3.times.map do |i|
        { satoshis: (i + 1) * 100, locking_script: output_script }
      end

      _txid, _raw_tx, vout_mapping = build_transaction(1, nil, multi_outputs, nil, nil, false)

      expect(vout_mapping.keys.sort).to eq([0, 1, 2])
      expect(vout_mapping.values.sort).to eq([0, 1, 2])
    end
  end

  # --- wire_ancestor: ProofStore-walking ancestor hydrator (#286) ---

  describe '#wire_ancestor (private)' do
    def make_fake_tx(satoshis:, inputs: [])
      tx = BSV::Transaction::Tx.new(version: 1, lock_time: 0)
      inputs.each do |inp|
        tx.add_input(BSV::Transaction::TransactionInput.new(
                       prev_wtxid: inp[:prev_wtxid],
                       prev_tx_out_index: 0,
                       unlocking_script: BSV::Script::Script.from_binary(OP_TRUE)
                     ))
      end
      tx.add_output(BSV::Transaction::TransactionOutput.new(
                      satoshis: satoshis,
                      locking_script: BSV::Script::Script.from_binary(OP_TRUE)
                    ))
      tx
    end

    def make_merkle_path(wtxid:, height: 800_000)
      sibling_hash = SecureRandom.random_bytes(32)
      BSV::Transaction::MerklePath.new(
        block_height: height,
        path: [[
          BSV::Transaction::MerklePath::PathElement.new(offset: 0, hash: wtxid, txid: true),
          BSV::Transaction::MerklePath::PathElement.new(offset: 1, hash: sibling_hash)
        ]]
      )
    end

    def wire_ancestor(wtxid)
      described_class.new(engine: engine_with_keys, row: { id: nil }).send(:wire_ancestor, wtxid)
    end

    it 'returns a proven ancestor with merkle_path set (no recursion)' do
      fake_tx = make_fake_tx(satoshis: 1000)
      raw_tx = fake_tx.to_binary
      wtxid = fake_tx.wtxid
      mp = make_merkle_path(wtxid: wtxid)

      proof_store.save_proof(
        wtxid: wtxid,
        proof: { height: 800_000, merkle_path: mp.to_binary, raw_tx: raw_tx }
      )

      result = wire_ancestor(wtxid)
      expect(result).to be_a(BSV::Transaction::Tx)
      expect(result.merkle_path).to be_a(BSV::Transaction::MerklePath)
      expect(result.merkle_path.block_height).to eq(800_000)
    end

    it 'recursively wires source_transactions for unconfirmed ancestors' do
      # Grandparent: proven (has merkle_path)
      grandparent_tx = make_fake_tx(satoshis: 2000)
      gp_raw = grandparent_tx.to_binary
      gp_wtxid = grandparent_tx.wtxid
      gp_mp = make_merkle_path(wtxid: gp_wtxid, height: 799_000)

      proof_store.save_proof(
        wtxid: gp_wtxid,
        proof: { height: 799_000, merkle_path: gp_mp.to_binary, raw_tx: gp_raw }
      )

      # Parent: unconfirmed (no merkle_path), spends grandparent
      parent_tx = make_fake_tx(satoshis: 1500, inputs: [{ prev_wtxid: gp_wtxid }])
      parent_raw = parent_tx.to_binary
      parent_wtxid = parent_tx.wtxid

      proof_store.save_proof(
        wtxid: parent_wtxid,
        proof: { raw_tx: parent_raw }
      )

      result = wire_ancestor(parent_wtxid)
      expect(result).to be_a(BSV::Transaction::Tx)
      expect(result.merkle_path).to be_nil

      # The input's source_transaction should be wired to the grandparent
      expect(result.inputs.first.source_transaction).to be_a(BSV::Transaction::Tx)
      expect(result.inputs.first.source_transaction.merkle_path).to be_a(BSV::Transaction::MerklePath)
      expect(result.inputs.first.source_transaction.merkle_path.block_height).to eq(799_000)
    end

    it 'terminates on circular references via visited set' do
      # Real Bitcoin transactions can't form cycles (wtxid depends on content),
      # but ProofStore entries can. Use fixed wtxids and store transactions
      # whose inputs reference each other's key.
      wtxid_a = ("\x01" * 32).b
      wtxid_b = ("\x02" * 32).b

      tx_a = make_fake_tx(satoshis: 500, inputs: [{ prev_wtxid: wtxid_b }])
      tx_b = make_fake_tx(satoshis: 500, inputs: [{ prev_wtxid: wtxid_a }])

      proof_store.save_proof(wtxid: wtxid_a, proof: { raw_tx: tx_a.to_binary })
      proof_store.save_proof(wtxid: wtxid_b, proof: { raw_tx: tx_b.to_binary })

      # Walk from wtxid_a → loads tx_a → input references wtxid_b →
      # loads tx_b → input references wtxid_a → ALREADY VISITED → stops.
      result = wire_ancestor(wtxid_a)
      expect(result).to be_a(BSV::Transaction::Tx)
    end

    it 'returns nil for missing proofs' do
      missing_wtxid = SecureRandom.random_bytes(32)
      result = wire_ancestor(missing_wtxid)
      expect(result).to be_nil
    end
  end

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
