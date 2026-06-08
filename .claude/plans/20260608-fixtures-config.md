# #292 — Centralise dev/test wallet configuration (BSV::Wallet::Fixtures)

**Issue:** #292
**Date:** 2026-06-08
**Status:** Plan — executing
**Branch:** `feat/292-fixtures-config` off `master`

## Goal

Build `BSV::Wallet::Fixtures.configure { |f| ... }` as the dev/test named-wallet registry. Migrates every site that currently decodes `BSV_WALLET_WIF_<NAME>` / `DATABASE_URL_<NAME>` / `BSV_WALLET_POSTGRES` via procedural lookup (CLI.boot's `env_fetch` helpers, `derive_postgres_url`, the e2e harness's ENV mutation, integration specs' direct ENV reads) to the new registry. After this PR, the named-wallet fixture surface is one shape across lib + bin + spec + e2e.

Companion to #277 — same audience-split frame: end-user config is `BSV::Wallet.configure`, dev/test fixtures are `BSV::Wallet::Fixtures.configure`.

## Audit (sites that migrate)

**Library:**
- `lib/bsv/wallet/cli.rb` — `env_fetch`, `env_fetch_optional`, `derive_postgres_url`, `missing_wif_message`
- `bin/walletd` — callers of those

**E2E / helpers:**
- `spec/support/e2e/wallet_harness.rb` — derives `w1`..`w5` WIFs from `BSV_WALLET_WIF_SDK`; sets `BSV_WALLET_WIF_*` + `DATABASE_URL_*` in ENV
- `spec/support/e2e/daemon_supervisor.rb` — uses `derive_postgres_url`
- `spec/bsv/wallet/store/shared_context.rb` — uses `derive_postgres_url('test')` for the unit spec test DB
- `spec/bin/boot_spec.rb` — tests `derive_postgres_url` directly
- `spec/support/e2e/wallet_harness_spec.rb` — tests the harness

**Integration specs (all read ENV directly):**
- `spec/integration/cli_spec.rb`
- `spec/integration/consolidation_dry_run_spec.rb`
- `spec/integration/stress_cascade_spec.rb`

## Design

### `lib/bsv/wallet/fixtures.rb`

```ruby
module BSV
  module Wallet
    module Fixtures
      Wallet = Struct.new(:name, :wif, :database_url, keyword_init: true)

      class Registry
        attr_accessor :postgres_base

        def initialize
          @postgres_base = nil
          @wallets = {}
        end

        # Register a named wallet. wif/database_url both optional —
        # database_url is derived from postgres_base when nil.
        def wallet(name, wif: nil, database_url: nil)
          sym = name.to_sym
          @wallets[sym] = Wallet.new(
            name: sym,
            wif: wif,
            database_url: database_url || derive_database_url(sym)
          )
        end

        def [](name) = @wallets[name.to_sym]
        def each(&block) = @wallets.values.each(&block)
        def names = @wallets.keys

        private

        def derive_database_url(name)
          base = @postgres_base&.strip
          return nil if base.nil? || base.empty?

          "#{base.chomp('/')}/bsv_wallet_#{name}"
        end
      end

      def self.registry; @registry ||= Registry.new; end
      def self.configure
        yield(registry)
        registry
      end
      def self.wallet(name) = registry[name]
      def self.reset! = (@registry = nil)

      # Load ~/.bsv-wallet/fixtures.rb (or BSV_WALLET_FIXTURES=<path>).
      # Absent file is a clean no-op (operator without one falls back
      # to nothing-registered — CLI.boot raises a clear error).
      def self.load_config_file!(path = nil)
        path ||= ENV.fetch('BSV_WALLET_FIXTURES',
                           File.expand_path('~/.bsv-wallet/fixtures.rb'))
        return unless File.exist?(path)

        BSV.logger&.info { "[BSV::Wallet::Fixtures] loading: #{path}" }
        load(path)
        path
      end
    end
  end
end
```

### `gem/bsv-wallet/config/fixtures.example.rb`

```ruby
# frozen_string_literal: true

BSV::Wallet::Fixtures.configure do |f|
  # Postgres base URL — per-wallet DBs derive as <base>/bsv_wallet_<name>
  f.postgres_base = ENV.fetch('BSV_WALLET_POSTGRES', nil)

  # Integration specs
  f.wallet :alice, wif: ENV.fetch('BSV_WALLET_WIF_ALICE', nil)
  f.wallet :bob,   wif: ENV.fetch('BSV_WALLET_WIF_BOB', nil)
  f.wallet :carol, wif: ENV.fetch('BSV_WALLET_WIF_CAROL', nil)

  # E2E harness funder
  f.wallet :sdk, wif: ENV.fetch('BSV_WALLET_WIF_SDK', nil)

  # Unit spec test DB (no WIF — specs generate their own keys)
  f.wallet :test

  # E2E fleet — WIFs derived at runtime from sdk; harness registers
  # these when it boots. Listed here for visibility of the inventory.
  # (1..5).each { |n| f.wallet :"w#{n}" }
end
```

### CLI.boot migration

```ruby
# Named wallet → fixtures registry (lazily loads fixtures.rb on first
# wallet-name boot). End-user (unnamed) → BSV::Wallet.config.
if wallet_name
  BSV::Wallet::Fixtures.load_config_file!
  fixture = BSV::Wallet::Fixtures.wallet(wallet_name.to_sym)
  abort missing_wif_message(wallet_name) if fixture.nil? || fixture.wif.nil? || fixture.wif.empty?

  wif = fixture.wif
  db_url = fixture.database_url
else
  wif = BSV::Wallet.config.wif
  abort missing_wif_message(nil) if wif.nil? || wif.empty?

  db_url = BSV::Wallet.config.database_url
end
db_url ||= default_sqlite_url(wallet_name)
```

`env_fetch`, `env_fetch_optional`, `derive_postgres_url` deleted from CLI. `missing_wif_message` kept (still useful for the abort).

### E2E harness migration

`WalletHarness#install_derived_wifs!` registers w1..w5 into Fixtures directly instead of mutating ENV:

```ruby
def install_derived_wifs!
  sdk_wif = BSV::Wallet::Fixtures.wallet(:sdk)&.wif || ENV.fetch('BSV_WALLET_WIF_SDK')
  wifs = E2E::WalletDerivation.derive_by_name(sdk_wif: sdk_wif)
  BSV::Wallet::Fixtures.configure do |f|
    wifs.each { |name, wif| f.wallet name.to_sym, wif: wif }
  end
end
```

`install_derived_db_urls!` collapses — Fixtures derivation handles it.

### Unit spec helper

```ruby
# spec/bsv/wallet/store/shared_context.rb
test_db_url = BSV::Wallet::Fixtures.wallet(:test)&.database_url
```

The example fixtures file registers `:test` so this resolves when `BSV_WALLET_POSTGRES` is set. When unset, returns nil → SQLite fallback.

### Integration spec migration

Each `spec/integration/*.rb` switches from:

```ruby
wif = ENV.fetch("BSV_WALLET_WIF_#{name.upcase}")
db = Sequel.connect(ENV.fetch("DATABASE_URL_#{name.upcase}"))
```

to:

```ruby
BSV::Wallet::Fixtures.load_config_file!
fixture = BSV::Wallet::Fixtures.wallet(name.to_sym)
wif = fixture.wif
db = Sequel.connect(fixture.database_url)
```

## Files touched

| File | Change |
|---|---|
| `lib/bsv/wallet/fixtures.rb` | NEW |
| `lib/bsv/wallet.rb` | `require_relative 'wallet/fixtures'` |
| `lib/bsv/wallet/cli.rb` | Delete `env_fetch`/`env_fetch_optional`/`derive_postgres_url`. Migrate boot. |
| `bin/walletd` | Migrate boot. |
| `config/fixtures.example.rb` | NEW (shipped via gemspec) |
| `bsv-wallet.gemspec` | (already includes `config/*` from #277) |
| `spec/bsv/wallet/fixtures_spec.rb` | NEW |
| `spec/bsv/wallet/store/shared_context.rb` | Migrate |
| `spec/support/e2e/wallet_harness.rb` | Migrate |
| `spec/support/e2e/daemon_supervisor.rb` | Migrate |
| `spec/support/e2e/wallet_harness_spec.rb` | Migrate / adjust |
| `spec/bin/boot_spec.rb` | Delete `derive_postgres_url` tests (helper deleted); keep `default_sqlite_url` etc. |
| `spec/integration/cli_spec.rb` | Migrate |
| `spec/integration/consolidation_dry_run_spec.rb` | Migrate |
| `spec/integration/stress_cascade_spec.rb` | Migrate |
| `CLAUDE.md` | Update Dev/test mode section to reference `Fixtures` |
| `README.md` | (no end-user impact — out of scope) |

## Acceptance criteria

- [ ] `BSV::Wallet::Fixtures.configure` / `.wallet(name)` / `.load_config_file!` / `.reset!` API.
- [ ] Gem ships `config/fixtures.example.rb`.
- [ ] `CLI.boot(wallet_name: 'alice')` consumes `Fixtures.wallet(:alice)`; legacy helpers deleted.
- [ ] `bin/walletd` same.
- [ ] E2E harness registers `w1`..`w5` via `Fixtures.configure` instead of ENV mutation.
- [ ] Unit spec helper uses `Fixtures.wallet(:test)`.
- [ ] Integration specs (`cli_spec`, `consolidation_dry_run`, `stress_cascade`) read fixtures via the registry.
- [ ] CLAUDE.md updated.
- [ ] Full unit suite green on both DBs; rubocop clean.
- [ ] Integration suite: at least one run against the live shell env confirms WIF + DB URL still resolve (per the project's "all specs means ALL" memory).

## Out of scope

- End-user configuration — #277 done.
- `bin/setup-dev` or DB-creation tooling — operator concern.
- Replacing GitHub Actions secrets mechanism.

## Commit shape

Single feature commit on `feat/292-fixtures-config`:

`feat(config): central BSV::Wallet::Fixtures surface (#292)`

## Verification gate

- `cd gem/bsv-wallet && bundle exec rspec spec/bsv spec/bin` (SQLite)
- `cd gem/bsv-wallet && BSV_WALLET_POSTGRES=postgres://postgres:postgres@localhost:5433/ bundle exec rspec spec/bsv spec/bin` (Postgres)
- `cd gem/bsv-wallet && bundle exec rubocop`
- `cd gem/bsv-wallet && bundle exec rspec spec/integration` (live WIFs, should be 11/11 modulo the documented intermittent)
