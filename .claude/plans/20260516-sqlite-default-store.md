# Default Store Implementation — Plan

**Issue:** #116
**Branch:** `feat/116-sqlite-default-store`
**Date:** 2026-05-16

## Overview

The wallet gem ships with a default Store implementation backed by SQLite. This makes `bsv-wallet` standalone — install the gem and it works. No separate database, no extra gems.

The default store lives in the `BSV::Wallet` namespace: `Store`, `Action`, `Output`, etc. SQLite is an implementation detail, not part of the public API. When someone adds `bsv-wallet-postgres`, that's the override with its own `BSV::Wallet::Postgres` namespace.

## What goes where

```
gem/bsv-wallet/
  bsv-wallet.gemspec              # adds sequel + sqlite3 deps
  db/migrations/
    001_create_schema.rb           # SQLite migration (from reference/schema.md)
  lib/
    bsv/wallet/database.rb         # connect/disconnect + SQLite pragmas
    bsv/wallet/models/             # Sequel models (Action, Output, etc.)
    bsv/wallet/store.rb            # Store implementation
    bsv/wallet/utxo_pool.rb        # UTXOPool implementation
    bsv/wallet/proof_store.rb      # ProofStore implementation
    bsv/wallet/broadcast_queue.rb  # BroadcastQueue implementation
    bsv/wallet/broadcast_callback.rb
    bsv/wallet/arc_adapter.rb
  spec/
    bsv/wallet/store_spec.rb       # just store specs — no "sqlite" qualifier
    bsv/wallet/models/             # model specs
    ...
```

## Namespace

| Class | Purpose |
|-------|---------|
| `BSV::Wallet::Database` | Connect/disconnect, pragmas, migrate! |
| `BSV::Wallet::Store` | Default Store implementation |
| `BSV::Wallet::UTXOPool` | Default UTXOPool |
| `BSV::Wallet::ProofStore` | Default ProofStore |
| `BSV::Wallet::BroadcastQueue` | Default BroadcastQueue |
| `BSV::Wallet::Action` | Sequel model |
| `BSV::Wallet::Output` | Sequel model |
| ... | (all models in `BSV::Wallet` namespace) |

The Postgres gem keeps `BSV::Wallet::Postgres::Store` etc. — it's the one with the qualifier because it's the override.

## SQLite-specific adaptations (from Postgres)

| Area | Change |
|------|--------|
| Enums | Text + CHECK constraint (no pg_enum) |
| `competing_txs` | JSON text (no pg_array) |
| `actions.reference` | `SecureRandom.uuid` in `before_create` (no gen_random_uuid) |
| Primary keys | `primary_key :id` (no identity: :always) |
| Binary columns | `:blob` (no :bytea) |
| Timestamps | `:datetime` + `CURRENT_TIMESTAMP` |
| Outbound trigger | SQLite `RAISE(ABORT)` syntax |
| Foreign keys | `PRAGMA foreign_keys = ON` via `after_connect` |
| `insert_conflict` | Verify ownership after insert (SQLite returns last_insert_rowid on DO NOTHING) |

## Tasks

### Task 1: Migration and Database module

- `db/migrations/001_create_schema.rb` — derived from `reference/schema.md`
- `lib/bsv/wallet/database.rb` — connect, pragmas, migrate!

### Task 2: Models

All in `lib/bsv/wallet/models/`:
- Action, Broadcast, Output, Spendable, Input, Block, TxProof
- Basket, Label, ActionLabel, Tag, OutputTag
- OutputDetail, OutputBasket, Certificate, CertificateField, Setting
- DisplayTxid module

### Task 3: Service implementations

- `lib/bsv/wallet/store.rb` — implements Interface::Store
- `lib/bsv/wallet/utxo_pool.rb` — implements Interface::UTXOPool
- `lib/bsv/wallet/proof_store.rb` — implements Interface::ProofStore
- `lib/bsv/wallet/broadcast_queue.rb` — implements Interface::BroadcastQueue
- `lib/bsv/wallet/broadcast_callback.rb`
- `lib/bsv/wallet/arc_adapter.rb`

### Task 4: Gemspec and wiring

- Add `sequel` and `sqlite3` to `bsv-wallet.gemspec`
- Wire up autoloads/requires in the wallet module
- Include `db/**/*` in gem files

### Task 5: Specs

- Store, model, and service specs in `spec/bsv/wallet/`
- Shared context for DB setup (in-memory SQLite, migrations, rollback)
- No "sqlite" in spec names or tags

### Task 6: Verify

- `cd gem/bsv-wallet && bundle exec rspec` — all existing + new specs green
- Postgres specs unaffected
