# ADR-011: Post-broadcast promotion and the scalability-tempered outputs-immutability invariant

## Status

Accepted.

## Context

The `outputs` table is an append-only log (ADR-003). Its immutability is not an end in itself — it exists for scalability: an INSERT-only table generates no dead tuples, so the hot, partitioned `outputs` table stays free of vacuum pressure and cold partitions remain detachable and archivable.

An action moves through four phases — lock, sign, broadcast, promote. Outputs are promoted into the canonical UTXO set only at Phase 4, once the broadcast is accepted, so that the existence of an output implies its action reached the network (which keeps `derived_status` honest and makes cascade-fail-with-descendants the rare path). The send path, however, must persist the caller's output metadata (basket, tags, derivation) at sign time, before acceptance — the BRC-100 `signAction` call does not carry the outputs array. A send-path output is therefore written early and marked not-yet-canonical until Phase 4; an internal-path action (`broadcast_intent = 'none'`) has no broadcast and promotes synchronously.

Two operations consequently depart from strict INSERT-only:
- the **UPDATE** that flips an output's `promoted` flag false → true at Phase 4;
- the **DELETE** that removes a failed or abandoned action's unpromoted outputs (reject / abort / reap).

## Decision Drivers

* An output's existence must imply its action was broadcast-accepted.
* Caller metadata must survive the sign → acceptance gap.
* Immutability exists to protect scalability; a deviation is acceptable iff it does not harm that purpose.
* Promotion is on the hot send path, so per-row enforcement there competes with throughput.

## Decision

**Promote outputs post-broadcast via a `promoted` flag.** Send-path outputs are written `promoted = false` at sign time and flipped to `true` at Phase-4 acceptance; internal-path outputs are born `promoted = true`. One flag carries both lifecycles in the one table.

**Outputs-immutability is tempered to its purpose, not held as an absolute.** Because immutability serves scalability, the two deviations are judged against vacuum and partition impact, and accepted, because neither harms it:
* The `promoted` flip is a **HOT update** — `promoted` is unindexed, so the new tuple stays on its page, prunes opportunistically, and creates no index bloat; internal-path outputs never update. At most one self-clearing dead tuple per send-path output.
* The reject/abort/reap **DELETE is failure-rate-bounded, not throughput-bounded**. The high-frequency case — deleting spent outputs on every spend — does not exist: spent outputs stay in the log, and only their `spendable` row is removed.

**Promote-authorisation is a transactional invariant, not a schema constraint.** An output reaches `promoted = true` only for an internal action or one whose broadcast was accepted. `Store#record_broadcast_result` performs the promotion in the same transaction as the status write, and `Store#reject_action` compensates if an accepted status later flips to REJECTED. `promoted` is a plain boolean; its correctness is held by the transaction (see Alternatives C–F).

## Alternatives Considered

### A. Hold strict immutability — promote at sign time, allow no deviations
Sign-time promotion makes "an output exists" no longer mean "broadcast accepted," breaks `derived_status`, and makes cascade-fail-with-descendants the common path. Strict INSERT-only also cannot stage caller metadata before acceptance. **Rejected.**

### B. Stage speculative outputs outside the log, or leave aborted outputs as orphans
A separate staging table — and orphaned speculative rows — both put non-outputs in or beside the log; an output should only ever be in `outputs` if it really was an output. Delete-on-failure keeps the log honest and is vacuum-neutral (failure-bounded). **Rejected.**

### C. Enforce promote-authorisation with a trigger
A trigger on the `promoted` UPDATE runs on every send, and triggers cap throughput (~10k tx/s). Enforcement on the hot path costs more than it buys. **Rejected.**

### D. Enforce it declaratively (composite FK + CHECK)
Declarative encoding needs a stable key match. Promote-authorisation gates a mutable flag by a mutable `tx_status`, with a disjunctive internal-path escape (no `broadcasts` row), and a CHECK cannot reference another table. Not expressible. **Rejected.**

### E. Materialise an "authorised" marker on `broadcasts` and FK to it
A marker duplicates information already derivable from `tx_status` — a stored-status denormalisation of the kind the schema avoids. **Rejected.**

### F. Make promotion structural — a row/FK rather than a boolean
Reduces to E (a redundant marker). The boolean stays; its correctness is the transaction's responsibility. **Rejected.**

## Consequences

### Positive
* The four-phase lifecycle holds; `derived_status` is sound; cascade-fail-with-descendants is rare.
* Caller metadata survives the sign → acceptance gap with no separate staging table.
* Immutability's purpose — scalability — is intact: both deviations are vacuum-neutral.

### Watch-items
* **`promoted` stays unindexed.** An index (e.g. a partial `WHERE promoted = false`) makes the update non-HOT — heap *and* index dead tuples. Coin selection enters through `spendable`, never `outputs.promoted`, so nothing legitimately needs such an index.
* **Consider `fillfactor < 100` on `outputs`** to reserve in-page room so the HOT update stays heap-only.
* **Monitor `n_dead_tup` on `outputs`** — the abort/reject-rate canary.
* Promote-authorisation has no schema backstop; it is a transactional invariant. Accepted because C–F are worse.

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

The deviations are appropriate, not erosion: each is measured against the only thing immutability protects — vacuum and partition scalability — and neither harms it (a HOT, self-pruning flip; a failure-bounded delete). Enforcing promote-authorisation in the transaction rather than the schema is the right trade on a hot path: declarative encoding is impossible and a trigger is too costly. The residual risk — an invariant held by code rather than a constraint — is bounded and guarded by the watch-items. The one real over-reach would be indexing `promoted`. **Approve.**

## Open question

The authorising set. Promotion fires optimistically on any status **not in `ArcStatus::REJECTED`** (`REJECTED`, `DOUBLE_SPEND_ATTEMPTED`) — so interim statuses (`RECEIVED` / `STORED` / `QUEUED`) promote, with `reject_action` compensating if a later poll flips to a rejected status (#240). The stricter alternative promotes only on `ArcStatus::ACCEPTED` (`SEEN_ON_NETWORK`, `SEEN_MULTIPLE_NODES`, `ACCEPTED_BY_NETWORK`, `MINED`, `IMMUTABLE`). The current design is deliberately *asymmetric*: promotion is optimistic (not-rejected), but the compensation is not — `reject_action` raises `CannotRejectAcceptedActionError` rather than unwind an action the network has already reported accepted (re-org is the only path to that state; #240). Optimistic-and-compensate, or strict-accept-only.

## References

* ADR-003 — the principle of state; this decision tempers its outputs-immutability layer.
* ADR-002 — the scale target this tempering rests on.
* ADR-019 — the constraint-enforcement hierarchy; promote-authorisation is its hot-path, application-atomic instance.
* HLR #183 (four-phase lifecycle), #194 (`promoted`), #189 (`outputs.action_id` RESTRICT), #221 (FK chosen over trigger; ~10k tx/s ceiling), #240 (`reject_action`).
* `reference/schema.md`; `ArcStatus` — `gem/bsv-wallet/lib/bsv/wallet/arc_status.rb`.
