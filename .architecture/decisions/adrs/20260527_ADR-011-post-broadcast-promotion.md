# ADR-011: Post-broadcast promotion — a one-shot UPDATE on outputs

## Status

**Superseded by [ADR-023](20260615_ADR-023-promotion-as-a-row.md)** (#307). The one-shot UPDATE deviation and the open promote-authorisation defect recorded below are resolved there: promotion became the existence of a `promotions` row with a declarative composite-FK backstop, and `outputs.promoted` no longer exists. This ADR is retained as the record of the interim flag-based design.

**Decided:** 2026-05-27 (PR #194, restore Phase-4 promotion; `1efb77a`)

## Context

The `outputs` table is the immutable, append-only log (ADR-004). Immutability is not an end in itself — its purpose is scalability (ADR-002): an INSERT-only table generates no dead tuples, so the hot, partitioned `outputs` table stays free of vacuum pressure and cold partitions remain detachable and archivable (`docs/reference/principle-of-state.md`, "A note on scale"). The *deletion* deviation is recorded separately (ADR-011, failure-bounded delete of unpromoted outputs); this ADR records only the *update* deviation.

An action moves through four phases — lock, sign, broadcast, promote (HLR #183). Outputs become part of the canonical UTXO set only at Phase 4, once the broadcast is accepted, so that the existence of a *promoted* output implies its action reached the network — which keeps the derived action status honest and makes cascade-fail-with-descendants the rare path. But the send path must persist the caller's output metadata (basket, tags, derivation) at sign time, before acceptance, because the BRC-100 `signAction` call does not carry the outputs array. A send-path output is therefore written early as `promoted = false` and must later be marked canonical. An internal-path action (`broadcast_intent = 'none'`) has no broadcast and is born `promoted = true`.

Marking a staged output canonical is, mechanically, a column update on a row in an append-only table — a deviation from strict INSERT-only. (Sign-time promotion had previously crept in and was rolled back by HLR #183; PR #194 restored promotion to its correct Phase-4 position, introducing the `promoted` column as the carrier.)

## Decision Drivers

* A *promoted* output's existence must imply its action was broadcast-accepted (or is internal-path).
* Caller metadata must survive the sign → acceptance gap, which means a staged row must exist before acceptance and be flipped after.
* Immutability exists to protect scalability; a deviation is acceptable iff it does not harm vacuum / partition behaviour.
* Promotion is on the hot send path — per-row enforcement there competes with throughput.

## Decision

**Promote a send-path output by a one-shot `promoted` UPDATE (false → true) at Phase-4 acceptance, and treat this as vacuum-neutral rather than a breach of immutability.** Send-path outputs are written `promoted = false` at sign time and flipped to `true` when the broadcast is accepted; internal-path outputs are born `promoted = true`. One unindexed boolean carries both lifecycles in the one table.

The flip is judged against vacuum impact and accepted because it does not harm it:

* It is a **HOT update** — `promoted` is unindexed, so the new tuple stays on its heap page, prunes opportunistically, and creates no index bloat. At most one self-clearing dead tuple per send-path output; internal-path outputs never update at all.
* It is **one-shot** — `false → true` once, never back. `Store#record_broadcast_result` performs the flip (`promote_action_outputs`) inside the same transaction as the broadcast status write; a second invocation finds already-promoted rows and is a no-op.

The alternative — rewriting output rows on every state change — would accumulate dead tuples and make vacuum the scaling ceiling at the wallet's millions-of-tx/s target. The one-shot HOT flip is the minimal deviation that achieves staged-then-canonical without that cost.

## Alternatives Considered

### A. Strict immutability — promote at sign time, no deviation
Sign-time promotion makes "a promoted output exists" no longer mean "broadcast accepted," breaks the derived action status, and makes cascade-fail-with-descendants the common path. It also cannot stage caller metadata as *not-yet-canonical*. This is exactly the drift HLR #183 reverted. **Rejected.**

### B. Make promotion structural — a row/FK rather than a boolean flip
Replace the flag with, e.g., a `promoted_outputs` membership row. This trades a HOT update for an INSERT + DELETE pair and a second table on the hot path, for no scalability gain over the self-pruning flip; it also reintroduces the staging-table smell the log avoids. **Rejected** — the boolean stays.

## Consequences

### Positive
* The four-phase lifecycle holds; the derived action status is sound; cascade-fail-with-descendants stays rare.
* Caller metadata survives the sign → acceptance gap with no separate staging table.
* Immutability's purpose — scalability — is intact: the flip is a self-pruning HOT update, vacuum-neutral.

### Watch-items
* **`promoted` must stay unindexed.** A partial index (e.g. `WHERE promoted = false`) would make the update non-HOT — heap *and* index dead tuples. Coin selection enters through `spendable`, never `outputs.promoted`, so nothing legitimately needs such an index.
* **Consider `fillfactor < 100` on `outputs`** to reserve in-page room so the HOT update stays heap-only.
* **Monitor `n_dead_tup` on `outputs`** as the canary.

## Open defect — promote-authorisation has no database backstop

Distinct from the UPDATE deviation itself (accepted above) is the question of *which write paths may flip the flag*. The invariant is: `promoted = true` only for an internal action, or one whose broadcast was accepted. Today that invariant is enforced **only in application code** — `Store#record_broadcast_result` performs the flip in the same transaction as the status write (`promote_action_outputs` runs only when the status is not in `ArcStatus::REJECTED`), and `Store#reject_action` compensates if an accepted status later flips to REJECTED. There is **no schema constraint** backing it.

Per ADR-003, an invariant the application cares about must be expressible as a database constraint, or consciously flagged where it is not. An invariant enforced in application code with **no database backstop explicitly breaks ADR-003** — it is not an acceptable design tier, it is a defect. It is recorded here as an **open problem under active scrutiny**, tracked in **GitHub issue #307**, to be resolved by moving the enforcement into the database (or restructuring so the database can hold it).

The reason it is hard — not a justification for leaving it in application code, but the constraint the fix must work within — is that the obvious database mechanisms do not fit a hot path:

* A trigger on the `promoted` UPDATE runs on every send, and triggers cap throughput (~10k tx/s, the #221 precedent). Too costly on the hot path.
* A declarative composite-FK-plus-CHECK encoding (the technique #221 used for the broadcasts-intent invariant) needs a stable key match; promote-authorisation gates a mutable flag by a mutable `tx_status`, with a disjunctive internal-path escape (no `broadcasts` row), and a CHECK cannot reference another table — so it is not declaratively expressible as written.
* A materialised "authorised" marker on `broadcasts` duplicates information derivable from `tx_status` — the stored-status denormalisation the schema avoids.

These rule out the *current* mechanisms; they do not make application-only enforcement acceptable. The resolution is open work in #307, not a settled trade-off. (An earlier framing presented this as the bottom tier of an "enforcement hierarchy"; that framing is rejected — ADR-003 admits no such tier.)

## Open question — the authorising set

Promotion currently fires on any status **not in `ArcStatus::REJECTED`** (i.e. not `REJECTED` / `DOUBLE_SPEND_ATTEMPTED`), so interim statuses (`RECEIVED` / `STORED` / `QUEUED`) promote optimistically, with `reject_action` compensating if a later poll flips to a rejected status (#240). The stricter alternative promotes only on `ArcStatus::ACCEPTED` (`SEEN_ON_NETWORK`, `SEEN_MULTIPLE_NODES`, `ACCEPTED_BY_NETWORK`, `MINED`, `IMMUTABLE`). The design is deliberately *asymmetric*: promotion is optimistic, but the compensation is not — `reject_action` raises `CannotRejectAcceptedActionError` rather than unwind an action the network has reported accepted (re-org is the only path to that state; #240). Optimistic-and-compensate vs strict-accept-only is unresolved.

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

The UPDATE deviation is appropriate, not erosion: it is measured against the only thing immutability protects — vacuum and partition scalability — and a self-pruning HOT flip does not harm it. The one over-reach to guard against is indexing `promoted`. Separately, promote-authorisation living in application code with no database backstop is a genuine defect against ADR-003, correctly tracked as open work (#307) rather than rationalised; the hot-path cost of the obvious database mechanisms explains why it is hard, not why it is acceptable. **Approve the UPDATE deviation; the enforcement gap remains open.**

## Validation

* `outputs.promoted` is an unindexed boolean, `NOT NULL DEFAULT true` (migration `005_outputs_promoted.rb`).
* `Store#record_broadcast_result` flips `promoted` inside the status-write transaction, gated on `!ArcStatus::REJECTED.include?(status)` (`store.rb:637`, `:669`).
* `promote_action_outputs` updates existing `promoted = false` rows to `true` and is a no-op on re-invocation (`store.rb:176`).
* Internal-path outputs are written `promoted = true` at create time (`store.rb:147`).
* No schema constraint enforces promote-authorisation — only the transaction does.

## References

* ADR-004 — outputs as the immutable append-only log; this decision is a bounded deviation from it.
* ADR-003 — the principle of state (the database enforces valid state; an app-only invariant with no backstop breaks it).
* ADR-002 — the scale target the immutability rests on.
* ADR-011 (failure-bounded delete) — the sibling deviation (the DELETE of unpromoted outputs).
* `docs/reference/principle-of-state.md` — "A note on scale" (the two vacuum-neutral deviations).
* HLR #183 (four-phase lifecycle), #194 (`promoted` column, Phase-4 promotion), #221 (FK chosen over trigger; ~10k tx/s ceiling), #240 (`reject_action` compensation), **#307 (the open promote-authorisation defect)**.
* `gem/bsv-wallet/lib/bsv/wallet/store.rb` — `record_broadcast_result`, `promote_action_outputs`; `gem/bsv-wallet/lib/bsv/wallet/arc_status.rb`; `gem/bsv-wallet/db/migrations/005_outputs_promoted.rb`.

## Unverified claims

None.
