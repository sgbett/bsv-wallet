# frozen_string_literal: true

# On-chain integration tests: Alice sends BSV to Bob.
#
# Environment variables (set in shell profile or CI):
#   WIF_ALICE, WIF_BOB       — wallet private keys
#   FUNDING_TXID              — dtxid hex of Alice's mined P2PKH UTXO
#   DATABASE_URL_ALICE/BOB    — optional, defaults to localhost:5433
#
# Run:
#   cd gem/bsv-wallet && bundle exec rspec --tag on_chain spec/integration/

require 'sequel'
require 'bsv-wallet'
require 'bsv-wallet-postgres'

RSpec.describe 'On-chain: Alice sends to Bob', :on_chain do # rubocop:disable RSpec/DescribeClass
  # --- Funding UTXO (mined, never moves) ---

  let(:funding_vout)     { 1 }
  let(:funding_satoshis) { 1_000_000 }

  # --- Environment ---

  let(:funding_dtxid) { ENV.fetch('BSV_WALLET_UTXO_ALICE') }
  let(:wif_alice)     { ENV.fetch('BSV_WALLET_WIF_ALICE') }
  let(:wif_bob)       { ENV.fetch('BSV_WALLET_WIF_BOB') }
  let(:db_url_alice)  { ENV.fetch('DATABASE_URL_ALICE', 'postgres://postgres:postgres@localhost:5433/bsv_wallet_alice') }
  let(:db_url_bob)    { ENV.fetch('DATABASE_URL_BOB', 'postgres://postgres:postgres@localhost:5433/bsv_wallet_bob') }

  # --- Database connections ---

  let(:db_alice) do
    db = Sequel.connect(db_url_alice)
    db.extension :pg_enum
    db.extension :pg_array
    db.extension :pg_json
    db
  end

  let(:db_bob) do
    db = Sequel.connect(db_url_bob)
    db.extension :pg_enum
    db.extension :pg_array
    db.extension :pg_json
    db
  end

  # --- Network ---

  let(:arc_provider)     { BSV::Network::Providers::GorillaPool.mainnet }
  let(:arc_adapter)      { BSV::Wallet::Postgres::ArcAdapter.new(arc_provider) }
  let(:network_provider) { BSV::Network::Providers::WhatsOnChain.mainnet }

  # --- Key derivers ---

  let(:alice_private_key) { BSV::Primitives::PrivateKey.from_wif(wif_alice) }
  let(:bob_private_key)   { BSV::Primitives::PrivateKey.from_wif(wif_bob) }
  let(:alice_key_deriver) { BSV::Wallet::KeyDeriver.new(private_key: alice_private_key) }
  let(:bob_key_deriver)   { BSV::Wallet::KeyDeriver.new(private_key: bob_private_key) }

  # --- Wallet engines ---

  let(:alice_engine) do
    run_migrations!(db_alice)
    store = BSV::Wallet::Postgres::Store.new(db: db_alice)
    BSV::Wallet::Engine.new(
      store: store,
      utxo_pool: BSV::Wallet::Postgres::UTXOPool.new(store: store),
      broadcast_queue: BSV::Wallet::Postgres::BroadcastQueue.new(db: db_alice),
      proof_store: BSV::Wallet::Postgres::ProofStore.new(db: db_alice),
      key_deriver: alice_key_deriver,
      network_provider: network_provider,
      network: :mainnet
    )
  end

  # Bob's engine is unused here — multi-wallet tests run via CLI
  # subprocess in cli_spec.rb (Sequel models use a global db).

  # --- Helpers ---

  def run_migrations!(db)
    BSV::Wallet::Postgres.connect(db)
    Sequel.extension :migration
    postgres_gem = Gem::Specification.find_by_name('bsv-wallet-postgres').gem_dir
    migrations_path = File.join(postgres_gem, 'db', 'migrations')
    Sequel::Migrator.run(db, migrations_path)
    # Clean slate — other specs may have used this database
    db.tables.each { |t| db[t].truncate(cascade: true) unless t == :schema_info }
  end

  def p2pkh_script(public_key_compressed)
    pubkey_hash = BSV::Primitives::Digest.hash160(public_key_compressed)
    BSV::Script::Script.p2pkh_lock(pubkey_hash).to_binary
  end

  # --- Tests ---

  it 'Alice pays Bob via auto-funded create_action with no_send' do
    # Import the funding UTXO (fetches tx from network, self-payment to derived address)
    import = alice_engine.import_utxo(dtxid: funding_dtxid, vout: funding_vout)
    expect(import[:imported]).to be true
    input_satoshis = import[:satoshis]

    listed = alice_engine.list_outputs(basket: 'default')
    expect(listed[:total_outputs]).to eq(1)

    # Bob's locking script (P2PKH to Bob's root key)
    payment_amount = 500
    bob_pubkey_bytes = [bob_key_deriver.identity_key].pack('H*')
    bob_script = p2pkh_script(bob_pubkey_bytes)

    # Auto-funded: no inputs, no manual fee, no change output.
    # The wallet selects UTXOs, computes fee, and generates change.
    result = alice_engine.create_action(
      description: 'integration test payment',
      outputs: [
        { satoshis: payment_amount, locking_script: bob_script,
          output_description: 'payment to Bob', basket: 'payments' }
      ],
      labels: ['integration-test'],
      no_send: true
    )

    wtxid = result[:txid]
    expect(wtxid).to be_a(String)
    expect(wtxid.bytesize).to eq(32)
    expect(result[:tx]).to be_a(String)

    # Verify change outpoints were returned (multiple due to pool sizing)
    expect(result[:no_send_change]).to be_an(Array)
    expect(result[:no_send_change].length).to be >= 1

    # Verify BEEF is parseable — 1 input, payment + change outputs
    parsed = BSV::Transaction::Transaction.from_beef(result[:tx])
    expect(parsed.inputs.length).to eq(1)
    expect(parsed.outputs.length).to be >= 2

    # Verify fee is reasonable (100 sat/kB)
    total_output = parsed.outputs.sum(&:satoshis)
    fee = input_satoshis - total_output
    expect(fee).to be > 0
    expect(fee).to be < 500 # more outputs = slightly larger tx

    # Verify Alice's change is spendable
    alice_outputs = alice_engine.list_outputs(basket: 'default')
    expect(alice_outputs[:total_outputs]).to be >= 1
    total_change = alice_outputs[:outputs].sum { |o| o[:satoshis] }
    expect(total_change).to eq(input_satoshis - payment_amount - fee)

    # NOTE: Bob's internalization requires a separate process (Sequel
    # models use a global db connection — two wallets can't coexist in
    # one process). The Alice→Bob flow is tested via CLI in cli_spec.rb.
  end
end
