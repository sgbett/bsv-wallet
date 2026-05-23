# frozen_string_literal: true

# Shared database setup for store specs.
#
# Backend selection:
#   DATABASE_URL unset / sqlite://  → in-memory SQLite (default)
#   DATABASE_URL=postgres://...     → Postgres
#
# All specs use BSV::Wallet::Store::* models regardless of backend.

require 'securerandom'
require 'sequel'

unless defined?(STORE_DB)
  database_url = ENV.fetch('DATABASE_URL', nil)

  if database_url&.start_with?('postgres')
    STORE_DB = Sequel.connect(database_url)
  else
    STORE_DB = Sequel.sqlite
    STORE_DB.run('PRAGMA foreign_keys = ON')
  end

  BSV::Wallet::Store::Connection.connect(STORE_DB)
  BSV::Wallet::Store::Connection.migrate!
  BSV::Wallet::Store::Connection.bind_models!

  STORE_DATABASE_TYPE = STORE_DB.database_type
end

RSpec.shared_context 'store setup' do
  let(:db) { STORE_DB }
  let(:store) { BSV::Wallet::Store::Persistence.new(db: db) }

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
