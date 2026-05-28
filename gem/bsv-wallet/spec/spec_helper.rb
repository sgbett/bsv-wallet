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
  config.disable_monkey_patching!
  config.order = :random
  Kernel.srand config.seed

  # Reset OMQ inproc transport's global registry between examples.
  # OMQ inproc bindings persist process-wide; without this, a spec that
  # boots a daemon after another spec already bound the same endpoint
  # would hit ArgumentError on bind. The fix at the engine layer (#176)
  # makes that failure visible rather than silent — this hook keeps
  # specs that exercise the daemon from tripping it.
  #
  # Also reset BSV::Wallet's process-wide event observer registry.
  # Scheduler#run! registers an observer and only Scheduler#shutdown
  # deregisters it — specs that boot a scheduler without a matching
  # shutdown leak observers across examples.
  config.before do
    OMQ::Transport::Inproc.reset! if defined?(OMQ::Transport::Inproc)
    BSV::Wallet.reset_event_observers! if defined?(BSV::Wallet) && BSV::Wallet.respond_to?(:reset_event_observers!)
  end
end
