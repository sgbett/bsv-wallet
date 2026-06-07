# frozen_string_literal: true

# Shared database setup for store specs.
#
# Backend selection (deliberately independent of +DATABASE_URL+ so an
# operator's working DATABASE_URL never silently hijacks the spec run):
#
#   BSV_WALLET_POSTGRES set    -> Postgres at <base>/bsv_wallet_test
#   BSV_WALLET_POSTGRES unset  -> in-memory SQLite
#
# Set +BSV_WALLET_POSTGRES+ (typically to e.g.
# +postgres://postgres:postgres@localhost:5433/+) to run the suite
# against Postgres. Leave it unset for SQLite.
#
# All specs use BSV::Wallet::Store::Models::* models regardless of backend.

require 'securerandom'
require 'sequel'
require 'bsv/wallet/cli'

unless defined?(STORE_DB)
  test_db_url = BSV::Wallet::CLI.derive_postgres_url('test')

  if test_db_url
    STORE_INSTANCE = BSV::Wallet::Store::Postgres.new(url: test_db_url)
  else
    db = Sequel.sqlite
    STORE_INSTANCE = BSV::Wallet::Store::SQLite.new(db: db)
  end

  STORE_DB = STORE_INSTANCE.db
  STORE_INSTANCE.migrate!
  STORE_DATABASE_TYPE = STORE_DB.database_type
end

RSpec.shared_context 'store setup' do
  let(:db) { STORE_DB }
  let(:store) { STORE_INSTANCE }

  let(:valid_wtxid) { SecureRandom.random_bytes(32) }
  let(:valid_raw_tx) { SecureRandom.random_bytes(191) }
  let(:valid_locking_script) { SecureRandom.random_bytes(25) }
  let(:valid_identity_key) { "02#{SecureRandom.hex(32)}" }

  def create_funded_output(satoshis: 1000, basket: nil, output_type: nil,
                           derivation_prefix: 'prefix', derivation_suffix: 'suffix',
                           sender_identity_key: nil)
    sender_identity_key ||= valid_identity_key
    action = BSV::Wallet::Store::Models::Action.create(
      description: 'fund action 12345', outgoing: false, broadcast_intent: 'none'
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

    output = BSV::Wallet::Store::Models::Output.create(attrs)
    BSV::Wallet::Store::Models::Spendable.create(output_id: output.id, action_id: action.id)

    if basket && basket != 'default'
      b = BSV::Wallet::Store::Models::Basket.first(name: basket) || BSV::Wallet::Store::Models::Basket.create(name: basket)
      BSV::Wallet::Store::Models::OutputBasket.create(output_id: output.id, basket_id: b.id, action_id: action.id)
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

  # Skip :postgres-tagged specs when running on SQLite
  config.before(:each, :postgres) do |_example|
    skip 'Postgres-only test' unless STORE_DATABASE_TYPE == :postgres
  end

  config.before(:suite) do
    next unless defined?(STORE_DB)

    case STORE_DATABASE_TYPE
    when :sqlite
      STORE_DB.run('PRAGMA foreign_keys = OFF')
      STORE_DB.tables.each do |table|
        next if table == :schema_info

        STORE_DB[table].delete
      end
      STORE_DB.run('PRAGMA foreign_keys = ON')
    when :postgres
      STORE_DB.tables.each do |table|
        next if table == :schema_info

        STORE_DB[table].truncate(cascade: true)
      end
    end
  end

  config.around(:each, :store) do |example|
    STORE_DB.transaction(rollback: :always, auto_savepoint: true) do
      example.run
    end
  end
end
