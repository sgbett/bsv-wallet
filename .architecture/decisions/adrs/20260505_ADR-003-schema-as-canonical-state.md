# ADR-003: Schema as canonical state (the Principle of State)

## Status

Accepted.

**Decided:** 2026-05-05 (commit `d08edd3`, "feat: PostgreSQL schema, migration, and Sequel models", HLR #1) — the principle is established with the original schema: derived state (no `status` column), structural single-spend (`UNIQUE(inputs.output_id)`), and constraints-as-enforcement. Later work (HLR #183 restored the strict 4-phase design, PR #297 closed an atomicity gap) manifests the principle rather than re-deciding it.

## Context

The wallet is a ground-up, clean-room rebuild (ADR-001). Its predecessor was a Ruby port of the TypeScript wallet-toolbox, whose schema was reverse-engineered from a SQLite dump rather than designed. Partway through that work the inversion became clear: the schema was arriving *after* the code, as a by-product of how the code happened to interact with the blockchain, rather than being designed in its own right. The question this ADR answers is the one that stop-and-rethink raised — from the ground up, what is a wallet's database, and what makes a state in it valid?

The inherited approach was translation, not design, and it produced a characteristic failure downstream: mangled databases. Flexible JSONB blobs that accept anything, no foreign keys, no CHECK constraints, and state flags that drift out of sync because nothing enforces the invariants. A real example was a single output row carrying `spendable: true`, `basket: NULL`, `isDeleted: 0`, `spentBy: NULL` — four fields that must agree on one fact, with no rule deciding which wins. The governing intuition is the opposite: bad data must never reach the database in the first place.

## Decision Drivers

* **Drift-prevention (the originating force).** The predecessor's mangled databases must be structurally impossible, not merely discouraged. The database is the last line of defence: constraints catch bugs in our own code, they do not validate user input.
* **Crash-safety by construction.** At any instant — including mid-operation — the database is in a valid state, so on restart the wallet knows what is true with no replay, reconstruction, or fix-up pass.
* **Single-spend without application-level locking.** Double-spend is prevented by structure (`UNIQUE(output_id)` + `INSERT … ON CONFLICT DO NOTHING`), so concurrency resolves in PostgreSQL rather than via a Ruby mutex — the UNIQUE constraint *is* the lock.
* **Idempotency.** Re-imports collide deterministically (`actions.wtxid UNIQUE`) without the application coordinating.
* **Relational-first design.** The schema is designed from relational first principles — entities, keys, constraints, normalisation — not translated from the shape of a foreign storage layer.

## Decision

Adopt **schema-as-canonical-state** as the wallet's foundational design principle:

> The database schema is the canonical source of truth for what is valid. All state-changing operations mutate the database atomically from one valid state to another. Invalid state is structurally impossible because the schema's constraints reject it.

Concretely:

* **State is derived, not stored.** No `status` column on `actions`; no `spendable` boolean on `outputs`. Status is computed from structural state at read time; spendability is set membership (presence of a `spendable` row, absence of an `inputs` row). No boolean, no enum, no duplication — the truth is structural, drawn from relationships rather than a flag someone has to remember to flip. The single exception is genuinely non-derivable *intent*: the `broadcast_intent` ENUM.
* **Constraints are the enforcement layer.** CHECK, FK (RESTRICT), ENUM, NOT NULL, UNIQUE, and triggers are load-bearing. Application code orchestrates; it never re-implements a rule the schema can enforce. Application-level validation is either a boundary check on caller input or a duplicate of a schema rule. (ADR-019 works a concrete instance: a cross-table invariant a single-row CHECK cannot express is kept in the schema by denormalising so a declarative constraint *can* express it — chosen over a hot-path trigger — rather than dropped to unenforced application code.)
* **Atomic transitions = one database transaction.** Multi-write operations are wrapped in a single `db.transaction`; no intermediate state is ever visible or persistable. The Store owns that boundary (ADR-006); the Engine never holds a transaction open across a network call.

**Architectural components affected:** the entire schema; `Store` (owns all transactions); `Engine` and every collaborator (orchestrate, never enforce); the daemon (drives the DB forward through atomic transitions, coordinating via the database rather than locks).

Two refinements that build directly on this principle are recorded separately, so this ADR stays the derived-state core: the **outputs / spendable vertical partition and inputs-as-lock** (ADR-004), and the **scalability-tempered immutability of `outputs`** with post-broadcast promotion (ADR-011).

## Alternatives Considered

### A. Stored `status` column (the TS SDK's 9-state machine)
Model the action lifecycle as an explicit enum (`unprocessed → sending → unproven → completed …`).
**Pros:** explicit and familiar; trivial worker queries (`WHERE status = 'unprocessed'`).
**Cons:** drifts from structural truth; opens crash-between-update-and-action gaps; most statuses are derivable anyway. The TS SDK's `unprocessed → sending → unproven` sequence is three statuses for what we handle with one network call between two DB transactions.
**Rejected** — status is derived from structure; only non-derivable intent (`broadcast_intent`) is kept as a column.

### B. `spendable` boolean / multi-flag output row
Carry spendability (and related flags) directly on the output row.
**Pros:** single-row read, no joins.
**Cons:** the four-fields-that-must-agree failure mode — exactly the predecessor's mangled data.
**Rejected** — spendability is set membership.

### Not considered: event-sourcing / replay
Recorded for honesty: an event-log-plus-replay model was **not** evaluated at decision time. The append-only `outputs` table is a *fact log*, not an event stream replayed to reconstruct state. If event-sourcing is ever weighed, it is new analysis, not a revisit of a rejected option.

Designs once weighed alongside these now have their own records: mutable lock column → ADR-004; `pending_outputs` staging → ADR-011; separate proof store → ADR-006; full transaction-DAG model → ADR-005; SQLite-portable schema → ADR-009; derivation data on `spendable` → ADR-010.

## Consequences

### Positive
* Invalid state is structurally impossible; the wallet is crash-safe by construction (no replay, no fix-up).
* Concurrency needs no application-level locks; multi-process / multi-fiber composition coordinates through the database as the single point of truth.
* No drift: there is no denormalised status that can disagree with reality.

### Negative
* **More verbose worker queries** — finding work is a structural predicate, not `WHERE status = '…'`. Accepted: verbosity in exchange for no possibility of a status column lying.
* **The network-straddling lifecycle is atomic per-phase, not end-to-end** — by deliberate co-design (two fast DB transactions either side of the broadcast; ADR-011). The cost is a reconciliation **reaper** that must distinguish a never-sent action (safe to delete) from a sent-but-outcome-unknown one (investigate via ARC, never blind-GC), because blindly freeing locked inputs on an in-flight transaction would create a double-spend race.
* **A hard dependency on Postgres-native features** to express the constraints (ADR-009); the table count is wider than a naive single-table design (the vertical partition, ADR-004).

### Neutral / Reversibility
* **Foundational and effectively irreversible.** Every table, constraint, transaction boundary, collaborator, and the daemon design defer to this principle. Undoing it is a second clean-room rebuild, not a refactor — by design. Later ADRs reference it rather than relitigate it.

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

The derived-state principle is appropriate engineering for a concrete, *already-observed* failure: the predecessor's mangled databases drifted in exactly the way deriving-not-storing prevents — the strongest possible evidence of need. The genuinely simpler option — a `status` column plus a `spendable` boolean (Alternatives A+B, the TS approach) — was not merely considered; it was run in production by the predecessor and failed. The cost (Postgres coupling, more verbose queries, the reconciliation reaper) is moderate and flows from the requirement, not from gold-plating. **Approve.**

* Necessity 9, Complexity 5, **Ratio 0.56** — well within the balanced target (<1.5).

## Validation

Acceptance criteria — each a checkable invariant restating one element of the decision (the standing compliance tests live in `reference/principle-of-state.md`):

* Every invariant the application cares about is expressible as a database constraint, or is consciously flagged where it is not (e.g. `validate_for_handoff!`) — the *constraints-as-enforcement* element.
* Every multi-write operation is a single transaction — the *atomic-transitions* element.
* No derived property is stored alongside its source — the *derived-not-stored* element.
* After a crash mid-operation the database is in a valid state, with no replay or fix-up needed — the *crash-safety* driver.

## References

* `reference/principle-of-state.md` — the living statement (canonical wording, manifestations, current leaks).
* `reference/state-boundaries.md` — sibling load-bearing principle (stateless SDK / stateful wallet).
* ADR-001 — clean-room, schema-first (why the schema is designed, not translated).
* ADR-004 — outputs / spendable partition and inputs-as-lock.
* ADR-005 — accounting ledger, not transaction DAG.
* ADR-006 — one relational store, one ACID boundary.
* ADR-010 — derivation on outputs; the inference ban.
* ADR-011 — scalability-tempered immutability and post-broadcast promotion.
* ADR-019 — broadcasts-intent: keeping a cross-table invariant in the database declaratively (a concrete exemplar of this ADR).
* `.architecture/principles.md` — principles #9 (the database IS the state), #11 (constraints at the schema level), #12 (Store owns atomicity).
* HLR #183 — restored the strict 4-phase design after drift. HLR #192 — batched sending under this principle. PR #297 — closed an `import_utxo` cross-call atomicity gap. #269 / #296 — `HydratedTxCache` as a performance projection *over* canonical state.
