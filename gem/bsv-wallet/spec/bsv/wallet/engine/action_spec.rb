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
          { satoshis: 500, locking_script: OP_TRUE,
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
          { satoshis: 500, locking_script: OP_TRUE,
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
          { satoshis: 500, locking_script: OP_TRUE,
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
end
