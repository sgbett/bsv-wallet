# Reaper foundation (#325 + #326)

Part of the #324 crash-recovery & atomicity umbrella. First track item: make the
reaper actually run, and make it reclaim the dominant leaky state (pre-sign
locked inputs). #325 and #326 ship together — scheduling a reaper whose predicate
skips the leak does nothing; relaxing a predicate that never runs does nothing.

## Goal

- The reaper runs in the daemon as a scheduled background task (#325).
- It reclaims abandoned **pre-sign** actions — inputs locked, never signed
  (`wtxid IS NULL`) — releasing their input locks back to the spendable set (#326).
- No multi-step flow regression; the existing leaf-population guarantees hold.

## Design decision: follow the OMQ logical-model pattern (not a bespoke loop)

The reaper becomes a logical model behind a PULL socket — `Engine::Reaper` —
exactly like `Engine::Broadcast` and `Engine::TxProof`. We considered a bespoke
direct-call loop in the Scheduler; rejected it because it bypasses the two
load-bearing reasons every other background task pays the OMQ cost:

1. **The drain contract.** `Scheduler#shutdown` drains on `task.dispatched` minus
   the four terminal events (`task.succeeded`/`.failed`/`.aborted`/`.skipped`).
   A task participates in cooperative shutdown *only* by going through
   `process(id)` and emitting those events. A direct call would have to fake the
   contract by hand-emitting events around a bulk call — implementing dishonestly
   what every real task implements structurally.
2. **The scaling seam.** OMQ is this codebase's concurrency infrastructure, and
   the PUSH/PULL boundary is the line along which work is designed to move off the
   reactor (other fibers/threads/processes) as the wallet scales. A reaper outside
   the bus structurally cannot ride that path; everything else can.

The reaper is **not** architecturally exceptional. The set-based bulk delete it
uses today is an optimisation, not a correctness requirement: abandoned actions
are leaves (their outputs were never spendable, so nothing locked them — see
`utxo_pool.rb` selecting only `find_spendable`), so per-action reclamation is the
natural granularity and there is no intra-set FK-ordering hazard to preserve.
Being DB-only just makes the per-item work cheap — it does not make the pattern
wrong. Per-action transactions and reactor fairness then fall out of the pattern
for free instead of being bolted onto a special case.

(Batch-atomic recovery — chained parked actions under #192 — is a *different*
population with batch-as-unit semantics; it reuses `do_reject`'s existing graph
teardown keyed by batch, and is out of scope here. See Forward notes.)

## Pieces

### 1. `lib/bsv/wallet/engine/reaper.rb` (new logical model)

- `include Engine::OmqSupport` (for `bind_or_die`).
- `ENDPOINT = 'inproc://reaper.pull'`.
- `self.pending(store, limit:, threshold:)` — discovery: returns stale action IDs
  (delegates to `Store#stale_action_ids`).
- `#pull!(task:)` — binds the PULL socket in an async fiber, `while (msg =
  pull.receive)` → `process(msg.first.to_i)`. Mirror `Engine::Broadcast#pull!`.
- `#process(action_id)` — emit exactly one `task.dispatched` on entry, then
  exactly one terminal event:
  - `Store#reap_action` returns truthy (reaped) → `task.succeeded`.
  - returns falsey (no longer reapable — advanced since discovery) → `task.skipped`
    (reason `:not_reapable`).
  - raises → `task.failed` (first line of message).
  Single dispatched + single terminal is the drain contract; match
  `Engine::Broadcast#process`'s shape.

### 2. Store: split the bulk reaper into discovery + per-ID reclaim

Replace `Store#reap_stale_actions(threshold:)` (no production callers — only the
definition and the interface declaration) with two methods. Wholesale replace; do
not leave the bulk method as dead code.

- **`stale_action_ids(threshold:, limit:)`** — the SELECT half of today's
  predicate, returning IDs, bounded by `limit`:
  - `created_at < (Time.now - threshold)`
  - `broadcast_intent != 'none'`  *(kept — internal path is #327's concern)*
  - NOT `promotion_exists`  *(promoted actions are protected)*
  - **drop `wtxid IS NOT NULL`**  *(the #326 relaxation — this is what lets the
    reaper reach pre-sign abandoned actions)*
- **`reap_action(action_id:)`** — per-ID teardown in one `db.transaction`:
  1. **Re-validate inside the transaction.** The action may have advanced between
     discovery and processing (got signed, promoted, broadcast-accepted). Re-check
     the reapable predicate; if it no longer holds, return falsey (→ `task.skipped`).
     This is the per-ID analogue of the bulk method doing predicate + delete in one
     transaction.
  2. Clear dependents (RESTRICT-safe order, same as the bulk version):
     `OutputBasket`, `OutputDetail`, `OutputTag` (by output_id), `Output`,
     `Broadcast`.
  3. `Action.where(id:).delete` — cascades `inputs`, releasing the input locks.
  4. Return truthy.
  The teardown is the per-action slice of today's bulk logic; the ordering is the
  same shape as `do_reject`.

Update `interface/store.rb` to declare the two new methods, remove the old one.

### 3. `Scheduler#run!` — add the reaper loop

```ruby
schedule(task: task, name: 'reaper', endpoint: Engine::Reaper::ENDPOINT,
         interval: REAP_INTERVAL_S) do
  Engine::Reaper.pending(@store, limit: REAP_LIMIT, threshold: REAP_THRESHOLD_S)
end
```

Constants (Scheduler-level for now; candidates for `Config` later):
- `REAP_INTERVAL_S` — cleanup is not latency-sensitive; ~60s, well off the
  broadcast hot path.
- `REAP_LIMIT` — IDs per discovery pass (bounds in-flight reclaim; ~50). Same role
  as `broadcast_submission`'s `limit: 10`.
- `REAP_THRESHOLD_S` — staleness cutoff. **Load-bearing** — see below.

### 4. `Daemon#run!` — wire the consumer

- `require_relative 'engine/reaper'` at the top (with the other engine requires).
- Construct `reaper = Engine::Reaper.new(store: @store)` and call
  `reaper.pull!(task: task)`, alongside the broadcast/tx_proof wiring.
- `autoload :Reaper, 'bsv/wallet/engine/reaper'` in `engine.rb`.

## The threshold: lifecycle timing, not deferral coverage

Initial framing was that the threshold must exceed the longest legitimate
*deferred-sign* window (a crashed-pre-sign action and a deliberately-parked one
look identical in the DB — locked inputs, no `wtxid`). **Refined (Simon,
2026-06-18):** that's the wrong basis. The threshold should be predicated on how
quickly we expect **delayed_broadcast** to work — i.e. how long a normal action
legitimately takes to progress lock→sign in its lifecycle. Intentionally-parked
*deferred* actions will likely get their own **marker** to exclude them from the
reaper, rather than relying on a stretched threshold to protect them.

This is the same shape as the #192 batch exclusion: **markers exclude the
intentional; thresholds catch the abandoned.** Don't overload the threshold to
cover deliberate parking — that's a discriminator's job.

Decision for this PR: **`REAP_THRESHOLD_S = 1 hour`** (approved), configurable via
`Config` for tuning without a code change. When the deferred-action marker lands,
it becomes an additive predicate exclusion (no threshold stretch).

## Input-lock release

An input lock is a row in `inputs` (unique on `output_id`). `reap_action`'s
`Action.where(id:).delete` cascades the `inputs` rows away, which releases the
locks; the source UTXOs become selectable again via `find_spendable`. No new
release code — verify the exact spendable mechanism during implementation and
assert it in the spec.

## Testing (Postgres primary; SQLite augmentation)

- `Store#stale_action_ids`:
  - includes a pre-sign action (`wtxid IS NULL`) past threshold *(the #326 win)*;
  - excludes promoted, `broadcast_intent = 'none'`, and within-threshold actions;
  - respects `limit`.
- `Store#reap_action`:
  - tears down one action atomically (no leftover dependent rows);
  - **releases input locks** — the source outputs are selectable again *(Postgres
    spec — the lock-release path)*;
  - re-validates: skips (returns falsey, no delete) when the action advanced to
    promoted/accepted between discovery and call.
- `Engine::Reaper#process`: emits one `task.dispatched` + exactly one terminal;
  `:skipped` on not-reapable.
- `Scheduler`: schedules a reaper loop; discovered IDs are enqueued to the socket.
- Drain: the reaper participates in the in-flight counter (dispatched/terminal),
  so `shutdown` waits for an in-flight reap.

## Forward notes (not this PR)

- **#192 (noSend/sendWith batches):** parked actions reference each other, so the
  reaper-target population stops being all-leaves. When batches land, the predicate
  gains a "don't reap live batch members" exclusion (same shape as today's
  `broadcast_intent != 'none'`), and batch-atomic abort is a separate batch-keyed
  reclaimer reusing `do_reject`'s graph teardown. Additive; does not change this PR.
- **Next in the #324 track:** #327 (internal `no_send` backstop) and #328
  (promote atomicity) — the internal path. #327's fork (backstop vs fold
  sign→promote atomically) is settled there, not here.

## PR shape

One PR closing **#325 and #326** (interdependent). Conventional title e.g.
`feat(reaper): schedule Engine::Reaper and reclaim pre-sign locked inputs (#325, #326)`.
