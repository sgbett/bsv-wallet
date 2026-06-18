# Internal-completion atomicity (#327 + #328 + #362)

Part of the #324 crash-recovery & atomicity umbrella. The synchronous internal
(`no_send` / incoming-BEEF) completion paths write across several separate Store
transactions, so a crash mid-sequence strands an action: signed but never
promoted (#327), or promoted with unspendable change (#328), or — for
internalize — created+signed with no promotions row (#362). All three are the
same class of gap, and the fix is the principle-of-state one: **collapse the
sequence into a single transaction so the intermediate state can't exist** (not
a recovery backstop).

## Walk-through outcome

Only **two** non-atomic internal-completion paths exist (verified by enumerating
every caller of the promote operations):

1. **`createAction(no_send: true)`** — `Engine::Action.create`'s synchronous
   branch: `sign_action` → `promote` → `promote_change_to_spendable`, each its
   own transaction. Carries both #327 (sign→promote) and #328 (promote→change).
2. **`internalize`** — `BeefImporter#import` (the `internalizeAction` ingress):
   `create → sign → save_proof → save_beef_proofs → promote`, unwrapped (#362).

Not in scope, for the record:
- `import_utxo` Phase 1 is **already** wrapped in `@store.db.transaction` — the
  model to copy, not a gap.
- The `wbikd` locking action is *aborted*, never promoted — no completion gap.

The decisive enabling fact: **neither path makes a network call between the
writes that must be atomic** (`no_send` = no broadcast; internalize already has
the verified BEEF in hand). All CPU / read-only work moves outside the
transaction — validation before the writes, BEEF build/validate after the
commit.

## Approach — (b) for Path A, (a) for Path B

The two paths get *different* hosts for the transaction, and that's correct, not
inconsistent — their atomic units genuinely differ.

### Path A — Store-owned (b)

New `Store#complete_internal_action(action_id:, wtxid:, raw_tx:, sign_outputs:,
change_outputs:, promote_outputs:)` composes the existing per-step methods in one
`@db.transaction` (their own transaction blocks flatten into it — the same Sequel
mechanism `import_utxo` Phase 1 already relies on). The atomic unit is pure Store
operations, so atomicity belongs in Store.

`Engine::Action.create`'s `no_send` branch becomes one call; the read-only
`build_atomic_beef` + `validate_for_handoff!` move after the commit (shared by
both branches); the now-dead `promote_with_outputs` instance method is removed.

### Path B — importer-owned (a)

`BeefImporter#import` hoists output resolution/validation *before* any write
(with a non-Array shape guard — #362's cheap secondary), then wraps
`create → sign → save_proof → attach_labels → save_beef_proofs → promote` in one
`@store.db.transaction`.

**Why (a) here, not (b):** `save_beef_proofs` is irreducibly BEEF-domain logic
(walks `beef.transactions`, resolves each entry's merkle path from
`beef.bumps[bump_index]`, skips `TxidOnlyEntry`) — it cannot move into Store, and
it is directly tested + referenced as contractual in `Interface::BeefImporter`.
The atomic unit therefore interleaves importer logic with persistence; it is not
a pure-Store operation. Forcing it into a Store method would mean a pre-extracted
plain-data payload whose *only* benefit is moving the `db.transaction` keyword —
for the cost of deleting a tested/contractual method. So the importer owns the
boundary here, exactly as `import_utxo` already does.

## Proof (not just assertion)

- `complete_internal_action`: stub `promote_action` to raise mid-transition →
  the action ends up **unsigned** (full rollback). Plus a happy-path commit.
- `internalize`: bad outputs → `InvalidParameterError` with **no action
  created** (validation runs pre-persistence); `promote_action` raising
  mid-ingress → **no dangling action** (wrapper rolls back create+sign). Without
  the wrapper these are exactly the stranded artefacts #362/#327 describe.

## Validation

Postgres 1145/0, SQLite 1145/0, RuboCop clean. Net Engine code is *simpler* (the
`no_send` branch shrank; a dead method removed).

## PR shape

One PR closing **#327, #328, #362**. Plan committed first, then implementation.
Title e.g. `feat(engine): atomic internal-action completion (#327, #328, #362)`.
