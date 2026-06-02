# frozen_string_literal: true

# spec_helper for the e2e on-chain harness (HLR #126).
#
# Separate from the gem's main +spec/spec_helper.rb+. +spec/e2e+ holds
# only the on-chain harness (+broadcast_spec.rb+), which spawns
# long-running walletd subprocesses and makes real ARC broadcasts —
# neither belongs in the unit run. The bare +rspec+ run drops it via the
# +--exclude-pattern+ in +.rspec+; this helper is loaded only when the
# spec is named explicitly (+bundle exec rspec spec/e2e/broadcast_spec.rb+).
#
# There is no load-time skip: the harness skips per-example (see the
# +before+ block in +broadcast_spec.rb+, which gates on +E2E_MODE+ and
# +E2E::WalletHarness.missing_env+). +BSV_WALLET_WIF_SDK+ is the on-chain
# funding key and the deterministic root for the 5 test wallets (see
# +spec/support/e2e/wallet_derivation.rb+).

require 'rspec'
require 'bsv-wallet'

# +DATABASE_URL_SDK+ / +BSV_WALLET_WIF_SDK+ / per-wallet URLs come from the
# shell environment (~/.zshenv locally, +env:+ blocks in CI), inherited by
# this rspec process and the +walletd+ subprocesses it spawns alike.

# The harness support modules now live in spec/support/e2e (so their own
# unit specs ride the bare +rspec+ run). Require them explicitly rather
# than globbing that directory — a glob would also pull in the co-located
# +*_spec.rb+ files.
%w[wallet_derivation event_log wallet_harness daemon_supervisor].each do |mod|
  require_relative File.join('..', 'support', 'e2e', mod)
end

# Per-spec skip is handled inside each phase's +before+ block via
# +E2E::WalletHarness.missing_env+ — the message lists exactly which
# env vars are unset rather than a blanket "BSV_WALLET_WIF_SDK is
# missing". This keeps responsibility with the phase that needs the
# env, and lets the support unit specs (no env required) run alongside.
