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
  # Test DB URL: register a :test fixture so the URL derives from
  # BSV_WALLET_POSTGRES via Fixtures' standard derivation. Unset
  # base → nil → SQLite fallback below.
  BSV::Wallet::Fixtures.configure do |f|
    f.postgres_base ||= ENV.fetch('BSV_WALLET_POSTGRES', nil)
    f.wallet :test unless f[:test]
  end
  test_db_url = BSV::Wallet::Fixtures.wallet(:test)&.database_url

  # Deterministic test +identity_pubkey_hash+ pinned at suite boot — the
  # per-wallet +outputs.spendable_recoverable+ CHECK literal needs the hash
  # at migration time (HLR #467). Specs that fabricate a "root" output
  # locking script use +TEST_ROOT_LOCKING_SCRIPT+ below.
  TEST_IDENTITY_PUBKEY_HASH = ("\x00".b * 20)
  TEST_ROOT_LOCKING_SCRIPT = BSV::Script::Script.p2pkh_lock(TEST_IDENTITY_PUBKEY_HASH).to_binary.freeze

  if test_db_url
    STORE_INSTANCE = BSV::Wallet::Store::Postgres.new(
      url: test_db_url, identity_pubkey_hash: TEST_IDENTITY_PUBKEY_HASH
    )
  else
    db = Sequel.sqlite
    STORE_INSTANCE = BSV::Wallet::Store::SQLite.new(
      db: db, identity_pubkey_hash: TEST_IDENTITY_PUBKEY_HASH
    )
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
  # Default to a non-root locking script for derived/outbound outputs. Specs
  # that want a root-shape output should pass +locking_script:
  # TEST_ROOT_LOCKING_SCRIPT+ explicitly so the per-wallet
  # +spendable_recoverable+ CHECK matches.
  let(:valid_locking_script) { SecureRandom.random_bytes(25) }
  let(:valid_identity_key) { "02#{SecureRandom.hex(32)}" }
  let(:test_root_locking_script) { TEST_ROOT_LOCKING_SCRIPT }

  # Build a wallet-owned, spendable output for the test wallet. The shape
  # follows the post-HLR-#467 schema:
  #   * +output_type: 'root'+   → root P2PKH (locking_script defaults to
  #     +TEST_ROOT_LOCKING_SCRIPT+, no derivation triple)
  #   * +output_type: 'outbound'+ → outbound (no derivation, non-root script,
  #     no spendable row)
  #   * +output_type: nil+ (default) → BRC-42 derived (derivation triple set)
  # +spendable_intent+ is derived from the legacy +output_type+ for back-
  # compat with existing specs; new specs should pass +spendable_intent:+
  # directly.
  def create_funded_output(satoshis: 1000, basket: nil, output_type: nil,
                           spendable_intent: nil,
                           locking_script: nil,
                           derivation_prefix: 'prefix', derivation_suffix: 'suffix',
                           sender_identity_key: nil)
    sender_identity_key ||= valid_identity_key
    action = BSV::Wallet::Store::Models::Action.create(
      description: 'fund action 12345', broadcast_intent: 'none'
    )
    action.update(wtxid: Sequel.blob(SecureRandom.random_bytes(32)),
                  raw_tx: Sequel.blob(valid_raw_tx))

    intent = spendable_intent || (output_type == 'outbound' ? 'none' : 'spendable')

    # Locking script defaults: root → wallet's root P2PKH; everything else
    # → an arbitrary non-root script so the +spendable_recoverable+ CHECK
    # doesn't trip on hash collisions with the per-wallet literal.
    attrs = { action_id: action.id, satoshis: satoshis, vout: 0,
              locking_script: locking_script || (output_type == 'root' ? TEST_ROOT_LOCKING_SCRIPT : valid_locking_script),
              spendable_intent: intent }
    if output_type
      # 'root' / 'outbound' carry no derivation triple.
    else
      attrs[:derivation_prefix] = derivation_prefix
      attrs[:derivation_suffix] = derivation_suffix
      attrs[:sender_identity_key] = sender_identity_key
    end

    output = BSV::Wallet::Store::Models::Output.create(attrs)
    # The promotions row authorises the spendable row (#307); intent='none'
    # matches this internal/incoming funding fixture.
    BSV::Wallet::Store::Models::Promotion.create(action_id: action.id, intent: 'none', authorising_status: nil)
    if intent == 'spendable'
      BSV::Wallet::Store::Models::Spendable.create(
        output_id: output.id, action_id: action.id, spendable_intent: 'spendable'
      )
    end

    if basket
      b = BSV::Wallet::Store::Models::Basket.first(name: basket) || BSV::Wallet::Store::Models::Basket.create(name: basket)
      BSV::Wallet::Store::Models::OutputBasket.create(output_id: output.id, basket_id: b.id, action_id: action.id)
    end

    output
  end

  def insert_action(description: 'test action 12345', **overrides)
    defaults = { description: description, reference: SecureRandom.uuid }
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
