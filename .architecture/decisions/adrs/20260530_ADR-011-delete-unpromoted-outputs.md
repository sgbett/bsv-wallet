# ADR-011: Failure-bounded DELETE of unpromoted outputs

## Status

Accepted.

**Decided:** 2026-05-30 (PR #243, `reject_action` cascade; `03ce420`)

## Context

The `outputs` table is the immutable, append-only log (ADR-004): an output row exists iff it really was an output, and once written it is never rewritten. Immutability is not held as an end in itself — its purpose is scalability (ADR-002): an INSERT-only table generates no dead tuples, so the hot, partitioned `outputs` table stays free of vacuum pressure and cold partitions remain detachable and archivable. The deviation that *flips* an output's `promoted` flag is recorded separately (ADR-011, post-broadcast promotion); this ADR records only the *deletion* deviation.

The four-phase lifecycle (lock → sign → broadcast → promote, HLR #183) means an output can be written before its action reaches the network. A send-path output is persisted at sign time (`promoted = false`) so the caller's metadata — basket, tags, derivation — survives the sign → acceptance gap, since the BRC-100 `signAction` call does not carry the outputs array. Such an output is *staged*, not canonical. Several paths can leave a staged-but-never-canonical output stranded:

- **abort** — the caller abandons an unbroadcast action (`Store#abort_action`);
- **reap** — the reconciliation reaper sweeps a never-accepted, stale action (`Store#reap_stale_actions`);
- **reject** — a broadcast the wallet speculatively promoted on a not-rejected ARC response later flips to a terminal REJECTED status, and the action plus every dependent must be unwound (`Store#reject_action` / `do_reject`).

A strict reading of immutability would forbid all of these and force an alternative — a separate staging table, or leaving aborted rows as orphans. The question is whether deleting these rows harms the scalability the immutability protects.

This decision has a history worth recording. The cascade infrastructure that makes the deletes single-statement was agreed early (`action_id` denormalised onto `spendable` / `output_baskets` / `output_details` with `ON DELETE CASCADE`, restored in PR #134). Drift then crept in: code promoted outputs at sign time, blurring staged from canonical. HLR #183 (#193/#194) rolled that back to the strict four-phase design, so in the cleaned-up world a delete only ever removed never-promoted rows. PR #243 (#240) then re-agreed controlled unwinding: `reject_action` lifts the old speculative-promotion guard and cascades forward through dependents on a definitive REJECTED.

## Decision Drivers

* An output row should exist only if it really was (or is) an output of the wallet — no orphans, no speculative rows beside the log.
* Caller metadata must be stageable before broadcast acceptance, which means staged rows can be abandoned and must be removable.
* Immutability exists to protect scalability; a deviation is acceptable iff it does not harm vacuum / partition behaviour.
* Cascade tear-down of an abandoned action must be a small number of statements, not a per-row walk.

## Decision

**Allow DELETE of *unpromoted* outputs along the failure paths (abort / reap / reject), and treat this as vacuum-neutral rather than a breach of immutability.** The deletion is **failure-rate-bounded, not throughput-bounded**: the high-frequency case — deleting a *spent* output on every spend — does not exist by design (a spent output stays in the log; only its `spendable` row is removed, ADR-004). Deletes happen only when an action fails or is abandoned, a rare path, so they do not generate the steady dead-tuple stream that would make vacuum the scaling ceiling.

The deletion is structured to respect the `outputs.action_id` RESTRICT FK (#189): the action row cannot be deleted while its outputs exist, so each path clears the output rows (and their `output_id`-keyed dependents) first, then deletes the action. The `action_id`-denormalised relationship tables (`spendable`, `output_baskets`, `output_details`) cascade on the action delete, but each path also deletes them explicitly for clarity and to guarantee zero leftover rows in the same transaction. `reject_action` additionally walks children before parents (post-order) so a child's `inputs` row — which references this action's output — is gone (via the child action's `inputs.action_id` CASCADE) before the output it references is deleted.

A promoted output is **never** deleted by these paths. `abort_action` refuses if any output is `promoted = true` (`CannotAbortPromotedActionError`); `reap_stale_actions` protects only actions with a promoted output; `reject_action` refuses an action ARC has reported accepted (`CannotRejectAcceptedActionError`) and refuses an internal-path action outright (`CannotRejectInternalActionError`). Deleting a promoted output would destroy canonical UTXO history — exactly what immutability protects.

## Alternatives Considered

### A. Strict INSERT-only — forbid all deletes; stage speculative outputs elsewhere, or leave aborted rows as orphans
A separate staging table puts non-outputs beside the log; orphaned speculative rows put non-outputs *in* the log. Both break "an output exists iff it was an output." Delete-on-failure keeps the log honest and is vacuum-neutral because it is failure-bounded. The orphan variant was considered and rejected as janky. **Rejected.**

### B. Record consumption with a mutable column instead of deleting
Out of scope here — that is the inputs-as-lock decision (ADR-004); a spent output is *not* deleted, only its `spendable` row is. This ADR concerns abandonment of *never-canonical* rows. **N/A.**

## Consequences

### Positive
* The `outputs` log stays honest — every row is, or was, a real output.
* Caller metadata can be staged before acceptance and cleanly removed if the action never completes.
* Immutability's purpose — scalability — is intact: the deletes are failure-bounded, not on the hot per-spend path, so they add no steady vacuum load.
* Abandoned-action tear-down is a handful of statements (the cascade FKs do most of the work).

### Watch-items
* **Monitor `n_dead_tup` on `outputs`** — the abort/reject/reap-rate canary. A spike means failures (or speculative-promotion churn) are higher than the failure-bounded assumption allows, and the vacuum-neutrality claim needs re-checking.
* **The promoted-output guards are application-enforced** on the abort path, with a defence-in-depth trigger (`prevent_internal_action_delete`, migration 008) backing the internal-action case. The reject/reap guards remain application-only.

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

The deletion is not erosion of immutability — it is measured against the only thing immutability protects (vacuum and partition scalability) and does not harm it, because the high-frequency spent-delete was *designed out* and only the rare failure path deletes. Keeping the log free of orphans and staging tables is the simpler, more honest design. The residual risk is that real-world failure rates exceed the failure-bounded assumption; the `n_dead_tup` watch-item is the right canary. **Approve.**

## Validation

* `Store#abort_action` deletes outputs and dependents only when no output is `promoted = true`, else raises `CannotAbortPromotedActionError` (`store.rb:203`).
* `Store#reap_stale_actions` excludes actions with a promoted output and clears unpromoted outputs + dependents before the action delete (`store.rb:790`).
* `Store#reject_action` / `do_reject` cascade forward, refuse accepted/internal actions, and delete only unpromoted outputs (`store.rb:253`, `store.rb:834`).
* The `action_id` denormalised FKs on `spendable` / `output_baskets` / `output_details` are `ON DELETE CASCADE` (migration `002_action_id_cascade.rb`); `outputs.action_id` is RESTRICT (migration `006_outputs_restrict_action_id.rb`).

## References

* ADR-004 — outputs as the immutable append-only log; this decision is a bounded deviation from it.
* ADR-003 — the principle of state.
* ADR-002 — the scale target the immutability (and thus this deviation's vacuum-neutrality test) rests on.
* ADR-011 (post-broadcast promotion) — the sibling deviation (the `promoted` UPDATE flip).
* `reference/principle-of-state.md` — "A note on scale" (the two vacuum-neutral deviations).
* HLR #183 (restored strict 4-phase, the rollback), #189 (`outputs.action_id` RESTRICT), #240 (`reject_action` cascade + lifted speculative-promotion guard, the re-agreement); PR #134 (restored cascade FKs), #243 (`reject_action`).
* `gem/bsv-wallet/lib/bsv/wallet/store.rb` — `abort_action`, `reap_stale_actions`, `reject_action`, `do_reject`.
* `gem/bsv-wallet/db/migrations/002_action_id_cascade.rb`, `006_outputs_restrict_action_id.rb`, `008_prevent_internal_action_delete.rb`.

## Unverified claims

None.
