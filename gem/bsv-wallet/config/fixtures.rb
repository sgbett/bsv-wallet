# frozen_string_literal: true

# config/fixtures.rb — BSV Wallet dev/test fixture registry (gem default)
#
# This file is the gem-bundled default registry. It is auto-loaded by
# +BSV::Wallet::Fixtures.load_config_file!+ when no user override
# exists at +~/.bsv-wallet/fixtures.rb+ (and no explicit
# +BSV_WALLET_FIXTURES=<path>+ is set).
#
# It registers the standard named wallets the wallet uses for dev/test:
# +alice+, +bob+, +carol+ (integration specs), +sdk+ (e2e funder),
# +w1+..+w5+ (e2e fleet), +test+ (unit-spec DB). Each wallet's WIF and
# database_url default from shell ENV vars (+BSV_WALLET_WIF_<NAME>+,
# +BSV_WALLET_POSTGRES+ — derives +<base>/bsv_wallet_<name>+; per-wallet
# +DATABASE_URL_<NAME>+ overrides if set).
#
# Per-wallet overrides: write +~/.bsv-wallet/fixtures.rb+ (or set
# +BSV_WALLET_FIXTURES=<path>+) to override or extend. Operators with
# full shell ENV typically need no override; the file is the inventory.

BSV::Wallet::Fixtures.configure do |f|
  f.postgres_base ||= ENV.fetch('BSV_WALLET_POSTGRES', nil)

  # Integration spec fixtures.
  f.wallet :alice, wif: ENV.fetch('BSV_WALLET_WIF_ALICE', nil),
                   database_url: ENV.fetch('DATABASE_URL_ALICE', nil)
  f.wallet :bob,   wif: ENV.fetch('BSV_WALLET_WIF_BOB',   nil),
                   database_url: ENV.fetch('DATABASE_URL_BOB',   nil)
  f.wallet :carol, wif: ENV.fetch('BSV_WALLET_WIF_CAROL', nil),
                   database_url: ENV.fetch('DATABASE_URL_CAROL', nil)

  # E2E harness funder.
  f.wallet :sdk, wif: ENV.fetch('BSV_WALLET_WIF_SDK', nil),
                 database_url: ENV.fetch('DATABASE_URL_SDK', nil)

  # Unit-spec test database. No WIF — unit specs generate keys.
  f.wallet :test

  # E2E fleet — WIFs derived at runtime from :sdk by the harness; the
  # registrations here just pin the DB URLs so the inventory is
  # visible. In the in-process harness the derivation overwrites these
  # registrations; the +ENV.fetch("BSV_WALLET_WIF_W#{n}", nil)+ here
  # picks the WIF up in spawned subprocesses (which don't run the
  # harness in-process) provided the caller exported the derived value.
  (1..5).each do |n|
    name = :"w#{n}"
    f.wallet name, wif: ENV.fetch("BSV_WALLET_WIF_W#{n}", nil),
                   database_url: ENV.fetch("DATABASE_URL_W#{n}", nil)
  end
end
