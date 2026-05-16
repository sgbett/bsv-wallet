# Shared Store Orchestration — Plan

**Issue:** #120
**Branch:** `feat/120-extract-shared-store-orchestration`
**Date:** 2026-05-16

## Overview

`Store::SQLite` (513 lines) and `Postgres::Store::Postgres` (598 lines) implement all 25 `Interface::Store` methods with effectively identical business logic. A line-by-line diff confirms exactly **one line of semantic divergence**: how `try_lock_input` interprets `insert_conflict`'s return value. Everything else is RuboCop layout differences.

Every new SQL backend therefore reimplements 25 methods of identical BRC-100 lifecycle orchestration to override one line. The interface was drawn at the wrong abstraction level.

This plan extracts the orchestration into a shared module — `BSV::Wallet::Store::Base` — included by both concrete Store classes. The 25 methods live in one place; the per-backend surface shrinks to a `models` accessor (namespace pointer) and any genuinely divergent primitives (currently just `try_lock_input`).

## Constraint stack (why this shape)

Three properties of the current codebase pin the design:

1. **Sequel models are connection-bound at class load.** `BSV::Wallet::Store::Action` and `BSV::Wallet::Postgres::Store::Action` are distinct Ruby classes, each permanently wired to their own DB via `Connection.bind_models!`. We can't unify models without abandoning Sequel's per-class binding (which #119 deliberately preserved).
2. **Ruby resolves constants lexically.** A bare `Action.create(...)` inside a shared module always resolves to whichever `Action` is nearest the module's lexical scope — never the including class's namespace. Constants can't be relative.
3. **Therefore the shared module must route, per-instance, to the right model class.** The only thing that varies per instance is which namespace its models live in.

Conclusion: each concrete Store class declares its models namespace; the shared module reaches models through that pointer.

## Architecture

```
BSV::Wallet::Store::
  Base                ← NEW: shared orchestration module (25 methods)
  SQLite              ← include Base; def self.models = BSV::Wallet::Store
  Connection, …       — unchanged

BSV::Wallet::Postgres::Store::
  Postgres            ← include BSV::Wallet::Store::Base
                        def self.models = BSV::Wallet::Postgres::Store
  Connection, …       — unchanged
```

### Call-site pattern

Inside `Base`, model access goes through a private `models` helper:

```ruby
module BSV::Wallet::Store::Base
  def create_action(action:, inputs: [])
    @db.transaction do
      record = models::Action.create(...)
      # ...
      try_lock_input(record_id: record.id, inp: inp)
      # ...
    end
  end

  private

  # Returns the concrete store's models namespace — BSV::Wallet::Store or
  # BSV::Wallet::Postgres::Store. Routes lookups like `models::Action` to
  # the right connection-bound model class.
  def models = self.class.models
end
```

Concrete classes:

```ruby
class BSV::Wallet::Store::SQLite
  include BSV::Wallet::Interface::Store
  include BSV::Wallet::Store::Base

  def self.models = BSV::Wallet::Store

  def initialize(db: nil)
    @db = db || Connection.db
  end

  private

  # SQLite's insert_conflict returns the rowid even on DO NOTHING,
  # so detect ownership with a re-query.
  def try_lock_input(record_id:, inp:)
    @db[:inputs].insert_conflict(target: :output_id).insert(
      action_id:   record_id,
      output_id:   inp[:output_id],
      vin:         inp[:vin],
      nsequence:   inp[:nsequence] || 4_294_967_295,
      description: inp[:description]
    )
    @db[:inputs].where(output_id: inp[:output_id], action_id: record_id).any?
  end
end
```

```ruby
class BSV::Wallet::Postgres::Store::Postgres
  include BSV::Wallet::Interface::Store
  include BSV::Wallet::Store::Base

  def self.models = BSV::Wallet::Postgres::Store

  def initialize(db: nil)
    @db = db || Connection.db
  end

  private

  # Postgres' insert_conflict returns nil on DO NOTHING,
  # so the result is truthy iff this insert won the race.
  def try_lock_input(record_id:, inp:)
    !!@db[:inputs].insert_conflict(target: :output_id).insert(
      action_id:   record_id,
      output_id:   inp[:output_id],
      vin:         inp[:vin],
      nsequence:   inp[:nsequence] || 4_294_967_295,
      description: inp[:description]
    )
  end
end
```

Net result:
- Concrete Store classes shrink to ~30 lines each (`include`, `models`, `initialize`, `try_lock_input`).
- `Base` holds the 25 BRC-100 orchestration methods.
- The adapter contract is two methods: `models` (class-level) + `try_lock_input` (instance-level).

## Approach

### 1. Create `BSV::Wallet::Store::Base` in the wallet gem

New file: `gem/bsv-wallet/lib/bsv/wallet/store/base.rb`. Contains the 25 `Interface::Store` methods plus private hash-serialization helpers, lifted verbatim from `Store::SQLite`. Every model reference becomes `models::Action`, `models::Output`, etc. The `try_lock_input` call replaces the inline insert+detect block.

### 2. Reduce `Store::SQLite` to its adapter

Strip the 25 methods from `Store::SQLite`. What remains: `include Interface::Store`, `include Base`, `self.models`, `initialize`, and the SQLite `try_lock_input` override (re-query variant).

### 3. Have Postgres re-use the same Base

`gem/bsv-wallet-postgres/lib/bsv/wallet/postgres/store/postgres.rb` includes `BSV::Wallet::Store::Base` from the wallet gem. The Postgres gem already depends on the wallet gem (for `Interface::Store`), so no new dependency is introduced.

Strip the 25 methods from the Postgres store; leave the same skeleton plus the Postgres `try_lock_input` override (result-nil variant).

### 4. Adjust the Base autoload

`gem/bsv-wallet/lib/bsv/wallet/store.rb` gains one autoload:
```ruby
autoload :Base, 'bsv/wallet/store/base'
```

### 5. Verify by running both spec suites unchanged

If the extraction is correct, both 233-example suites pass without modification. No new specs are needed — the existing suites already exercise every path through the orchestration.

## Acceptance criteria (mirrors issue #120)

- [ ] `BSV::Wallet::Store::Base` module exists, contains the 25 `Interface::Store` methods and private serialization helpers
- [ ] `Store::SQLite` overrides only `try_lock_input` (re-query variant) and exposes `self.models`
- [ ] `Postgres::Store::Postgres` overrides only `try_lock_input` (result-nil variant) and exposes `self.models`
- [ ] Both gems pass their existing 233-example spec suites unchanged

## Verification

```bash
cd gem/bsv-wallet && bundle exec rspec
cd gem/bsv-wallet-postgres && bundle exec rspec
cd gem/bsv-wallet && bundle exec rubocop
```

Both suites must pass with zero modifications. Rubocop must remain clean — formatting style of the extracted file follows whichever convention the wallet gem currently enforces (the postgres-side formatting was the divergent variant).

## Out of scope

- Moving models into a shared namespace (Sequel binding makes this impossible without significant restructure).
- Extracting additional adapter primitives. `try_lock_input` is the only current divergence; further primitives (e.g. array-column handling) emerge only as new backends arrive.
- The Broadcast model's `competing_txs` difference (`pg_array` vs `JSON.generate`) — model-level concern, not orchestration. Already lives in the respective `Broadcast` model files; unchanged by this plan.
- #117 auto-discovery wiring — separate sequencing step.

## Sequencing (from issue #120)

1. #116 — Default store ✅
2. #119 — Restructure Postgres to match ✅
3. **#120 — Extract common orchestration** ← this plan
4. #117 — Auto-discovery wiring
