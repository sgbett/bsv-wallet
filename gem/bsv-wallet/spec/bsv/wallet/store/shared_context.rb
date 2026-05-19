# frozen_string_literal: true

# Shared database setup for store and engine specs.
#
# Backend selection: set BSV_WALLET_BACKEND=postgres to run against
# Postgres instead of the default in-memory SQLite. Postgres requires
# DATABASE_URL (defaults to localhost:5433/bsv_wallet_test).

require 'securerandom'
require 'sequel'

unless defined?(STORE_DB)
  if ENV['BSV_WALLET_BACKEND'] == 'postgres'
    require 'bsv-wallet-postgres'
    url = ENV.fetch('DATABASE_URL', 'postgres://postgres:postgres@localhost:5433/bsv_wallet_test')
    STORE_DB = Sequel.connect(url)
    BSV::Wallet::Postgres::Store::Connection.connect(STORE_DB)
    BSV::Wallet::Postgres::Store::Connection.migrate!
    BSV::Wallet::Postgres::Store::Connection.bind_models!
    STORE_BACKEND = BSV::Wallet::Postgres::Store
  else
    STORE_DB = Sequel.sqlite
    STORE_DB.run('PRAGMA foreign_keys = ON')
    Sequel.extension :migration
    migrations_path = File.expand_path('../../../../db/migrations', __dir__)
    Sequel::Migrator.run(STORE_DB, migrations_path)
    BSV::Wallet::Store::Connection.connect(STORE_DB)
    BSV::Wallet::Store::Connection.bind_models!
    STORE_BACKEND = BSV::Wallet::Store
  end
end

RSpec.shared_context 'store setup' do
  before do
    if STORE_BACKEND != BSV::Wallet::Store
      skip 'SQLite-only spec (BSV_WALLET_BACKEND is set to a different backend)'
    end
  end

  let(:db) { STORE_DB }
  let(:store) { BSV::Wallet::Store::SQLite.new(db: db) }

  let(:valid_wtxid) { SecureRandom.random_bytes(32) }
  let(:valid_raw_tx) { SecureRandom.random_bytes(191) }
  let(:valid_locking_script) { SecureRandom.random_bytes(25) }
  let(:valid_identity_key) { "02#{SecureRandom.hex(32)}" }

  def create_funded_output(satoshis: 1000, basket: nil, output_type: nil,
                           derivation_prefix: 'prefix', derivation_suffix: 'suffix',
                           sender_identity_key: nil)
    sender_identity_key ||= valid_identity_key
    action = BSV::Wallet::Store::Action.create(
      description: 'fund action 12345', outgoing: false, broadcast: 'none'
    )
    action.update(wtxid: Sequel.blob(SecureRandom.random_bytes(32)),
                  raw_tx: Sequel.blob(valid_raw_tx))

    attrs = { action_id: action.id, satoshis: satoshis, vout: 0,
              locking_script: valid_locking_script }
    if output_type
      attrs[:output_type] = output_type
    else
      attrs[:derivation_prefix] = derivation_prefix
      attrs[:derivation_suffix] = derivation_suffix
      attrs[:sender_identity_key] = sender_identity_key
    end

    output = BSV::Wallet::Store::Output.create(attrs)
    BSV::Wallet::Store::Spendable.create(output_id: output.id, action_id: action.id)

    if basket && basket != 'default'
      b = BSV::Wallet::Store::Basket.first(name: basket) || BSV::Wallet::Store::Basket.create(name: basket)
      BSV::Wallet::Store::OutputBasket.create(output_id: output.id, basket_id: b.id, action_id: action.id)
    end

    output
  end

  def insert_action(description: 'test action 12345', **overrides)
    defaults = { description: description, outgoing: true, nlocktime: 0, reference: SecureRandom.uuid }
    db[:actions].insert(defaults.merge(overrides))
  end
end

RSpec.configure do |config|
  config.include_context 'store setup', :store

  config.before(:suite) do
    next unless defined?(STORE_DB)

    if STORE_BACKEND == BSV::Wallet::Store
      STORE_DB.run('PRAGMA foreign_keys = OFF')
      STORE_DB.tables.each { |t| STORE_DB[t].delete unless t == :schema_info }
      STORE_DB.run('PRAGMA foreign_keys = ON')
    else
      STORE_DB.tables.each { |t| STORE_DB[t].truncate(cascade: true) unless t == :schema_info }
    end
  end

  config.around(:each, :store) do |example|
    STORE_DB.transaction(rollback: :always, auto_savepoint: true) do
      example.run
    end
  end
end
