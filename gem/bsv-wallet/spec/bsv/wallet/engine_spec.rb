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
  ENGINE_DB.extension :pg_json
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
    it 'raises for invalid reference' do
      expect do
        engine.sign_action(spends: {}, reference: 'nonexistent')
      end.to raise_error(BSV::Wallet::InvalidParameterError)
    end

    it 'completes a deferred signing flow with outputs only' do
      # Deferred action with outputs but no inputs
      create_result = engine.create_action(
        description: 'deferred outputs',
        sign_and_process: false,
        outputs: [
          { satoshis: 500, locking_script: SecureRandom.random_bytes(25),
            output_description: 'output' }
        ]
      )

      reference = create_result[:signable_transaction][:reference]

      # Sign with empty spends (no inputs to sign)
      result = engine.sign_action(
        spends: {},
        reference: reference,
        no_send: true
      )

      expect(result[:txid]).to be_a(String)
      expect(result[:txid].bytesize).to eq(32)
      expect(result[:tx]).to be_a(String)

      # Verify the transaction can be deserialized
      parsed = BSV::Transaction::Transaction.from_binary(result[:tx])
      expect(parsed.outputs.length).to eq(1)
      expect(parsed.outputs[0].satoshis).to eq(500)
    end
  end

  # --- apply_spends (deferred signing) (#24) ---

  describe '#apply_spends (private)' do
    # Helpers for building realistic test data
    def p2pkh_locking_script_for(private_key)
      pubkey_hash = BSV::Primitives::Digest.hash160(private_key.public_key.compressed)
      BSV::Script::Script.p2pkh_lock(pubkey_hash)
    end

    def derive_key(prefix: 'wallet payment', suffix: 'suffix1', counterparty: 'self')
      key_deriver.derive_private_key(
        protocol_id: [2, prefix], key_id: suffix, counterparty: counterparty
      )
    end

    # Fund the wallet with a real P2PKH output that can be signed
    def fund_wallet_with_keys(satoshis: 1000, count: 1,
                              prefix: 'wallet payment', suffix: 'suffix1',
                              sender_identity_key: nil)
      derived_key = key_deriver.derive_private_key(
        protocol_id: [2, prefix], key_id: suffix,
        counterparty: sender_identity_key || 'self'
      )
      script = p2pkh_locking_script_for(derived_key)

      # Create a source action with a txid (needed for input resolution)
      source_action = store.create_action(
        action: { description: 'funding source', broadcast: :none, outgoing: false }
      )
      # Set a real txid on the source action
      source_txid = SecureRandom.random_bytes(32)
      store.sign_action(action_id: source_action[:id], txid: source_txid, raw_tx: "\x00".b)

      outputs = count.times.map do |i|
        {
          satoshis: satoshis, vout: i,
          locking_script: script.to_binary,
          basket: 'default',
          derivation_prefix: prefix,
          derivation_suffix: i.zero? ? suffix : "#{suffix}-#{i}",
          sender_identity_key: sender_identity_key
        }
      end
      store.promote_action(action_id: source_action[:id], outputs: outputs)
    end

    context 'full deferred flow with P2PKH inputs' do
      it 'wallet signs all P2PKH inputs when spends is empty' do
        fund_wallet_with_keys(satoshis: 1000)
        output_script = p2pkh_locking_script_for(derive_key).to_binary

        # Get the funded output ID
        listed = engine_with_keys.list_outputs(basket: 'default')
        output_id = listed[:outputs].first[:id]

        # Create a deferred action with an input
        create_result = engine_with_keys.create_action(
          description: 'deferred p2pkh',
          sign_and_process: false,
          inputs: [{ output_id: output_id }],
          outputs: [{ satoshis: 900, locking_script: output_script }]
        )

        reference = create_result[:signable_transaction][:reference]

        # Sign with empty spends — wallet signs the P2PKH input
        result = engine_with_keys.sign_action(
          spends: {},
          reference: reference,
          no_send: true
        )

        expect(result[:txid]).to be_a(String)
        expect(result[:txid].bytesize).to eq(32)

        # Verify the transaction is valid
        parsed = BSV::Transaction::Transaction.from_binary(result[:tx])
        expect(parsed.inputs.length).to eq(1)
        expect(parsed.outputs.length).to eq(1)
        expect(parsed.outputs[0].satoshis).to eq(900)

        # Verify the txid matches
        expected_txid = BSV::Primitives::Digest.sha256d(result[:tx]).reverse
        expect(result[:txid]).to eq(expected_txid)
      end
    end

    context 'caller provides unlocking scripts for all inputs' do
      it 'applies caller scripts without wallet signing' do
        fund_wallet_with_keys(satoshis: 1000)
        output_script = SecureRandom.random_bytes(25)

        listed = engine.list_outputs(basket: 'default')
        output_id = listed[:outputs].first[:id]

        create_result = engine.create_action(
          description: 'deferred caller',
          sign_and_process: false,
          inputs: [{ output_id: output_id }],
          outputs: [{ satoshis: 900, locking_script: output_script }]
        )

        reference = create_result[:signable_transaction][:reference]
        custom_unlock = "\x01\x02\x03".b

        # Caller provides unlocking script for input 0
        result = engine.sign_action(
          spends: { 0 => { unlocking_script: custom_unlock } },
          reference: reference,
          no_send: true
        )

        expect(result[:txid]).to be_a(String)
        expect(result[:txid].bytesize).to eq(32)

        parsed = BSV::Transaction::Transaction.from_binary(result[:tx])
        expect(parsed.inputs[0].unlocking_script.to_binary).to eq(custom_unlock)
      end
    end

    context 'mixed signing' do
      it 'applies caller scripts for some inputs, wallet signs the rest' do
        # Fund with two outputs
        fund_wallet_with_keys(satoshis: 1000, count: 2)
        output_script = SecureRandom.random_bytes(25)

        listed = engine_with_keys.list_outputs(basket: 'default')
        output_ids = listed[:outputs].map { |o| o[:id] }

        create_result = engine_with_keys.create_action(
          description: 'deferred mixed',
          sign_and_process: false,
          inputs: output_ids.each_with_index.map { |id, i| { output_id: id, vin: i } },
          outputs: [{ satoshis: 1800, locking_script: output_script }]
        )

        reference = create_result[:signable_transaction][:reference]
        custom_unlock = "\x04\x05\x06".b

        # Caller provides script for input 0, wallet signs input 1
        result = engine_with_keys.sign_action(
          spends: { 0 => { unlocking_script: custom_unlock } },
          reference: reference,
          no_send: true
        )

        expect(result[:txid]).to be_a(String)
        expect(result[:txid].bytesize).to eq(32)

        parsed = BSV::Transaction::Transaction.from_binary(result[:tx])
        expect(parsed.inputs.length).to eq(2)
        # Input 0: caller-provided
        expect(parsed.inputs[0].unlocking_script.to_binary).to eq(custom_unlock)
        # Input 1: wallet-signed (has an unlocking script)
        expect(parsed.inputs[1].unlocking_script).not_to be_nil
      end
    end

    context 'invalid input reference' do
      it 'raises for non-existent vin in spends' do
        create_result = engine.create_action(
          description: 'deferred invalid',
          sign_and_process: false,
          outputs: [{ satoshis: 500, locking_script: SecureRandom.random_bytes(25) }]
        )

        reference = create_result[:signable_transaction][:reference]

        expect do
          engine.sign_action(
            spends: { 99 => { unlocking_script: "\x00".b } },
            reference: reference,
            no_send: true
          )
        end.to raise_error(BSV::Wallet::InvalidParameterError, /vin 99/)
      end
    end

    context 'pending outputs' do
      it 'clears pending outputs after signing' do
        create_result = engine.create_action(
          description: 'deferred clear',
          sign_and_process: false,
          outputs: [{ satoshis: 500, locking_script: SecureRandom.random_bytes(25) }]
        )

        action = store.find_action(reference: create_result[:signable_transaction][:reference])

        # Verify pending outputs exist before signing
        pending = store.get_pending_outputs(action_id: action[:id])
        expect(pending).not_to be_nil
        expect(pending.length).to eq(1)
        expect(pending[0][:satoshis]).to eq(500)

        # Sign
        engine.sign_action(
          spends: {},
          reference: create_result[:signable_transaction][:reference],
          no_send: true
        )

        # Verify pending outputs are cleared
        pending_after = store.get_pending_outputs(action_id: action[:id])
        expect(pending_after).to be_nil
      end

      it 'preserves locking scripts through serialization round-trip' do
        binary_script = "\x76\xa9\x14".b + ("\x00" * 20).b + "\x88\xac".b
        create_result = engine.create_action(
          description: 'deferred script',
          sign_and_process: false,
          outputs: [{ satoshis: 500, locking_script: binary_script }]
        )

        action = store.find_action(reference: create_result[:signable_transaction][:reference])
        pending = store.get_pending_outputs(action_id: action[:id])
        expect(pending[0][:locking_script]).to eq(binary_script)
      end
    end

    context 'sequence number override' do
      it 'applies sequence number from spends' do
        fund_wallet_with_keys(satoshis: 1000)
        output_script = SecureRandom.random_bytes(25)

        listed = engine.list_outputs(basket: 'default')
        output_id = listed[:outputs].first[:id]

        create_result = engine.create_action(
          description: 'deferred seqnum',
          sign_and_process: false,
          inputs: [{ output_id: output_id }],
          outputs: [{ satoshis: 900, locking_script: output_script }]
        )

        reference = create_result[:signable_transaction][:reference]

        result = engine.sign_action(
          spends: { 0 => { unlocking_script: "\x01".b, sequence_number: 42 } },
          reference: reference,
          no_send: true
        )

        parsed = BSV::Transaction::Transaction.from_binary(result[:tx])
        expect(parsed.inputs[0].sequence).to eq(42)
      end
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

  # --- Output Construction and Randomization (#21) ---

  describe '#build_outputs (private)' do
    # Access the private method for direct testing
    def build_outputs(outputs, randomize)
      engine.send(:build_outputs, outputs, randomize)
    end

    def resolve_locking_script(data)
      engine.send(:resolve_locking_script, data)
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
      script_bytes = "\x76\xa9\x14".b + ("\x00" * 20).b + "\x88\xac".b  # P2PKH pattern
      outputs = [
        { satoshis: 1000, locking_script: script_bytes },
        { satoshis: 2000, locking_script: "\x6a\x05hello".b }  # OP_RETURN
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
      hex_script = '76a914' + '00' * 20 + '88ac'
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
      op_return_script = "\x00\x6a\x05hello".b  # OP_FALSE OP_RETURN <data>
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
          { satoshis: (i + 1) * 100, locking_script: SecureRandom.random_bytes(25) }
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
          { satoshis: (i + 1) * 100, locking_script: SecureRandom.random_bytes(25) }
        end

        tx_outputs, _vout_mapping = build_outputs(outputs, true)

        expect(tx_outputs.map(&:satoshis).sort).to eq([100, 200, 300, 400, 500])
      end

      it 'produces correct vout mapping' do
        outputs = 5.times.map do |i|
          { satoshis: (i + 1) * 100, locking_script: SecureRandom.random_bytes(25) }
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
        outputs = [{ satoshis: 1000, locking_script: SecureRandom.random_bytes(25) }]

        tx_outputs, vout_mapping = build_outputs(outputs, true)

        expect(tx_outputs.length).to eq(1)
        expect(tx_outputs[0].satoshis).to eq(1000)
        expect(vout_mapping).to eq({ 0 => 0 })
      end
    end
  end

  # --- Input Resolution and P2PKH Signing (#22) ---

  describe '#build_inputs (private)' do
    # Use engine_with_keys for key derivation
    def build_inputs(resolved_inputs, caller_inputs)
      engine_with_keys.send(:build_inputs, resolved_inputs, caller_inputs)
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
                 SecureRandom.random_bytes(25)
               end

      {
        vin: vin,
        sequence: 0xFFFFFFFF,
        source_txid: SecureRandom.random_bytes(32),
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
      source_txid = SecureRandom.random_bytes(32)
      # Derive the key the same way the engine will
      derived_key = key_deriver.derive_private_key(
        protocol_id: [2, 'wallet payment'], key_id: 'suffix1', counterparty: 'self'
      )
      resolved = [make_resolved_input(vin: 0, private_key: derived_key).merge(source_txid: source_txid, source_vout: 2)]

      tx_inputs, _signing_keys = build_inputs(resolved, nil)

      expect(tx_inputs.length).to eq(1)
      expect(tx_inputs[0]).to be_a(BSV::Transaction::TransactionInput)
      expect(tx_inputs[0].prev_tx_id).to eq(source_txid)
      expect(tx_inputs[0].prev_tx_out_index).to eq(2)
      expect(tx_inputs[0].sequence).to eq(0xFFFFFFFF)
    end

    it 'sets source_satoshis and source_locking_script for sighash' do
      derived_key = key_deriver.derive_private_key(
        protocol_id: [2, 'wallet payment'], key_id: 'suffix1', counterparty: 'self'
      )
      script = p2pkh_locking_script_for(derived_key)
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
      tx = BSV::Transaction::Transaction.new
      tx.add_input(tx_inputs[0])
      tx.add_output(BSV::Transaction::TransactionOutput.new(satoshis: 900, locking_script: script))

      # Sign with the derived key
      tx.sign(0, signing_keys[0])

      expect(tx_inputs[0].unlocking_script).not_to be_nil
      expect(tx.verify_input(0)).to be true
    end

    it 'applies caller-provided unlocking script for custom inputs' do
      custom_unlock = "\x01\x02\x03".b
      custom_lock = "\x04\x05\x06".b  # Non-P2PKH locking script
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
      custom_lock = "\x04\x05\x06".b  # Non-P2PKH
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
        engine.send(:build_inputs, resolved, nil)
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
        source_txid: SecureRandom.random_bytes(32),
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
      engine_with_keys.send(:build_transaction, action_id, inputs, outputs, lock_time, version, randomize)
    end

    it 'assembles a transaction and returns txid, raw_tx, and vout_mapping' do
      txid, raw_tx, vout_mapping = build_transaction(1, nil, caller_outputs, nil, nil, false)

      expect(txid).to be_a(String)
      expect(txid.bytesize).to eq(32)
      expect(raw_tx).to be_a(String)
      expect(raw_tx.bytesize).to be > 10
      expect(vout_mapping).to eq({ 0 => 0 })
    end

    it 'produces a txid that is the double-SHA-256 of serialized tx (display order)' do
      txid, raw_tx, _vout_mapping = build_transaction(1, nil, caller_outputs, nil, nil, false)

      expected_txid = BSV::Primitives::Digest.sha256d(raw_tx).reverse
      expect(txid).to eq(expected_txid)
    end

    it 'produces a serialized tx that can be deserialized back' do
      _txid, raw_tx, _vout_mapping = build_transaction(1, nil, caller_outputs, nil, nil, false)

      parsed = BSV::Transaction::Transaction.from_binary(raw_tx)
      expect(parsed.inputs.length).to eq(1)
      expect(parsed.outputs.length).to eq(1)
      expect(parsed.outputs[0].satoshis).to eq(900)
    end

    it 'round-trips: serialize -> deserialize -> re-serialize produces identical bytes' do
      _txid, raw_tx, _vout_mapping = build_transaction(1, nil, caller_outputs, nil, nil, false)

      parsed = BSV::Transaction::Transaction.from_binary(raw_tx)
      expect(parsed.to_binary).to eq(raw_tx)
    end

    it 'sets version and lock_time correctly' do
      _txid, raw_tx, _vout_mapping = build_transaction(1, nil, caller_outputs, 500, 2, false)

      parsed = BSV::Transaction::Transaction.from_binary(raw_tx)
      expect(parsed.version).to eq(2)
      expect(parsed.lock_time).to eq(500)
    end

    it 'defaults version to 1 and lock_time to 0' do
      _txid, raw_tx, _vout_mapping = build_transaction(1, nil, caller_outputs, nil, nil, false)

      parsed = BSV::Transaction::Transaction.from_binary(raw_tx)
      expect(parsed.version).to eq(1)
      expect(parsed.lock_time).to eq(0)
    end

    it 'signs P2PKH inputs that pass verify_input' do
      txid, raw_tx, _vout_mapping = build_transaction(1, nil, caller_outputs, nil, nil, false)

      # Reconstruct the transaction with source data for verification
      parsed = BSV::Transaction::Transaction.from_binary(raw_tx)
      parsed.inputs[0].source_satoshis = resolved_inputs[0][:source_satoshis]
      parsed.inputs[0].source_locking_script = BSV::Script::Script.from_binary(
        resolved_inputs[0][:source_locking_script]
      )

      expect(parsed.inputs[0].unlocking_script).not_to be_nil
      expect(parsed.verify_input(0)).to be true
    end

    it 'handles outputs-only transaction (no inputs)' do
      allow(store).to receive(:resolve_inputs_for_signing).and_return([])

      txid, raw_tx, vout_mapping = build_transaction(1, nil, caller_outputs, nil, nil, false)

      parsed = BSV::Transaction::Transaction.from_binary(raw_tx)
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

      txid, raw_tx, vout_mapping = build_transaction(1, nil, multi_outputs, nil, nil, false)

      parsed = BSV::Transaction::Transaction.from_binary(raw_tx)
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
end
