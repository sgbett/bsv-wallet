# ADR-023: Promotion is a row, not a column

## Status

Accepted. **Supersedes ADR-011 (post-broadcast promotion).**

**Decided:** 2026-06-15 (#307).

## Context

ADR-011 (post-broadcast promotion) recorded two things: the `outputs.promoted` flag as a one-shot UPDATE (a scalability-tempered deviation from append-only immutability), and — as an open defect — that *promote-authorisation* (`promoted ⟹ the action is internal, or its broadcast was accepted`) was enforced **only in application code**, with no database backstop. Under ADR-003 an invariant with no schema backstop is a defect, not an accepted tier; #307 tracked closing it.

The obvious backstop is a trigger on the `promoted` UPDATE — but that fires on the Phase-4 send path, the throughput the scalability target (ADR-002) protects (~10k tx/s, #221). A single-row CHECK cannot express the rule (it spans `actions.broadcast_intent` and `broadcasts.tx_status`). So the defect sat between two principles: ADR-003 wants a schema backstop; ADR-002 forbids a hot-path trigger.

## Decision Drivers

* The authorisation invariant must have a **declarative** schema backstop (ADR-003) — not application code, not a hot-path trigger (ADR-002).
* `promoted` is already a per-*action* fact: every read/write is `action_id`-scoped and Phase 4 flips all of an action's outputs together. Nothing needs per-output granularity.
* The #221 insight (ADR-019): turn a cross-table predicate into **row existence** so a foreign key enforces it for free.

## Decision

**Represent promotion as the existence of a per-action `promotions` row, not an `outputs` column.**

* **Drop `outputs.promoted`.** `outputs` returns to pure INSERT-only — the HOT-tuple churn and the "immutable except one flip" caveat of ADR-011 disappear (a vacuum *win*). "Is it promoted?" becomes `EXISTS (SELECT 1 FROM promotions WHERE action_id = …)`.
* **`promotions(action_id PK → actions ON DELETE CASCADE)`** — the row's existence *is* the canonical-state fact. Lossless: one row per action, since promotion was always per-action.
* **`spendable(action_id) → promotions(action_id) ON DELETE CASCADE`** — UTXO-set membership is structurally gated on authorisation; a spendable row cannot exist without a promotions row. Reject/reorg teardown is a single `DELETE FROM promotions` that cascades the spendable rows out.
* **Gate the promotions row declaratively** (the #221 composite-FK trick): `intent` + `authorising_status` columns; a `promo_path` CHECK for the internal/send disjunction (`intent='none' ⟺ status NULL`); an `auth_not_rejected` CHECK; a composite FK `(action_id, intent) → actions(id, broadcast_intent)`; and a composite FK `(action_id, authorising_status) → broadcasts(action_id, tx_status)`. A send promotion can therefore only be created while its broadcast actually holds that status; a NULL status (internal path) skips the broadcasts FK (MATCH SIMPLE).

**Authorising set: optimistic, unchanged.** `auth_not_rejected` admits any status except `REJECTED`/`DOUBLE_SPEND_ATTEMPTED` — the same predicate `record_broadcast_result` used before. Promote on a non-rejected ACK; `reject_action` compensates on a later flip. No behaviour change.

**Mutable-target handling: `ON UPDATE CASCADE` on the broadcasts FK.** As `tx_status` advances (RECEIVED→SEEN_ON_NETWORK→MINED) the cascade keeps `authorising_status` synced — `tx_status` stays the single source of truth, no duplicated "accepted" latch. The consequence: a flip to `REJECTED` while a promotions row exists is rejected (the cascade would breach `auth_not_rejected`), so `reject_action` deletes the promotions row first. Correct-by-construction.

This **realises ADR-022** (state as a FK row) and **supersedes ADR-011's promoted-UPDATE deviation** — there is no UPDATE on `outputs` any more. ADR-011 (failure-bounded delete of unpromoted outputs) still stands: outputs are still deleted on abort/reap/reject.

## Alternatives Considered

### A. A trigger on the `promoted` UPDATE
Enforce authorisation in a `BEFORE UPDATE` trigger.
**Rejected** — fires on every send at Phase 4, the hot path; caps throughput (ADR-002, #221). The very cost ADR-011 flagged.

### B. Keep the boolean, enforce in application code (the ADR-011 status quo)
**Rejected** — this *is* the #307 defect: an invariant with no schema backstop, which ADR-003 forbids. "Not very detrimental" was the wrong test; the test is "can the database reject the invalid state?"

### C. A stable "accepted" latch instead of `ON UPDATE CASCADE`
A monotonic boolean on `broadcasts` as the FK target, so it stops moving once set.
**Rejected** — it duplicates information derivable from `tx_status` (the stored-status denormalisation the schema avoids, ADR-003). CASCADE keeps a single source of truth; the cascade writes hit a tiny table.

## Consequences

### Positive
* Promote-authorisation has a **declarative** backstop — no trigger, anywhere. The database refuses an unauthorised promotion (no broadcast, or a rejected one) and refuses a spendable row without one.
* `outputs` is pure INSERT-only again: no HOT-update churn, no vacuum erosion, the immutability caveat of ADR-011 is gone.
* Reject/reorg teardown is one `DELETE FROM promotions` (cascades spendable), not a multi-table sweep.

### Negative / watch-items
* **Reject ordering is coupled:** `tx_status` cannot flip to `REJECTED` while a promotions row exists — `reject_action` must delete the promotions row first. This is enforced (the cascade breaches `auth_not_rejected` otherwise), so a violation fails loudly rather than drifting.
* **Residual app-trust** (unchanged from ADR-011): the database guarantees "no promotion unless the broadcast is/was non-rejected", but cannot guarantee ARC reported the truth.

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

This removes machinery rather than adding it: a mutable column and its UPDATE path become an INSERT-only row gated by constraints the schema already knows how to enforce. The genuinely simpler-looking option (B, keep the flag + app code) is the one rejected, because "simpler" there means "no backstop", which is the defect. The chosen design is *cheaper* than the trigger it replaces and restores immutability the wallet wanted anyway — scale and correctness pull the same way. The one subtlety (CASCADE + the reject-first ordering) is enforced, not assumed. **Approve.**

## Validation

* `promo_path`, `auth_not_rejected`, both composite FKs, the `spendable → promotions` FK, `ON DELETE CASCADE`, and `ON UPDATE CASCADE` (incl. the REJECTED-flip rejection) are each proven in `spec/bsv/wallet/store/constraints_spec.rb` (Postgres).
* Full wallet unit suite green on both Postgres and SQLite; the internal-path NULL-status promotion (MATCH SIMPLE skip) and the send-path gate verified on both backends.

## References

* ADR-011 (post-broadcast promotion) — superseded; this records the same lifecycle without the `outputs` UPDATE.
* ADR-011 (failure-bounded delete of unpromoted outputs) — still in force; outputs are still deleted on failure.
* ADR-022 — state as a FK row; this is its concrete application to promotion.
* ADR-019 — the broadcasts-intent composite-FK trick this generalises.
* ADR-003 — schema as canonical state; the principle the old app-only enforcement breached.
* ADR-002 — design for scale; why a hot-path trigger was the wrong backstop.
* ADR-004 — outputs/spendable partition + spendable-as-a-FK-row, the seed of the membership pattern.
* `#307` — the defect this closes; `#221` — the composite-FK precedent.
* `gem/bsv-wallet/db/migrations/012_promotions.rb`; `gem/bsv-wallet/lib/bsv/wallet/store.rb` (`record_promotion`, `promote_action`, `promote_action_outputs`, `promote_change_to_spendable`, `do_reject`); `gem/bsv-wallet/lib/bsv/wallet/store/models/promotion.rb`.
