# frozen_string_literal: true

# Rake tasks for swapping dev-wallet databases — operator plumbing,
# not a runtime path.
#
# Three tasks under +fixtures:+ — see
# +BSV::Wallet::Fixtures::Rebuilder+ for the orchestration semantics.
#
# Usage (from +gem/bsv-wallet+):
#
#   bundle exec rake fixtures:rebuild[alice]
#   bundle exec rake fixtures:rebuild_all FORCE=1
#   bundle exec rake fixtures:verify
#
# Wall time is chain-tip bound (~5-15 minutes for the full fleet).
# Requires +BSV_WALLET_POSTGRES+ + +BSV_WALLET_WIF_<NAME>+ in ENV — a
# unit-spec run never invokes these tasks.

require 'bsv-wallet'
require_relative '../bsv/wallet/cli'
require_relative '../bsv/wallet/fixtures/rebuilder'

namespace :fixtures do
  desc 'Drop, recreate, migrate, and re-fund a single dev wallet. ' \
       'Usage: rake fixtures:rebuild[alice]'
  task :rebuild, %i[wallet] do |_t, args|
    name = args[:wallet]
    abort 'fixtures:rebuild requires a wallet name (e.g. rake fixtures:rebuild[alice])' if name.nil? || name.empty?

    BSV::Wallet::Fixtures.load_config_file!
    BSV::Wallet::Fixtures::Rebuilder.new.rebuild(name)
  end

  desc 'Drop, recreate, migrate, and re-fund every registered dev wallet ' \
       'except :test. Set FORCE=1 to skip the confirmation prompt.'
  task :rebuild_all do
    BSV::Wallet::Fixtures.load_config_file!

    unless ENV['FORCE'] == '1'
      warn 'fixtures:rebuild_all will DROP every dev-wallet database and refund from :sdk.'
      warn 'This is destructive. Re-run with FORCE=1 to proceed.'
      abort 'aborted: confirmation required'
    end

    BSV::Wallet::Fixtures::Rebuilder.new.rebuild_all
  end

  desc 'Verify every registered dev wallet has fresh state + non-zero ' \
       'root balance. Exits non-zero on any failure (merge-gate).'
  task :verify do
    BSV::Wallet::Fixtures.load_config_file!
    failures = BSV::Wallet::Fixtures::Rebuilder.new.verify
    exit(failures.empty? ? 0 : 1)
  end
end
