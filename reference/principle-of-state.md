# Principle of State

A load-bearing principle of the wallet (see also [`state-boundaries.md`](state-boundaries.md) for its sibling). The design of every table, every constraint, every transaction boundary, every collaborator defers to this. Subsequent design choices either follow it or are mistakes.

## Statement

> **The database schema is the canonical source of truth for what is valid. All state-changing operations mutate the database atomically from one valid state to another. Invalid state is structurally impossible because the schema's constraints will reject it.**

Three consequences fall out:

1. **CHECK constraints, FK semantics, ENUM types, UNIQUE indexes, triggers** are the load-bearing safety mechanism. Application-layer "validation" is either a boundary check on caller input (rejecting before it touches the schema) or a duplicate of a schema rule (which the schema would reject anyway).
2. **Atomic state transitions = one database transaction.** A multi-write operation not wrapped in `db.transaction` is a bug. Partial mutations between two valid states leak intermediate invalid states which the schema would normally forbid.
3. **State is read, not stored.** Derived properties (action status, output spendability, broadcast progress) are computed from structural state on demand. There is no `status` column to drift; the relationships between rows are themselves the status.

The corollary, which is the test for whether we've followed the principle:

> At any instant — including immediately after a crash mid-operation — the database is in a valid state. On restart, query the database and the wallet knows exactly what is true. No reconstruction logic, no replay, no fix-up pass.

This is what makes the wallet **crash-safe by construction**, and what makes async / fiber / multi-process composition tractable — the database is the single coordination point. No distributed locking, no leader election, no application-layer mutexes.

## A note on scale

Not every part of this principle earns its place the same way. The **derived-state core** — no stored status, structural locking, single-transaction transitions — is justified by drift-prevention and correctness at *any* scale; it makes invalid state impossible regardless of throughput. The **full immutability** of the `outputs` table (append-only but for two narrow, vacuum-neutral deviations — a one-shot `promoted` flip and failure-bounded deletes of unpromoted outputs) is a different kind of bet: at ordinary wallet volumes its performance benefit is marginal, and it is justified specifically by the wallet's millions-of-tx/s target, where rows rewritten on every state change would accumulate dead tuples and vacuum contention would become the scaling ceiling. The decision, the alternatives weighed against it, and that conditionality are recorded in [ADR-011 (post-broadcast promotion)](../.architecture/decisions/adrs/ADR-011-post-broadcast-promotion.md) and [ADR-011 (failure-bounded delete)](../.architecture/decisions/adrs/ADR-011-delete-unpromoted-outputs.md) — the `promoted` flip and the unpromoted-output delete respectively.

## How this manifests

### Schema as canon

The schema is not documentation of what the application maintains; the application maintains what the schema enforces.

- **`actions.broadcast_intent` ENUM** rejects malformed values at insert time. The application cannot write `broadcast_intent: 'pending'` even if a typo would produce one.
- **`actions.wtxid` UNIQUE.** Re-imports collide deterministically. The idempotency guard on `import_utxo` works *because* the constraint exists — the application doesn't have to coordinate.
- **`tx_proofs.path_requires_block` CHECK** (`merkle_path IS NULL OR block_id IS NOT NULL`). A proof row cannot exist with a path but no anchor. The application doesn't validate this; it can't get past it.
- **RESTRICT FK on outputs** prevents deleting an action whose outputs are referenced. Cascade order is forced top-down by the schema.
- **`prevent_outbound_spendable` trigger** enforces that an outgoing action cannot have a spendable row before broadcast acceptance. This is the 4-phase invariant (output canonicalisation only post-broadcast) enforced *in the database*, not in `Engine::Action`.
- **`inputs.output_id` UNIQUE** is how single-spend is enforced. Two concurrent `create_action` calls competing for the same output resolve in PostgreSQL: both use `INSERT ... ON CONFLICT (output_id) DO NOTHING`, so the loser's insert turns into a no-op rather than an exception. `Store#lock_inputs_atomic?` then checks whether every requested lock was actually inserted; the losing call's transaction rolls back. The Engine doesn't need a Ruby mutex, and neither caller has to handle a uniqueness exception explicitly — the schema's UNIQUE constraint plus the `ON CONFLICT` clause turns contention into a deterministic loser-rolls-back outcome.

If a future bug allows the application to attempt invalid state, the schema raises and the operation aborts. The bug surfaces immediately and loudly. It cannot persist.

### Atomicity

Every multi-write operation is one transaction. The Store owns this:

```ruby
def create_action(...)
  @db.transaction do
    action_id = @db[:actions].insert(...)
    raise Sequel::Rollback unless lock_inputs_atomic?(action_id:, inputs:)
    action_id
  end
end

# lock_inputs_atomic? uses INSERT ... ON CONFLICT (output_id) DO NOTHING
# for each row and returns true iff every requested lock was actually
# inserted (i.e. no contender already held it).
```

If any lock contended (another caller already claimed that output), `lock_inputs_atomic?` returns false, the explicit `Sequel::Rollback` fires, and the action row plus any inputs inserted so far are unwound together. The Engine never sees a half-committed lifecycle — it sees either success or a clean rollback.

The Engine never assembles multi-write sequences itself. It calls Store methods, each of which is a single transaction or composes others within its own transaction block. When the Engine needs to span what would otherwise be two Store calls (e.g. import_utxo's five Phase 1 writes), it wraps them explicitly in `@store.db.transaction` and the principle holds.

### Derived state

There is no `actions.status` column. Status is computed at read time from structural state:

| Structural state | Derived status |
|---|---|
| `wtxid IS NULL` | unsigned |
| `wtxid IS NOT NULL`, `tx_proof_id IS NOT NULL` | completed |
| `wtxid IS NOT NULL`, `broadcast_intent = 'none'`, no proof | internal |
| `wtxid IS NOT NULL`, send path, ≥1 promoted output, no proof | unproven |
| `wtxid IS NOT NULL`, send path, broadcast `tx_status = 'REJECTED'` | failed |
| `wtxid IS NOT NULL`, send path, broadcast row exists, no promoted outputs | sending |
| `wtxid IS NOT NULL`, send path, no broadcast row | unprocessed |

A status column would be a denormalisation that *might* drift from the structural truth. By not having one, drift is impossible.

The same pattern holds for `outputs`: there is no `spendable` boolean on the row. An output is spendable iff there is a row in the `spendable` table whose `output_id` matches. Pure set membership. The presence of the row IS the state.

## What this means for application code

The Engine and its collaborators **orchestrate** atomic transitions; they do not **enforce** validity. Enforcement lives in the schema. The Engine's job is:

1. Translate BRC-100 calls into Store operations.
2. Drive workflows (e.g. the 4-phase action lifecycle, the funding loop).
3. Translate schema errors into BRC-100 error codes for the caller.

When you find yourself writing application code that checks "is this state valid?", ask whether the schema *could* enforce the same invariant. If yes, lift it to the schema. The application check then becomes a boundary guard that produces a friendlier error message — but the schema is the actual gate.

Collaborators are stateless or hold transient state only. Their durable state goes through the Store. `Engine::FundingStrategy`, `Engine::TxBuilder`, `Engine::Hydrator`, `Engine::BeefImporter`, `Engine::BRC100` — none should hold persistent state. They orchestrate operations on database-canonical state.

## Performance projections sit *over* canonical state

Caches and derived indexes are allowed when they make the wallet faster. They are never allowed to be the source of truth. The test:

> Delete the cache. Rebuild from the database. The wallet behaves identically.

`Engine::HydratedTxCache` (#269) is a performance projection — it caches hydrated `Transaction` objects so the broadcast hot path doesn't re-do the JOINs and BEEF reconstruction. The cache lies in the same direction as truth (it can only be empty or correct), never against it. The monotonic-cache evolution planned in #296 Phase D tightens this further: the cache is keyed by wtxid, holds immutable bytes, and can only progress toward database truth via `proof_arrived` enrichment. Cold restart → empty cache → wallet rebuilds it from DB on first access.

The same pattern applies to any future projection (block header cache, spendable set count, fee model state). Build *over* the schema; never *beside* it.

## What this means for the daemon

The daemon is a worker that drives the database forward through atomic transitions. It reads pending work from the database (queued broadcasts, unresolved proofs), performs network I/O, and writes the outcome as another atomic transition. At every instant the database tells the truth about what has happened so far; the daemon's in-flight network calls are not state, they are work toward producing the next valid state.

This is why:

- Cross-fiber coordination doesn't need explicit synchronisation — fibers communicate via the database.
- Multi-process composition (producer CLI + walletd daemon + future hydrator) doesn't need a coordinator — they share the database.
- A daemon crash mid-broadcast doesn't corrupt state. The pending broadcast row is still there; the next poll resumes it.

## What this means for batched sending (#192)

The chopped `noSend × sendWith` quadrants (see #291 sanity-check section) were chopped because the base wallet couldn't honestly support them: there was no database-canonical representation of a *batch*. Restoring them requires a `batches` (or similarly named) entity:

- A row per batch group, with a state machine over the batch as a whole.
- An FK from `actions.batch_id` linking each member action.
- CHECK constraints and/or triggers enforcing "a batch cannot partially succeed" — e.g. all members must reach the same lifecycle stage before the batch transitions to its terminal state.
- Atomic batch commit = one DB transaction touching the `batches` row and every member `actions` row.

Under this principle, the application cannot construct a batch where action A is broadcast-accepted and action B is broadcast-rejected: the schema's constraints reject the partial state. The application's job is to orchestrate the atomic resolution of every batch transition.

Bringing back `sendWith` without this structural backing would reintroduce the drift that motivated #183 in the first place.

## Where it leaks today

An honest assessment. These are the places where the principle is partially observed; tightening them is ongoing work:

- **`Engine::Action#validate_for_handoff!`** (added in #296 Phase B) enforces an invariant — "the BEEF this action would emit is valid" — at the application layer, because the database doesn't natively express it. The principle is partially preserved by the strict-import contract upstream (every imported root has a merkle_path, schema-enforced via the proof acquisition pre-write check) — but the egress assertion itself is application-layer. Tightening would mean encoding the closure invariant into the schema (a view or constraint that asserts "every spendable output's ancestry terminates at a proven anchor"). Out of scope for now; flagged as #296 Phase D / future work.

- **Engine methods that span multiple Store calls** without explicit transaction wrapping. The `import_utxo` fix landed in #297 closed one such gap; an audit for others is worth doing as collaborators are extracted (#290 Phase 2).

- **In-flight broadcast state** straddles database and network. The database has a `broadcasts` row recording what the wallet *attempted*; the network's actual reception is outside DB control. The 4-phase design handles this by treating the `broadcasts` row as ground truth and converging on the network's verdict via subsequent atomic writes.

None of these are violations of the principle — they are places where the principle is being progressively tightened. Each is a known gap with a known path to closure.

## Tests for compliance

When designing a new feature, ask:

1. **Is every invariant the application cares about expressible as a database constraint?** If not, can we add one?
2. **Is every multi-write operation a single transaction?** If not, why?
3. **Is any derived property stored in addition to its source?** If yes, we are accepting drift risk — is the perf benefit worth it?
4. **If the process crashed right now, would the database be in a valid state?** If not, the operation is not atomic.
5. **If we deleted every in-memory cache, would the wallet rebuild correctly?** If not, the cache holds state that should be in the database.

A "no" to any of these is the principle leaking. Sometimes the leak is deliberate and worth the cost (HydratedTxCache); usually it isn't, and the right response is to lift the invariant into the schema.

## Related

- [`reference/state-boundaries.md`](state-boundaries.md) — companion load-bearing principle. Where the principle of state defines *what* the wallet maintains (a DB always in a valid state), state-boundaries defines *where* that maintenance lives by the stateless/stateful axis (SDK / wallet).
- `reference/schema.md` — the schema design that operationalises this principle. Principle #11 ("the database is the last line of defense") is the schema-side restatement.
- `reference/schema-intent.md` — why the schema chose Postgres-native primitives rather than portable subsets.
- `docs/design.md` §6 (Cross-Cutting Concerns) — high-level summary that defers to this document for detail.
- #183 — the HLR that restored the strict 4-phase design after drift.
- #192 — the HLR that will reintroduce batched sending under this principle.
- #296 Phase B (PR #297) — the egress-validity work; the strict-import contract is an example of the principle being progressively applied.
