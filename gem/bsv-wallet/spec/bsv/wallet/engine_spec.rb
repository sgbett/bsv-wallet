# frozen_string_literal: true

require 'securerandom'
require 'sequel'
require 'bsv-wallet-postgres'

# Connect to test database for integration tests
TEST_DB_URL = ENV.fetch('DATABASE_URL', 'postgres://postgres:postgres@localhost:5433/bsv_wallet_test')
ENGINE_DB = Sequel.connect(TEST_DB_URL)
ENGINE_DB.extension :pg_enum
ENGINE_DB.extension :pg_array
Sequel.extension :migration
migrations_path = File.expand_path('../../../../bsv-wallet-postgres/db/migrations', __dir__)
Sequel::Migrator.run(ENGINE_DB, migrations_path)
BSV::Wallet::Postgres.connect(ENGINE_DB)

RSpec.describe BSV::Wallet::Engine do
  let(:store) { BSV::Wallet::Postgres::Store.new }
  let(:utxo_pool) { BSV::Wallet::Postgres::UTXOPool.new(store: store) }
  let(:broadcast_queue) { BSV::Wallet::Postgres::BroadcastQueue.new }
  let(:proof_store) { BSV::Wallet::Postgres::ProofStore.new }

  subject(:engine) do
    described_class.new(
      store: store,
      utxo_pool: utxo_pool,
      broadcast_queue: broadcast_queue,
      proof_store: proof_store,
      network: :mainnet
    )
  end

  around(:each) do |example|
    ENGINE_DB.transaction(rollback: :always, auto_savepoint: true) do
      example.run
    end
  end

  # Pre-fund the wallet with spendable outputs
  def fund_wallet(satoshis: 1000, count: 1, basket: 'default')
    source_action = store.create_action(
      action: { description: 'funding source', broadcast: :none, outgoing: false }
    )

    outputs = count.times.map do |i|
      {
        satoshis: satoshis, vout: i,
        locking_script: SecureRandom.random_bytes(25),
        basket: basket
      }
    end
    store.promote_action(action_id: source_action[:id], outputs: outputs)
  end

  describe 'construction' do
    it 'accepts pluggable components' do
      expect(engine).to be_a(BSV::Wallet::Engine)
    end

    it 'includes BRC100 interface' do
      expect(described_class.ancestors).to include(BSV::Wallet::Interface::BRC100)
    end
  end

  describe '#create_action' do
    it 'creates an action with outputs' do
      result = engine.create_action(
        description: 'test payment',
        outputs: [
          { satoshis: 500, locking_script: SecureRandom.random_bytes(25),
            output_description: 'payment', basket: 'payments' }
        ]
      )

      expect(result).to include(:txid, :tx)
      expect(result[:txid]).to be_a(String)
      expect(result[:txid].length).to eq(32)
    end

    it 'creates a deferred signing action' do
      result = engine.create_action(
        description: 'deferred action',
        sign_and_process: false,
        outputs: [
          { satoshis: 500, locking_script: SecureRandom.random_bytes(25),
            output_description: 'output' }
        ]
      )

      expect(result).to include(:signable_transaction)
      expect(result[:signable_transaction][:reference]).to be_a(String)
    end

    it 'creates a no-send action' do
      result = engine.create_action(
        description: 'no-send action',
        no_send: true,
        outputs: [
          { satoshis: 500, locking_script: SecureRandom.random_bytes(25),
            output_description: 'output', basket: 'pending' }
        ]
      )

      expect(result).to include(:txid, :tx, :no_send_change)
    end

    it 'attaches labels' do
      result = engine.create_action(
        description: 'labeled action',
        no_send: true,
        labels: %w[payment urgent],
        outputs: [
          { satoshis: 500, locking_script: SecureRandom.random_bytes(25),
            output_description: 'output' }
        ]
      )

      actions = engine.list_actions(labels: ['payment'], include_labels: true)
      expect(actions[:total_actions]).to eq(1)
      expect(actions[:actions].first[:labels]).to include('payment', 'urgent')
    end

    it 'validates description length' do
      expect {
        engine.create_action(description: 'hi', outputs: [{ satoshis: 1, output_description: 'x' }])
      }.to raise_error(BSV::Wallet::InvalidParameterError)
    end

    it 'validates at least one input or output' do
      expect {
        engine.create_action(description: 'no inputs or outputs')
      }.to raise_error(BSV::Wallet::InvalidParameterError)
    end

    context 'with inline broadcast' do
      let(:arc_response) do
        double('Result', success?: true, data: {
          txStatus: 'SEEN_ON_NETWORK', status: 200,
          blockHash: nil, blockHeight: nil, merklePath: nil
        })
      end
      let(:arc_client) { double('ARC', call: arc_response) }
      let(:broadcast_queue) { BSV::Wallet::Postgres::BroadcastQueue.new(arc_client: arc_client) }

      it 'broadcasts inline and promotes on acceptance' do
        result = engine.create_action(
          description: 'inline broadcast',
          accept_delayed_broadcast: false,
          outputs: [
            { satoshis: 500, locking_script: SecureRandom.random_bytes(25),
              output_description: 'output', basket: 'payments' }
          ]
        )

        expect(result[:txid]).not_to be_nil
        expect(arc_client).to have_received(:call).with(:broadcast, anything)

        # Verify outputs were promoted
        listed = engine.list_outputs(basket: 'payments')
        expect(listed[:total_outputs]).to eq(1)
      end
    end
  end

  describe '#sign_action' do
    it 'completes a deferred signing flow' do
      # Create deferred
      create_result = engine.create_action(
        description: 'deferred signing',
        sign_and_process: false,
        outputs: [
          { satoshis: 500, locking_script: SecureRandom.random_bytes(25),
            output_description: 'output' }
        ]
      )

      reference = create_result[:signable_transaction][:reference]

      # Sign
      result = engine.sign_action(
        spends: { 0 => { unlocking_script: SecureRandom.random_bytes(72) } },
        reference: reference,
        no_send: true
      )

      expect(result[:txid]).to be_a(String)
      expect(result[:txid].length).to eq(32)
    end

    it 'raises for invalid reference' do
      expect {
        engine.sign_action(spends: {}, reference: 'nonexistent')
      }.to raise_error(BSV::Wallet::InvalidParameterError)
    end
  end

  describe '#abort_action' do
    it 'aborts an unsigned action' do
      create_result = engine.create_action(
        description: 'to be aborted',
        sign_and_process: false,
        outputs: [
          { satoshis: 500, locking_script: SecureRandom.random_bytes(25),
            output_description: 'output' }
        ]
      )

      reference = create_result[:signable_transaction][:reference]
      result = engine.abort_action(reference: reference)

      expect(result).to eq({ aborted: true })

      # Verify action is gone
      found = store.find_action(reference: reference)
      expect(found).to be_nil
    end

    it 'raises for invalid reference' do
      expect {
        engine.abort_action(reference: 'nonexistent')
      }.to raise_error(BSV::Wallet::InvalidParameterError)
    end
  end

  describe '#list_actions' do
    before do
      engine.create_action(
        description: 'payment action', no_send: true, labels: ['payment'],
        outputs: [{ satoshis: 100, output_description: 'output', locking_script: "\x00".b }]
      )
      engine.create_action(
        description: 'transfer action', no_send: true, labels: ['transfer'],
        outputs: [{ satoshis: 200, output_description: 'output', locking_script: "\x00".b }]
      )
      engine.create_action(
        description: 'both labels', no_send: true, labels: %w[payment transfer],
        outputs: [{ satoshis: 300, output_description: 'output', locking_script: "\x00".b }]
      )
    end

    it 'filters by label (any mode)' do
      result = engine.list_actions(labels: ['payment'])
      expect(result[:total_actions]).to eq(2)
    end

    it 'filters by label (all mode)' do
      result = engine.list_actions(labels: %w[payment transfer], label_query_mode: :all)
      expect(result[:total_actions]).to eq(1)
    end

    it 'paginates' do
      result = engine.list_actions(labels: ['payment'], limit: 1, offset: 0)
      expect(result[:actions].size).to eq(1)
      expect(result[:total_actions]).to eq(2)
    end

    it 'includes derived status' do
      result = engine.list_actions(labels: ['payment'])
      statuses = result[:actions].map { |a| a[:status] }
      expect(statuses).to all(be_a(Symbol))
    end
  end

  describe '#internalize_action' do
    it 'creates a completed incoming action with basket insertion' do
      result = engine.internalize_action(
        tx: SecureRandom.random_bytes(200),
        description: 'incoming payment',
        labels: ['incoming'],
        outputs: [
          {
            output_index: 0,
            protocol: :basket_insertion,
            satoshis: 500,
            insertion_remittance: {
              basket: 'tokens',
              tags: ['nft'],
              custom_instructions: 'token-id-123'
            }
          }
        ]
      )

      expect(result).to eq({ accepted: true })

      # Verify outputs are in the basket
      listed = engine.list_outputs(basket: 'tokens', include_tags: true)
      expect(listed[:total_outputs]).to eq(1)
      expect(listed[:outputs].first[:tags]).to eq(['nft'])
    end

    it 'creates a completed incoming action with wallet payment' do
      result = engine.internalize_action(
        tx: SecureRandom.random_bytes(200),
        description: 'incoming payment',
        outputs: [
          {
            output_index: 0,
            protocol: :wallet_payment,
            satoshis: 1000,
            payment_remittance: {
              derivation_prefix: 'prefix123',
              derivation_suffix: 'suffix456',
              sender_identity_key: 'sender_pubkey_hex'
            }
          }
        ]
      )

      expect(result).to eq({ accepted: true })
    end

    it 'validates description' do
      expect {
        engine.internalize_action(tx: "\x00".b, description: 'hi', outputs: [])
      }.to raise_error(BSV::Wallet::InvalidParameterError)
    end
  end

  describe '#list_outputs' do
    before do
      engine.create_action(
        description: 'create outputs', no_send: true,
        outputs: [
          { satoshis: 500, locking_script: SecureRandom.random_bytes(25),
            output_description: 'first', basket: 'wallet', tags: ['payment'] },
          { satoshis: 300, locking_script: SecureRandom.random_bytes(25),
            output_description: 'second', basket: 'wallet', tags: ['change'] },
          { satoshis: 100, locking_script: SecureRandom.random_bytes(25),
            output_description: 'third', basket: 'other' }
        ]
      )
    end

    it 'filters by basket' do
      result = engine.list_outputs(basket: 'wallet')
      expect(result[:total_outputs]).to eq(2)
    end

    it 'filters by tag' do
      result = engine.list_outputs(basket: 'wallet', tags: ['payment'])
      expect(result[:total_outputs]).to eq(1)
    end

    it 'paginates' do
      result = engine.list_outputs(basket: 'wallet', limit: 1)
      expect(result[:outputs].size).to eq(1)
      expect(result[:total_outputs]).to eq(2)
    end
  end

  describe '#relinquish_output' do
    it 'removes output from tracking' do
      engine.create_action(
        description: 'with output', no_send: true,
        outputs: [
          { satoshis: 500, locking_script: SecureRandom.random_bytes(25),
            output_description: 'to relinquish', basket: 'wallet' }
        ]
      )

      listed = engine.list_outputs(basket: 'wallet')
      output_id = listed[:outputs].first[:id]

      result = engine.relinquish_output(basket: 'wallet', output: output_id)
      expect(result).to eq({ relinquished: true })

      listed_after = engine.list_outputs(basket: 'wallet')
      expect(listed_after[:total_outputs]).to eq(0)
    end
  end

  describe '#network' do
    it 'returns the configured network' do
      expect(engine.network).to eq({ network: :mainnet })
    end
  end

  describe '#version' do
    it 'returns the wallet version' do
      result = engine.version
      expect(result[:version]).to start_with('bsv-wallet-')
    end
  end
end
