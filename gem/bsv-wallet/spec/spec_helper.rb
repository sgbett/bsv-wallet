# frozen_string_literal: true

if ENV['COVERAGE'].to_s == 'true'
  require_relative '../../../spec/simplecov_setup'
  SimpleCov.command_name 'bsv-wallet'
  SimpleCov.start
end

require 'bsv-wallet'

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

  # Clean slate when a test database is available.
  # SQLite (in-memory by default) is freshly created per process — no
  # cleanup needed. Postgres persists, so truncate everything bar the
  # migrator metadata.
  config.before(:suite) do
    next unless defined?(ENGINE_DB)
    next unless defined?(BSV_WALLET_BACKEND) && BSV_WALLET_BACKEND == :postgres

    ENGINE_DB.tables.each { |t| ENGINE_DB[t].truncate(cascade: true) unless t == :schema_info }
  end
end
