# ADR-001: Clean-room redesign, schema-first

## Status

Accepted.

**Decided:** 2026-04-30 (commit `b355dc8`, "feat: initial gem scaffolding with BRC-100 interface and machinery contracts") — the clean-room rebuild begins in a fresh repository, schema-first; the schema itself follows days later at `d08edd3` (HLR #1).

## Context

The wallet exists as a TypeScript implementation (wallet-toolbox) and a Ruby port of it. The port inherits the TypeScript approach wholesale: the schema is a reverse-engineered SQLite dump — JSONB blobs that accept anything, no real foreign keys, status flags maintained by application code. The schema arrived *after* the code, as a consequence of how the code happened to interact with the blockchain.

Inspecting the reference schema directly, it reads as an afterthought — storage shaped to serve the code, with SQLite's limitations baked in (no real booleans or timestamps, `TEXT` for everything, `isDeleted` integers instead of proper modelling). For a wallet, that inversion is backwards: the data *is* the product — what the wallet owns, what it has spent, the evidence behind each. The schema should be the lynchpin the application reads and manipulates, not a byproduct the application happens to leave behind.

## Decision Drivers

* The port carries no structural integrity — JSONB blobs and absent foreign keys let inconsistent data persist.
* The reference schema is code-shaped and SQLite-bound; adopting it imports those limitations.
* A wallet's worth is its data, so the schema must be designed first, from the domain — BRC-100's required data shapes and Bitcoin's UTXO model — and treated as the source of truth.
* Pre-1.0 is when a wholesale redesign costs least.

## Decision

Rebuild the wallet from scratch, designing the database schema as the primary, deliberately-modelled artifact.

* **Design from first principles**, not by translating the reference. The schema follows from what BRC-100 must persist and how Bitcoin's UTXO model actually works. The reference SQLite schema is consulted only to confirm the core entities; it is never a template. Translating it would be translation, not design.
* **The schema is canonical**; the application serves it. (This is the ground the principle of state — ADR-003 — stands on.)
* **Build in a fresh repository**, not the existing monorepo slot, so the new project's history, CI, and issue tracker carry none of the replaced implementation's baggage.

The TypeScript wallet remains the reference for *behaviour* and BRC-100 semantics. Only its schema and structure are set aside.

## Alternatives Considered

### A. Continue the port — iterate the existing Ruby-on-TypeScript implementation
Keeps working code, but keeps the defect: the schema stays a code byproduct of JSONB blobs and absent constraints. The mangled-data problem is structural, not incidental, so iterating does not remove it. **Rejected.**

### B. Adopt or translate the reference SQLite schema into PostgreSQL
Less work up front, but it bakes SQLite's limitations and the code-shaped denormalisations into the new system — translation in place of design. **Rejected.**

### C. Continue in the monorepo slot
The dependency runs one way and the cadences diverge; the slot, its history, and its open issues all carry the replaced implementation. A clean repository gives a clean record. **Rejected.**

## Consequences

### Positive
* The schema is designed deliberately, as the source of truth, with structural integrity available (foreign keys, constraints, real types).
* The data model follows the domain rather than the prior code — the foundation the principle of state and everything downstream depends on.
* A clean repository: history and CI start fresh.

### Negative
* A wholesale rebuild discards working code and re-derives the data model from first principles.
* No git-history continuity with the port; the reference schema gives only confirmation of entities, not a shortcut.

### Neutral
* The TypeScript wallet stays the behavioural reference; rejecting its schema does not reject its BRC-100 semantics.

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

**Necessity (9/10).** The driver is a concrete, observed failure — the port's mangled databases — not a hypothetical. The cost of *not* rebuilding is carrying that defect into the new system as its foundation.

**Complexity (4/10).** The decision itself is a simple stance; its consequence (re-deriving the schema and engine) is real work, but it *reduces* structural complexity — a designed schema replaces accreted blobs.

**Alternative analysis.** The simpler option — keep porting — is the status quo that produced the problem; translating the reference schema is cheaper still but reintroduces the defect. The cheaper paths are cheaper precisely because they skip the design this decision exists to do.

**Recommendation: ✅ Approve.** Pre-1.0, a schema-first rebuild is appropriate engineering, not over-engineering. **Ratio ≈ 0.44** — well within balance.

## Validation

* The schema is authored from BRC-100 and the UTXO model, with the reference SQLite schema used only to confirm entities.
* No JSONB-blob storage; integrity is enforced structurally (foreign keys, constraints, real types).
* The project lives in its own repository with its own history and CI.

## References

* ADR-003 — the principle of state, which this decision makes possible (schema as the canonical source of truth).
* `reference/schema.md` — the schema this redesign produces.
* BRC-100 — the specification the data model is derived from.
