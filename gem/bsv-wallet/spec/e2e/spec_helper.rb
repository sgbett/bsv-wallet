# frozen_string_literal: true

# spec_helper for the e2e on-chain harness (HLR #126).
#
# Separate from the gem's main +spec/spec_helper.rb+ so that
# +bundle exec rspec spec/bsv spec/bin+ does NOT load the e2e tree —
# the e2e specs spawn long-running walletd subprocesses and make real
# ARC broadcasts, neither of which belongs in the unit-test run.
#
# Loaded explicitly by +bundle exec rspec spec/e2e/...+.
#
# The whole tree is skipped at load time unless +BSV_WALLET_WIF_SDK+ is
# set in the environment — that WIF is the on-chain funding key and the
# deterministic root for the 5 test wallets (see +support/wallet_derivation.rb+).

require 'rspec'
require 'bsv-wallet'

# Load .env from repo root so +DATABASE_URL_SDK+ / +BSV_WALLET_WIF_SDK+
# / per-wallet URLs are visible to the harness (and to its walletd
# subprocesses, which inherit the parent env).
begin
  require 'dotenv'
  Dotenv.load(File.expand_path('../../../../.env', __dir__))
rescue LoadError
  # optional — env can come from shell profile or CI workflow
end

Dir[File.join(__dir__, 'support', '*.rb')].each { |f| require f }

RSpec.configure do |config|
  config.before(:suite) do
    if ENV['BSV_WALLET_WIF_SDK'].to_s.strip.empty?
      warn 'Skipping e2e suite: BSV_WALLET_WIF_SDK is not set'
      warn 'Set it in .env or your shell profile to enable the e2e harness.'
      RSpec.world.example_groups.each { |g| g.skip = 'BSV_WALLET_WIF_SDK not set' }
    end
  end
end
