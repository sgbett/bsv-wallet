# Database Architect Review — Phase 2 Refresh (#290)

**Reviewer:** Dr. Lin Wei, Database Architect (`database_architect`)
**Target:** #290 comment *"Phase 2 refresh — classification after #307 + #296 egress landed (2026-06-15)"*
**Date:** 2026-06-15
**Scope:** the refreshed `Engine::Action` re-classification only — design, not code. Reviewed against `engine/action.rb`, `store.rb`, ADR-003/004/019/022/023.

## Perspective

The schema is the source of truth; the Store owns the ACID boundary (ADR-006). My only question of a refactor that *moves Ruby around* is whether it moves any **transaction boundary** with it. Extracting collaborators is free as long as each multi-write transition stays inside one `db.transaction` *in the Store* — the collaborators must remain orchestrators that call already-atomic Store methods, never assemblers of multi-statement DB work in Engine space.

## Assessment

The classification is sound from the schema's side, and Correction 2 is exactly right. The extraction as described does **not** move any transaction boundary, because there are none to move: every atomic transition already lives wholly inside a single Store method (`create_action`, `lock_inputs`, `sign_action`, `promote_action`, `save_proof`, `record_promotion`). The collaborators inherit the orchestrate-don't-assemble shape that `Action` already has. That is the good news and also the latent risk — see Concern 1.

`FundingStrategy` respects the structural-lock model correctly: `run_funding_loop` never inserts a lock itself; it calls `Store#lock_inputs`, which wraps `INSERT … ON CONFLICT (output_id) DO NOTHING` (`try_lock_input`, store.rb:929) in `db.transaction` and reports the locked count. The loop's `locked == top_up.size` check (action.rb:889) is the correct read of the structural lock: a short count means contention rolled the batch back. The lock model is in the schema (`UNIQUE(output_id)` on `inputs`, ADR-004(b)); the collaborator only reads its verdict. Good.

`BeefImporter`'s proof storage is the one place to watch (Concern 1), but per-call it is correct: `save_beef_proofs` calls `Store#save_proof` (its own transaction) per ancestor and `Store#link_proof` at the end. No proof write is assembled in Engine space.

## Strengths

- **Correction 2 leans on the schema, not application code — correct.** Promotion-authorisation now has a declarative backstop: the `promotions` composite FKs to `actions(id, broadcast_intent)` and `broadcasts(action_id, tx_status)`, plus `promo_path`/`auth_not_rejected` CHECKs (ADR-023), and `spendable.action_id → promotions` gates UTXO membership. Removing #60's `output_type` inference and stating type explicitly is *reducing* application-level guessing precisely because the schema now refuses an unauthorised promotion. This is the ADR-003 direction, not a regression. `record_promotion` (store.rb:960) reads `broadcast_intent` and inserts the row idempotently — the gate is the FK, the code serves it.
- **Verification correctly classified as SDK-delegated (Correction 1).** From the schema's lens this is neutral-positive: `verify` touches no Store write, so folding the two adapters into one helper moves no transaction boundary and adds no DB surface. `TrustedSelfChainTracker` is injected state, not stored state — no schema implication.
- **`FundingStrategy` keeps the lock in the schema.** Selection (`select_inputs` → `utxo_pool.select`, read-only) is cleanly separated from locking (`Store#lock_inputs`, atomic). The collaborator never owns a lock insert.

## Concerns

### 1. (Low–Medium) The extraction must not split a Store call out of an *implied* atomic sequence — and `internalize`/`create` are already a sequence of separate transactions

Neither `Action.create` nor `Action.internalize` wraps its Store calls in an outer transaction. `internalize` (action.rb:237-285) runs `create_action` → `sign_action` → `save_proof` → `save_beef_proofs` (N× `save_proof` + `link_proof`) → `promote_action` as **five-plus independent transactions**. A crash between any two leaves a partially-built incoming action (e.g. action row + signing artifacts committed, proofs or promotion absent).

This is a pre-existing property of the monolith, *not introduced by the extraction* — and it is arguably defensible under the principle of state (each committed step is itself a valid intermediate; the missing-proof case is exactly what the daemon's proof-acquisition task #167 and `save_beef_proofs`' subject-proof guard at action.rb:1133 are built to tolerate). **The refactor risk is regression by relocation:** once `BeefImporter` owns `save_beef_proofs`/`replace_known_ancestors!` and `Action` owns `create`/`promote`, the *sequencing contract* between them (save proofs BEFORE `replace_known_ancestors!`, after `verify`) becomes an inter-collaborator ordering dependency rather than a visible top-to-bottom method body. The comment at action.rb:252-264 documenting that ordering is load-bearing and must travel with the code.

**Fix:** (a) The Phase 6 HLR must carry the proof-save / txid-only-replace ordering as an explicit acceptance criterion, with the spec that proves it. (b) State as a non-goal that `BeefImporter` introduce any Engine-space `db.transaction` — if a future requirement needs `create_action`+`promote`+proof-save to be *one* atomic unit, that belongs as a new Store method (`Store#internalize_action(...)`), not as a transaction opened in a collaborator. Make the rule explicit in the ADR: **collaborators call atomic Store methods; they never open transactions.**

### 2. (Low) `FundingStrategy` absorbing `select_inputs` + lock-retry must keep selection (read) and locking (write) on opposite sides of the Store boundary

`select_inputs` currently lives on `Engine` (engine.rb:1067) and is pure-read via `utxo_pool.select`; the lock is `Store#lock_inputs`. The refresh folds both plus #213 lock-retry into `FundingStrategy`. The hazard is a future "optimisation" that reads candidates and locks them in one Engine-space loop holding an open transaction to reduce the contention window. That would pull lock-acquisition logic out of the Store. **Fix:** the Phase 3 HLR should state that #213 retry is *re-invocation of `Store#lock_inputs`* (each call its own transaction, ON CONFLICT resolving the race in the DB per ADR-004(b)), not a held-open Engine transaction. The current loop already does this correctly — pin it as the contract.

## Recommendations

1. Add to the Phase 6 (`BeefImporter`) HLR acceptance criteria: the `save_beef_proofs` → `replace_known_ancestors!` ordering (and the subject-proof merkle-path guard) is preserved and spec-covered; no `db.transaction` is opened in the collaborator.
2. Add one sentence to the Phase 2 design ADR establishing the invariant for *all* extracted collaborators: **a collaborator orchestrates atomic Store methods and never opens a transaction; any new multi-write atomic unit is a new Store method.** This is the single rule that makes the whole extraction safe from the schema's side.
3. Correction 2 is approved as written — proceed to remove the #60 inference and state `output_type` explicitly. Confirm the existing Postgres constraint spec (`store/constraints_spec.rb`) covers the `resolve_internalize_output` `output_type='root'` path after the inference is removed, so the schema, not the helper, is the thing asserted.

Net: the classification is schema-safe. Two low-severity guard-rails (no Engine-space transactions; preserve the proof-ordering contract) convert "safe today because nothing moves a boundary" into "safe by stated contract." Nothing here blocks opening the extraction HLRs.
