# Engine Specs Against SQLite — Plan

**Issue:** #123
**Branch:** `feat/123-engine-specs-against-sqlite`
**Date:** 2026-05-16

## Overview

`engine_spec.rb` and its four sibling spec files exercise the BRC-100 Engine against a real Store — but the Store is hardcoded to `BSV::Wallet::Postgres`. Now that the default SQLite store exists (#116) and shared `Store::Base` orchestration (#120) confirms the engine logic is backend-agnostic by design, the same specs should run against SQLite by default and Postgres as a parallel verification.

The default flips: SQLite becomes the primary engine-spec backend (in-memory, no infrastructure, fast feedback). Postgres becomes the secondary "did we break Postgres-specifically?" canary. Both backends run in CI; both must stay green.

## Scope

Five spec files cluster around engine testing, all guarded by `if: POSTGRES_AVAILABLE`, all `include_context 'engine setup'`:

| File | LOC | Direct Postgres refs |
|---|---:|---:|
| `engine_spec.rb` | 2803 | 3 (lines 168, 484, 804) |
| `engine/shared_context.rb` | 157 | 7 (the setup itself) |
| `engine/limp_mode_spec.rb` | — | 0 (guard only) |
| `engine/porcelain_spec.rb` | — | 0 (guard only) |
| `engine/wbikd_spec.rb` | — | 0 (guard only) |

The 4 satellite specs only touch Postgres via the `POSTGRES_AVAILABLE` constant. The bulk of the work is `shared_context.rb` + 3 surgical replacements in `engine_spec.rb`.

The 3 direct refs in `engine_spec.rb` reach around the Store interface to verify implementation details:

- **L168:** `BSV::Wallet::Postgres::Store::BroadcastQueue.new(services: services)` — overriding `broadcast_queue` to inject a mocked services double
- **L484:** `BSV::Wallet::Postgres::Store::Action.where(id: ...).delete` — simulating reaper by direct row delete
- **L804:** `BSV::Wallet::Postgres::Store::Action.first(wtxid: ...)` — reading `tx_proof_id` column not exposed by Store interface

These need backend-aware namespace access — same pattern as `Store::Base#models`.

## Design

### 1. Parameterise `shared_context.rb` by `BSV_WALLET_BACKEND`

```ruby
# Read backend selection from env; default to SQLite (the default store).
BSV_WALLET_BACKEND = (ENV['BSV_WALLET_BACKEND'] || 'sqlite').to_sym

unless defined?(ENGINE_BACKEND)
  begin
    require 'sequel'
    case BSV_WALLET_BACKEND
    when :sqlite
      require 'bsv-wallet'
      ENGINE_BACKEND = BSV::Wallet::Store
      TEST_DB_URL = ENV.fetch('DATABASE_URL', 'sqlite::memory:')
    when :postgres
      require 'bsv-wallet-postgres'
      ENGINE_BACKEND = BSV::Wallet::Postgres::Store
      TEST_DB_URL = ENV.fetch('DATABASE_URL', 'postgres://postgres:postgres@localhost:5433/bsv_wallet_test')
    else
      raise "Unknown BSV_WALLET_BACKEND: #{BSV_WALLET_BACKEND}"
    end

    ENGINE_BACKEND::Connection.connect(TEST_DB_URL)
    ENGINE_BACKEND::Connection.migrate!
    ENGINE_BACKEND::Connection.bind_models!
    ENGINE_DB = ENGINE_BACKEND::Connection.db
    ENGINE_AVAILABLE = true
  rescue LoadError, Sequel::DatabaseConnectionError => e
    warn "Skipping engine integration specs: #{e.message}"
    ENGINE_AVAILABLE = false
  end
end
```

Key points:

- **Default to SQLite in-memory** — zero infra, fast feedback. The `transaction(rollback: :always)` wrapper around each example keeps data isolated.
- **`Store.bootstrap`** (from #117) returns the four services pre-wired to the backend. The shared context uses it for `store`, `utxo_pool`, `proof_store`, `broadcast_queue`.
- **`models` accessor** exposes the backend module for the 3 direct refs in `engine_spec.rb`. Reads cleanly as `models::Action.where(...)`.
- **`POSTGRES_AVAILABLE` → `ENGINE_AVAILABLE`** — the guard is now backend-agnostic.

### 2. Update `RSpec.shared_context 'engine setup'`

```ruby
RSpec.shared_context 'engine setup' do
  let(:services_hash)  { ENGINE_BACKEND.bootstrap(db: ENGINE_DB) }
  let(:store)          { services_hash[:store] }
  let(:utxo_pool)      { services_hash[:utxo_pool] }
  let(:proof_store)    { services_hash[:proof_store] }
  let(:broadcast_queue){ services_hash[:broadcast_queue] }
  let(:models)         { ENGINE_BACKEND }

  # ...rest unchanged — subject(:engine), key derivers, fund helpers, etc.

  around do |example|
    ENGINE_DB.transaction(rollback: :always, auto_savepoint: true) do
      example.run
    end
  end
end
```

### 3. Replace the 3 direct refs in `engine_spec.rb`

| Line | Before | After |
|---|---|---|
| 10 | `if: POSTGRES_AVAILABLE` | `if: ENGINE_AVAILABLE` |
| 168 | `BSV::Wallet::Postgres::Store::BroadcastQueue.new(services: services)` | `ENGINE_BACKEND::BroadcastQueue.new(services: services)` |
| 484 | `BSV::Wallet::Postgres::Store::Action.where(id: action[:id]).delete` | `models::Action.where(id: action[:id]).delete` |
| 804 | `BSV::Wallet::Postgres::Store::Action.first(wtxid: ...)` | `models::Action.first(wtxid: ...)` |

Update the four satellite specs' `if: POSTGRES_AVAILABLE` guards likewise.

### 4. CI: add a second Postgres step per Ruby job (Option B)

```yaml
- name: Run wallet specs (SQLite — default)
  run: bundle exec rspec --tag ~on_chain
  working-directory: gem/bsv-wallet
  env:
    BSV_WALLET_BACKEND: sqlite
    COVERAGE: ${{ matrix.ruby == '3.4' && 'true' || '' }}

- name: Run wallet specs (Postgres — backend canary)
  run: bundle exec rspec --tag ~on_chain
  working-directory: gem/bsv-wallet
  env:
    BSV_WALLET_BACKEND: postgres
    DATABASE_URL: postgres://postgres:postgres@localhost:5433/bsv_wallet_test
```

Both runs execute the full wallet suite. Coverage is captured only on the SQLite run (the default) to avoid double-counting in codecov.

CI is verification, not the source of truth — devs must run both locally before pushing:

```bash
BSV_WALLET_BACKEND=sqlite   bundle exec rspec
BSV_WALLET_BACKEND=postgres bundle exec rspec
```

## Why SQLite first

- **In-memory by default** (`sqlite::memory:`) — schema lives for the test-process lifetime, no file artifacts, fastest possible startup.
- **No Postgres infrastructure required** for the default dev loop. Devs without a local Postgres can still run the engine suite.
- **The engine is provably backend-agnostic** (#120) — there's no design reason to prefer Postgres. The historical default was an accident of Postgres being the first Store implementation.
- **Faster wall time** — SQLite specs typically run 2-3× faster than Postgres for unit-scale tests like these.

The Postgres run remains valuable as a canary: if a future change introduces backend-specific drift (a Postgres-only SQL feature, an array-column quirk, transaction-isolation difference), the Postgres step catches it.

## Acceptance criteria (from issue #123)

- [ ] Engine spec runs to green against both SQLite and Postgres backends
- [ ] No duplication of test bodies — backend selection is a setup concern
- [ ] CI runs both backends (sequential steps within each Ruby matrix entry)
- [ ] No new ARC mocking or fixtures required beyond what exists
- [ ] Default local-dev backend is SQLite (no Postgres infra required for first-run)

## Verification

```bash
# 1. Both backends pass locally
cd gem/bsv-wallet
BSV_WALLET_BACKEND=sqlite   bundle exec rspec
BSV_WALLET_BACKEND=postgres bundle exec rspec

# 2. Rubocop clean
bundle exec rubocop

# 3. Postgres gem suite unaffected
cd ../bsv-wallet-postgres
bundle exec rspec

# 4. CI green on PR (both backend steps must pass per Ruby version)
```

## Out of scope

- **Backend-specific tagging** (`if: BACKEND == :postgres`) — only worth adding when real divergence is observed. Don't pre-tag.
- **Engine spec restructure** — the 2803-line file stays as one spec. Splitting it is a separate concern.
- **Coverage on Postgres run** — only the SQLite run uploads coverage. Avoids double-counting; Postgres reaches the same lines.
- **bsv-wallet-postgres gem specs** — those are backend-specific by definition; they don't change.

## Risks

- **SQLite-specific test failures** are the most likely surface. The shared `Store::Base` orchestration claims the engine is backend-agnostic; this PR is the empirical test of that claim. Discovering and fixing those failures *is* the work.
- **In-memory SQLite + transactions** — Sequel handles SQLite savepoints fine, but the `auto_savepoint: true` option must work the same as on Postgres. Will verify during implementation; if it doesn't, fall back to file-backed SQLite at `/tmp`.
- **Sequel::Model.db global** — only one backend per process. Switching mid-run isn't supported. CI runs each backend as a separate step in a fresh ruby process. ✓

## Sequencing

1. #116 — Default SQLite store ✅
2. #119 — Restructure Postgres to match ✅
3. #120 — Extract shared orchestration ✅
4. #117 — Auto-discovery wiring ✅
5. **#123 — Engine specs against SQLite** ← this plan
