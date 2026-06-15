# Promotion as a row (#307)

Tracked as #307. Realises the principle in ADR-022 (state as a FK row). **Supersedes ADR-011 (post-broadcast promotion)** — the `promoted` UPDATE deviation disappears. ADR-011 (delete-unpromoted-outputs) still stands.

## Problem

`#307` conflated two things:
1. **Persisting `promoted`** — settled: it stays (the value is needed). The immutability worry was accepted as "not very detrimental" and the issue stopped there.
2. **A database constraint on it** — the real, unresolved defect. Promote-authorisation (`promoted ⟹ internal OR broadcast-accepted`) is enforced only in application code; per ADR-003 an invariant with no DB backstop is a defect. The obvious backstop is a trigger on the `promoted` UPDATE — on the hot send path, the ~10k tx/s ceiling (#221) it exists to protect.

## The validity rule (no maybes)

An action may be **promoted** iff:

| Action | broadcasts row | tx_status | Promoted valid? |
|---|---|---|---|
| internal (`broadcast_intent = 'none'`) | forbidden (ADR-019) | — | ✅ always |
| send | none | — | ❌ |
| send | exists | `REJECTED` / `DOUBLE_SPEND_ATTEMPTED` | ❌ |
| send | exists | anything else (incl. interim) | ✅ |

**Authorising set = optimistic = NOT-REJECTED.** Unchanged from today (`store.rb:669`). Promote as soon as ARC acks; `reject_action` compensates if it later flips. No behaviour change.

## Solution — promotion is a row, not a column

The #221 insight generalised: turn the predicate into row-existence so an FK enforces it, no trigger.

1. **Drop `outputs.promoted`.** `outputs` returns to pure INSERT-only — the HOT-tuple churn, the immutability caveat, the vacuum debt all go. "Is it promoted?" → `EXISTS(promotions WHERE action_id = …)`.
2. **`promotions` table** — existence = "this action's outputs are canonical". `promoted` is already per-action (every read/write is `action_id`-scoped; `promote_action_outputs` flips all of an action's outputs together — verified), so one row per action is lossless.
   ```
   promotions(
     action_id          bigint PRIMARY KEY REFERENCES actions(id) ON DELETE CASCADE,
     intent             broadcast_intent NOT NULL,
     authorising_status tx_status        NULL          -- NULL on the internal path
   )
   ```
3. **Gate `spendable` declaratively** — `spendable` already has `action_id`:
   `FOREIGN KEY (action_id) REFERENCES promotions(action_id) ON DELETE CASCADE`.
   A spendable row cannot exist without a promotions row. Reject/reorg = `DELETE FROM promotions` → cascades spendable out in one statement.
4. **Gate the promotions row itself** (the #221 composite-FK trick):
   - `CHECK promo_path`: `(intent = 'none' AND authorising_status IS NULL) OR (intent <> 'none' AND authorising_status IS NOT NULL)` — internal authorised by being internal; send must name a status.
   - `CHECK auth_not_rejected`: `authorising_status IS NULL OR authorising_status NOT IN ('REJECTED','DOUBLE_SPEND_ATTEMPTED')` — the optimistic set.
   - `FOREIGN KEY (action_id, intent) REFERENCES actions(id, broadcast_intent)` — intent tracks the action (as `broadcasts.intent` does).
   - `FOREIGN KEY (action_id, authorising_status) REFERENCES broadcasts(action_id, tx_status) ON UPDATE CASCADE` — a send promotion can only exist while a broadcasts row is in a non-rejected status. Needs `UNIQUE(action_id, tx_status)` on `broadcasts` (action_id is already unique, so trivially satisfiable).

   Net: `promotions` row exists ⟹ (internal) OR (broadcasts row currently non-rejected). Declarative, no trigger, on the hot path or anywhere.

### Mutable-target decision — ON UPDATE CASCADE
`broadcasts.tx_status` keeps advancing (RECEIVED→SEEN_ON_NETWORK→MINED). The FK references the live value, so `ON UPDATE CASCADE` keeps `authorising_status` synced — **single source of truth, no duplicated "accepted" latch.** Consequence: the only non-rejected→rejected exit forces teardown first — `reject_action` must `DELETE FROM promotions` before (or as) `tx_status` flips to REJECTED (it already tears down). Accepted as correct-by-construction.

## Code changes
- `promote_action_outputs` → **INSERT a promotions row** (`intent` + `authorising_status` = the broadcast's current tx_status) instead of flipping output flags; no-op if the row exists.
- Internal Phase 4 (`store.rb:147‑163`) → INSERT promotions (`intent='none'`, `authorising_status=NULL`) instead of writing `promoted: true`.
- `record_broadcast_result` (`:669`) → on non-rejected status, insert the promotions row (same optimistic guard).
- `reject_action`/`do_reject` → `DELETE FROM promotions` (cascade tears spendable out); drop the promoted-output reads.
- `abort_action` guard (`:214`) and reaper (`:798‑808`) → `EXISTS(promotions)` instead of `outputs.promoted`.
- `Action#derived_status` (`action.rb:46`) → promotions-EXISTS instead of `outputs.where(promoted: true)`.
- Output create helpers (`:948`, `:972`) → stop writing the `promoted` column.

## Migration (pre-production — edit migrations directly, wipe & re-migrate)
- Remove `outputs.promoted` (drop `005_outputs_promoted.rb`'s column add / fold into schema).
- Add the `promotions` table + the two composite FKs + two CHECKs.
- Add `UNIQUE(action_id, tx_status)` on `broadcasts` (FK target).
- Add the `spendable.action_id → promotions` FK.

## Specs
- `constraints_spec.rb` (Postgres): promotions CHECKs + both composite FKs reject the invalid rows in the table above; spendable→promotions cascade; reject deletes promotions and cascades spendable.
- Engine/store specs: derived status, abort, reaper, reject all green against the new structure.

## Verify before committing
- **Portability:** the conditional composite FK relies on NULL-skips-MATCH-SIMPLE (a NULL `authorising_status` skips the broadcasts FK). Holds on PG and SQLite in principle — confirm against the Sequel model wiring.
- **CASCADE + CHECK interaction on reject:** confirm the delete-first ordering in `reject_action` so a flip to REJECTED never cascades a CHECK violation.

## Deliverables, in order
1. Re-scope #307 to this (its body is stale).
2. Write the superseding ADR (realises ADR-022; supersedes ADR-011-promotion; ADR-011-delete stands).
3. Implement: migration → store → models/derived_status → specs.
4. Full spec + rubocop run (Postgres primary, SQLite augmentation).
