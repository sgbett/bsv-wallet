# Store Auto-Discovery — Plan

**Issue:** #117
**Branch:** `feat/117-store-auto-discovery`
**Date:** 2026-05-16
**Follow-up tracked:** #123 (run engine specs against SQLite)

## Overview

The wallet gem (`bsv-wallet`) still hard-references `bsv-wallet-postgres` in its CLI boot path: a top-level `require`, direct instantiation of `BSV::Wallet::Postgres::Store::*` classes, and a `Gem::Specification.find_by_name('bsv-wallet-postgres')` lookup to find migrations. With the default SQLite store (#116) and shared `Store::Base` orchestration (#120) in place, this coupling is the last thing standing between the wallet gem and full backend independence.

This plan replaces those hard references with gem-presence-based auto-discovery: install `bsv-wallet-postgres` to use Postgres, omit it to use SQLite. An explicit `DATABASE_URL` overrides discovery by scheme.

## Scope (per HLR + investigation)

The actual coupling surface is narrower than the HLR suggests:

| Location | Coupling | Action |
|---|---|---|
| `gem/bsv-wallet/lib/bsv/wallet/cli.rb` (~lines 34, 44–63, 79) | top-level `require 'bsv-wallet-postgres'` + 9 direct Postgres class references | rewrite the boot path |
| `gem/bsv-wallet/lib/bsv/wallet/engine.rb:16-19` | docstring example using `PostgresStore.new` | refresh comment |
| `gem/bsv-wallet/lib/bsv/wallet/daemon.rb:11-14` | docstring discussing postgres independence | refresh comment |
| `gem/bsv-wallet/bsv-wallet.gemspec` | ✅ already free of postgres | unchanged |
| `gem/bsv-wallet/Gemfile` | postgres in dev/test only | unchanged |
| `gem/bsv-wallet/spec/**` | engine specs use Postgres directly | **out of scope — tracked in #123** |

The shared orchestration work (#120) means each backend already exposes the same shape: `Connection.connect / .migrate! / .bind_models!` plus the four service classes (Store, ProofStore, UTXOPool, BroadcastQueue). Auto-discovery is mostly about picking *which namespace* to call into.

## Detection logic

```ruby
def pick_backend(db_url)
  if db_url
    # Explicit URL wins — honour the scheme the user chose
    db_url.start_with?('postgres') ? load_postgres! : BSV::Wallet::Store
  else
    # No URL — gem presence drives the choice
    begin
      require 'bsv-wallet-postgres'
      BSV::Wallet::Postgres
    rescue LoadError
      BSV::Wallet::Store
    end
  end
end

def load_postgres!
  require 'bsv-wallet-postgres'
  BSV::Wallet::Postgres
rescue LoadError
  abort 'DATABASE_URL is postgres:// but bsv-wallet-postgres is not in your bundle'
end
```

Behaviors this produces:

- **Bundle without postgres** → SQLite default, the postgres gem is never touched.
- **Bundle with postgres, no `DATABASE_URL`** → Postgres at `postgres://localhost/bsv_wallet_${wallet_name || 'default'}`. If the postgres server isn't running, the connect call raises loudly (the "did you forget Docker?" failure mode).
- **`DATABASE_URL=postgres://...`** → postgres backend (load gem or abort).
- **`DATABASE_URL=sqlite://...`** → SQLite, even if postgres gem is loadable.

The Bundler restriction means `require 'bsv-wallet-postgres'` only succeeds if it's in the user's Gemfile — system-wide installs don't leak into bundle-loaded apps.

## Default URLs

Used only when `DATABASE_URL` (and its wallet-name-suffixed variants) are unset.

| Backend | Default URL |
|---|---|
| SQLite | `sqlite://~/.bsv-wallet/${wallet_name \|\| 'default'}.db` (directory auto-created) |
| Postgres | `postgres://localhost/bsv_wallet_${wallet_name \|\| 'default'}` (raises on connect failure) |

Wallet-name suffix matches the existing WIF env-var pattern. The directory `~/.bsv-wallet/` is created with `FileUtils.mkdir_p` on first use.

The multi-wallet env-var fallback chain (`BSV_WALLET_DATABASE_URL_ALICE` → `DATABASE_URL_ALICE` → `DATABASE_URL` → backend default) preserves the current `env_fetch` behavior — only the terminal step changes from "abort" to "use default".

## Backend entry-point shape

Each backend exposes a `bootstrap(db:)` module method that vends the four service instances. This puts the concrete-class knowledge inside each backend, so the CLI never names `SQLite`, `Postgres::Store::Postgres`, `ProofStore`, etc.

### Wallet gem

```ruby
# gem/bsv-wallet/lib/bsv/wallet/store.rb
module BSV::Wallet::Store
  # ...existing autoloads...

  # Returns the four wallet services wired to the given Sequel::Database.
  # Used by the CLI auto-discovery boot path; engine consumers may inject
  # their own service instances instead.
  def self.bootstrap(db:)
    store = SQLite.new(db: db)
    {
      store:           store,
      proof_store:     ProofStore.new(db: db),
      utxo_pool:       UTXOPool.new(store: store),
      broadcast_queue: BroadcastQueue.new(db: db)
    }
  end
end
```

### Postgres gem

```ruby
# gem/bsv-wallet-postgres/lib/bsv/wallet/postgres/store.rb
module BSV::Wallet::Postgres::Store
  # ...existing autoloads...

  def self.bootstrap(db:)
    store = Postgres.new(db: db)
    {
      store:           store,
      proof_store:     ProofStore.new(db: db),
      utxo_pool:       UTXOPool.new(store: store),
      broadcast_queue: BroadcastQueue.new(db: db)
    }
  end
end
```

Symmetric shape; each gem owns its own class naming.

## CLI rewrite

```ruby
def boot(wallet_name: nil, network: :mainnet)
  require_dotenv_optional
  require 'sequel'
  require 'logger'
  require 'bsv-wallet'

  setup_logger

  wif = env_fetch('WIF', wallet_name)
  db_url = env_fetch_optional('DATABASE_URL', wallet_name)

  backend = pick_backend(db_url)
  db_url ||= default_url_for(backend, wallet_name)

  backend::Store::Connection.connect(db_url)
  backend::Store::Connection.migrate!
  backend::Store::Connection.bind_models!
  db = backend::Store::Connection.db

  services = backend::Store.bootstrap(db: db)

  private_key = BSV::Primitives::PrivateKey.from_wif(wif)
  key_deriver = BSV::Wallet::KeyDeriver.new(private_key: private_key)

  network_provider = BSV::Network::Providers::WhatsOnChain.send(network)
  network_services = BSV::Network::Services.new(providers: [network_provider])
  chain_tracker = BSV::Network::ChainTracker.new(db: db, services: network_services)

  engine = BSV::Wallet::Engine.new(
    **services,
    key_deriver:    key_deriver,
    chain_tracker:  chain_tracker,
    network_provider: network_provider,
    network:        network,
    limp_threshold: parse_limp_threshold
  )

  { engine:, **services, key_deriver:, db:, identity_key: key_deriver.identity_key, private_key: }
end
```

About 25 lines of boot logic vs the current 50+. Critically:

- **No top-level `require 'bsv-wallet-postgres'`** — only inside `pick_backend`'s rescue-guarded require.
- **No direct Postgres class references** — `backend::Store.bootstrap` does the wiring, returning a hash.
- **No `Gem::Specification.find_by_name`** — `Connection.migrate!` already knows where its own migrations live (both backends had this since #119; the CLI was just bypassing it).

### Note on namespace nesting

`backend::Store::Connection` works for both backends because the wallet gem's Connection lives at `BSV::Wallet::Store::Connection` and the postgres gem's at `BSV::Wallet::Postgres::Store::Connection`. With `backend = BSV::Wallet::Store` or `BSV::Wallet::Postgres`, the `::Store::Connection` suffix is consistent. The wallet gem's `Store` is its own concept (it's the module containing both the SQLite implementation and the shared `Base`); the postgres gem's `Store` is nested inside the `Postgres` namespace. The dual-suffix `backend::Store::Connection` exploits that symmetry.

## Doc updates

- `engine.rb:16-19` — replace `PostgresStore.new(db)` example with the auto-discovery story (or generic `store: backend::Store.bootstrap(db:)[:store]` form).
- `daemon.rb:11-14` — comment already describes the backend-agnostic design; refresh phrasing to point at the new bootstrap pattern.

## Acceptance criteria (from issue #117)

- [ ] Zero `require 'bsv-wallet-postgres'` in the wallet gem source (only in gemspec as optional dev dependency — *already true*; verify after rewrite)
- [ ] CLI boots with SQLite by default when `bsv-wallet-postgres` is not in the bundle and no `DATABASE_URL` is set
- [ ] CLI uses Postgres when `bsv-wallet-postgres` is in the bundle (with default URL if `DATABASE_URL` unset, explicit URL if set)
- [ ] CLI honours `DATABASE_URL` scheme as override (sqlite:// → SQLite even with postgres gem present)
- [ ] Engine accepts injected store instances (no behavioural change — *already true*; verify no regression)
- [ ] `bsv-wallet.gemspec` does not depend on `bsv-wallet-postgres` (*already true*; verify after rewrite)
- [ ] Daemon comments updated to reflect the new discovery mechanism

## Verification

```bash
# 1. Spec suites still pass
cd gem/bsv-wallet && bundle exec rspec
cd gem/bsv-wallet-postgres && bundle exec rspec
cd gem/bsv-wallet && bundle exec rubocop

# 2. Manual auto-discovery smoke test
#    a) Postgres bundle, no URL
unset DATABASE_URL
cd gem/bsv-wallet && bundle exec bin/balance alice  # uses default postgres URL

#    b) Postgres bundle, sqlite override
DATABASE_URL=sqlite:///tmp/test.db bundle exec bin/balance alice  # uses sqlite

#    c) Wallet-only bundle (no postgres) — requires a separate Gemfile
#       to verify SQLite fallback when the gem is genuinely absent.
```

The third case can't be reproduced in the monorepo's standard bundle. Documenting it in the verification section is enough; a user-facing integration smoke test would require a separate test fixture.

## Out of scope

- **Engine specs against SQLite** — tracked separately in #123. This plan focuses on the CLI boot path; the engine spec's direct Postgres usage is an integration concern, not a coupling concern.
- **Docker / CloudFormation templates** — the user has flagged these as future work; auto-discovery removes the wallet-gem-side blockers but ops scaffolding is its own deliverable.
- **`Sequel::Model.db` global teardown** — both Connection modules set `Sequel::Model.db = @db` for autoload bootstrap (per #119). Auto-discovery doesn't change this; running both backends in one process remains untested territory.

## Sequencing

1. #116 — Default SQLite store ✅
2. #119 — Restructure Postgres to match ✅
3. #120 — Extract shared orchestration ✅
4. **#117 — Auto-discovery wiring** ← this plan
5. #123 — Engine specs against SQLite (follow-up)
