# frozen_string_literal: true

# spec_helper for the e2e on-chain harness (HLR #126).
#
# Separate from the gem's main +spec/spec_helper.rb+. +spec/e2e+ holds
# the on-chain workload harness (+e2e_workload_spec.rb+) and the
# SSE-driven broadcast scenarios (+broadcast_spec.rb+, HLR #251), both of
# which spawn long-running walletd subprocesses or make real ARC
# broadcasts — neither belongs in the unit run. The bare +rspec+ run
# drops them via the +--exclude-pattern+ in +.rspec+; this helper is
# loaded only when an e2e spec is named explicitly (e.g.
# +bundle exec rspec spec/e2e/e2e_workload_spec.rb+).
#
# There is no load-time skip: each spec skips per-example (see the
# +before+ block in +e2e_workload_spec.rb+, which gates on +E2E_MODE+
# and +E2E::WalletHarness.missing_env+). +BSV_WALLET_WIF_SDK+ is the
# on-chain funding key and the deterministic root for the 5 test
# wallets (see +spec/support/e2e/wallet_derivation.rb+).

require 'rspec'
require 'bsv-wallet'

# +DATABASE_URL_SDK+ / +BSV_WALLET_WIF_SDK+ / per-wallet URLs come from the
# shell environment (~/.zshenv locally, +env:+ blocks in CI), inherited by
# this rspec process and the +walletd+ subprocesses it spawns alike.

# The harness support modules now live in spec/support/e2e (so their own
# unit specs ride the bare +rspec+ run). Require them explicitly rather
# than globbing that directory — a glob would also pull in the co-located
# +*_spec.rb+ files.
%w[wallet_derivation event_log wallet_harness daemon_supervisor sse_test_listener].each do |mod|
  require_relative File.join('..', 'support', 'e2e', mod)
end

# Per-spec skip is handled inside each phase's +before+ block via
# +E2E::WalletHarness.missing_env+ — the message lists exactly which
# env vars are unset rather than a blanket "BSV_WALLET_WIF_SDK is
# missing". This keeps responsibility with the phase that needs the
# env, and lets the support unit specs (no env required) run alongside.
