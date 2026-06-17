# Engine::Action Re-classification — Record of the #291 Decomposition

> **Type:** Historical record of a refactor (AC1 of #290). **Not** a load-bearing design contract — durable principles live in `reference/` and `.architecture/decisions/`. This captures *what moved where* during the #291 "Monolith to Manageable" roadmap so the classification isn't lost once the work is merged. The *why* is **ADR-024**; the umbrella is **#291**; the design that scheduled this is **#290**.

## Context

#214 (Phase 1) moved everything `Engine#create_action` touched onto `Engine::Action` as a deliberate structural step — visibility first. The result was an oversized (~1,157 LOC) `Action` whose abstraction lied: methods like `build_atomic_beef` implied "an Action builds its own BEEF" while actually walking the ProofStore graph using nothing from the action row.

#290 (Phase 2) re-classified each method along one axis — **does it read action state, or does it just happen to run during action creation?** — and scheduled the redistribution. This document records the executed result.

## Classification table (as merged)

| Original (on `Engine`/`Action`) | Landed as | Collaborator | Extraction (PR) |
|---|---|---|---|
| `run_funding_loop` | `acquire` | `Engine::FundingStrategy` | #323 (PR #334) |
| `select_inputs` | `select_candidates` | `Engine::FundingStrategy` | #323 (PR #334) |
| lock-retry / `total_input_satoshis_for` | `lock_with_retry` / `lock_initial_inputs` | `Engine::FundingStrategy` | #323 (PR #334) |
| `build_transaction` | `build` | `Engine::TxBuilder` | #336 (PR #341) |
| `build_inputs`, `build_outputs` | (same) | `Engine::TxBuilder` | #336 (PR #341) |
| `resolve_locking_script`, `resolve_unlocking_script` | folded / `resolve_unlocking_script` | `Engine::TxBuilder` | #336 (PR #341) |
| `generate_change` + Benford distribution | `build_change` | `Engine::TxBuilder` (ChangeGenerator **folded in**) | #336 (PR #341) |
| `derive_signing_key` | (same) | `Engine::TxBuilder` | #336 (PR #341) |
| `apply_spends` (finalise-and-sign core) | `apply_spends` | `Engine::TxBuilder` | #336 (PR #341) |
| `build_atomic_beef`, `wire_ancestor` | (same) | `Engine::Hydrator` | #343 (PR #347) |
| `validate_for_handoff!` | (same) | `Engine::Hydrator` | #343 (PR #347) |
| `parse_beef`, `verify_incoming_transaction!` | (same) | `Engine::BeefImporter` | #357 (PR #361) |
| `hydrate_known_sources!`, `save_beef_proofs` | (same) | `Engine::BeefImporter` | #357 (PR #361) |
| `replace_known_ancestors!`, `resolve_internalize_output` | (same) | `Engine::BeefImporter` | #357 (PR #361) |
| the 28 BRC-100 spec methods | (same) | `Engine::BRC100` (mixin facade) | #364 (PR #367) |

## Resolved judgement calls

- **ChangeGenerator folded into TxBuilder** (not a separate collaborator). ADR-024: a chained-send link needs tx N's change placed → shuffled → signed *atomically* before N+1 can reference its outpoint; a separate collaborator would put a seam inside that finalisation. `build_change` is the fee-fixpoint body.
- **`derive_signing_key` → TxBuilder**, not a bare `KeyDeriver` call. TxBuilder owns signing, so it derives over its own injected `key_deriver`; this removed the last `require_key_deriver!` reach on the build path.
- **`apply_spends` → TxBuilder** (the #290 "Action or TxBuilder" judgement call). Its finalise-and-sign core is construction; `Action#apply_spends` became thin orchestration (load unsigned tx, resolve, validate vins, delegate).

## What stays on Action (the slim logical model)

The action's own row is its scope:

- **Factories:** `find`, `find_by_id`, `list`, and `create` (now orchestration over the collaborators, not a procedural body).
- **Lifecycle transitions:** `sign!`, `abort!`, `promote_with_outputs`.
- **Derived / query:** `query_change_outpoints`, status derivation (computed, never stored — principle-of-state).
- Action legitimately reaches the **physical model** via `engine.store.*` (logical model ↔ physical model). What it should *not* do is reach Engine's machinery via `engine.send(:…)` — that residue is enumerated in #370 and migrates in the next phase ("Manageable → Machined").

## Cross-references

- **ADR-024** — why the Engine had to be decomposed (precondition for restoring the deferred sends).
- **#291** — the umbrella roadmap; **#290** — the Phase-2 classification this records; **#371** — extraction follow-ups.
- The interface↔machinery separation this exposes (but does not perform) is the next phase: `.claude/plans/20260617-manageable-machined.md`.
