# Action lifecycle — atomic states and crash recovery

The wallet's action flows are **not** single atomic transactions. Each is a chain of independent atomic Store transactions (each its own `@db.transaction`), sometimes with non-atomic gaps between them. The **principle of state** requires every gap to leave the database in a *valid* state that some mechanism either completes or reclaims — no intermediate state may be left with no recovery owner.

This document is the current-state map of those transitions across every multi-step flow: the atomic Store units, the recovery mechanisms, and a per-flow gap/owner audit. (The crash-recovery work that produced it — and the history of each gap as it was found and closed — lives in #324 and its sub-issues/PRs, not here.)

Source of truth: `gem/bsv-wallet/lib/bsv/wallet/engine/action.rb`, `gem/bsv-wallet/lib/bsv/wallet/engine/beef_importer.rb`, `gem/bsv-wallet/lib/bsv/wallet/engine.rb`, `gem/bsv-wallet/lib/bsv/wallet/store.rb`, `gem/bsv-wallet/lib/bsv/wallet/engine/broadcast.rb`, and `gem/bsv-wallet/lib/bsv/wallet/scheduler.rb`.

## Atomic Store units

Each is one `@db.transaction` — all-or-nothing.

| Unit | Writes |
|------|--------|
| `create_action` | action row (called with `inputs: []`; initial lock is a separate `lock_inputs` via `FundingStrategy`) |
| `lock_inputs` | input rows (all-or-nothing) |
| `sign_action` | wtxid + raw_tx, TxProof upsert, **broadcasts row (only if intent ≠ none)**, pending + change output rows |
| `stage_action` | wtxid + raw_tx, TxProof upsert, pending outputs — deferred path; **no broadcasts row** |
| `save_proof` | TxProof upsert (raw_tx, plus merkle material when present) |
| `complete_internal_action` | `sign_action` + `save_proof` + `promote_action` + `promote_change_to_spendable` — **one transaction** (internal `no_send` completion) |
| `promote_action` | promotions row + output rows + spendable rows (wallet-owned) |
| `promote_action_outputs` | promotions row + spendable rows for existing outputs (send path, on broadcast accept); idempotent |
| `promote_change_to_spendable` | promotions row + spendable rows for change |
| `record_broadcast_result` | broadcasts status update **+ `promote_action_outputs` in the same transaction** when not rejected |
| `reap_action` | per-ID reclaim: clear dependents, delete action (cascades inputs → releases locks) |
| `abort_action` | clear dependents + delete action (cascades inputs); refuses broadcasts-row / promoted |
| `reject_action` / `do_reject` | recursive post-order DAG teardown; refuses internal / network-accepted |
| internalize (`BeefImporter#import`) | create + sign + save_proof + labels + save_beef_proofs + promote — **one transaction** |
| `import_utxo` Phase 1 | create + sign + save_proof + link_proof + promote (root UTXO) — **one transaction** |

## Recovery mechanisms

- **Reaper** — `Engine::Reaper` logical model behind `inproc://reaper.pull`, driven by a `Scheduler#run!` discovery loop (`stale_action_ids`, interval 60 s, bounded by limit). Reclaims actions that are past the staleness threshold (`Config#reap_threshold`, default 1 h), **unpromoted**, with **no broadcasts row**, and either broadcastable (`intent ≠ 'none'`) **or** pre-sign (`wtxid IS NULL`). `reap_action` re-validates under a `FOR UPDATE` row lock and releases locks via the `inputs` CASCADE on action delete. The two exclusions (promoted, broadcasts-row) protect completed and in-flight actions; see the per-flow audit for why each arm is needed.
- **Broadcast submission loop** — `pending_submissions` (broadcasts rows with `broadcast_at IS NULL`), every 5 s. Drives `Engine::Broadcast#submit`.
- **Broadcast resolution loop** — `pending_resolutions` (`broadcast_at` set, non-terminal `tx_status`), every 30 s. Drives `poll_status` → `record_broadcast_result` (status + promotion atomic).
- **Proof acquisition loop** — `Engine::TxProof`, every 30 s.
- **Atomic completions** — `complete_internal_action` (internal `no_send`), the internalize ingress, `import_utxo` Phase 1, and `record_broadcast_result` (send-path promotion) each commit their multi-row work in one transaction, so no recovery owner is needed *between* their steps.
- **`reject_action` / `abort_action`** — terminal teardowns for network-rejected sends and operator/CLI aborts.

## Send paths — `createAction`

### Deferred / signable (`sign_and_process: false`)

`create_action` → `lock_inputs` → `stage_action` → `save_proof` → return signable handle. Promotion happens later via `signAction`.

| Gap | Valid intermediate state | Owner |
|-----|--------------------------|-------|
| before `stage_action` | inputs locked, `wtxid IS NULL`, no broadcasts row | **Reaper** (pre-sign arm). |
| staged, awaiting `signAction` | wtxid (placeholder) set, intent delayed, **no broadcasts row**, unpromoted | **Reaper** after threshold — correct once the signer never returns; see **Known limitations** (#383) for the slow-signer caveat. |

### Internal `no_send` (`broadcast_intent = 'none'`)

`create_action` → `lock_inputs` → `complete_internal_action` (atomic) → read-only BEEF build/validate (post-commit).

| Gap | Valid intermediate state | Owner |
|-----|--------------------------|-------|
| before `complete_internal_action` | intent none, inputs locked, `wtxid IS NULL`, unpromoted, no broadcasts row | **Reaper** (pre-sign arm — `wtxid IS NULL`). |
| completion | — | **No gap.** `complete_internal_action` signs, proves, promotes, and makes change spendable in one transaction. |

A *signed* internal action with no promotion (a deliberately-parked / OP_RETURN completion) is **never reaped** — the predicate's `wtxid IS NULL` arm only matches pre-sign internal rows.

### Broadcast — inline and delayed

`create_action` → `lock_inputs` → `sign_action` (writes broadcasts row, `broadcast_at IS NULL`) → `save_proof` → BEEF build/validate → `publish_beef_hint` → (inline only) `broadcast_worker.process`. Delayed differs only in that the daemon's submission loop picks up the broadcasts row later.

| Gap | Valid intermediate state | Owner |
|-----|--------------------------|-------|
| before `sign_action` | inputs locked, `wtxid IS NULL`, no broadcasts row | **Reaper** (pre-sign arm). |
| after `sign_action` (broadcasts row, `broadcast_at IS NULL`) | wtxid + raw_tx + broadcasts row + pending outputs, unpromoted | **Submission loop.** This is the designed steady state for delayed; inline crash here degrades to it. |
| after `mark_broadcast_attempted`, before status | `broadcast_at` set, `tx_status IS NULL` | **Resolution loop** rediscovers and resolves. |
| accept recorded | promotions + spendable rows | Terminal-valid. `record_broadcast_result` makes status + promotion one transaction. |

## `signAction` (deferred completion)

`apply_spends` (sign) → `sign_action` (broadcasts row) → `save_proof` → BEEF build/validate → broadcast per intent. Structurally the broadcast path: it never promotes synchronously — promotion happens on broadcast accept via `record_broadcast_result`. Owners are identical to the broadcast paths above. (The `no_send` return is unreachable in the base wallet: deferred + `no_send` isn't creatable — that combination belongs to #192.)

## `internalizeAction` (`BeefImporter#import`)

Parse Atomic BEEF → SPV verify → **resolve + validate outputs before any write** → one transaction (`create` + `sign` + `save_proof` + labels + `save_beef_proofs` + `promote`).

| Gap | State | Owner |
|-----|-------|-------|
| output resolution failure (bad shape/vout/satoshis) | nothing persisted | Validation runs pre-persistence — `InvalidParameterError`, no rows written. |
| any failure mid-ingress | nothing persisted | **No gap.** The single transaction rolls back create + sign + proofs + promote together. |

## `import_utxo`

Fetch tx + merkle proof from the network (pre-persistence) → **Phase 1** (atomic: create + sign + save_proof + link + promote the root UTXO as spendable) → **Phase 2** (`create_action(no_send)` — atomic, the internal path above) that spends the root output to a BRC-42-derived address.

| Gap | Valid intermediate state | Owner |
|-----|--------------------------|-------|
| network fetch failure | nothing persisted | Pre-persistence; strands nothing. |
| between Phase 1 and Phase 2 | root UTXO imported and **spendable**, self-payment not done | **Degraded-but-safe.** Funds are usable (a spendable root output), not locked or lost. A re-run short-circuits as `already_imported` (idempotent on `wtxid`) rather than auto-completing Phase 2 — the operator can sweep the root output. |

## `sweep`

Computes the fee and **fails fast on a dust-only wallet before locking any inputs** (no orphan), then delegates to `create_action` (`no_send` → atomic internal completion; broadcast → the broadcast paths). No completion logic of its own, so no new gap.

## `abort` / `reject`

- **`abort_action`** — one transaction: refuses if a broadcasts row exists (owned by the broadcast loops) or the action is promoted (canonical UTXO history); otherwise clears dependents and deletes the action, cascading inputs to release locks.
- **`reject_action` / `do_reject`** — one recursive transaction: post-order DAG teardown of a network-rejected send and its descendants; refuses internal (`intent='none'`) and network-accepted actions.

Both are single atomic transitions — no intermediate gap.

## Known limitations

- **Deferred-signer staleness ambiguity (#383).** A staged action awaiting `signAction` (intent delayed, no broadcasts row, unpromoted) is reaper-eligible after the staleness threshold. That is correct once the signer never returns, but is structurally indistinguishable from a legitimately slow external signer. The threshold is the only lever today; the fix is a "parked" marker that exempts deferred rows the caller is still working on (the same discriminator #192's batching needs). The staged state *is* owned — this is a precision gap, not an unowned state.
