# frozen_string_literal: true

# Rake tasks for managing dev-wallet databases — operator plumbing,
# not a runtime path.
#
# Schema lifecycle and on-chain funding are intentionally separate
# tasks. +rebuild+ is destructive but on-chain-neutral (apart from
# the wallet's own sweep-to-root). +fund+ is the only task that
# moves sats from +:sdk+. There is no bundled "rebuild + fund" path.
#
# See +BSV::Wallet::Fixtures::Rebuilder+ for orchestration details.
#
# Usage (from +gem/bsv-wallet+):
#
#   bundle exec rake fixtures:rebuild[alice]
#   bundle exec rake fixtures:rebuild_all FORCE=1
#   bundle exec rake fixtures:fund[alice]
#   bundle exec rake fixtures:fund[alice,500000]
#   bundle exec rake fixtures:verify
#
# Requires +BSV_WALLET_POSTGRES+ + +BSV_WALLET_WIF_<NAME>+ in ENV.
# Unit specs never invoke these tasks.

require 'bsv-wallet'
require_relative '../bsv/wallet/cli'
require_relative '../bsv/wallet/fixtures/rebuilder'

namespace :fixtures do
  desc 'Reset a single dev wallet to clean schema state ' \
       '(sweep to own root + DROP + CREATE + migrate). ' \
       'Aborts if sweep fails. Does NOT fund — use fixtures:fund. ' \
       'Usage: rake fixtures:rebuild[alice]'
  task :rebuild, %i[wallet] do |_t, args|
    name = args[:wallet]
    abort 'fixtures:rebuild requires a wallet name (e.g. rake fixtures:rebuild[alice])' if name.nil? || name.empty?

    BSV::Wallet::Fixtures.load_config_file!
    BSV::Wallet::Fixtures::Rebuilder.new.rebuild(name)
  end

  desc 'Reset every registered dev wallet except :test (sweep + drop + create + migrate). ' \
       'Does NOT fund. Set FORCE=1 to skip the confirmation prompt.'
  task :rebuild_all do
    BSV::Wallet::Fixtures.load_config_file!

    unless ENV['FORCE'] == '1'
      warn 'fixtures:rebuild_all will DROP every dev-wallet database.'
      warn 'This is destructive (DB only — chain funds at root are preserved). ' \
           'Re-run with FORCE=1 to proceed.'
      abort 'aborted: confirmation required'
    end

    BSV::Wallet::Fixtures::Rebuilder.new.rebuild_all
  end

  desc 'Fund a wallet by sending sats from :sdk to its root P2PKH. ' \
       'Default 1_000_000 sats. Cannot fund :sdk (it IS the funder). ' \
       'Usage: rake fixtures:fund[alice] or rake fixtures:fund[alice,500000]'
  task :fund, %i[wallet sats] do |_t, args|
    name = args[:wallet]
    abort 'fixtures:fund requires a wallet name (e.g. rake fixtures:fund[alice])' if name.nil? || name.empty?

    BSV::Wallet::Fixtures.load_config_file!
    rebuilder = BSV::Wallet::Fixtures::Rebuilder.new
    if args[:sats]
      rebuilder.fund(name, sats: args[:sats].to_i)
    else
      rebuilder.fund(name)
    end
  end

  desc 'Verify every registered dev wallet has clean schema state ' \
       'and a non-zero root balance on chain. ' \
       'Exits non-zero on any failure.'
  task :verify do
    BSV::Wallet::Fixtures.load_config_file!
    failures = BSV::Wallet::Fixtures::Rebuilder.new.verify
    exit(failures.empty? ? 0 : 1)
  end
end
