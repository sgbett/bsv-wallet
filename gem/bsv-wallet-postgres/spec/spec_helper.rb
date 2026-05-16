# frozen_string_literal: true

if ENV['COVERAGE'].to_s == 'true'
  require_relative '../../../spec/simplecov_setup'
  SimpleCov.command_name 'bsv-wallet-postgres'
  SimpleCov.start
end

require 'securerandom'
require 'sequel'

# Connect to test database before loading models
TEST_DB_URL = ENV.fetch('DATABASE_URL', 'postgres://postgres:postgres@localhost:5433/bsv_wallet_test')
DB = Sequel.connect(TEST_DB_URL)
DB.extension :pg_enum
DB.extension :pg_array

# Run migrations
Sequel.extension :migration
Sequel::Migrator.run(DB, File.expand_path('../db/migrations', __dir__))

# Load the gem (connects models to DB, then bind after migrations)
require 'bsv-wallet-postgres'
BSV::Wallet::Postgres::Store::Connection.connect(DB)
BSV::Wallet::Postgres::Store::Connection.bind_models!

RSpec.configure do |config|
  config.expect_with :rspec do |expectations|
    expectations.include_chain_clauses_in_custom_matcher_descriptions = true
  end

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.shared_context_metadata_behavior = :apply_to_host_groups
  config.filter_run_when_matching :focus
  config.filter_run_excluding on_chain: true
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  # Clean slate before the suite
  config.before(:suite) do
    DB.tables.each do |table|
      next if table == :schema_info
      DB[table].truncate(cascade: true)
    end
  end

  # Transaction rollback for test isolation
  config.around(:each) do |example|
    DB.transaction(rollback: :always, auto_savepoint: true) do
      example.run
    end
  end
end
