# frozen_string_literal: true

require 'securerandom'

# Engine integration tests require PostgreSQL.
# Skip gracefully when the database is unavailable (e.g. CI for the core gem).
begin
  require 'sequel'
  require 'bsv-wallet-postgres'

  TEST_DB_URL = ENV.fetch('DATABASE_URL', 'postgres://postgres:postgres@localhost:5433/bsv_wallet_test')
  ENGINE_DB = Sequel.connect(TEST_DB_URL)
  ENGINE_DB.extension :pg_enum
  ENGINE_DB.extension :pg_array
  Sequel.extension :migration
  migrations_path = File.expand_path('../../../../bsv-wallet-postgres/db/migrations', __dir__)
  Sequel::Migrator.run(ENGINE_DB, migrations_path)
  BSV::Wallet::Postgres.connect(ENGINE_DB)
  POSTGRES_AVAILABLE = true
rescue LoadError, Sequel::DatabaseConnectionError => e
  warn "Skipping engine integration specs: #{e.message}"
  POSTGRES_AVAILABLE = false
end

RSpec.describe BSV::Wallet::Engine, if: POSTGRES_AVAILABLE do
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

  # --- Key Management, Crypto, Certificates, Auth, Network (HLR #5) ---

  # Mock key deriver for crypto tests
  let(:mock_identity_key) { '02' + SecureRandom.hex(32) }
  let(:mock_derived_public_key) { SecureRandom.random_bytes(33) }
  let(:mock_ciphertext) { SecureRandom.random_bytes(48) }
  let(:mock_plaintext) { 'hello world'.b }
  let(:mock_hmac_value) { SecureRandom.random_bytes(32) }
  let(:mock_signature_value) { SecureRandom.random_bytes(72) }

  let(:key_deriver) do
    deriver = double('KeyDeriver')
    allow(deriver).to receive(:identity_key).and_return(mock_identity_key)
    allow(deriver).to receive(:derive_public_key).and_return(mock_derived_public_key)
    allow(deriver).to receive(:encrypt).and_return(mock_ciphertext)
    allow(deriver).to receive(:decrypt).and_return(mock_plaintext)
    allow(deriver).to receive(:create_hmac).and_return(mock_hmac_value)
    allow(deriver).to receive(:create_signature).and_return(mock_signature_value)
    allow(deriver).to receive(:verify_signature).and_return(true)
    allow(deriver).to receive(:reveal_counterparty_linkage).and_return({
      prover: mock_identity_key, verifier: SecureRandom.random_bytes(33),
      counterparty: SecureRandom.random_bytes(33),
      revelation_time: Time.now.iso8601,
      encrypted_linkage: SecureRandom.random_bytes(32),
      encrypted_linkage_proof: SecureRandom.random_bytes(32)
    })
    allow(deriver).to receive(:reveal_specific_linkage).and_return({
      prover: mock_identity_key, verifier: SecureRandom.random_bytes(33),
      counterparty: SecureRandom.random_bytes(33),
      encrypted_linkage: SecureRandom.random_bytes(32),
      encrypted_linkage_proof: SecureRandom.random_bytes(32),
      proof_type: 0
    })
    allow(deriver).to receive(:derive_revelation_keyring).and_return({
      'name' => SecureRandom.random_bytes(32),
      'email' => SecureRandom.random_bytes(32)
    })
    deriver
  end

  let(:engine_with_keys) do
    described_class.new(
      store: store, utxo_pool: utxo_pool,
      broadcast_queue: broadcast_queue, proof_store: proof_store,
      key_deriver: key_deriver, network: :mainnet
    )
  end

  describe '#public_key' do
    it 'returns the identity key when identity_key: true' do
      result = engine_with_keys.public_key(identity_key: true)
      expect(result[:public_key]).to eq(mock_identity_key)
    end

    it 'derives a public key with protocol_id and key_id' do
      result = engine_with_keys.public_key(
        protocol_id: [1, 'test protocol'], key_id: 'key1', counterparty: 'self'
      )
      expect(result[:public_key]).to eq(mock_derived_public_key)
      expect(key_deriver).to have_received(:derive_public_key).with(
        protocol_id: [1, 'test protocol'], key_id: 'key1',
        counterparty: 'self', for_self: false, privileged: false
      )
    end

    it 'raises without key_deriver' do
      expect { engine.public_key(identity_key: true) }
        .to raise_error(BSV::Wallet::Error, /key deriver/)
    end
  end

  describe '#reveal_counterparty_key_linkage' do
    it 'delegates to key_deriver' do
      result = engine_with_keys.reveal_counterparty_key_linkage(
        counterparty: SecureRandom.random_bytes(33),
        verifier: SecureRandom.random_bytes(33)
      )
      expect(result).to include(:prover, :verifier, :counterparty)
    end
  end

  describe '#reveal_specific_key_linkage' do
    it 'delegates to key_deriver' do
      result = engine_with_keys.reveal_specific_key_linkage(
        counterparty: SecureRandom.random_bytes(33),
        verifier: SecureRandom.random_bytes(33),
        protocol_id: [1, 'test protocol'], key_id: 'key1'
      )
      expect(result).to include(:prover, :encrypted_linkage)
    end
  end

  describe '#encrypt / #decrypt' do
    it 'encrypts data' do
      result = engine_with_keys.encrypt(
        plaintext: mock_plaintext,
        protocol_id: [1, 'encryption test'], key_id: 'enc1'
      )
      expect(result[:ciphertext]).to eq(mock_ciphertext)
    end

    it 'decrypts data' do
      result = engine_with_keys.decrypt(
        ciphertext: mock_ciphertext,
        protocol_id: [1, 'encryption test'], key_id: 'enc1'
      )
      expect(result[:plaintext]).to eq(mock_plaintext)
    end

    it 'raises without key_deriver' do
      expect {
        engine.encrypt(plaintext: 'data'.b, protocol_id: [1, 'test proto'], key_id: 'k')
      }.to raise_error(BSV::Wallet::Error, /key deriver/)
    end
  end

  describe '#create_hmac / #verify_hmac' do
    it 'creates an HMAC' do
      result = engine_with_keys.create_hmac(
        data: 'test data'.b, protocol_id: [1, 'hmac test proto'], key_id: 'h1'
      )
      expect(result[:hmac]).to eq(mock_hmac_value)
    end

    it 'verifies a valid HMAC' do
      result = engine_with_keys.verify_hmac(
        data: 'test data'.b, hmac: mock_hmac_value,
        protocol_id: [1, 'hmac test proto'], key_id: 'h1'
      )
      expect(result).to eq({ valid: true })
    end

    it 'raises InvalidHmacError for wrong HMAC' do
      expect {
        engine_with_keys.verify_hmac(
          data: 'test data'.b, hmac: SecureRandom.random_bytes(32),
          protocol_id: [1, 'hmac test proto'], key_id: 'h1'
        )
      }.to raise_error(BSV::Wallet::InvalidHmacError)
    end
  end

  describe '#create_signature / #verify_signature' do
    it 'creates a signature' do
      result = engine_with_keys.create_signature(
        data: 'sign me'.b, protocol_id: [1, 'sig test proto'], key_id: 's1'
      )
      expect(result[:signature]).to eq(mock_signature_value)
    end

    it 'verifies a valid signature' do
      result = engine_with_keys.verify_signature(
        signature: mock_signature_value, data: 'sign me'.b,
        protocol_id: [1, 'sig test proto'], key_id: 's1'
      )
      expect(result).to eq({ valid: true })
    end

    it 'raises InvalidSignatureError for invalid signature' do
      allow(key_deriver).to receive(:verify_signature).and_return(false)

      expect {
        engine_with_keys.verify_signature(
          signature: 'bad'.b, data: 'sign me'.b,
          protocol_id: [1, 'sig test proto'], key_id: 's1'
        )
      }.to raise_error(BSV::Wallet::InvalidSignatureError)
    end
  end

  describe '#acquire_certificate' do
    it 'acquires a certificate directly' do
      result = engine_with_keys.acquire_certificate(
        type: 'identity', certifier: 'certifier_key',
        acquisition_protocol: :direct,
        fields: { 'name' => 'Alice', 'email' => 'alice@test.com' },
        serial_number: 'sn001', signature: 'sig_hex'
      )

      expect(result[:id]).to be_a(Integer)
      expect(result[:fields]).to eq({ 'name' => 'Alice', 'email' => 'alice@test.com' })
    end

    it 'raises for issuance protocol (not yet supported)' do
      expect {
        engine_with_keys.acquire_certificate(
          type: 'identity', certifier: 'c1',
          acquisition_protocol: :issuance,
          fields: {}, certifier_url: 'https://cert.example.com'
        )
      }.to raise_error(BSV::Wallet::UnsupportedActionError)
    end
  end

  describe '#list_certificates' do
    before do
      engine_with_keys.acquire_certificate(
        type: 'id', certifier: 'c1', acquisition_protocol: :direct,
        fields: { 'name' => 'Alice' }, serial_number: 'sn1', signature: 's1'
      )
      engine_with_keys.acquire_certificate(
        type: 'id', certifier: 'c2', acquisition_protocol: :direct,
        fields: { 'name' => 'Bob' }, serial_number: 'sn2', signature: 's2'
      )
    end

    it 'lists certificates filtered by certifier and type' do
      result = engine_with_keys.list_certificates(certifiers: ['c1'], types: ['id'])
      expect(result[:total_certificates]).to eq(1)
      expect(result[:certificates].first[:fields]['name']).to eq('Alice')
    end
  end

  describe '#prove_certificate' do
    it 'derives revelation keyring for the verifier' do
      cert = engine_with_keys.acquire_certificate(
        type: 'id', certifier: 'c1', acquisition_protocol: :direct,
        fields: { 'name' => 'Alice', 'email' => 'alice@test.com' },
        serial_number: 'sn1', signature: 's1'
      )

      result = engine_with_keys.prove_certificate(
        certificate: cert, fields_to_reveal: ['name'],
        verifier: SecureRandom.random_bytes(33)
      )

      expect(result[:keyring_for_verifier]).to be_a(Hash)
    end
  end

  describe '#relinquish_certificate' do
    it 'soft-deletes a certificate' do
      engine_with_keys.acquire_certificate(
        type: 'id', certifier: 'c1', acquisition_protocol: :direct,
        fields: { 'name' => 'Alice' }, serial_number: 'sn1', signature: 's1'
      )

      result = engine_with_keys.relinquish_certificate(
        type: 'id', serial_number: 'sn1', certifier: 'c1'
      )
      expect(result).to eq({ relinquished: true })

      listed = engine_with_keys.list_certificates(certifiers: ['c1'], types: ['id'])
      expect(listed[:total_certificates]).to eq(0)
    end
  end

  describe '#authenticated?' do
    it 'returns true with key_deriver' do
      expect(engine_with_keys.authenticated?).to eq({ authenticated: true })
    end

    it 'returns false without key_deriver' do
      expect(engine.authenticated?).to eq({ authenticated: false })
    end
  end

  describe '#wait_for_authentication' do
    it 'returns immediately when authenticated' do
      expect(engine_with_keys.wait_for_authentication).to eq({ authenticated: true })
    end

    it 'raises when not authenticated' do
      expect { engine.wait_for_authentication }.to raise_error(BSV::Wallet::Error)
    end
  end

  describe '#height' do
    it 'raises UnsupportedActionError (chain data source not configured)' do
      expect { engine.height }.to raise_error(BSV::Wallet::UnsupportedActionError)
    end
  end

  describe '#header_for_height' do
    it 'raises UnsupportedActionError (chain data source not configured)' do
      expect { engine.header_for_height(height: 1) }.to raise_error(BSV::Wallet::UnsupportedActionError)
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
