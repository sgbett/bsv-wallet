# Plan: #240 — Broadcast resolution + reject_action cascade

## Context

#240 captures architectural work surfaced by the #126 e2e investigation. The wallet promotes outputs *speculatively* on any non-rejected ARC response so callers and downstream tx-building unblock immediately — this is central to the wallet's opportunistic-spending model. When the network later contradicts the speculation (terminal REJECTED arrives via the daemon's polling loop), the wallet currently has no clean unwind: `Store#fail_broadcast_action` refuses if outputs are promoted, leaving rows stuck in a "DB says spent / chain says no such tx" state. Compounding the problem: if action X is rejected and another action Y has already spent X's outputs, Y is invalid too — the cascade must propagate.

Concrete trigger: SDK action #22 in the #126 harness was promoted on Arcade's `RECEIVED` response, then ARC rejected with `PROCESSING (4)`. No daemon was running to discover the rejection, but even if it had run, `fail_broadcast_action` would have refused the unwind.

The fix is three coupled changes: (1) introduce `Store#reject_action` with cascade semantics that replaces `fail_broadcast_action`; (2) rename the two scheduler loops to `broadcast_submission` / `broadcast_resolution` so their roles are legible; (3) unify the speculative-promotion predicate across inline and daemon paths so both follow the same "promote on non-rejection" rule, with `reject_action` as the safety net.

## Design

### Two loops, semantic names

| Current | New | Role | Interval |
|---|---|---|---|
| `broadcast_push_submission` | **`broadcast_submission`** | Discover `broadcast_at IS NULL` → submit to ARC | 5s |
| `broadcast_push` | **`broadcast_resolution`** | Discover `broadcast_at IS NOT NULL AND tx_status NOT IN TERMINAL_STATUSES` → poll to terminal | **30s** (was 5s) |

Shared worker drains `inproc://broadcasts.pull` and routes via `process` based on `broadcast_at`. Worker internals (`submit`, `poll_status`) keep their names — only discovery roles get renamed.

### `Store#reject_action`

Replaces `fail_broadcast_action`. Semantics:

- One outer DB transaction. Inner recursive method walks forward: `outputs.action_id=X → inputs.output_id=O → actions.id=child` for every output O of X, recursively rejecting children **before** tearing down the target.
- For `broadcast_intent='none'` target: raise `BSV::Wallet::CannotRejectInternalActionError`. Outer txn rolls back; broadcasts row + retry_count visible for next resolution-loop pass. Single-error design — no `ChainedSendError` variant.
- For `inline` / `delayed`: drop the promoted-output guard. Unwind in order: `output_baskets`, `output_details`, `output_tags`, `spendable`, `outputs`, `broadcasts`, `action`. Also defensively clear `actions.tx_proof_id` (should be NULL on a rejection but belt-and-braces) and any `action_labels` rows.
- Cycle defence: carry a `visited` Set into recursion; raise on re-encounter (DAG invariant violation, costs nothing).
- Idempotent: calling on a deleted action_id is a no-op (queries return empty, deletes affect 0 rows). retry_count increment lives in the *caller* (resolution loop) so phantom increments aren't possible.

### Speculation unification

Currently asymmetric:
- **Engine inline** path (engine.rb:279, 324): promotes via `accepted?(broadcast_result)` — true if status present AND `NOT IN REJECTED_STATUSES`. So `RECEIVED`, `QUEUED`, `ANNOUNCED_TO_NETWORK` all trigger promotion.
- **Daemon** path (`store.rb:635` in `record_broadcast_result`): promotes only on `ACCEPTED_STATUSES` membership (`SEEN_ON_NETWORK`, `ACCEPTED_BY_NETWORK`, `MINED`, `IMMUTABLE`).

Per user decision: unify on the **optimistic predicate**. Change `record_broadcast_result` to promote when status is present AND not in `REJECTED_STATUSES`. Both paths now follow "promote on non-rejection." The cadence change to 30s for the resolution loop is the operational counterweight — speculation is more aggressive but the safety net runs more deliberately.

### Schema

Single migration adds `broadcasts.retry_count INTEGER NOT NULL DEFAULT 0`. Postgres 11+ optimises `ADD COLUMN ... NOT NULL DEFAULT <constant>` to metadata-only (no rewrite); brief ACCESS EXCLUSIVE lock. Counter increments **only** on raise+rollback (invariant-violation rollback path in the resolution loop). Small numbers expected.

### Error class

New `BSV::Wallet::CannotRejectInternalActionError < BSV::Wallet::Error` in `lib/bsv/wallet/errors.rb`. Existing `CannotAbortPromotedActionError` retained because BRC-100 `abort_action` keeps its narrow contract (pre-broadcast cancel, refuses on promoted) — that semantic is unchanged.

## Implementation breakdown

One PR closing #240. Commits ordered:

1. **`db: migrate broadcasts.retry_count column`**
   - New migration `gem/bsv-wallet/db/migrations/NNN_add_broadcasts_retry_count.rb` following the pattern in `001_create_schema.rb` and `006_*` — branch by `database_type`, both `up`/`down`.

2. **`feat(errors): CannotRejectInternalActionError`**
   - Add to `lib/bsv/wallet/errors.rb`.

3. **`feat(store): reject_action with cascade + child discovery`**
   - New `child_actions_of(action_id:)` query in `lib/bsv/wallet/store.rb` — returns action_ids whose inputs reference the given action's outputs.
   - New `reject_action(action_id:)` public method with the recursive inner method (extracted private) and the no_send raise. Inside the outer txn. Unwind side-table list above. `visited` Set for cycle defence.
   - Update `lib/bsv/wallet/interface/store.rb` — replace `fail_broadcast_action` docblock + signature with `reject_action`; add `child_actions_of`.
   - Remove `Store#fail_broadcast_action` (and its interface entry).

4. **`feat(engine): speculation unification + reject_action callers`**
   - `lib/bsv/wallet/store.rb` `record_broadcast_result` line 635: change `Models::Broadcast::ACCEPTED_STATUSES.include?(...)` to "status present AND `NOT IN REJECTED_STATUSES`" — same shape as `Engine#accepted?`. Note in the method's docstring that this matches the inline path's predicate and is intentional speculation; resolution loop + `reject_action` is the safety net.
   - `lib/bsv/wallet/engine.rb` lines 278, 325 (uncommitted rejection wiring): change `@store.fail_broadcast_action(...)` → `@store.reject_action(...)`.
   - `lib/bsv/wallet/engine/broadcast.rb` lines 157, 194: same replacement. Daemon now wraps the call in a `rescue BSV::Wallet::CannotRejectInternalActionError` that increments `broadcasts.retry_count` for the row, then re-raises for emit/observability. (The row stays alive; next polling cycle re-encounters.)

5. **`refactor(scheduler): rename to broadcast_submission/broadcast_resolution`**
   - `lib/bsv/wallet/scheduler.rb` — task name strings, intervals (resolution = 30).
   - `lib/bsv/wallet/store.rb` `pending_polls` → `pending_resolutions`; `pending_pushes` → `pending_submissions`.
   - `lib/bsv/wallet/interface/store.rb` matching renames.
   - `lib/bsv/wallet/engine/broadcast.rb` `pending_polls` / `pending_pushes` class methods → matching new names.
   - `inproc://broadcasts.pull` socket name unchanged (it's the queue, not the discovery role).
   - Event-name strings emitted via `BSV::Wallet.emit` change to match (`task: 'broadcast_submission'` / `'broadcast_resolution'`) — check `docs/wallet-events.md` if it exists and update.

6. **`test: reject_action specs`**
   - Spec updates per next section.

## Test coverage

Target spec files:

- `spec/bsv/wallet/store/persistence_spec.rb` (already has the `fail_broadcast_action` describe at line 569 — replace with `reject_action`):
  - inline action with promoted outputs: unwinds cleanly (the previously-blocked case).
  - delayed action with promoted outputs: unwinds cleanly.
  - 3-level chain X → Y → Z all inline: rejecting X cascades, Z removed before Y before X, all in one txn.
  - 3-level deep recursion proven via spy on `child_actions_of`.
  - **Partial-cascade rollback isolation**: child A cleans, child B is no_send → raise → entire outer txn rolls back; parent + both children intact. Load-bearing invariant.
  - no_send target: raises `CannotRejectInternalActionError`, action and row intact.
  - cycle (synthetic): raises (defence-in-depth).
  - idempotent: calling on already-deleted id is a no-op.
  - Side-table cleanup: outputs with output_baskets/output_details/output_tags + an action with action_labels — all removed.
  - `actions.tx_proof_id` defensively cleared (or NULL) post-reject.

- `spec/bsv/wallet/engine/broadcast_spec.rb` (~12 sites currently mock `fail_broadcast_action`):
  - Convert mock receiver to `reject_action`.
  - Add a spec for the daemon poll discovering REJECTED: row+descendants gone afterwards.
  - Add a spec for the `CannotRejectInternalActionError` rescue path: `retry_count` incremented, row intact, emit event observable.

- `spec/bsv/wallet/engine_spec.rb` (line 692): the BRC-100 `abort_action` wrapper test is unchanged (different method, unchanged contract).

- **Postgres-only spec** for the migration's `ADD COLUMN NOT NULL DEFAULT 0` semantics — same shape as existing schema-CHECK specs. SQLite branch verified by the general test suite passing under SQLite.

Concurrency note: the inner txn relies on Sequel's default read-committed. The cascade walks via outputs→inputs joins; concurrent `promote_action_outputs` on a sibling action is safe (different rows). The plan agent flagged this as a potential bug — verify with a targeted spec that runs cascade and a concurrent promote in two threads and asserts no FK violation / no half-cascade.

## Files to modify

```
gem/bsv-wallet/db/migrations/NNN_add_broadcasts_retry_count.rb  (new)
gem/bsv-wallet/lib/bsv/wallet/errors.rb
gem/bsv-wallet/lib/bsv/wallet/store.rb
gem/bsv-wallet/lib/bsv/wallet/interface/store.rb
gem/bsv-wallet/lib/bsv/wallet/scheduler.rb
gem/bsv-wallet/lib/bsv/wallet/engine.rb
gem/bsv-wallet/lib/bsv/wallet/engine/broadcast.rb
gem/bsv-wallet/spec/bsv/wallet/store/persistence_spec.rb
gem/bsv-wallet/spec/bsv/wallet/engine/broadcast_spec.rb
docs/wallet-events.md (if it touches task name strings)
```

## Verification

```bash
# Run from gem/bsv-wallet directory.
DATABASE_URL=postgres://localhost/bsv_wallet_test bundle exec rspec spec/bsv spec/bin  # Postgres
bundle exec rspec spec/bsv spec/bin                                                     # SQLite
bundle exec rubocop
```

Expectations:
- All specs green under both DB adapters.
- New persistence specs assert reject_action cascade + raise on no_send + partial-rollback isolation.
- broadcast_spec mocks renamed from `fail_broadcast_action` to `reject_action`.
- No `fail_broadcast_action` references left in `lib/` or `spec/`.
- `pending_polls` / `pending_pushes` no longer referenced.

Manual: after the #126 cleanup_spec is re-run (separately, with the resolution loop active), action #22's row would naturally resolve to deletion via the cascade path. That's confirmation in the wild but not gated on this PR.

## Out of scope (tracked separately)

- **Orphan handling** (MINED_IN_STALE_BLOCK → reorg recovery). Resolution loop already keeps polling stale-block txs per the existing `TERMINAL_STATUSES` exclusion. *Response* strategy is its own issue.
- **Resolution cadence tuning under load**. 30s is the chosen default; production tuning is separate.
- **Surgery on SDK's current stuck state from #126** (action #22 + no_send orphans). Handled under #126; not gated on #240.
- **External children** (UTXOs spent on-chain by a tx the wallet doesn't track). Out of scope by definition — cascade only reaches the wallet's DB.

## Persistence

This plan also written to `/opt/ruby/bsv-wallet/.claude/plans/20260530-240-broadcast-resolution-reject-action.md` for durable project storage.
