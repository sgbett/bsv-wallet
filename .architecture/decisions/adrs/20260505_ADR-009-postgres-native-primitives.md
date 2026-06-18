# ADR-009: Postgres-native primitives over a portable subset

## Status

Accepted.

**Decided:** 2026-05-05 (commit `d08edd3`, "feat: PostgreSQL schema, migration, and Sequel models", HLR #1) — the original schema uses Postgres-native primitives (`bytea`, ENUM, CHECK, partial indexes, `ON CONFLICT`, partitioning, triggers) rather than a portable subset; SQLite carries them by translation as a logic-only convenience.

## Context

Designing the schema from first principles (ADR-001) means designing it for the database it actually runs on. The reference schema was SQLite-shaped — `TEXT` for everything, integer flags for booleans, no real types — because that is what SQLite offers. The integrity guarantees this design relies on are not expressible in a lowest-common-denominator SQL subset: structural single-spend needs `UNIQUE … ON CONFLICT`; the typed-vs-derived and range invariants need CHECK constraints; intent needs an ENUM; the outbound-spendable ban needs a trigger; scale needs partitioning.

## Decision Drivers

* The structural invariants the wallet depends on require Postgres-native features.
* A portable subset would forgo exactly the guarantees that make state valid by construction.
* PostgreSQL is the production target; SQLite is a development convenience, not the target.

## Decision

Use Postgres-native primitives deliberately: `bytea` for hash-shaped data, ENUM types for intent, CHECK constraints for cross-column and range invariants, partial indexes, `INSERT … ON CONFLICT`, table partitioning, and triggers where a constraint can't express the rule. The schema is not written to a portable subset.

SQLite is retained only as a convenience for fast logic-only specs; it carries the Postgres features by translation (ENUM → CHECK, and so on) and is **not** the production target. How the gem selects a backend by default is a separate decision (ADR-012, store abstraction); this ADR is about the schema using the production database's strengths rather than a portable lowest common denominator.

## Alternatives Considered

### A. A portable SQL subset / SQLite-compatible schema
**Rejected.** It bakes SQLite's limitations into the design (no real types, integer flags) and forgoes the native features — CHECK, ENUM, `ON CONFLICT`, triggers, partitioning — that the integrity and scale guarantees rest on. That is translation, not design (ADR-001).

## Consequences

### Positive
* The structural guarantees (single-spend, typed-derived CHECKs, the outbound trigger, partition archival) are available because the schema uses the features that provide them.

### Negative
* A hard dependency on Postgres-native features for production. SQLite support is a translated convenience and must keep pace with the constraints (Postgres-specific behaviour — CHECK violations, ENUM rejection, RESTRICT semantics, the trigger — is verified against Postgres, not assumed from SQLite).

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

Designing to a portable subset to keep a notional door open would forfeit the structural integrity that is the whole point of the schema-first design — paying a real cost now for a portability the product doesn't require. Using the production database's strengths is the right call; SQLite stays a convenience, not a constraint on the design. **Approve.**

## Validation

* The schema uses `bytea`, ENUM, CHECK, partial indexes, `ON CONFLICT`, partitioning, and triggers.
* Postgres-specific behaviour is tested against Postgres; SQLite is a logic-only convenience.

## References

* ADR-001 — design from first principles, not translation.
* ADR-006 — one relational store (this is which features that store uses).
* ADR-012 — store abstraction (default backend selection; SQLite translates these features).
* `reference/schema.md` — the table-by-table reference that uses these primitives.
