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

RSpec.describe 'On-chain: Alice sends to Bob', :on_chain do
  # --- Funding UTXO (mined, never moves) ---

  FUNDING_VOUT     = 0
  FUNDING_SATOSHIS = 2000

  # --- Environment ---

  let(:funding_dtxid) { ENV.fetch('FUNDING_TXID') }
  let(:wif_alice)     { ENV.fetch('WIF_ALICE') }
  let(:wif_bob)       { ENV.fetch('WIF_BOB') }
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
      broadcast_queue: BSV::Wallet::Postgres::BroadcastQueue.new(db: db_alice, arc_client: arc_adapter),
      proof_store: BSV::Wallet::Postgres::ProofStore.new(db: db_alice),
      key_deriver: alice_key_deriver,
      network_provider: network_provider,
      network: :mainnet
    )
  end

  let(:bob_engine) do
    run_migrations!(db_bob)
    store = BSV::Wallet::Postgres::Store.new(db: db_bob)
    BSV::Wallet::Engine.new(
      store: store,
      utxo_pool: BSV::Wallet::Postgres::UTXOPool.new(store: store),
      broadcast_queue: BSV::Wallet::Postgres::BroadcastQueue.new(db: db_bob, arc_client: arc_adapter),
      proof_store: BSV::Wallet::Postgres::ProofStore.new(db: db_bob),
      key_deriver: bob_key_deriver,
      network_provider: network_provider,
      network: :mainnet
    )
  end

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

  def root_key_script(key_deriver)
    pubkey_bytes = [key_deriver.identity_key].pack('H*')
    p2pkh_script(pubkey_bytes)
  end

  # --- Tests ---

  it 'Alice pays Bob via create_action with no_send' do
    # Import the funding UTXO (fetches tx from network, self-payment to derived address)
    import = alice_engine.import_utxo(dtxid: funding_dtxid, vout: FUNDING_VOUT)
    expect(import[:imported]).to be true
    input_satoshis = import[:satoshis] # FUNDING_SATOSHIS minus 1-sat self-payment fee
    puts "\n  Imported #{input_satoshis} sats from funding UTXO"

    listed = alice_engine.list_outputs(basket: 'default')
    expect(listed[:total_outputs]).to eq(1)
    output = listed[:outputs].first
    output_id = output[:id]

    # Payment params
    payment_amount = 500
    fee = 226
    change_amount = input_satoshis - payment_amount - fee

    # Bob's locking script (P2PKH to Bob's root key)
    bob_pubkey_bytes = [bob_key_deriver.identity_key].pack('H*')
    bob_script = p2pkh_script(bob_pubkey_bytes)

    # Alice's change locking script (root key, nil derivation)
    alice_change_script = root_key_script(alice_key_deriver)

    # Create the transaction (no_send — build and sign but don't broadcast)
    result = alice_engine.create_action(
      description: 'integration test payment',
      inputs: [{ output_id: output_id }],
      outputs: [
        { satoshis: payment_amount, locking_script: bob_script,
          output_description: 'payment to Bob', basket: 'payments', output_type: 'root' },
        { satoshis: change_amount, locking_script: alice_change_script,
          output_description: 'change to self', basket: 'default', output_type: 'change' }
      ],
      labels: ['integration-test'],
      no_send: true
    )

    wtxid = result[:txid]
    expect(wtxid).to be_a(String)
    expect(wtxid.bytesize).to eq(32)
    expect(result[:tx]).to be_a(String)

    dtxid_hex = wtxid.reverse.unpack1('H*')
    puts "  Created dtxid: #{dtxid_hex}"
    puts "  Payment: #{payment_amount} sats to Bob"
    puts "  Change:  #{change_amount} sats to Alice"
    puts "  Fee:     #{fee} sats"

    # Verify BEEF is parseable
    parsed = BSV::Transaction::Transaction.from_beef(result[:tx])
    expect(parsed.inputs.length).to eq(1)
    expect(parsed.outputs.length).to eq(2)

    # Verify Alice's change is spendable
    alice_outputs = alice_engine.list_outputs(basket: 'default')
    expect(alice_outputs[:total_outputs]).to eq(1)
    expect(alice_outputs[:outputs].first[:satoshis]).to eq(change_amount)
    puts "  Alice change output: #{change_amount} sats (spendable)"

    # Bob internalizes the payment
    bob_engine.internalize_action(
      tx: result[:tx],
      outputs: [{
        output_index: 0,
        protocol: 'basket insertion',
        insertion_remittance: { basket: 'received', tags: ['from-alice'] }
      }],
      description: 'received from Alice',
      labels: ['integration-test']
    )

    bob_outputs = bob_engine.list_outputs(basket: 'received')
    expect(bob_outputs[:total_outputs]).to eq(1)
    expect(bob_outputs[:outputs].first[:satoshis]).to eq(payment_amount)
    puts "  Bob received: #{payment_amount} sats in 'received' basket"
  end
end
