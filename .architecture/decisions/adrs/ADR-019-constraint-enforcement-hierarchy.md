# ADR-019: Constraint-enforcement hierarchy — declarative over trigger over application-atomic

## Status

Accepted.

## Context

ADR-003 establishes that the schema is the canonical source of truth and that "constraints are the enforcement layer" — but it deliberately leaves open *which* mechanism enforces *which* invariant, forward-referencing "a later ADR". This is that ADR.

The schema has three enforcement mechanisms available, in descending order of how much the database does for us:

1. **Declarative** — FK (including composite), CHECK, UNIQUE, NOT NULL, ENUM. The rule is encoded as a constraint; the planner enforces it on every relevant write with no procedural code to maintain.
2. **Trigger** — a `plpgsql` (or SQLite `WHEN … BEGIN RAISE`) routine that runs per affected row. Expresses rules a CHECK cannot — cross-row JOIN conditions, cross-table existence checks, and constraints on DELETE (CHECKs never fire on DELETE).
3. **Application-atomic** — the rule is held by Ruby inside a single `db.transaction`, with no schema backstop. The invariant is true because the writes that would violate it are bundled into one atomic transition (ADR-006), not because the database would reject the bad state.

These are not interchangeable. A declarative encoding is cheapest to run and impossible to forget; a trigger is procedural code that taxes every write it guards; an application-atomic invariant is the weakest — it relies on every write path going through the one method that maintains it. The wallet already uses all three (verified below), so the question is not "which one" globally but "what decides which one for a given invariant".

Two forces pull against each other. ADR-003's drift-prevention argues for pushing every invariant as far up the hierarchy as it will go — ideally declarative, so the database is genuinely the last line of defence. Scale (ADR-002) argues that a trigger runs per row and caps throughput; #221 records the design-discussion figure that triggers "limit throughput to ~10k tx/s region". On a hot path that ceiling is the binding constraint, so there even the trigger rung is too expensive and the rule drops to application-atomic.

## Decision Drivers

* ADR-003 wants invariants enforced by the schema, not re-implemented in application code — so prefer the most declarative mechanism that *can* express the rule.
* A trigger is procedural and runs per affected row; on a throughput-critical path it competes directly with the scale target (~10k tx/s ceiling, #221).
* Some rules are not declaratively expressible at all (cross-table existence, constraints on DELETE) — for these a trigger is the *only* schema mechanism.
* Whichever mechanism is chosen, the transition must still be atomic (ADR-006); application-atomic enforcement is the floor, not an escape from atomicity.

## Decision

Adopt an **enforcement hierarchy** and a rule for descending it:

> **Declarative (FK / CHECK / UNIQUE / ENUM) > trigger > application-atomic.**
> Encode every invariant declaratively. Fall back to a trigger only when the rule is not declaratively expressible. On a throughput-critical path, where a per-row trigger would tax the scale target, drop to enforcing the rule consciously in application code within a single transaction — and flag that it has no schema backstop.

Descend a rung only for a stated reason: the rung above cannot express the rule, or (for the trigger → application step) the rung above is too costly on a hot path. The choice is recorded per-invariant, not left implicit.

This refines ADR-003's "constraints are the enforcement layer" into a graded mechanism: the schema is still the canonical truth, but *how* an invariant is held depends on what the mechanism can express and what the path can afford.

**Worked examples** (each verified against the named file):

* **broadcasts-intent — declarative (FK + CHECK), chosen over an earlier trigger proposal.** The invariant: an action with `broadcast_intent = 'none'` (internalize, import, wbikd, receipts) must never own a `broadcasts` row. A trigger was proposed (#198 gap 5, mirroring `prevent_outbound_spendable`) and rejected in #221 on throughput grounds — the `broadcasts` INSERT is on the hot send path. It is instead encoded declaratively in `db/migrations/001_create_schema.rb`: a composite FK `broadcasts(action_id, intent) → actions(id, broadcast_intent)` (lines 122-123), targeting the `unique %i[id broadcast_intent]` on `actions` (line 93, added by the `broadcast_intent` rename, #217), plus `constraint(:intent_not_none, "intent != 'none'")` on `broadcasts` (line 124). The FK forces a broadcast row's `intent` to equal its parent's `broadcast_intent`; the CHECK forbids `intent = 'none'`; composed, a `broadcast_intent = 'none'` action can hold no `broadcasts` row — declaratively, no trigger. The same FK with `on_update: :restrict` makes `actions.broadcast_intent` effectively immutable while a `broadcasts` row exists (one constraint, two invariants).

* **promote-authorisation — application-atomic, hot path.** The invariant: an output reaches `promoted = true` only for an internal-path action or one whose broadcast was accepted. This sits one rung below the trigger because it is *both* non-declarable and on a hot path. `Store#record_broadcast_result` (`lib/bsv/wallet/store.rb` lines 637-673) runs the promotion inside the same transaction as the status write, guarded on a non-rejected status (line 669); `Store#reject_action` (lines 253-257, via `do_reject`) compensates if a previously non-rejected status later flips to REJECTED (#240). The full rationale — why declarative and trigger are both rejected here, and the scalability tempering of immutability that the `promoted` flag rests on — is recorded in ADR-011; it is not duplicated here. This ADR records only that promote-authorisation is the hierarchy's bottom-rung instance, and why it lands there.

* **Triggers are not banned — two invariants live on that rung legitimately.** A trigger is correct when the rule is declaratively impossible *and* the guarded write is not throughput-critical:
  - `prevent_outbound_spendable` (`db/migrations/003_schema_constraints.rb` lines 109-125) — a `BEFORE INSERT ON spendable` trigger that rejects a `spendable` row for an `output_type = 'outbound'` output. The condition is a cross-row check against `outputs`, which a CHECK on `spendable` cannot express (ADR-004).
  - `prevent_internal_action_delete` (`db/migrations/008_prevent_internal_action_delete.rb` lines 28-45) — a `BEFORE DELETE ON actions` trigger that blocks deleting a `broadcast_intent = 'none'` action that owns a `promoted` output. CHECKs never fire on DELETE, and the condition is a cross-table existence check — declaratively impossible on both counts.

## Alternatives Considered

### A. No hierarchy — pick a mechanism case-by-case with no stated rule
**Pros:** maximal freedom per invariant; no policy to apply.
**Cons:** the mechanism choice becomes implicit and inconsistent; reviewers cannot tell whether an application-enforced invariant was a considered trade or an oversight that should have been a constraint. ADR-003 explicitly defers the *which-mechanism* question to a later ADR — leaving it unanswered re-opens the drift gap that ADR-003 closes for derived state.
**Rejected** — the point of recording the hierarchy is that descending a rung now demands a reason.

### B. Declarative-only — forbid triggers entirely, encode everything as FK/CHECK or push it to application code
**Pros:** the simplest possible schema vocabulary; no procedural code in the database.
**Cons:** `prevent_outbound_spendable` and `prevent_internal_action_delete` guard invariants a CHECK cannot express (cross-row, cross-table, on-DELETE). Banning triggers would force these into application code — *demoting* two enforceable invariants below the rung the schema can actually hold them at, contradicting ADR-003's drift-prevention.
**Rejected** — triggers are the correct rung for non-declarable rules off the hot path; removing the rung loses real enforcement.

### C. Trigger-first — enforce every cross-state invariant with a trigger for maximal schema backstop
**Pros:** every invariant has a database backstop; nothing relies on application code remembering the rule.
**Cons:** a trigger runs per affected row and caps throughput at the ~10k tx/s region (#221). Promote-authorisation fires on every successful send (the `promoted` flip); a trigger there taxes exactly the path the wallet must scale (ADR-011 alternative C). And where a rule *is* declaratively expressible (broadcasts-intent), a trigger is strictly worse than the FK+CHECK that needs no procedural code at all.
**Rejected** — a trigger is a fallback for non-declarable rules off the hot path, not the default; on the hot path it is the wrong trade.

## Consequences

### Positive
* The mechanism for each invariant is a recorded decision with a reason, not an implicit accident — a reviewer can check that an application-enforced invariant earned its rung (non-declarable and/or hot-path) rather than slipping there by omission.
* ADR-003's "constraints are the enforcement layer" gains an operational test: try declarative first, drop to a trigger only for non-declarable rules, drop to application-atomic only when a trigger is too costly on a hot path.
* Declarative encodings are preferred where they fit, so most invariants need no procedural code and cannot be forgotten by a new write path.

### Negative
* **Application-atomic invariants have no schema backstop.** Promote-authorisation is correct only because every write path routes through `record_broadcast_result` / `reject_action`; a new path that flips `promoted` without that guard would not be rejected by the database. This residual risk is the explicit price of the bottom rung (ADR-011 watch-items track it).
* **The hot-path judgement is a judgement.** Whether a given write is "throughput-critical" enough to forgo a trigger rests on the ~10k tx/s figure, which is a design-discussion estimate (#221), not a measured per-trigger benchmark on this schema. A path mis-classified as hot would forgo a backstop it could afford.
* **Mechanism can drift from rung as the schema evolves.** A rule enforced application-atomically today may become declaratively expressible after a schema change (or vice versa); the recorded choice must be revisited, not assumed permanent.

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

The hierarchy is a discipline, not new machinery — it adds no code, only a stated order and a requirement to justify each descent. That is the right weight for the problem: it makes the *which-mechanism* question (which ADR-003 left open) answerable and reviewable without prescribing a one-size mechanism that the two legitimate triggers and the hot-path promote-authorisation case each show would be wrong. The genuinely simpler option (B, declarative-only) was rejected for a concrete reason — it would demote two enforceable invariants — and the maximalist option (C, trigger-first) for a measured-scale reason. The residual risk (bottom-rung invariants lack a backstop) is real but bounded and already tracked in ADR-011. The hierarchy earns its place by turning an implicit choice into a recorded, checkable one. **Approve.**

## Open question

The authorising set for promote-authorisation — the same open question ADR-011 carries, restated here because it is the substantive content of the bottom-rung instance. The current guard promotes on **not-`ArcStatus::REJECTED`** (optimistic: `REJECTED` is `%w[REJECTED DOUBLE_SPEND_ATTEMPTED]`, so anything else — `RECEIVED`, `STORED`, `QUEUED` — promotes), with `reject_action` compensating on a later flip to REJECTED. The stricter alternative gates on `ArcStatus::ACCEPTED` (`%w[SEEN_ON_NETWORK SEEN_MULTIPLE_NODES ACCEPTED_BY_NETWORK MINED IMMUTABLE]`) only. Optimistic-and-compensate (current) versus strict-accept-only — unresolved. `ArcStatus` (`lib/bsv/wallet/arc_status.rb`) is the single source of truth for both sets.

## Validation

* Each invariant's enforcement mechanism is the highest rung that can express it within its path's throughput budget: broadcasts-intent is declarative (FK + CHECK); `prevent_outbound_spendable` and `prevent_internal_action_delete` are triggers (non-declarable, off the hot path); promote-authorisation is application-atomic (non-declarable and hot-path).
* No invariant enforced application-atomically is one a declarative constraint or an affordable trigger could hold instead — each bottom-rung case has a recorded reason (non-declarable and/or hot-path).
* Postgres-specific enforcement (CHECK violations, ENUM rejection, RESTRICT semantics, both triggers) is verified against Postgres, not assumed from SQLite (ADR-009).

## References

* ADR-003 — schema as canonical state; this ADR refines its "constraints are the enforcement layer" into the graded mechanism it forward-references.
* ADR-011 — post-broadcast promotion and tempered immutability; the fully-recorded promote-authorisation instance (alternatives C–F there cover why declarative and trigger are both rejected for it).
* ADR-009 — Postgres-native primitives; the FK / CHECK / ENUM / trigger features the hierarchy selects among.
* ADR-004 — outputs / spendable partition; the invariant `prevent_outbound_spendable` guards.
* ADR-006 — one relational store, one ACID boundary; the atomicity every rung relies on.
* `db/migrations/001_create_schema.rb` (actions `unique %i[id broadcast_intent]` :93; broadcasts `intent` column + composite FK + `intent_not_none` CHECK :108, :122-124) — the declarative broadcasts-intent encoding.
* `db/migrations/003_schema_constraints.rb` (:109-125) — `prevent_outbound_spendable` trigger.
* `db/migrations/008_prevent_internal_action_delete.rb` (:28-45) — `prevent_internal_action_delete` trigger.
* `lib/bsv/wallet/store.rb` — `record_broadcast_result` (:637-673, promote guard :669); `reject_action` / `do_reject` (:253-257, :834-888).
* `lib/bsv/wallet/arc_status.rb` — `ACCEPTED` / `REJECTED` / `TERMINAL` sets.
* HLR #198 (constraint-gap analysis; gap 5 proposed the trigger), #221 (FK + CHECK chosen over trigger; the ~10k tx/s ceiling), #217 (`broadcast_intent` rename adding the `UNIQUE(id, broadcast_intent)` FK target), #240 (`reject_action` cascade + lifted speculative-promotion guard).

## Unverified claims

None. Every structural claim above was read from the named file. One correction worth noting against the drafting brief: the broadcasts-intent composite FK + CHECK lives in `001_create_schema.rb` (the schema was consolidated; #221 drafted it as "migration 011"), **not** in `003_schema_constraints.rb` — `003` holds the `prevent_outbound_spendable` trigger. The references cite the live locations. The `ArcStatus::REJECTED` set is two values (`REJECTED`, `DOUBLE_SPEND_ATTEMPTED`), broader than the single `REJECTED` implied in the source notes and ADR-011's open-question wording; the text above uses the verified set.
