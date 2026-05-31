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
# There is no load-time skip: the support unit specs run without any
# on-chain env, and the harness itself skips per-example (see the
# +before+ block in +broadcast_spec.rb+, which gates on +E2E_MODE+ and
# +E2E::WalletHarness.missing_env+). +BSV_WALLET_WIF_SDK+ is the on-chain
# funding key and the deterministic root for the 5 test wallets (see
# +support/wallet_derivation.rb+).

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

# Per-spec skip is handled inside each phase's +before+ block via
# +E2E::WalletHarness.missing_env+ — the message lists exactly which
# env vars are unset rather than a blanket "BSV_WALLET_WIF_SDK is
# missing". This keeps responsibility with the phase that needs the
# env, and lets the support unit specs (no env required) run alongside.
