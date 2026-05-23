# Phase 2+3: Fix Store Boundary Violations + Strip Behavioral Contracts

**Date**: 2026-05-23
**Status**: Plan
**Depends on**: Phase 1 (store consolidation, merged as PR #142)
**Related**: .architecture/reviews/store-walletd-boundary.md, .claude/plans/20260523-walletd-omq-architecture.md

---

## Context

The Store is the reactive persistence layer — it accepts atomic writes and answers queries. Several components violate this boundary by writing to Sequel models directly, bypassing Store's transaction guarantees. Additionally, physical Sequel models include behavioral contracts (Pushable/Fetchable) that define network interaction — these belong on logical Engine models, not database records.

Phase 2 (boundary fixes) and Phase 3 (logical model separation) are inseparable: the `Action#write!` and `Broadcast#write!` violations are called by `Services.push!/fetch!` via the Pushable/Fetchable contracts. Fixing them requires removing those contracts from models, which IS Phase 3.

**Outcome**: Store owns all writes atomically. Models are pure data. Engine calls services directly and writes results through Store. ProofStore and BroadcastQueue dissolve — their persistence becomes Store methods, their behavior becomes Engine's responsibility.

---

## The Violations Being Fixed

| Violation | Tables | Transaction? | Root cause |
|-----------|--------|-------------|------------|
| `Action#write!` → ProofStore → find_or_create_block | Action + TxProof + Block | No | Model instantiates store component |
| `Broadcast#write!` | Broadcast | No | Model parses network response |
| `BroadcastQueue#submit` | Broadcast | No | Bypasses Store for model creation |
| `BroadcastQueue#handle_event` | Broadcast | No | Direct model create/update |
| `ChainTracker#persist_block` | Block | No | Raw dataset write |

---

## Task Breakdown

### Group A: Add Store Methods (foundation, parallelizable)

**Task 1: Proof persistence → Store**
- Add `save_proof(wtxid:, proof:)`, `find_proof(wtxid:)`, `proof_exists?(wtxid:)` to Store
- `save_proof` wraps TxProof upsert + Block find_or_create in `@db.transaction` — fixes the 3-table violation
- Lift implementation from `Store::ProofStore`, add transaction wrapper
- Files: `store.rb`, `interface/store.rb`, `persistence_spec.rb`

**Task 2: Broadcast persistence → Store**
- Add `submit_broadcast(action_id:)`, `record_broadcast_result(action_id:, tx_status:, ...)`, `broadcast_status(action_id:)`, `pending_broadcasts(limit:)` to Store
- Handle hex→binary decode, competing_txs Postgres/SQLite divergence
- Files: `store.rb`, `interface/store.rb`, `persistence_spec.rb`

**Task 3: Block header persistence → Store**
- Add `record_block_header(height:, merkle_root:, block_hash:)`, `find_block(height:)` to Store
- Files: `store.rb`, `interface/store.rb`, `persistence_spec.rb`

### Group B: Rewire callers (depends on Group A, parallelizable)

**Task 4: Engine proof_store → store** (depends on Task 1)
- Replace all 16 `@proof_store.*` calls with `@store.*` in Engine
- Remove `proof_store:` from Engine constructor
- Update engine specs and shared_context

**Task 5: Engine broadcast_queue → store + services** (depends on Task 2)
- Replace 4 `@broadcast_queue.submit(...)` call sites with `@store.submit_broadcast` + `@services.call(:broadcast, raw_tx)` + `@store.record_broadcast_result`
- Engine gains `services:` constructor arg, loses `broadcast_queue:`
- Private helper `broadcast_and_record(action_id:, raw_tx:)` to DRY the 4 sites
- Update engine specs: stub `services.call(:broadcast, ...)` instead of `services.push!`

**Task 6: ChainTracker → store** (depends on Task 3)
- ChainTracker takes `store:` instead of `db:`
- `persist_block` → `@store.record_block_header(...)`
- Fast-path read → `@store.find_block(height:)`

### Group C: Strip models (depends on Group B)

**Task 7: Strip Fetchable from Action model** (depends on Task 4)
- Remove `include Fetchable`, `write!`, `fetch_command`, `fetch_args`, `needs_fetch?`, `decode_hex`
- Keep: `derived_status`, `before_create`, associations, `DisplayTxid`

**Task 8: Strip Pushable + Fetchable from Broadcast model** (depends on Task 5)
- Remove both includes, all behavioral methods
- Keep: associations, timestamps, `TERMINAL_STATUSES`, `FETCH_STALENESS`

### Group D: Cleanup (depends on Groups B+C)

**Task 9: Update BroadcastCallback + deprecate Daemon** (depends on Tasks 2, 8)
- BroadcastCallback: change from `broadcast_queue:` to `store:`, call `store.record_broadcast_result`
- Daemon: mark deprecated with comment (Phase 4 replaces with walletd)

**Task 10: Update CLI boot wiring** (depends on Tasks 4, 5, 6)
- Remove ProofStore and BroadcastQueue construction from CLI.boot
- Update Engine construction (remove `broadcast_queue:`, `proof_store:`, add `services:`)
- Update ChainTracker construction (store: instead of db:)

**Task 11: Delete dead code** (depends on all above)
- Delete: `Store::ProofStore`, `Store::BroadcastQueue`, `Store::ArcAdapter`
- Delete: `Interface::BroadcastQueue`, `Interface::ProofStore`
- Delete: `Pushable` module, `Fetchable` module
- Delete corresponding specs
- Remove autoload entries from `store.rb`, `interface.rb`, `wallet.rb`

---

## Dependency Graph

```
Tasks 1, 2, 3  (Store methods — parallel)
      ↓
Tasks 4, 5, 6  (Rewire callers — parallel)
      ↓
Tasks 7, 8     (Strip models — parallel)
      ↓
Tasks 9, 10    (Callback, CLI, Daemon)
      ↓
Task 11        (Delete dead code)
```

---

## Key Design Decisions

**Engine gains `services:`**. Currently Engine has `network_provider:` (raw provider for WBIKD) and `broadcast_queue:` (which wraps Services). After this change, Engine takes `services:` directly for broadcasting. `network_provider:` stays for WBIKD scanning (different concern, different call pattern).

**ProofStore dissolves into Store, not into a logical Engine model**. ProofStore's 3 methods are pure persistence — no network I/O, no lifecycle. Engine calls them synchronously during BEEF construction (16 call sites). The future `Engine::TxProof` logical model (Phase 4) handles the background task of discovering and fetching missing proofs from the network — that's a different concern.

**BroadcastQueue dissolves**. Its `submit` splits into Store write + Services call. Its `process_pending` becomes a Store discovery query for the Phase 4 scheduler. Its `handle_event` becomes a Store method called by BroadcastCallback.

**Daemon marked deprecated, not deleted**. It still works for anyone using it, but Pushable/Fetchable removal breaks its entity dispatch. Phase 4 replaces it entirely with walletd.

**No OMQ in this phase**. Logical models (Engine::Broadcast, Engine::TxProof) are Phase 4 concerns that need OMQ sockets. This phase just fixes the boundary violations and strips behavioral contracts — synchronous, no new dependencies.

---

## Verification

After every task:
```bash
cd gem/bsv-wallet && bundle exec rspec spec/bsv spec/bin
cd gem/bsv-wallet && bundle exec rubocop
DATABASE_URL=postgres://postgres:postgres@localhost:5433/bsv_wallet_test bundle exec rspec spec/bsv spec/bin
```
