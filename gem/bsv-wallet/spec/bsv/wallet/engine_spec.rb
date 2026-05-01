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
      engine.create_action(
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
      expect do
        engine.create_action(description: 'hi', outputs: [{ satoshis: 1, output_description: 'x' }])
      end.to raise_error(BSV::Wallet::InvalidParameterError)
    end

    it 'validates at least one input or output' do
      expect do
        engine.create_action(description: 'no inputs or outputs')
      end.to raise_error(BSV::Wallet::InvalidParameterError)
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
      expect do
        engine.sign_action(spends: {}, reference: 'nonexistent')
      end.to raise_error(BSV::Wallet::InvalidParameterError)
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
      expect do
        engine.abort_action(reference: 'nonexistent')
      end.to raise_error(BSV::Wallet::InvalidParameterError)
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
      expect do
        engine.internalize_action(tx: "\x00".b, description: 'hi', outputs: [])
      end.to raise_error(BSV::Wallet::InvalidParameterError)
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

  # Real KeyDeriver for end-to-end crypto tests
  let(:root_key) { BSV::Primitives::PrivateKey.generate }
  let(:privileged_key) { BSV::Primitives::PrivateKey.generate }
  let(:key_deriver) { BSV::Wallet::KeyDeriver.new(private_key: root_key) }
  let(:counterparty_key) { BSV::Primitives::PrivateKey.generate }
  let(:counterparty_hex) { counterparty_key.public_key.to_hex }
  let(:verifier_key) { BSV::Primitives::PrivateKey.generate }
  let(:verifier_hex) { verifier_key.public_key.to_hex }

  let(:engine_with_keys) do
    described_class.new(
      store: store, utxo_pool: utxo_pool,
      broadcast_queue: broadcast_queue, proof_store: proof_store,
      key_deriver: key_deriver, network: :mainnet
    )
  end

  let(:engine_with_privileged_keys) do
    priv_deriver = BSV::Wallet::KeyDeriver.new(private_key: root_key, privileged_key: privileged_key)
    described_class.new(
      store: store, utxo_pool: utxo_pool,
      broadcast_queue: broadcast_queue, proof_store: proof_store,
      key_deriver: priv_deriver, network: :mainnet
    )
  end

  describe '#public_key' do
    it 'returns the identity key when identity_key: true' do
      result = engine_with_keys.public_key(identity_key: true)
      expect(result[:public_key]).to be_a(String)
      expect(result[:public_key].length).to eq(66)
      expect(result[:public_key]).to match(/\A(?:02|03)[0-9a-f]{64}\z/)
      expect(result[:public_key]).to eq(root_key.public_key.to_hex)
    end

    it 'derives a public key with protocol_id and key_id' do
      result = engine_with_keys.public_key(
        protocol_id: [1, 'test proto'], key_id: 'key1', counterparty: 'self'
      )
      expect(result[:public_key]).to be_a(String)
      expect(result[:public_key].bytesize).to eq(33)

      # Verify determinism — same params yield same key
      result2 = engine_with_keys.public_key(
        protocol_id: [1, 'test proto'], key_id: 'key1', counterparty: 'self'
      )
      expect(result2[:public_key]).to eq(result[:public_key])
    end

    it 'raises without key_deriver' do
      expect { engine.public_key(identity_key: true) }
        .to raise_error(BSV::Wallet::Error, /key deriver/)
    end
  end

  describe '#reveal_counterparty_key_linkage' do
    it 'returns revelation with encrypted linkage and proof' do
      result = engine_with_keys.reveal_counterparty_key_linkage(
        counterparty: counterparty_hex,
        verifier: verifier_hex
      )
      expect(result).to include(:prover, :verifier, :counterparty,
                                :revelation_time, :encrypted_linkage, :encrypted_linkage_proof)
      expect(result[:prover]).to eq(root_key.public_key.to_hex)
      expect(result[:verifier]).to eq(verifier_hex)
      expect(result[:counterparty]).to eq(counterparty_hex)
      expect(result[:encrypted_linkage]).to be_a(String)
      expect(result[:encrypted_linkage_proof]).to be_a(String)
    end
  end

  describe '#reveal_specific_key_linkage' do
    it 'returns revelation with encrypted linkage and proof_type' do
      result = engine_with_keys.reveal_specific_key_linkage(
        counterparty: counterparty_hex,
        verifier: verifier_hex,
        protocol_id: [1, 'test proto'], key_id: 'key1'
      )
      expect(result).to include(:prover, :encrypted_linkage, :encrypted_linkage_proof, :proof_type)
      expect(result[:prover]).to eq(root_key.public_key.to_hex)
      expect(result[:proof_type]).to eq(0)
    end
  end

  describe '#encrypt / #decrypt' do
    let(:plaintext) { 'hello world'.b }

    it 'encrypts data to ciphertext different from plaintext' do
      result = engine_with_keys.encrypt(
        plaintext: plaintext,
        protocol_id: [1, 'encryption test'], key_id: 'enc1'
      )
      expect(result[:ciphertext]).to be_a(String)
      expect(result[:ciphertext]).not_to eq(plaintext)
    end

    it 'round-trips encrypt then decrypt' do
      encrypted = engine_with_keys.encrypt(
        plaintext: plaintext,
        protocol_id: [1, 'encryption test'], key_id: 'enc1'
      )
      decrypted = engine_with_keys.decrypt(
        ciphertext: encrypted[:ciphertext],
        protocol_id: [1, 'encryption test'], key_id: 'enc1'
      )
      expect(decrypted[:plaintext]).to eq(plaintext)
    end

    it 'raises without key_deriver' do
      expect do
        engine.encrypt(plaintext: 'data'.b, protocol_id: [1, 'test proto'], key_id: 'k')
      end.to raise_error(BSV::Wallet::Error, /key deriver/)
    end
  end

  describe '#create_hmac / #verify_hmac' do
    it 'creates a 32-byte HMAC' do
      result = engine_with_keys.create_hmac(
        data: 'test data'.b, protocol_id: [1, 'hmac test proto'], key_id: 'h1'
      )
      expect(result[:hmac]).to be_a(String)
      expect(result[:hmac].bytesize).to eq(32)
    end

    it 'round-trips create then verify' do
      created = engine_with_keys.create_hmac(
        data: 'test data'.b, protocol_id: [1, 'hmac test proto'], key_id: 'h1'
      )
      result = engine_with_keys.verify_hmac(
        data: 'test data'.b, hmac: created[:hmac],
        protocol_id: [1, 'hmac test proto'], key_id: 'h1'
      )
      expect(result).to eq({ valid: true })
    end

    it 'raises InvalidHmacError for wrong HMAC' do
      expect do
        engine_with_keys.verify_hmac(
          data: 'test data'.b, hmac: SecureRandom.random_bytes(32),
          protocol_id: [1, 'hmac test proto'], key_id: 'h1'
        )
      end.to raise_error(BSV::Wallet::InvalidHmacError)
    end
  end

  describe '#create_signature / #verify_signature' do
    it 'creates a signature object' do
      result = engine_with_keys.create_signature(
        data: 'sign me'.b, protocol_id: [1, 'sig test proto'], key_id: 's1'
      )
      expect(result[:signature]).to be_a(BSV::Primitives::Signature)
    end

    it 'round-trips create then verify' do
      created = engine_with_keys.create_signature(
        data: 'sign me'.b, protocol_id: [1, 'sig test proto'], key_id: 's1'
      )
      result = engine_with_keys.verify_signature(
        signature: created[:signature], data: 'sign me'.b,
        protocol_id: [1, 'sig test proto'], key_id: 's1'
      )
      expect(result).to eq({ valid: true })
    end

    it 'raises InvalidSignatureError for wrong data' do
      created = engine_with_keys.create_signature(
        data: 'sign me'.b, protocol_id: [1, 'sig test proto'], key_id: 's1'
      )

      expect do
        engine_with_keys.verify_signature(
          signature: created[:signature], data: 'wrong data'.b,
          protocol_id: [1, 'sig test proto'], key_id: 's1'
        )
      end.to raise_error(BSV::Wallet::InvalidSignatureError)
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
      expect do
        engine_with_keys.acquire_certificate(
          type: 'identity', certifier: 'c1',
          acquisition_protocol: :issuance,
          fields: {}, certifier_url: 'https://cert.example.com'
        )
      end.to raise_error(BSV::Wallet::UnsupportedActionError)
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
      certifier_deriver = BSV::Wallet::KeyDeriver.new(private_key: counterparty_key)
      cert_type = 'id'
      serial = 'sn1'

      # Certifier encrypts field keys for the subject (BRC-52)
      encrypt_protocol = [2, "authrite certificate field encryption #{cert_type}"]
      keyring = {
        'name' => certifier_deriver.encrypt(
          plaintext: SecureRandom.random_bytes(32),
          protocol_id: encrypt_protocol,
          key_id: "#{serial} name",
          counterparty: key_deriver.identity_key
        )
      }

      # Build certificate hash with keyring (prove_certificate operates on
      # the in-memory hash, not the DB record)
      cert = {
        type: cert_type,
        serial_number: serial,
        certifier: counterparty_hex,
        subject: key_deriver.identity_key,
        fields: { 'name' => 'Alice' },
        keyring: keyring
      }

      result = engine_with_keys.prove_certificate(
        certificate: cert, fields_to_reveal: ['name'],
        verifier: verifier_hex
      )

      expect(result[:keyring_for_verifier]).to be_a(Hash)
      expect(result[:keyring_for_verifier]).to have_key('name')
      expect(result[:keyring_for_verifier]['name']).to be_a(String)
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

  describe 'privileged mode' do
    it 'derives a different public key with privileged: true' do
      normal = engine_with_privileged_keys.public_key(
        protocol_id: [1, 'test proto'], key_id: 'key1', counterparty: 'self'
      )
      privileged = engine_with_privileged_keys.public_key(
        protocol_id: [1, 'test proto'], key_id: 'key1', counterparty: 'self',
        privileged: true
      )
      expect(privileged[:public_key]).not_to eq(normal[:public_key])
    end

    it 'round-trips encrypt/decrypt with privileged: true' do
      plaintext = 'privileged secret'.b
      encrypted = engine_with_privileged_keys.encrypt(
        plaintext: plaintext,
        protocol_id: [1, 'priv encrypt test'], key_id: 'p1',
        privileged: true
      )
      decrypted = engine_with_privileged_keys.decrypt(
        ciphertext: encrypted[:ciphertext],
        protocol_id: [1, 'priv encrypt test'], key_id: 'p1',
        privileged: true
      )
      expect(decrypted[:plaintext]).to eq(plaintext)
    end

    it 'round-trips HMAC create/verify with privileged: true' do
      created = engine_with_privileged_keys.create_hmac(
        data: 'privileged data'.b, protocol_id: [1, 'priv hmac test'], key_id: 'p1',
        privileged: true
      )
      result = engine_with_privileged_keys.verify_hmac(
        data: 'privileged data'.b, hmac: created[:hmac],
        protocol_id: [1, 'priv hmac test'], key_id: 'p1',
        privileged: true
      )
      expect(result).to eq({ valid: true })
    end

    it 'round-trips signature create/verify with privileged: true' do
      created = engine_with_privileged_keys.create_signature(
        data: 'privileged data'.b, protocol_id: [1, 'priv sig test'], key_id: 'p1',
        privileged: true
      )
      result = engine_with_privileged_keys.verify_signature(
        signature: created[:signature], data: 'privileged data'.b,
        protocol_id: [1, 'priv sig test'], key_id: 'p1',
        privileged: true
      )
      expect(result).to eq({ valid: true })
    end

    it 'raises when privileged key is not configured' do
      expect do
        engine_with_keys.public_key(
          protocol_id: [1, 'test proto'], key_id: 'key1',
          counterparty: 'self', privileged: true
        )
      end.to raise_error(BSV::Wallet::Error, /privileged key/)
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
