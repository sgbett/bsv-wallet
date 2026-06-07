# #277 — Central configuration surface (BSV::Wallet.configure block)

**Issue:** #277
**Date:** 2026-06-07
**Status:** Plan — approved, executing
**Branch:** `feat/277-central-config` off `master`

## Goal

Build `BSV::Wallet.configure do |c| ... end` as **the** end-user configuration surface. Find every end-user-facing configuration knob in the code, extract it to the Config class, and route the call sites through `BSV::Wallet.config.x`. The configure block reads the corresponding ENV vars by default; users can override either by editing their `~/.bsv-wallet/config.rb` or by setting the ENV var.

The HLR's "Phase 1 advisory / Phase 2 migration" framing was exploratory — actually doing this means moving the call sites, not just adding a parallel surface that nothing reads.

Also folds in the `dotenv` removal and the pending CLAUDE.md audience-split clarification.

## Scope: end-user vs dev/test

**In scope** — knobs an end-user installing the gem cares about:

| ENV var | Today read at | Config attr |
|---|---|---|
| `DATABASE_URL` | `cli.rb` via `env_fetch_optional` (unnamed wallet path) | `c.database_url` |
| `WIF` | `cli.rb` via `env_fetch` (unnamed wallet path) | `c.wif` |
| `LIMP_THRESHOLD` | `cli.rb:88` | `c.limp_threshold` |
| `BSV_WALLET_HINTS_SOCKET` | `engine.rb:1091` + `daemon.rb:163` | `c.hints_socket` |
| `BSV_WALLET_TX_CACHE_SIZE` | `engine/hydrated_tx_cache.rb:49` | `c.tx_cache_size` |
| `BSV_WALLET_DAEMON_SEQUEL_CONNECTIONS` | `bin/walletd:46` | `c.daemon_pool_size` |
| (`BSV_WALLET_NETWORK` — not currently read; today's `network: :mainnet` kwarg) | new | `c.network` (expose for completeness) |

**Out of scope — sibling HLR (filed as part of this PR's setup):** dev/test scaffolding for multi-wallet integration runs.

- `BSV_WALLET_POSTGRES` — Postgres base for per-wallet derivation
- `BSV_WALLET_WIF_<NAME>` (ALICE, BOB, CAROL, SDK, W1..W5)
- `DATABASE_URL_<NAME>` — per-wallet override
- `WIF_<NAME>` — fallback suffix in `env_fetch`

These stay in `CLI.boot`'s `env_fetch` / `env_fetch_optional` helpers and `derive_postgres_url` for now. Sibling HLR will design a `BSV::Wallet::Test.configure` (or similar) shape that centralises the named-wallet fixture surface.

**Also out of scope:** `BSV_WALLET_CONFIG` — the env var that names the config file's path. That's the bootstrap; can't be inside the file.

## Implementation

### 1. `lib/bsv/wallet/config.rb`

```ruby
module BSV
  module Wallet
    class Config
      attr_accessor :database_url, :wif, :network,
                    :limp_threshold,
                    :daemon_pool_size,
                    :tx_cache_size, :hints_socket

      def initialize
        # Defaults read ENV (preserving today's behaviour for users who
        # have set shell env vars). The configure block in a user's
        # ~/.bsv-wallet/config.rb can override any of these.
        @database_url     = ENV.fetch('DATABASE_URL', nil)
        @wif              = ENV.fetch('WIF', nil)
        @network          = ENV.fetch('BSV_WALLET_NETWORK', 'mainnet').to_sym
        @limp_threshold   = Integer(ENV.fetch('LIMP_THRESHOLD', '50000'))
        @daemon_pool_size = Integer(ENV.fetch('BSV_WALLET_DAEMON_SEQUEL_CONNECTIONS', '16'))
        @tx_cache_size    = Integer(ENV.fetch('BSV_WALLET_TX_CACHE_SIZE', '1000'))
        @hints_socket     = blank_to_nil(ENV.fetch('BSV_WALLET_HINTS_SOCKET', nil))
      end

      private

      def blank_to_nil(s) = s && !s.strip.empty? ? s : nil
    end

    module_function

    # Singleton config instance.
    def config
      @config ||= Config.new
    end

    # User-facing configuration block.
    def configure
      yield(config)
      config
    end

    # Reset (test-only — sometimes useful between specs).
    def reset_config!
      @config = nil
    end

    # Load ~/.bsv-wallet/config.rb (or BSV_WALLET_CONFIG=<path>) if present.
    # Silent no-op when absent.
    def load_config_file!(path = nil)
      path ||= ENV.fetch('BSV_WALLET_CONFIG',
                         File.expand_path('~/.bsv-wallet/config.rb'))
      return unless File.exist?(path)

      BSV.logger&.info { "[BSV::Wallet] loading config: #{path}" }
      load(path)
    end
  end
end
```

Key choices:

- **Defaults baked into `Config#initialize` read ENV.** This preserves today's behaviour for users with shell env vars set, AND gives `BSV::Wallet.config.x` a working value even when no `~/.bsv-wallet/config.rb` exists. The ENV reads are now in ONE place (`Config#initialize`) instead of seven.
- **Lazy `@config ||= Config.new`** — first `BSV::Wallet.config` call instantiates; subsequent calls return same singleton.
- **`load_config_file!` runs AFTER first read is OK** because the user's `configure` block reassigns attrs on the existing singleton.

### 2. `gem/bsv-wallet/config/config.example.rb`

Template the user copies to `~/.bsv-wallet/config.rb`. Documents every knob. Each line either confirms the default or shows how to override.

```ruby
# ~/.bsv-wallet/config.rb — BSV Wallet end-user configuration
#
# This file is loaded at boot by BSV::Wallet.load_config_file!. Override
# the path via BSV_WALLET_CONFIG=<path> if you keep it elsewhere.
#
# Settings here override the defaults in BSV::Wallet::Config (which
# themselves read ENV for backwards compatibility). Three ways to use:
#
#   1. Do nothing — Config defaults read shell ENV vars. Set
#      LIMP_THRESHOLD=100000 in your shell and that's it.
#
#   2. Pin a value in this file:
#        c.limp_threshold = 100_000
#      ignoring the ENV var entirely.
#
#   3. Read an alternate ENV var or do other computation:
#        c.limp_threshold = Integer(ENV.fetch('MY_LIMP_VAR', '50000'))

BSV::Wallet.configure do |c|
  # --- Wallet identity ---

  # Database URL (sqlite:// or postgres://)
  # c.database_url = 'sqlite://~/.bsv-wallet/default.db'

  # Wallet private key (WIF format)
  # c.wif = 'L1...'

  # Network: :mainnet or :testnet
  # c.network = :mainnet

  # --- Wallet behaviour ---

  # Limp mode threshold (sats) — below this, outbound is blocked.
  # c.limp_threshold = 50_000

  # --- Daemon (walletd) ---

  # Sequel pool size for walletd
  # c.daemon_pool_size = 16

  # --- EF hint cache (#269) ---

  # EF cache capacity (entries)
  # c.tx_cache_size = 1000

  # Opt-in cross-process EF hint socket. Producers (CLI, API) PUSH
  # hints to walletd via this socket, eliminating the broadcast-time
  # DB JOIN. Set to a path writable by all producers and readable
  # by walletd.
  # c.hints_socket = '/tmp/bsv-wallet-hints.sock'
end
```

### 3. Wire `load_config_file!` into `CLI.boot`

Top of `BSV::Wallet::CLI.boot`:

```ruby
def boot(wallet_name: nil, network: :mainnet)
  require 'bsv-wallet'
  BSV::Wallet.load_config_file!   # replaces require 'dotenv/load'
  # ... rest unchanged for now
end
```

### 4. Replace ENV.fetch call sites with `BSV::Wallet.config.x`

| File | Before | After |
|---|---|---|
| `engine/hydrated_tx_cache.rb:49` | `Integer(ENV.fetch('BSV_WALLET_TX_CACHE_SIZE', DEFAULT_CAPACITY))` | `BSV::Wallet.config.tx_cache_size` |
| `engine.rb:1091` (`publish_beef_hint`) | `socket_path = ENV.fetch('BSV_WALLET_HINTS_SOCKET', nil); socket_path = nil if socket_path&.strip&.empty?` | `socket_path = BSV::Wallet.config.hints_socket` (blank-to-nil handled inside Config) |
| `daemon.rb:163` | `value = ENV.fetch('BSV_WALLET_HINTS_SOCKET', nil)` | `value = BSV::Wallet.config.hints_socket` |
| `cli.rb:88` | `limp_threshold_raw = ENV.fetch('LIMP_THRESHOLD', BSV::Wallet::Engine::LIMP_THRESHOLD); limp_threshold = Integer(limp_threshold_raw) rescue abort...` | `limp_threshold = BSV::Wallet.config.limp_threshold` (Config's `Integer(...)` raises at load time, not boot time) |
| `bin/walletd:46` | `daemon_pool_size = ENV.fetch('BSV_WALLET_DAEMON_SEQUEL_CONNECTIONS', '16').to_i` | `daemon_pool_size = BSV::Wallet.config.daemon_pool_size` |
| `cli.rb` unnamed-wallet path | `wif = env_fetch('WIF', wallet_name)` (still applies to dev/test named-wallet) | When `wallet_name` is nil: `wif = BSV::Wallet.config.wif`; when named: keep `env_fetch('WIF', wallet_name)` per the sibling-HLR scope split |
| `cli.rb` unnamed-wallet DB path | `db_url ||= default_sqlite_url(wallet_name)` after env_fetch_optional/derive_postgres_url fall through | When `wallet_name` is nil: `db_url = BSV::Wallet.config.database_url || default_sqlite_url(nil)`; when named: keep today's chain |

After this PR, the **only** `ENV.fetch` calls for the in-scope vars are inside `Config#initialize`. All consumer sites read from config.

### 5. Remove dotenv

- `Gemfile`: remove `gem 'dotenv'`
- `Gemfile.lock`: regen via `bundle install`
- `cli.rb`: remove the `require 'dotenv/load'` rescue block (lines 33-37)
- `cli.rb`: update the header doc comment (lines 10-15) to reference the config file and the dev/test-vs-end-user split
- `gem/bsv-wallet/.env.example`: delete (no .env file convention)

### 6. Documentation

- `README.md`: end-user section gets the config-file pointer (`config/config.example.rb` as the canonical reference; copy to `~/.bsv-wallet/config.rb` to override).
- `CLAUDE.md`: commit the pending audience-split clarification (dev/test mode vs end-user mode) — directly supports this PR's scope split.

### 7. Open sibling HLR for dev/test scaffolding (FIRST — as setup)

Before implementing, file the sibling HLR so the dev/test boundary is explicit and tracked. Title: `[HLR] Centralise dev/test wallet configuration surface (named-wallet fixtures)`. Body covers: `BSV_WALLET_POSTGRES`, `BSV_WALLET_WIF_<NAME>`, `DATABASE_URL_<NAME>`, `WIF_<NAME>`, and the `env_fetch` / `derive_postgres_url` helpers currently in CLI.boot. Out of scope here, in scope there.

### 8. Tests

`spec/bsv/wallet/config_spec.rb` (new):

- Default `Config.new` reads ENV with documented defaults (override ENV in spec, instantiate, assert).
- `BSV::Wallet.configure { |c| ... }` yields the singleton; assignments persist.
- `BSV::Wallet.config` returns the same singleton across calls.
- `BSV::Wallet.reset_config!` clears the singleton (next read instantiates fresh).
- `BSV::Wallet.load_config_file!` with present file: evaluates it, configure block applies.
- `BSV::Wallet.load_config_file!` with absent default path: no-op.
- `BSV::Wallet.load_config_file!` with `BSV_WALLET_CONFIG` env: loads from that path.
- `BSV::Wallet.load_config_file!` with a file that raises: surfaces the error.

Plus updates to existing specs that mock `ENV.fetch('BSV_WALLET_HINTS_SOCKET', ...)` etc. — those need to drive `BSV::Wallet.config.hints_socket` or call `reset_config!` to refresh after `ENV` mutation.

## Commit shape

Two commits on `feat/277-central-config`:

1. **`docs: clarify wallet configuration model in CLAUDE.md`** — the pending audience-split clarification.
2. **`feat(config): central BSV::Wallet.configure surface + remove dotenv (#277)`** — the actual implementation.

## Verification gate

- `cd gem/bsv-wallet && bundle install` (regen Gemfile.lock without dotenv)
- `cd gem/bsv-wallet && bundle exec rspec spec/bsv spec/bin` (SQLite)
- `cd gem/bsv-wallet && BSV_WALLET_POSTGRES=postgres://postgres:postgres@localhost:5433/ bundle exec rspec spec/bsv spec/bin` (Postgres)
- `cd gem/bsv-wallet && bundle exec rubocop`
- (Skip integration suite — irrelevant to a config-surface change; covered by unit specs.)

## Acceptance criteria

- [x] `BSV::Wallet.configure do |c| ... end` API exists, callable, populates a singleton accessible via `BSV::Wallet.config`.
- [x] Gem ships `config/config.example.rb` template listing every end-user knob.
- [x] Boot path loads `~/.bsv-wallet/config.rb` (or `BSV_WALLET_CONFIG` env path); absent is a clean no-op.
- [x] **Every** in-scope ENV.fetch call site in `lib/` and `bin/` reads from `BSV::Wallet.config.x` instead. The ONLY place those env vars are read is `Config#initialize`.
- [x] `bin/walletd` consumes `BSV::Wallet.config.daemon_pool_size`.
- [x] Opt-in features (EF hint socket) appear as commented-out blocks in the template with default visible.
- [x] README points operators at the config file as the canonical reference.
- [x] dotenv removed (Gemfile + cli.rb require + cli.rb header + `.env.example`).
- [x] Sibling HLR opened for dev/test scaffolding (named-wallet fixtures).
- [x] Full unit suite (Postgres + SQLite) + rubocop green.

## Out of scope

- Dev/test scaffolding (named-wallet WIFs, BSV_WALLET_POSTGRES, DATABASE_URL_<NAME>) — sibling HLR opened.
- Non-env config sources (Vault, KMS, k8s ConfigMaps).
- Dynamic config reload at runtime.
- YAML / JSON config format.

## Risks

| Risk | Mitigation |
|---|---|
| Singleton populated before user's config.rb loads → user overrides don't take effect | `load_config_file!` reassigns attrs on the existing singleton (doesn't replace it). Order in CLI.boot: `load_config_file!` runs at the top, before any other code reads config. |
| Config file errors silently corrupt boot | `load_config_file!` lets errors propagate (no rescue). Bad config = loud boot failure. |
| Tests pollute the global `@config` singleton across examples | `BSV::Wallet.reset_config!` helper exists for test cleanup. Config specs use it in `before` blocks. |
| Removing dotenv breaks anyone with a real `.env` file | HLR confirms dotenv is no longer used; CI uses shell env; `.env.example` deleted. Anyone with `.env` should migrate to `~/.bsv-wallet/config.rb`. |
| Per-call-site behaviour shift from "read ENV at this exact moment" to "read config snapshot from boot time" | In practice nothing in the wallet mutates ENV at runtime. If a future code path needs live ENV reads, it would re-read from ENV directly — not a regression of current behaviour. |
