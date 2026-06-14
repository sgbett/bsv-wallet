# ADR-006: Single relational store, one ACID boundary

## Status

Accepted.

## Context

The schema is one tightly-related set of tables: an action links to its proof (`actions.tx_proof_id → tx_proofs`), proofs anchor to blocks, outputs reference actions, inputs reference outputs. Almost every operation joins across them, and the invariants that keep state valid — the foreign keys, the derived statuses — only hold if the related rows commit together.

There is a recurring temptation to split parts out: namespace the tables into "wallet" versus "machinery," or move the machinery (proofs, work queues) to a different backend such as a key-value store.

## Decision Drivers

* The relationships are tight — nearly everything joins, and integrity constraints span the tables.
* A foreign key cannot span two stores, and an atomic transition cannot straddle them.
* Proofs are not independent, losable data — BEEF construction needs them joined to the transactions whose outputs are spent.

## Decision

Keep everything in one relational store, one ACID boundary, one schema (`public`, no namespacing). Proofs and work-queue tables are **not** split into a separate backend.

* `actions.tx_proof_id` is a foreign key into `tx_proofs`; a FK can't span stores, so they share the database.
* A proof's arrival and the action state it resolves commit in one transaction — impossible across two stores.
* `tx_proofs` is assembled in place (`raw_tx`, then block context, then merkle path) and consumed wholesale by BEEF construction; it is canonical, evolving state, not disposable side-data.
* Schema-namespacing is cosmetic for a single-domain wallet and is dropped; it can be added later (`ALTER TABLE … SET SCHEMA`) only if multi-tenancy ever demands it.

## Alternatives Considered

### A. Split proofs / work queues to a separate backend (e.g. Redis)
**Rejected.** The `tx_proof_id` FK and the atomic proof-arrival transition both require one ACID boundary; and losing a proof means BEEF can't be built for anything spending that action's outputs. Proof data is neither independent nor losable, and a key-value store can't provide the relational integrity the contract needs.

### B. Schema-namespace the tables (`wallet.*` core vs machinery)
**Rejected.** Cosmetic for a single domain where everything joins — pure overhead. Addable later if a second application ever shares the database.

## Consequences

### Positive
* Every invariant the schema enforces is *enforceable*, because the related rows share a transaction.
* No cross-store coordination, no distributed transaction.

### Negative
* The store is single and relational — backends without transactions and foreign keys (key-value stores) are excluded. Which relational engine is pluggable is a separate decision (ADR-012, store abstraction): "one ACID boundary" means one store *instance*, not one fixed engine.

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

Splitting stores is the speculative-flexibility trap: it buys a separation the wallet doesn't need and breaks the integrity it does. One ACID boundary is both simpler and the only thing that makes the structural guarantees real. Namespacing is correctly deferred to an actual multi-tenancy need. **Approve.**

## Validation

* All tables live in one schema; there is no second store.
* `actions.tx_proof_id` is an in-database FK; proof arrival commits atomically with the action state it resolves.

## References

* ADR-003 — atomic transitions in one transaction.
* ADR-011 — `completed` derived from `tx_proof_id`; the proof co-location this enables.
* ADR-012 — store abstraction (which relational engine backs the one ACID boundary).
* `reference/schema.md`.
