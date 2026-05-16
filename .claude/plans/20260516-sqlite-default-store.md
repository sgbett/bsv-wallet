# SQLite Default Store — Implementation Plan

**Issue:** #116
**Branch:** `feat/116-sqlite-default-store`
**Date:** 2026-05-16

## Overview

Mechanical port of `bsv-wallet-postgres` to SQLite. Same interfaces, same hash-in/hash-out contract, different adapter. The gem structure mirrors Postgres 1:1 with namespace `BSV::Wallet::Sqlite`.

## Non-Trivial Differences from Postgres

| Area | Postgres | SQLite |
|------|----------|--------|
| Enums (`broadcast_intent`, `output_type`) | `pg_enum` | Text column + CHECK constraint |
| `competing_txs` | `text[]` via `Sequel.pg_array` | JSON text column |
| `actions.reference` default | `gen_random_uuid()` DB default | `SecureRandom.uuid` in `before_create` hook |
| Primary keys | `identity: :always` (BIGINT) | `primary_key :id` (INTEGER autoincrement) |
| Binary columns | `:bytea` | `:blob` |
| Timestamps | `:timestamptz` | `:datetime` + `CURRENT_TIMESTAMP` |
| Outbound spendable trigger | PL/pgSQL function | `BEFORE INSERT` trigger with `RAISE(ABORT, ...)` |
| Foreign keys | Always on | Requires `PRAGMA foreign_keys = ON` per connection |
| Journal mode | WAL by default | Requires `PRAGMA journal_mode = WAL` |
| Extensions | `pg_enum`, `pg_array` | None needed |
| Test cleanup | `truncate(cascade: true)` | `DELETE` with FK-aware ordering |

Everything else is find-and-replace `Postgres` -> `Sqlite`.

---

## Tasks

### Task 1: Scaffold gem directory structure

Create `gem/bsv-wallet-sqlite/` mirroring the Postgres gem layout:

```
gem/bsv-wallet-sqlite/
  .rspec
  bsv-wallet-sqlite.gemspec      # sqlite3 dep instead of pg
  CHANGELOG.md
  LICENSE
  Gemfile
  Rakefile
  db/migrations/
    001_create_schema.rb
  lib/
    bsv-wallet-sqlite.rb
    bsv/wallet/sqlite.rb          # connect/disconnect + pragmas
    bsv/wallet/sqlite/version.rb
    bsv/wallet/sqlite/store.rb
    bsv/wallet/sqlite/utxo_pool.rb
    bsv/wallet/sqlite/proof_store.rb
    bsv/wallet/sqlite/broadcast_queue.rb
    bsv/wallet/sqlite/broadcast_callback.rb
    bsv/wallet/sqlite/arc_adapter.rb
    bsv/wallet/sqlite/display_txid.rb
    bsv/wallet/sqlite/action.rb
    bsv/wallet/sqlite/broadcast.rb
    bsv/wallet/sqlite/output.rb
    bsv/wallet/sqlite/spendable.rb
    bsv/wallet/sqlite/input.rb
    bsv/wallet/sqlite/block.rb
    bsv/wallet/sqlite/tx_proof.rb
    bsv/wallet/sqlite/basket.rb
    bsv/wallet/sqlite/label.rb
    bsv/wallet/sqlite/action_label.rb
    bsv/wallet/sqlite/tag.rb
    bsv/wallet/sqlite/output_tag.rb
    bsv/wallet/sqlite/output_basket.rb
    bsv/wallet/sqlite/output_detail.rb
    bsv/wallet/sqlite/certificate.rb
    bsv/wallet/sqlite/certificate_field.rb
    bsv/wallet/sqlite/setting.rb
  spec/
    spec_helper.rb
    bsv/wallet/sqlite/
      (mirror Postgres specs)
```

### Task 2: Consolidated migration

Single `001_create_schema.rb` derived from `reference/schema.md` (the authoritative schema design), translated for SQLite. Do NOT reverse-engineer from the Postgres migrations — use the reference doc as the source of truth.

- `bytea` -> `blob`, `timestamptz` -> `datetime`, enums -> text + CHECK
- `text[]` (competing_txs) -> text (JSON serialized)
- `gen_random_uuid()` -> removed (handled in Ruby via `SecureRandom.uuid`)
- `identity: :always` -> `primary_key :id`
- Outbound spendable trigger in SQLite syntax
- Named CHECK constraints (for spec error message matching)
- All CHECK constraints, indexes, and FK cascades as specified in the reference doc

### Task 3: Connect/disconnect module

`lib/bsv/wallet/sqlite.rb`:

- No PG extensions
- `PRAGMA foreign_keys = ON` via `after_connect` proc (per-connection)
- `PRAGMA journal_mode = WAL`
- `Sequel::Model.db = @db`
- Autoload declarations for all model/service classes

### Task 4: Port model files

Namespace rename `Postgres` -> `Sqlite` for all models. Specific changes:

- **`action.rb`**: Add `before_create` hook for `SecureRandom.uuid` reference default
- **`broadcast.rb`**: `Sequel.pg_array(data[:competing_txs])` -> `JSON.generate(data[:competing_txs])`; add JSON parse on read if needed (currently write-only, low priority)
- **All others**: Pure namespace rename

### Task 5: Port service files

Namespace rename for Store, UTXOPool, ProofStore, BroadcastQueue. Specific changes:

- **`broadcast_queue.rb`**: `Sequel.pg_array(event[:competing_txs])` -> `event[:competing_txs]&.to_json`
- **`store.rb`**: Verify `insert_conflict(target:)` works identically on SQLite (it does — Sequel translates to `ON CONFLICT(col) DO NOTHING`)
- All `Sequel.blob()`, `Sequel.lit()`, `.exists` subqueries work unchanged

### Task 6: Spec helper

- `sqlite::memory:` connection (no external DB needed)
- `PRAGMA foreign_keys = ON`
- Run migrations inline
- `DELETE` instead of `truncate(cascade: true)` for cleanup (disable FKs temporarily during suite cleanup)
- Savepoint-based transaction rollback per example (same pattern as Postgres)

### Task 7: Port spec files

Namespace rename for all specs. Specific rewrites:

- **`migration_spec.rb`**: Rewrite enum tests as CHECK constraint violation tests
- **`broadcast_spec.rb`**: Rewrite `pg_array` test as JSON serialization test
- **`constraints_spec.rb`**: Verify SQLite error classes match (may need `Sequel::ConstraintViolation` instead of subclass); verify trigger error message regex matches
- **Other specs**: Pure namespace rename

### Task 8: Verify

- `cd gem/bsv-wallet-sqlite && bundle exec rspec` — full green
- `require 'bsv-wallet-sqlite'` loads cleanly
- `BSV::Wallet::Sqlite.connect('sqlite::memory:')` creates all tables

---

## SQLite Gotchas to Watch

1. **Boolean storage**: SQLite uses 0/1. Sequel adapter handles transparently.
2. **Datetime storage**: Text (ISO 8601). Sequel adapter handles conversion.
3. **BLOB comparison**: Byte-by-byte comparison works correctly for wtxid lookups.
4. **`insert_conflict` return value**: Returns nil on DO NOTHING, same as Postgres. The `locked += 1 if result` check in `create_action` works identically.
5. **Concurrent writes**: Serialized in SQLite. Acceptable for single-user wallet. WAL mode allows concurrent reads.
6. **No `TRUNCATE`**: Use `DELETE FROM` for cleanup.
