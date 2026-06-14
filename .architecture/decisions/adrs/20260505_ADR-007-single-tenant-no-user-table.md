# ADR-007: Single-tenant engine, no user table

## Status

Accepted.

**Decided:** 2026-05-05 (commit `d08edd3`, "feat: PostgreSQL schema, migration, and Sequel models", HLR #1) — the original schema carries no `users` table and no `user_id` column or FK anywhere; identity is a construction parameter, fixed from the first migration.

## Context

The reference implementation modelled multi-tenant hosting — a storage server holding many users' wallets, so every row carried a `user_id`. That shape is dead weight for what this is: a single wallet, constructed with one identity key, meant to run as a dedicated high-throughput process (ADR-002). The wallet knows who it is because it was built with a key — that is a runtime parameter, not a row in a table.

## Decision Drivers

* The wallet is one identity, not a host for many.
* A `user_id` on every row is overhead on every index and constraint, and it actively works against the high-throughput single-wallet case.
* Authentication and multi-tenancy are concerns that sit *above* the engine.

## Decision

The wallet is a single-tenant engine: no `users` table, no `user_id` foreign keys anywhere. Identity is a construction parameter (the wallet's key), not stored as a row. BRC-100 authentication and any multi-tenant hosting are layers above the engine — a user→wallet mapping service, or row-level security, added only if a hosting product ever needs it. That is an additive change to a layer above, not a change to the core schema.

## Alternatives Considered

### A. Per-row `user_id` (the multi-tenant storage-server model)
**Rejected.** It taxes every index and constraint for a tenancy the engine doesn't have, and harms the dedicated-wallet use case the design targets. Multi-tenancy, if ever needed, belongs in a layer above (mapping or RLS), not woven through every table.

## Consequences

### Positive
* A lean schema — no tenancy column on every table, no tenancy predicate on every query.
* The engine is unambiguously one wallet.

### Negative
* Hosting many wallets is an explicit layer to build later; the core won't do it implicitly.

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

Carrying `user_id` "in case we host multiple wallets" is the textbook speculative-generality cost — paid on every row forever for a feature this product doesn't have. Dropping it is correct, and multi-tenancy remains addable above the engine without touching the core. **Approve.**

## Validation

* No `users` table; no `user_id` column or FK in the schema.
* The wallet's identity is supplied at construction.

## References

* ADR-002 — the dedicated high-throughput wallet this single-tenant stance serves.
* ADR-001 — schema designed from the domain, not inherited from the reference's hosting model.
* `reference/schema.md`.
