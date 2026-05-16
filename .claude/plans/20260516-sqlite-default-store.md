# Default Store Implementation — Plan

**Issue:** #116
**Branch:** `feat/116-sqlite-default-store`
**Date:** 2026-05-16

## Overview

The wallet gem ships with a default Store implementation backed by SQLite. This makes `bsv-wallet` standalone — install the gem and it works. No separate database, no extra gems.

Everything lives under `BSV::Wallet::Store` — a module that encapsulates connection management, Sequel models, and the service implementations. The tree depth reflects abstraction: walk down and you move from interfaces to infrastructure. Nothing outside `Store` needs to know that SQLite or Sequel exists.

## Architecture

```
BSV::Wallet::Store::
  Connection          — SQLite setup, pragmas, per-model DB binding
  SQLite         — implements Interface::Store (25 methods)
  UTXOPool            — implements Interface::UTXOPool
  ProofStore          — implements Interface::ProofStore
  BroadcastQueue      — implements Interface::BroadcastQueue
  BroadcastCallback   — Rack app for ARC webhooks
  ArcAdapter          — bridges BroadcastQueue with SDK ARC protocol
  Action, Output, …   — Sequel models (internal)
```

## Key design decisions

**Per-model DB binding.** `Connection.bind_models` calls `model.dataset = @db[table]` on each model class, avoiding the `Sequel::Model.db` global. This allows the default store and Postgres store to coexist in the same process.

**UUID generation in Ruby.** SQLite has no `gen_random_uuid()`. The `Action` model generates `reference` via `SecureRandom.uuid` in a `before_create` hook. Raw inserts (constraint specs) must provide it explicitly.

**insert_conflict ownership check.** SQLite returns `last_insert_rowid` even on `ON CONFLICT DO NOTHING` (Postgres returns nil). `SQLite#create_action` verifies ownership after each insert attempt.

**competing_txs as JSON text.** Postgres uses `text[]` via `pg_array`. The default store uses `JSON.generate` — write-only audit data, never queried.

## File layout

```
gem/bsv-wallet/
  db/migrations/
    001_create_schema.rb              # SQLite schema from reference/schema.md
  lib/bsv/wallet/
    store.rb                          # Module entry point + autoloads
    store/
      connection.rb                   # Database setup, pragmas, bind_models
      persistence.rb                  # Interface::Store implementation
      utxo_pool.rb                    # Interface::UTXOPool
      proof_store.rb                  # Interface::ProofStore
      broadcast_queue.rb              # Interface::BroadcastQueue
      broadcast_callback.rb           # Rack ARC webhook handler
      arc_adapter.rb                  # SDK ARC bridge
      models/
        display_txid.rb               # Shared mixin
        action.rb block.rb broadcast.rb …  # 17 Sequel models
  spec/bsv/wallet/store/
    shared_context.rb                 # In-memory SQLite, rollback isolation
    persistence_spec.rb               # Store interface tests
    utxo_pool_spec.rb proof_store_spec.rb …
    migration_spec.rb constraints_spec.rb
    models/
      action_spec.rb broadcast_spec.rb …
```

## SQLite-specific adaptations

| Area | Postgres | Default Store |
|------|----------|---------------|
| Enums | `pg_enum` | Text + CHECK constraint |
| `competing_txs` | `text[]` / `pg_array` | JSON text |
| `actions.reference` | `gen_random_uuid()` | `SecureRandom.uuid` hook |
| Primary keys | `identity: :always` | `primary_key :id` |
| Binary columns | `:bytea` | `:blob` |
| Outbound trigger | PL/pgSQL | SQLite `RAISE(ABORT)` |
| Foreign keys | Always on | `PRAGMA foreign_keys = ON` per connection |
| Model DB scope | Global `Sequel::Model.db` | Per-model `dataset=` |
| `insert_conflict` | Returns nil on DO NOTHING | Returns last_insert_rowid — ownership verified |
