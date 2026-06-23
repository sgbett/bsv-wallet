# schema.md re-sync to promotion-as-a-row (#378)

Closes HLR #378. Follow-up to PR #320 (#307 / ADR-023) — the migration, store code, and models all reflect promotion-as-a-row, but `docs/reference/schema.md` still describes the pre-#307 `outputs.promoted` flag throughout. This plan brings the doc back in line with the merged code.

## Context

- **PR #320** (merged 2026-06-15) implemented ADR-023: dropped `outputs.promoted`, added `promotions` table with composite-FK gating to `actions(id, broadcast_intent)` and `broadcasts(action_id, tx_status) ON UPDATE CASCADE`, plus `spendable.action_id → promotions(action_id) ON DELETE CASCADE` as the structural authorisation gate.
- **Migration 003** also added `prevent_internal_action_delete` BEFORE DELETE trigger as defence-in-depth for internal-path canonical UTXO history (mirrors `Store#reject_action`'s `CannotRejectInternalActionError`). Not in the original ADR-023 design; added during implementation. Worth documenting.
- **schema.md** was partially updated for #189 (the `outputs.action_id` RESTRICT FK is correctly documented), but the `promoted`-flag mental model survives in ~15 places.
- **Section placement (user decision):** new §7 Promotions between §6 Outputs and §7 Spendable. Renumber downstream §8–§18 → §9–§19. Accepted: reference docs prioritise correctness over diff size.
- **Principle 4 reframing (user agreed):** "outputs are write-once during their canonical lifetime; cleanup deletions only touch never-promoted rows during atomic action tear-down."
- **Ruby model blocks (user agreed):** update inline so they match `action.rb`, `output.rb`, `spendable.rb`, `promotion.rb`.

## Reality (verified against code)

### Schema (migrations 001 + 002 + 003)

- `outputs` table: no `promoted` column. `action_id NOT NULL ON DELETE RESTRICT`.
- `promotions(action_id PK → actions ON DELETE CASCADE, intent broadcast_intent NOT NULL, authorising_status tx_status NULL)`. CHECK `promo_path` enforces internal/send disjunction; CHECK `auth_not_rejected` admits any status except REJECTED / DOUBLE_SPEND_ATTEMPTED. Composite FK `(action_id, intent) → actions(id, broadcast_intent)`. Composite FK `(action_id, authorising_status) → broadcasts(action_id, tx_status) ON UPDATE CASCADE`.
- `spendable(id, output_id UNIQUE, action_id NOT NULL)`. Two FKs on `action_id`: `→ actions(id) ON DELETE CASCADE` (denormalised-cascade pattern) and `→ promotions(action_id) ON DELETE CASCADE` (structural authorisation gate).
- `broadcasts UNIQUE(action_id, tx_status)` — FK target for promotions composite FK.
- Triggers: `prevent_outbound_spendable` (already documented), `prevent_internal_action_delete` (new, undocumented).

### Code (store.rb, action.rb)

- `Action#derived_status` keys off `Promotion.where(action_id: id).any?` (action.rb:43).
- `promote_action_outputs`: insert promotions row + insert spendable rows; idempotent (store.rb:187–206).
- `promote_action` (internal path): insert promotions row with `authorising_status: NULL` (store.rb:150-ish).
- `abort_action`: raises `CannotAbortPromotedActionError` if a promotions row exists (store.rb:223).
- `do_reject`: recursive child-first teardown; raises `CannotRejectInternalActionError` for `broadcast_intent='none'`; raises `CannotRejectAcceptedActionError` for ARC-accepted statuses; deletes promotions row before broadcasts row (FK ordering critical, store.rb:945–951).

## Documents touched

1. `docs/reference/schema.md` — primary target.
2. After landing, grep `docs/reference/` for stray `promoted` refs (state-boundaries.md, principle-of-state.md) — out of scope here, raise as follow-up if any.

## Edit list (with line refs into the current schema.md)

### Top-of-file

1. **Principle 4** (line 8) — reframe to "outputs are write-once during their canonical lifetime; cleanup deletions only touch never-promoted rows during atomic action tear-down".
2. **Principle 5** (line 9) — unchanged (spendable description already accurate).

### §3 Actions

3. **derived_status table** (138–148) — replace `outputs with promoted = true` row with `promotions row exists`. Confirm all 7 BRC-100 status symbols still derivable (`:unsigned`, `:completed`, `:internal`, `:unproven`, `:failed`, `:sending`, `:unprocessed`).
4. **Ruby `derived_status` block** (158–170) — match `action.rb:37`: `return :unproven if BSV::Wallet::Store::Models::Promotion.where(action_id: id).any?`.

### §4 Broadcasts

5. **Constraints list** (198–205) — add `UNIQUE (action_id, tx_status)` with rationale (FK target for promotions composite FK; ON UPDATE CASCADE keeps `promotions.authorising_status` synced; a flip to REJECTED requires deleting the promotions row first or the cascade hits `auth_not_rejected`).

### Action Lifecycle

6. **Phase 2 SQL** (255–273) — drop `promoted = false` from INSERT INTO outputs. Update prose about post-Phase 2 state.
7. **Phase 3 prose** (290–301) — replace "idempotent via the promoted flag" with "idempotent via the promotions row".
8. **Phase 4 SQL** (303–340) — replace `UPDATE outputs SET promoted = true` with `INSERT INTO promotions (action_id, intent, authorising_status)`. Then `INSERT INTO spendable` (note the FK gate now requires the promotions row to exist first). Update internal-path narrative — `Store#promote_action` inserts a promotions row with `authorising_status NULL` in the same transaction as Phase 1+2.
9. **Broadcast Failure SQL** (342–362) — replace with: DELETE promotions FIRST (cascades spendable via structural FK), DELETE broadcasts, DELETE actions (CASCADE inputs). Document why the ordering matters (the promotions composite FK to broadcasts blocks the broadcasts delete otherwise).
10. **Reaper "Never sent"** (378–395) — drop the `promoted = false` comment. The cleanup still needs explicit deletes because of RESTRICT, but the rationale shifts to "no promotions row was ever recorded, so spendable is empty by construction".
11. **Internal-path reaper immunity** (411) — add reference to the `prevent_internal_action_delete` trigger as schema-level enforcement (beyond the application-level `CannotRejectInternalActionError`).
12. **abortAction** (432–451) — add the `CannotAbortPromotedActionError` guard. Update the SQL comments — no `promoted = false` reference.
13. **Deferred Signing — signAction** (453–504) — drop all `promoted = false` references. Semantic claim ("not in the UTXO set") stays — explain it as "no promotions row exists yet; the `spendable → promotions` FK structurally prevents any spendable row from existing".
14. **New subsection: reject_action / do_reject** (insert after Broadcast Failure or after Deferred Signing) — document the recursive forward-walk, the two guards (`CannotRejectInternalActionError`, `CannotRejectAcceptedActionError`), the visited-set idempotency, and the FK-ordered teardown sequence.

### §6 Outputs

15. **Column listing** (636) — remove `promoted` row.
16. **Immutability prose** (614–656) — rewrite around the new framing. Mention cleanup paths exist but only ever touch never-promoted rows.
17. **`promoted` column paragraph** (652) — delete entirely.
18. **Cascade note** (654) — keep RESTRICT explanation, drop the `promoted = false` caveat (the gating is now via the promotions row, not a column).
19. **Note paragraph** (656) — keep the column-ordering and no-`updated_at`/no-`basket_id`/no-`wtxid` notes; remove the "immutable apart from the `promoted` flip" wording.
20. **Ruby `Wallet::Output` model** (658–705) — review the `dataset_module` `spendable` query and `spendable?` helper. Currently the query uses the spendable-row-exists + no-input-claim test, which stays correct. Make sure no `promoted` reference is hiding.

### New §7 Promotions (insertion point: between current §6 Outputs and §7 Spendable)

21. Add the section. Cover:
    - Existence-as-state principle (ADR-022 / ADR-023).
    - Column listing.
    - Both CHECKs.
    - Both composite FKs and the `ON UPDATE CASCADE` consequence.
    - Optimistic-promotion semantics (`auth_not_rejected` set).
    - Mutable-target consequence — REJECTED flip requires promotions delete first; correct-by-construction.
    - Internal-path: `authorising_status NULL`, no broadcasts FK match (MATCH SIMPLE skip).
    - `ON DELETE CASCADE` from actions (and reverse: the FK target relationship for spendable).
    - Ruby `Wallet::Promotion` model.
    - Cross-references: ADR-022, ADR-023, #307, #221.

### §8 Spendable (was §7, renumbered)

22. **Column listing** (715–719) — note the action_id has TWO FKs (the second one to promotions).
23. **Cascade note** (724) — document both cascades. Cross-reference to `do_reject` ordering.
24. **Note paragraph** (728) — DELETE pattern includes "or via promotions cascade" addition.

### Sections §8 through §18

25. Mechanical bump §8–§18 → §9–§19. Update any internal cross-references that use numeric labels.

### Resolved Design Questions

26. **"Two lifecycles, one schema"** (1126) — replace "structural marker is the `promoted` flag" with "structural marker is the existence of a promotions row".
27. **"outputs.promoted carve-out"** (1127) — DELETE entirely.
28. **"outputs.action_id RESTRICT"** (1128) — keep, update rationale: cleanup only ever encounters never-promoted rows because spendable rows require a promotions row (FK gate); deleting the promotion deletes the spendable; deleting the action triggers the RESTRICT, forcing cleanup explicit.
29. **Add new entry: "Promotion as a row"** — point at ADR-023; note no trigger on the hot send path.

### BRC-100 Transaction Operations Reference

30. **signAction** (1136) — drop `promoted = false`, replace with "no promotions row yet".
31. **internalizeAction** (1140) — drop `promoted = true`, replace with "+ a promotions row, all in one transaction". Reference the `prevent_internal_action_delete` trigger as defence-in-depth.

## What I will NOT touch (unless I find drift while editing)

- Enum definitions (§Enums) — accurate.
- §1 Blocks, §2 Tx Proofs, §5 Baskets — unaffected.
- §10–§18 (renumbered §11–§19) — content stays except numeric refs.
- ADRs themselves — already correct; this is doc-sync only.
- Code under `gem/bsv-wallet/` — code is the canonical source for this resync; not in scope to change.

## Sequencing

Single editing pass over schema.md, working top-to-bottom so that the renumbering at §8+ happens once after the §7 insertion lands. Verify with `grep -c promoted docs/reference/schema.md` (target: 0). Then run `grep -rn promoted docs/reference/` to surface any other-file follow-ups.

## Acceptance (matches HLR #378)

- [ ] No `outputs.promoted` references anywhere in `docs/reference/schema.md`.
- [ ] New `## 7. Promotions` section matches migration 001 lines 324–381 (Postgres + SQLite both).
- [ ] derived_status keys off promotions row existence.
- [ ] All Phase SQL snippets reflect actual `store.rb` paths.
- [ ] Principle 4 reframed.
- [ ] Resolved Design Questions cleaned.
- [ ] `prevent_internal_action_delete` trigger documented.
- [ ] §7 Promotions and §8 Spendable Ruby models present and correct.

## After

Commit on the current branch (`docs/315-documentation-cleanup`) with a conventional-commit message referencing #378 and #307. Don't push or open a PR without confirmation.
