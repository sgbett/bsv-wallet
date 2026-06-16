# createAction lifecycle — atomic states and crash recovery

> Produced by the #323 crash-recovery audit. The findings flagged inline as
> **FINDING** are tracked under umbrella **#324** (Crash-recovery & atomicity):
> R1 → #325 (wire the reaper), G1/I1/D1 → #326 (pre-sign reclaim), I2 → #327
> (internal `no_send` backstop), I3 → #328 (partial-promotion atomicity), and
> the wider-flow audit → #329. This is the seed reference for that audit and
> will grow as #329 extends the analysis to the other multi-step flows.

`createAction` is **not** a single atomic transaction. It is a chain of
independent atomic Store transactions (each its own `@db.transaction`) with
non-atomic gaps between them. The principle of state requires every gap to
leave the database in a *valid* state that some mechanism either completes or
reclaims. This document maps those states per path and audits each gap.

Source of truth verified against:
`gem/bsv-wallet/lib/bsv/wallet/engine/action.rb` (`do_create_action` /
`self.create`, lines 22–204), `gem/bsv-wallet/lib/bsv/wallet/store.rb`, and
`gem/bsv-wallet/lib/bsv/wallet/engine/broadcast.rb`.

> **Baseline note.** This audit was performed against the **pre-#323**
> lifecycle, where `Store#create_action` locked the initial inputs
> atomically with the action row. #323 (the option-(a) seam) has since
> moved initial acquisition out of `create_action` — it is now always
> called with `inputs: []` — into `Store#lock_inputs` via
> `Engine::FundingStrategy`, which owns both the initial lock and the
> top-up loop. The pre-sign leak states (G1/I1/D1) are **unchanged in
> kind**: the inputs are simply locked one step later, by `lock_inputs`
> rather than inside `create_action`. Read "`create_action`'s initial
> lock" below as "`lock_inputs` via FundingStrategy" under #323.

## The atomic Store units

| Unit | Source | Writes (one transaction) |
|------|--------|--------------------------|
| `create_action` | `store.rb:82` | action row + initial `lock_inputs_atomic?` (pre-#323; see baseline note — under #323 this is `inputs: []`, row only) |
| `lock_inputs` (top-up) | `store.rb:99` | additional input rows (all-or-nothing) |
| `sign_action` | `store.rb:109` | wtxid + raw_tx on action, TxProof upsert, broadcasts row (if intent ≠ none), pending + change output rows |
| `stage_action` | `store.rb:135` | wtxid + raw_tx, TxProof upsert, pending output rows (deferred path) |
| `save_proof` | `store.rb:474` | TxProof upsert (raw_tx, and merkle material when present) |
| `promote_action` | `store.rb:151` | promotions row + output rows + spendable rows (internal path) |
| `promote_action_outputs` | `store.rb:188` | promotions row + spendable rows for existing outputs (send path) |
| `promote_change_to_spendable` | `store.rb:603` | promotions row + spendable rows for change outputs |
| `record_broadcast_result` | `store.rb:657` | broadcasts status update **+ `promote_action_outputs` in the same transaction** when not rejected |

## Recovery mechanisms

- **Reaper** — `Store#reap_stale_actions` (`store.rb:811`). Deletes actions
  where `created_at < cutoff` **AND** `broadcast_intent ≠ 'none'` **AND**
  `wtxid IS NOT NULL` **AND** no promotions row. Clears dependent output /
  basket / detail / tag / broadcasts rows first (RESTRICT FKs), then the
  action (cascades inputs). **FINDING R1 (#325): no caller.** `reap_stale_actions`
  is defined and interface-declared but is **not** scheduled anywhere in
  `lib/` or `bin/` — `Scheduler#run!` (`scheduler.rb:33–58`) wires only
  `broadcast_submission`, `broadcast_resolution`, and `proof_acquisition`.
  The reaper only runs from specs. Every "the reaper reclaims it" conclusion
  below is therefore **latent**: correct in design, dead in practice until
  wired.
- **Broadcast submission discovery** — `Store#pending_submissions`
  (`store.rb:731`): broadcasts rows with `broadcast_at IS NULL`. Scheduled
  every 5 s (`scheduler.rb:39`). Drives `Engine::Broadcast#submit`.
- **Broadcast resolution discovery** — `Store#pending_resolutions`
  (`store.rb:722`): broadcasts rows with `broadcast_at IS NOT NULL` and a
  non-terminal `tx_status`. Scheduled every 30 s (`scheduler.rb:49`). Drives
  `poll_status`.
- **Idempotent promotion** — `promote_action_outputs` early-returns when a
  promotions row already exists (`store.rb:190`); all spendable inserts are
  `INSERT … ON CONFLICT (output_id) DO NOTHING`. Re-entrant and safe.
- **`reject_action`** — `store.rb:263` / `do_reject` `store.rb:853`. Terminal
  cascade for network-rejected sends; refuses internal (`intent='none'`) and
  network-accepted actions.

## Path 1 — deferred / signable (`sign_and_process: false`)

Order: `create_action` → `stage_action` → `save_proof` → return signable
handle. No promotion here; promotion happens later via `signAction`.

| Gap | Valid intermediate state | Owner |
|-----|--------------------------|-------|
| after `create_action`, before `stage_action` | action row, inputs locked, `wtxid IS NULL`, no outputs, intent = caller's (delayed/none) | **FINDING D1 (#326)** — `wtxid IS NULL` means the reaper's `wtxid IS NOT NULL` predicate skips this row. Inputs stay locked indefinitely. No owner. (Same shape as the funding-loop / Path 2–4 pre-sign gap — see G1.) |
| after `stage_action`, before `save_proof` | action row + wtxid + raw_tx + pending outputs; TxProof already upserted by `stage_action`'s `write_signing_artifacts` | Reaper *would* reclaim (wtxid set, intent delayed, no promotion) **iff wired (R1)**. `save_proof` here is a redundant TxProof upsert of the same raw_tx — crash before it is harmless. |
| after return, signer never calls `signAction` | staged unpromoted action, inputs locked | Reaper (latent, R1). This is the leak the reaper's relaxed predicate (#: "abandoned deferred actions kept inputs locked") was written for. |

## Path 2 — internal `no_send` (`broadcast_intent = 'none'`)

Order: `create_action` → (funding loop: `lock_inputs` × N) → `sign_action`
→ `save_proof` → `promote_with_outputs` (`promote_action`) →
`promote_change_to_spendable`.

| Gap | Valid intermediate state | Owner |
|-----|--------------------------|-------|
| after `create_action` / mid funding-loop, before `sign_action` | action row, some inputs locked, `wtxid IS NULL`, intent = none | **FINDING I1 (#326)** — reaper excludes `intent='none'` (`store.rb:825`) **and** requires `wtxid IS NOT NULL`. Doubly skipped. No owner; inputs locked forever. |
| after `sign_action`, before `promote_action` | action + wtxid + raw_tx + pending outputs, **no promotions row**, intent = none, no broadcasts row | **FINDING I2 (#327)** — nothing completes or reclaims this. Reaper excludes `intent='none'`. No broadcasts row ⇒ no discovery loop touches it. `abort_action` would work (no broadcasts row, no promotions row) but is never called automatically. Outputs written, never promoted, never spendable, inputs locked forever. |
| after `promote_action`, before `promote_change_to_spendable` | caller outputs promoted (promotions row exists), change outputs written but not spendable | Partial-but-valid: a promotions row now exists, so a re-run of `promote_change_to_spendable` would complete it — but **nothing re-runs it** (synchronous, in-process only). Change sats stranded (not double-spendable, just unspendable). **FINDING I3 (#328).** |

Degenerate sub-case: `no_send` with no caller outputs *and* no change derives
no promotions row at all (both promote calls are guarded — `promote_with_outputs`
returns early on empty outputs `action.rb:537`; `promote_change_to_spendable`
runs only `if change_outputs.any?` `action.rb:189`). Valid (nothing to
promote) but indistinguishable from I2 by structural state.

## Path 3 — broadcast inline (`broadcast == :inline`)

Order: `create_action` → (funding loop) → `sign_action` (writes broadcasts
row, `broadcast_at IS NULL`) → `save_proof` → `publish_beef_hint` →
`broadcast_worker.process` → on 202, `record_broadcast_result` (status +
`promote_action_outputs` **atomic**, `store.rb:688`).

| Gap | Valid intermediate state | Owner |
|-----|--------------------------|-------|
| after `create_action` / funding loop, before `sign_action` | inputs locked, `wtxid IS NULL`, intent = delayed | **FINDING G1 (#326)** — reaper skips (`wtxid IS NULL`). No broadcasts row yet ⇒ no discovery. Inputs locked forever. No owner. |
| after `sign_action`, before `broadcast_worker.process` | wtxid + raw_tx + broadcasts row (`broadcast_at IS NULL`) + pending outputs, no promotions row | **Owned.** The broadcasts row sits in the `pending_submissions` set; the daemon's submission loop re-drives it. Inline crash here degrades gracefully to the delayed path. Correct. |
| during `submit`, after `mark_broadcast_attempted`, before response | `broadcast_at IS NOT NULL`, `tx_status IS NULL` | **Owned.** `pending_resolutions` rediscovers it; `poll_status` resolves via `get_tx_status`. Documented at `broadcast.rb:255–259`. |
| crash after network-accept, before status recorded | tx is in mempool but DB has `tx_status IS NULL`, no promotions row | **Owned.** Resolution loop polls, records, and promotes atomically. |
| accept recorded + promoted | promotions row + spendable rows | Terminal-valid. `record_broadcast_result` made status-and-promotion one transaction (`store.rb:675–690`), closing the historic accept-without-promote gap. |

## Path 4 — broadcast delayed (`broadcast == :delayed`)

Order: identical to Path 3 up to and including `save_proof`; then **no**
inline `process`. The daemon's `pending_submissions` loop picks up the
broadcasts row later.

| Gap | Valid intermediate state | Owner |
|-----|--------------------------|-------|
| after `create_action` / funding loop, before `sign_action` | inputs locked, `wtxid IS NULL` | **FINDING G1 (#326)** (same as Path 3). No owner. |
| after `sign_action` (terminal local state) | wtxid + raw_tx + broadcasts row (`broadcast_at IS NULL`) + pending outputs | **Owned.** This *is* the designed steady state for delayed: `pending_submissions` discovery drives submission → resolution → atomic promotion. Correct and re-entrant. |

## Cross-cutting finding: partial funding-loop top-up locks

The wallet-selected funding loop commits each top-up `lock_inputs` in its own
transaction (`action.rb:888`) before `sign_action`. A crash mid-loop leaves
an action row with *some* inputs locked and `wtxid IS NULL`. This is the same
no-wtxid pre-sign state as G1/I1/D1 and shares their fate: **not reaped**
(both because the reaper is unwired, R1, and because of the `wtxid IS NOT NULL`
predicate even if it were).

## Summary of findings

| # | Issue | State | Severity | Note |
|---|-------|-------|----------|------|
| R1 | #325 | Reaper has no scheduled caller | High | Every "reaper reclaims" recovery below is latent until `reap_stale_actions` is wired into `Scheduler#run!`. |
| G1 / I1 / D1 | #326 | Pre-`sign_action` crash: inputs locked, `wtxid IS NULL` | High | The reaper's `wtxid IS NOT NULL` predicate (`store.rb:826`) explicitly excludes exactly this state. Even when wired, the reaper cannot reclaim a crash *before* signing. Inputs lock indefinitely. This is the dominant gap and the one most relevant to the #213 seam (below). |
| I2 | #327 | Internal `no_send`: signed, outputs written, never promoted | High | `intent='none'` is excluded from the reaper *and* has no broadcasts row, so no discovery loop and no reaper touches it. No automatic completion or reclaim. |
| I3 | #328 | Internal `no_send`: caller outputs promoted, change not | Medium | Promotions row exists so a re-run completes it, but nothing re-runs the synchronous step. Change sats stranded. |

The send paths (3, 4) are well-covered *post-sign*: the broadcasts-row +
`broadcast_at` state machine plus atomic `record_broadcast_result` promotion
form a correct, re-entrant recovery chain. The exposure is concentrated in
(a) the **pre-sign window** across all paths and (b) the **internal `no_send`
path's** synchronous Phase-4 promotion, which has no asynchronous backstop.

## Bearing on the #213 seam (explicit verdict)

The #323 plan's option (a) for #213 separates action-row creation from the
initial input lock, introducing a new intermediate state: **an action row
with zero locked inputs** (between row-create and the first lock).

**Verdict: option (a) introduces no novel recovery exposure, and is safe on
that axis** — and was adopted for #323 on that basis. Reasoning:

1. An input-less action row is *already* a routine, valid state — the
   deferred path's `create_action(inputs: [])` and the wallet-selected
   no-output path (`action.rb:81–88`, `initial_inputs = []`) both create
   action rows with zero inputs today. The schema permits it; nothing about
   it is new.
2. The transient zero-input row under option (a) is strictly *less* leaky
   than the states G1/I1/D1 that already exist and already have no owner: it
   holds **no** locked inputs, so a crash in that window strands nothing —
   the only orphan is an empty action row (no locked UTXOs, no outputs).
3. The reaper's existing predicate (`wtxid IS NOT NULL`) skips it just as it
   skips every pre-sign state — so option (a) neither adds to nor subtracts
   from the reaper's coverage gap.

**Caveat (not a blocker for the seam choice):** option (a) does *not* fix the
pre-existing pre-sign leak (G1/I1/D1) — it inherits it. If anything, by making
the initial lock a separate committed transaction inside FundingStrategy
rather than folded into `create_action`'s single transaction, it widens the
window in which inputs are locked but `wtxid IS NULL` by one extra
round-trip. The widening is marginal and the leaked state is identical in
*kind* to what already exists. So the seam decision should be made on design
grounds (where #213's retry lives most cleanly), not on crash-recovery
grounds — recovery is neutral-to-marginally-worse and the underlying gap
predates this work.

The real recommendation that falls out of this audit is independent of the
seam: **wire the reaper and relax its `wtxid IS NOT NULL` predicate** (or add
a companion pre-sign reclaim keyed on age + absent signing artifact) so that
G1/I1/D1 acquire an owner. Tracked separately from #323 as #325 (wire) and
#326 (predicate), under umbrella #324.
