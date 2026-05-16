# frozen_string_literal: true

require 'securerandom'

# Shared setup for engine specs. Provides database connection, component
# lets, transaction rollback, funding helpers, and common constants.
#
# Usage:
#   RSpec.describe BSV::Wallet::Engine, if: POSTGRES_AVAILABLE do
#     include_context 'engine setup'
#     ...
#   end

# Database connection — shared across all engine spec files.
# Guard against double-definition when multiple files are loaded.
unless defined?(POSTGRES_AVAILABLE)
  begin
    require 'sequel'
    require 'bsv-wallet-postgres'

    TEST_DB_URL = ENV.fetch('DATABASE_URL', 'postgres://postgres:postgres@localhost:5433/bsv_wallet_test')
    ENGINE_DB = Sequel.connect(TEST_DB_URL)
    ENGINE_DB.extension :pg_enum
    ENGINE_DB.extension :pg_array
    ENGINE_DB.extension :pg_json
    Sequel.extension :migration
    migrations_path = File.expand_path('../../../../../bsv-wallet-postgres/db/migrations', __dir__)
    Sequel::Migrator.run(ENGINE_DB, migrations_path)
    BSV::Wallet::Postgres::Store::Connection.connect(ENGINE_DB)
    POSTGRES_AVAILABLE = true
  rescue LoadError, Sequel::DatabaseConnectionError => e
    warn "Skipping engine integration specs: #{e.message}"
    POSTGRES_AVAILABLE = false
  end
end

# Constants at top level so they're accessible as bare constants in specs.
OP_TRUE = "\x51".b.freeze unless defined?(OP_TRUE)
unless defined?(DUMMY_RAW_TX)
  DUMMY_RAW_TX = ['01000000016ce7229f014164e254aad172b1f8b40d496942ad7e323b47e0424c2b2e2e3772010000006a47' \
                  '30440220463fcf8f57a61c4f8ede208773db8732bf3a0757d929a8cbbe29bf4905fe5ef6022005d74398fa' \
                  'f5b24912821836171af44f55f89858f3edf92863cde4823da11d4641210362f5fb9274834bb0cd0376a8d5' \
                  'd02bdbf459a37a62c5baef3fb06d1159b55597ffffffff01f0991600000000001976a9141f36a49fcf6ada' \
                  '1f74f82377b33b17b68f7a016188acd3740e00'].pack('H*').freeze
end

RSpec.shared_context 'engine setup' do
  subject(:engine) do
    described_class.new(
      store: store,
      utxo_pool: utxo_pool,
      broadcast_queue: broadcast_queue,
      proof_store: proof_store,
      network: :mainnet
    )
  end

  let(:store) { BSV::Wallet::Postgres::Store::Postgres.new }
  let(:engine_with_privileged_keys) do
    priv_deriver = BSV::Wallet::KeyDeriver.new(private_key: root_key, privileged_key: privileged_key)
    described_class.new(
      store: store, utxo_pool: utxo_pool,
      broadcast_queue: broadcast_queue, proof_store: proof_store,
      key_deriver: priv_deriver, network: :mainnet
    )
  end
  let(:engine_with_keys) do
    described_class.new(
      store: store, utxo_pool: utxo_pool,
      broadcast_queue: broadcast_queue, proof_store: proof_store,
      key_deriver: key_deriver, network: :mainnet
    )
  end
  let(:verifier_hex) { verifier_key.public_key.to_hex }
  let(:verifier_key) { BSV::Primitives::PrivateKey.generate }
  let(:counterparty_hex) { counterparty_key.public_key.to_hex }
  let(:counterparty_key) { BSV::Primitives::PrivateKey.generate }
  let(:key_deriver) { BSV::Wallet::KeyDeriver.new(private_key: root_key) }
  let(:privileged_key) { BSV::Primitives::PrivateKey.generate }
  let(:root_key) { BSV::Primitives::PrivateKey.generate }
  let(:utxo_pool) { BSV::Wallet::Postgres::Store::UTXOPool.new(store: store) }
  let(:broadcast_queue) { BSV::Wallet::Postgres::Store::BroadcastQueue.new }
  let(:proof_store) { BSV::Wallet::Postgres::Store::ProofStore.new }

  around do |example|
    ENGINE_DB.transaction(rollback: :always, auto_savepoint: true) do
      example.run
    end
  end

  # Fund a reserve UTXO so outbound operations pass the limp mode guard.
  # Limp mode specs manage their own funding and skip this.
  before do |example|
    fund_reserve unless example.metadata[:skip_reserve]
  end

  # Parse Atomic BEEF and extract the subject transaction.
  def parse_beef_tx(beef_data)
    BSV::Transaction::Transaction.from_beef(beef_data)
  end

  # Constants defined at top level (before shared_context) to avoid RSpec/LeakyConstantDeclaration.
  # Referenced as plain constants inside specs — they're in the global namespace.

  def op_true
    "\x51".b
  end

  def dummy_raw_tx
    ['01000000016ce7229f014164e254aad172b1f8b40d496942ad7e323b47e0424c2b2e2e3772010000006a47' \
     '30440220463fcf8f57a61c4f8ede208773db8732bf3a0757d929a8cbbe29bf4905fe5ef6022005d74398fa' \
     'f5b24912821836171af44f55f89858f3edf92863cde4823da11d4641210362f5fb9274834bb0cd0376a8d5' \
     'd02bdbf459a37a62c5baef3fb06d1159b55597ffffffff01f0991600000000001976a9141f36a49fcf6ada' \
     '1f74f82377b33b17b68f7a016188acd3740e00'].pack('H*')
  end

  def fund_wallet(satoshis: 1000, count: 1, basket: 'default',
                  prefix: 'wallet payment', suffix: 'suffix',
                  sender_identity_key: 'self')
    source_action = store.create_action(
      action: { description: 'funding source', broadcast: :none, outgoing: false }
    )
    source_wtxid = SecureRandom.random_bytes(32)
    store.sign_action(action_id: source_action[:id], wtxid: source_wtxid, raw_tx: dummy_raw_tx)

    outputs = count.times.map do |i|
      out_suffix = count > 1 ? "#{suffix}#{i}" : suffix

      script = if key_deriver
                 derived_key = key_deriver.derive_private_key(
                   protocol_id: [2, prefix], key_id: out_suffix,
                   counterparty: sender_identity_key || 'self'
                 )
                 pubkey_hash = BSV::Primitives::Digest.hash160(derived_key.public_key.compressed)
                 BSV::Script::Script.p2pkh_lock(pubkey_hash).to_binary
               else
                 op_true
               end

      {
        satoshis: satoshis, vout: i,
        locking_script: script,
        basket: basket,
        derivation_prefix: prefix,
        derivation_suffix: out_suffix,
        sender_identity_key: sender_identity_key
      }
    end
    store.promote_action(action_id: source_action[:id], outputs: outputs)
  end

  def fund_reserve
    fund_wallet(satoshis: 100_000, prefix: 'limp reserve', suffix: 'reserve', basket: 'reserve')
  end
end
