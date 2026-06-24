# ADR-027: Core wallet vs BRC-100 conformance

## Status

Accepted.

**Decided:** 2026-06-24 — articulated as a principle after seven months of instinctive application. The rule had been at work since ADR-007 (single-tenant, no user table, 2026-05-05) and ADR-021 (BRC-100 as a plain Ruby module over the schema, 2026-05-05); this ADR names it so subsequent decisions can defer to it explicitly.

## Context

BRC-100 is titled "Wallet-to-Application Interface". Its design presupposes:

- A trusted wallet daemon serving multiple untrusted application clients.
- A human principal mediating per-application permission grants.
- Each application identified by FQDN (`originator`).
- Permission state (per-app access to baskets, protocols, certificates, spending limits) maintained on the principal's behalf, with a UI to prompt them.

Our deployment model differs:

- A library and future daemon serving one consumer per instance.
- Identity is a construction parameter (the WIF), not a runtime authentication step.
- Access control is WIF-level: whoever has the key has the wallet.
- No permission UI, no per-origin sandboxing, no multi-tenant hosting.

The wallet has been built — instinctively at first, then deliberately — by keeping the *core Bitcoin operations* separable from the *BRC-100 application-interface conventions*. Several BRC-100 concepts (`user_id`, `originator`, `seekPermission`, BRC-116 permission machinery, the basket-as-sandbox semantic) have been deferred or amputated where they have no operational equivalent in our model. The decisions were correct in retrospect; the unstated principle behind them needs to be named so future decisions can defer to it explicitly rather than be re-derived from first principles each time.

The trigger for naming it was a design discussion on 2026-06-24 (this branch's parent conversation) that surfaced the principle from underneath the originator deferral, the user-table amputation, and the basket-semantic divergence — three apparently independent decisions that turned out to be consequences of one rule.

## Decision Drivers

* **The throughput target (ADR-002).** Per-row tenancy columns, permission-overlay joins on the hot path, and BRC-100 vocabulary leaking into core operations all foreclose the scaling vision. Keeping conformance paper-thin preserves the budget.
* **Reviewability of the boundary.** If the rule isn't named, the question "should this go in the Engine or stay at conformance?" gets re-litigated for every new BRC-100 surface. A named principle reduces the question to a filter.
* **Convergence with other load-bearing principles.** Principle-of-state (ADR-003) defines *what* the wallet maintains; state-boundaries (ADR-018) defines *where* statefulness can live; this principle defines *what concerns are part of the wallet at all*. The three together form the architectural skeleton.
* **Past decisions accumulating without an explanation.** ADR-007, the originator deferral, the basket-semantic divergence — each has its own rationale, but none of them surface the common principle. A reader trying to understand the wallet's BRC-100 stance has to triangulate from three sources.

## Decision

**Core wallet operations (build, sign, broadcast, observe, account) live in the Engine and Store. BRC-100 conformance (the wallet-to-application interface contract) lives at `BSV::Wallet::BRC100`, wrapping the Engine. The two sit on opposite sides of an internal boundary. The conformance layer adapts BRC-100 vocabulary onto core operations; the core never reaches outward into conformance vocabulary.**

For every BRC-100 concept arriving at the boundary, the filter is:

1. **Does this describe a Bitcoin operation, or an application-interface convention?**
2. **Does this presuppose multi-tenancy, permission UI, or app sandboxing?**
3. **If we ever did support this concern, where would it live — in the core or in an overlay above the core?**

Concepts that pass the first filter go into the core (Engine/Store). Concepts that fail it stay at the conformance layer, are stubbed, or are amputated entirely. Concepts that would live in an overlay (per-user databases, per-origin permission tokens) are deferred, with their forward direction recorded so the core stays unchanged when the overlay arrives.

The full per-element classification is the living register at [`docs/reference/brc100-conformance.md`](../../../docs/reference/brc100-conformance.md). The principle's statement, manifestations, and tests for compliance are at [`docs/reference/core-vs-conformance.md`](../../../docs/reference/core-vs-conformance.md).

**Concrete consequences enforced by this ADR:**

1. **The Engine speaks wallet vocabulary, never BRC-100 vocabulary.** No `originator` parameter, no `seekPermission` flag, no BRC-100 hash-shaped return values from primitives. This restates ADR-026 as a consequence of the broader principle.
2. **The Store schema carries no application-interface columns.** No `users` table, no `originator` column, no permission-overlay tables denormalised into data tables. Permission state, when implemented, lives in an overlay above the core.
3. **The conformance layer is a wrapper, not a tier.** `BSV::Wallet::BRC100` translates vocabulary at the request/response boundary; it does not maintain state, does not interpose business logic, does not own its own collaborators.
4. **Spec-shape validation lives at the conformance layer; operation invariants live at the Engine.** ADR-026's two-kinds-of-preconditions rule generalises: anything that is "did the caller meet the BRC-100 contract" is conformance; anything that is "is this a legal wallet operation" is core.
5. **Reserved-name enforcement lives at the conformance layer.** BRC-99 (basket `admin*`, `default`, `p `, trailing ` basket`) and BRC-98 (protocol `admin*`, `p `, trailing ` protocol`) reserved patterns are rejected at the boundary, even where the corresponding machinery isn't built.

## Alternatives Considered

### A. Let BRC-100 vocabulary flow into the core where convenient

Allow Engine primitives to accept `originator:` if it's "more convenient" than translating, allow Store columns to carry per-origin axes if a permissions feature is anticipated, allow conformance shapes to leak into Engine returns where the translation cost feels like overhead.

**Rejected.** This is the path that produced the reference implementation's shape (every row carries `userId`, permission state is woven through the data layer). The cost is paid on every operation forever, for tenancy and permission concerns that may or may not arrive, and which when they do arrive should live in an overlay anyway. ADR-007 made this rejection for `userId` specifically; this ADR generalises the rule.

### B. Implement BRC-100 conformance as a separate tier with its own state

Give `BSV::Wallet::BRC100` its own session cache, its own per-originator tracking, its own permission state, so it can be "fully featured" without changing the Engine.

**Rejected.** This violates principle-of-state — a second source of truth beside the database. Conformance state that needs to persist belongs in the schema (and therefore in the core); state that doesn't need to persist is a per-call translation that doesn't need a tier. The conformance layer stays a millimetres-thin wrapper.

### C. Drop BRC-100 conformance altogether and expose only the Engine

If conformance is always thin, why have it as a layer at all? Expose `Engine` directly to callers.

**Rejected.** The conformance contract is a real product obligation — consumers interoperate against BRC-100 shapes, not Engine shapes. The layer is thin but load-bearing; eliminating it would push translation duty onto every consumer. The right shape is "thin layer that exists", not "no layer".

### D. Implement BRC-100 conformance once we have multi-tenancy / permissions

Defer thinking about the boundary until we actually need it (when we add multi-user or originator support).

**Rejected as the cost of deferral has already been observed.** The wallet has been built for seven months *without* an articulated principle, and the result has been a coherent set of decisions that read as instinctively right. Articulating the principle now is cheap and prevents the inevitable case where a future contributor doesn't share the instinct and the boundary leaks. The decision is "name what we've been doing", not "decide what to do".

## Consequences

### Positive

* **Future BRC-100 deferral decisions become filter applications, not first-principles work.** When the next BRC-100 concept arrives that doesn't fit the core, the register and the principle answer the question: amputate, defer, or implement at the boundary.
* **The throughput-target argument has a single home.** ADR-002's "design for scale" rationale, applied to specific BRC-100 concepts, no longer needs to be re-derived for each one — the principle states it once.
* **Multi-user support and originator support both become additive.** Both are overlays above the core. Adding them does not require disturbing the Engine, the Store schema, or existing specs. The per-user-databases ADR and the originator ADR (this branch) commit to this shape explicitly.
* **The principle is testable by inspection.** Engine method signatures contain no BRC-100 vocabulary; Store columns carry no application-interface axes; the conformance layer's source file is the only place BRC-100 names appear. Drift is reviewable.

### Negative

* **The conformance layer carries vocabulary translation overhead per call.** A method call through `BSV::Wallet::BRC100` always involves translation in and out of the Engine's wallet-vocabulary shape. The cost is real but small (~one shape mapping per call); the alternative (vocabulary leakage into the Engine) is worse over the lifetime of the wallet.
* **Spec-shape validation duplicates the Engine's operation invariants in two places (the conformance layer for shape, the Engine for legality).** Both checks are necessary, but a single input may be rejected at the first or the second. ADR-026's two-kinds-of-preconditions rule frames why this is correct, not redundant.

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

Naming a principle that has already governed seven months of design decisions is not speculative complexity — it is *removing* speculation by writing down what is already true. The retrospective costs nothing (the decisions are made; recording them clarifies them) and the forward benefit is real (the next decision in the same shape doesn't get re-derived from scratch). No new abstraction is built; no code is added; the conformance layer is the same wrapper it has been. **Approve.**

## Validation

* The Engine's public surface (the 28 primitives ratified under ADR-026) carries no BRC-100 vocabulary in any parameter name or return key.
* The Store schema contains no `users`, no `originator`, no per-application permission tables.
* `BSV::Wallet::BRC100` is the unique source file in which BRC-100 spec vocabulary (`originator`, `seekPermission`, BRC-100 hash-shape keys) appears at the conformance/core boundary.
* The conformance register at [`docs/reference/brc100-conformance.md`](../../../docs/reference/brc100-conformance.md) classifies every BRC-100 concept against this principle.

## References

* [`docs/reference/core-vs-conformance.md`](../../../docs/reference/core-vs-conformance.md) — the principle's statement and manifestations.
* [`docs/reference/brc100-conformance.md`](../../../docs/reference/brc100-conformance.md) — the living per-concept register.
* ADR-002 — design for scale; the throughput argument behind this principle.
* ADR-003 — schema as canonical state; the principle whose corollary this is on the BRC-100 axis.
* ADR-007 — single-tenant engine, no user table; first application of this principle (retrospective).
* ADR-018 — stateless SDK / stateful wallet; companion structural boundary.
* ADR-021 — BRC-100 interface as a plain Ruby module; the conformance layer's shape.
* ADR-026 — Engine primitive surface; codified "Engine doesn't speak BRC-100" for the primitive layer; this ADR generalises that to the whole core.
* ADR-028 (this branch) — per-user databases as the multi-user primitive; one forward application of this principle.
* ADR-029 (this branch) — originator deferral and DBAP direction; another forward application.
