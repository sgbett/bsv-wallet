# Pragmatic Enforcer review — Phase 2 refresh classification (#290)

**Reviewer:** Sam Oduya, Pragmatic Enforcer (`pragmatic_enforcer`)
**Target:** Issue #290 comment "Phase 2 refresh — classification after #307 + #296 egress landed (2026-06-15)"
**Source under review:** `gem/bsv-wallet/lib/bsv/wallet/engine/action.rb` (1,202 LOC), umbrella #291, ADR-015 (egress), ADR-018 (state boundary), ADR-019/022/023.
**Date:** 2026-06-15

---

## Perspective

I challenge every abstraction with one question: *do we need this collaborator today, or are we drawing a box for a future that may never arrive?* A 1,202-LOC `Action` is real pain — a reader is genuinely misled, and that is debt worth paying down. But the cure for over-largeness is not automatically five new classes. My job is to confirm each extracted box earns its keep against *code that exists now*, and to hunt for boxes that can collapse into one.

The refresh is design-only (no code), the target methods all exist and are messy, and the sequence is "biggest mass first, cosmetic split last." That is the right disposition. My scrutiny is therefore narrow: is the collaborator *count* honest, and is anything justified only by appeal to #192/#296 futures?

## Assessment

**The refresh is materially leaner than the original, and the direction is sound.** Correction 1 is exactly the kind of win I exist to find — it deletes a phantom collaborator by reading the actual code instead of the original table. I affirm it without reservation (evidence below) and I found one further collapse the refresh stops short of making. The 5-collaborator count is *defensible* but not *proven*: `ChangeGenerator`-as-separate-from-`TxBuilder` is the one box still drawn on speculation, and the refresh itself flags it as undecided ("± `ChangeGenerator`"). I would force that decision to "inside `TxBuilder`" now and let a future split earn its own extraction. Net recommendation: **proceed, with `ChangeGenerator` folded and one more adapter de-dup pulled forward.**

## Strengths

1. **Correction 1 is correct and verified, not asserted.** `validate_for_handoff!` (action.rb:574–590) and `verify_incoming_transaction!` (action.rb:1093–1099) are both ~6-line adapters whose entire body is `subject_tx.verify(chain_tracker: …)` wrapped in a `rescue VerificationError`. They differ in exactly two values: the tracker (`TrustedSelfChainTracker` vs `@engine.chain_tracker`) and the raised error class (`EgressBeefInvalidError` vs `InvalidBeefError`). ADR-015 and ADR-018 confirm verification *is* the SDK's stateless operation; the tracker is the wallet's injected state. A "Verifier" collaborator would wrap a one-line SDK delegation — pure ceremony. Deleting it is the most pragmatic move in the whole refresh. **Affirmed.**

2. **Design-only, biggest-mass-first.** FundingStrategy (`run_funding_loop` + `total_input_satoshis_for` + the `select_inputs`/lock-retry plumbing, action.rb:847–901) is the only Action-resident code with non-trivial state shape and the largest single block. Extracting it first validates the direction on real risk rather than on a safe stub. Correct ordering.

3. **BRC100 split is explicitly deferred as cosmetic until delegators are clean.** This is YAGNI applied to the team's own roadmap — it resists the urge to do the satisfying-looking split before it pays. Good discipline.

4. **Correction 2 removes inference rather than relocating it.** Carrying #60's engine-side half (state `output_type` explicitly; stop guessing from field shape in `resolve_internalize_output`, action.rb:1175–1198) deletes logic rather than moving it behind a new name. Removal beats relocation every time.

## Concerns

### C1 — `ChangeGenerator` as a separate collaborator is speculative today (severity: medium)

The refresh table lists `ChangeGenerator` owning a *single method*, `generate_change` (action.rb:940–1040), while the `TxBuilder` row is annotated "± `ChangeGenerator`" and Phase 4 says "inside or beside." That undecidedness is the tell. `generate_change` is one method, and it is not standalone transaction-agnostic logic: it builds inputs (`build_inputs`), builds outputs, attaches P2PKH templates, runs fee detection, distributes, shuffles, and signs — it *is* transaction assembly with change folded in. The only genuinely separable nugget is the BRC-42 change-key derivation block (lines 952–962), and that is ~10 lines that already delegate to `key_deriver.derive_public_key`.

A one-method, ~10-lines-of-own-logic collaborator is a box drawn for tidiness, not need. There is no second consumer of change generation, and #192 (chained send) is cited nowhere as requiring an independent `ChangeGenerator` seam.

**Fix:** Decide now — fold `generate_change` into `TxBuilder`. Drop `ChangeGenerator` from the collaborator count (5 → 4 named extractions). If a second consumer or a genuinely independent change *policy* emerges later, extract it then, against a real call site. Update #291 Phase 4 to "Extract TxBuilder (change generation included)."

### C2 — One more adapter collapse the refresh leaves on the table (severity: low)

Correction 1 folds the *two egress/ingress verify adapters* into one `verify_beef(tx, chain_tracker:, error:)` helper — good. But the same shape repeats a third time in spirit: `resolve_locking_script` (class method, action.rb:384–390) and `resolve_unlocking_script` (instance method, action.rb:738–744) are byte-for-byte identical except the class returns via `self.class` context — both do the exact same `ASCII_8BIT-or-non-hex ? from_binary : from_hex` branch on a `Script::Script`. When `TxBuilder` lands, these should collapse into one `resolve_script(data)` rather than be carried across as two methods.

**Fix:** Note this de-dup in the TxBuilder extraction sub-HLR's acceptance criteria, the same way Correction 1 notes the `verify_beef` de-dup. It is not a phase; it is a one-line collapse at extraction time.

### C3 — Hydrator-before-BeefImporter ordering imports #296's cache ambition prematurely (severity: low / watch-only)

The refresh keeps Hydrator (Phase 5) as a precondition for BeefImporter (Phase 6), inheriting #291's framing of Hydrator as a "monotonically enriching cross-fiber substrate … asynchronously optimised LRU." That is a *performance/concurrency* design (wtxid-keyed cache, LRU eviction, `proof_arrived` enrichment) riding into a *classification* refactor. The methods being extracted today — `build_atomic_beef` and `wire_ancestor` (action.rb:598–646) — are simple recursive ProofStore walks with no cache at all. 

This is not a Phase-2 defect (the cache redesign is explicitly #296's territory, with its own plan file), so I raise it only as a guard, not a blocker: **the Hydrator *extraction* (move `build_atomic_beef`/`wire_ancestor` to a class) and the Hydrator *cache redesign* are two different sizes of work.** If the extraction sub-HLR cannot be done without also landing the LRU substrate, scope has leaked. Keep the extraction a pure move; let the cache be its own follow-up with its own measured justification.

**Fix:** When the Hydrator sub-HLR is opened, state explicitly that it extracts the two existing methods unchanged; the wtxid-keyed LRU substrate is a separate, later, measurement-backed change. Do not let #296's endgame inflate a classification move.

## Recommendations

1. **Affirm Correction 1 as written.** Fold the two verify adapters into one `verify_beef` helper at BeefImporter-extraction time. It is a de-dup, not a phase — the issue says this correctly. (Verified against source.)
2. **Resolve the `± ChangeGenerator` ambiguity to "inside TxBuilder" now.** 4 named collaborators, not 5. Extract a separate `ChangeGenerator` only when a second consumer or an independent change *policy* gives it a job. Update #291 Phase 4 wording.
3. **Pull the `resolve_locking_script`/`resolve_unlocking_script` collapse into the TxBuilder sub-HLR's criteria** — same treatment as the verify de-dup.
4. **Keep the Hydrator extraction a pure move.** Bar the #296 LRU-substrate redesign from the classification sub-HLR; it gets its own measured follow-up.
5. **Hold the line on design-only.** The refresh respects this; the acceptance criteria in #290 already forbid code changes. Good.

## Verdict

The plan is *nearly* lean. Correction 1 is a model of the kind of collapse I want to see — read the code, find the abstraction that wraps a one-line delegation, delete it. The remaining slack is small: one speculative single-method collaborator (`ChangeGenerator`) that should fold into `TxBuilder` until a real consumer appears, one further adapter de-dup to schedule, and a watch on Hydrator's scope so a classification move doesn't smuggle in a performance redesign. With `ChangeGenerator` folded, the collaborator count drops to four — and every one of those four earns its rent against code that exists today. Proceed.
