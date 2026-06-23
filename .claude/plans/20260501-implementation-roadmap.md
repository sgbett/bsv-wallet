# Implementation Roadmap

**Date:** 2026-05-01
**Goal:** Implement the bsv-wallet gem from interfaces to working BRC-100 wallet

---

## What We Have

- **DESIGN.md** — philosophy, SOA architecture, functional area flows, data layer design
- **Interface modules** — BRC100 (28 methods), Store, UTXOPool, BroadcastQueue, ProofStore
- **Error hierarchy** — BSV::Wallet::Error with BRC-100 codes
- **Schema** — 17-table PostgreSQL design (in reference, WIP)
- **Gem scaffolding** — `gem/bsv-wallet/` with gemspec, specs, Gemfile

## What We're Building

A two-gem wallet ecosystem:

- **`bsv-wallet`** — core gem: interfaces, engine, errors, in-memory test store. Zero database dependencies.
- **`bsv-wallet-postgres`** — adapter gem: Sequel models, PostgreSQL Store/ProofStore/BroadcastQueue, migrations. Depends on `sequel`, `pg`.

## Implementation Order

```
HLR 1: Schema & Models ─────────────────────────────┐
  (migrations, Sequel models, database setup)        │
                                                     │
HLR 2: Store ────────────────────────────────────────┤
  (Phase 1-4 lifecycle, queries, reaper)             │
                                                     ├── HLR 4: Engine — Transactions
HLR 3: Machinery ───────────────────────────────────┤    (create_action, sign_action, etc.)
  (UTXOPool tier 1, BroadcastQueue, ProofStore)      │
                                                     │
HLR 5: Engine — Crypto & Identity ──────────────────┘
  (keys, encryption, signatures, certificates)
  (parallel — mostly SDK delegation)
```

### Why This Order

1. **Models first** — every component above depends on them. The schema IS the data vocabulary. You can't write a Store method without an Action model, can't write a UTXOPool without Output and Spendable models.

2. **Store second** — the largest component, touches the most tables. The action lifecycle (create → sign → promote → abort) is the backbone. Everything else calls through the Store.

3. **Machinery third** — UTXOPool, BroadcastQueue, ProofStore each own a concern that the Store doesn't. They're smaller individually but need the Store and models to exist. BroadcastQueue needs the Broadcast model and ARC protocol integration. ProofStore needs TxProof and TxReq models.

4. **Engine last** — pure orchestration. By this point all machinery exists and is tested. Each BRC-100 method is a composition of Layer 2 calls. Transactions are complex (multi-phase, multi-component). Crypto is thin (SDK delegation). Certificates are moderate (Store + crypto).

5. **Crypto/Identity can parallelise** — these methods barely touch the database (certificates aside). They can be developed alongside the transaction engine.

## Cross-Cutting Decisions Already Made

- Binary internally, hex at Layer 4 boundaries only
- Sequel, not ActiveRecord
- PostgreSQL, bytea for all binary data
- Derived status, no status columns
- Structural locking via input rows + UNIQUE constraints
- The wallet owns broadcast; the SDK owns protocol
- Sync methods, async is infrastructure

## Per-HLR Plan Structure

Each HLR gets a GitHub issue and an implementation plan in `.claude/plans/`. The plan covers:
- File-by-file implementation steps
- Key decisions specific to that scope
- Edge cases and error scenarios
- Test strategy and acceptance criteria

## Repo Structure (target)

```
DESIGN.md
docs/reference/
  BRC100.md
  arcade-api-1.json
  sse.md
  transactions.md
gem/
  bsv-wallet/
    lib/bsv/wallet/
      interface/          ← abstract contracts (done)
      engine.rb           ← Layer 3 orchestration (HLR 4-5)
      error.rb            ← error classes (done)
    spec/
  bsv-wallet-postgres/
    lib/bsv/wallet/
      postgres/
        models/           ← Sequel models (HLR 1)
        store.rb          ← Store implementation (HLR 2)
        utxo_pool.rb      ← UTXOPool tier 1 (HLR 3)
        broadcast_queue.rb ← BroadcastQueue (HLR 3)
        proof_store.rb    ← ProofStore (HLR 3)
      migrations/         ← Schema migrations (HLR 1)
    spec/
```
