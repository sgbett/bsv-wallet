# Systems Architect Review: Phase 2 refresh — Engine::Action re-classification (#290)

**Reviewer**: Dr. Elena Vasquez, Systems Architect
**Target**: Issue #290 comment "Phase 2 refresh — classification after #307 + #296 egress landed (2026-06-15)"; the extraction classification for the Engine refactor (umbrella #291)
**Date**: 2026-06-15
**Review Type**: Specialist Review (boundaries · interface stability · dependency direction · evolvability)

---

## Specialist Perspective

**Focus**: Whether the proposed collaborator decomposition draws boundaries that *serve evolution* — that dependencies point the right way, that interfaces stay stable as the four collaborators are extracted one at a time, and that the shapes chosen don't foreclose the chained-send subsystem (#192) the umbrella explicitly requires this refactor to keep open.

I am not assessing BRC-100 fidelity (domain expert), schema constraints (database architect), or Ruby idiom (Ruby expert). My single question for each boundary is: *does this seam compose under the next thing we already know is coming, without a parallel rewrite?*

---

## Executive Summary

This is a strong, well-grounded re-classification. Both corrections sharpen the design rather than complicate it: folding BEEF verification back to a one-line SDK adapter (Correction 1) is the *correct* application of ADR-018 and removes a collaborator that would have had no state of its own to own; carrying #60's inference removal into the BeefImporter extraction (Correction 2) is now structurally unblocked by ADR-023 and is genuinely cheaper to do during the move than after. The extraction sequence respects the real dependency edges (`Hydrator` before `BeefImporter`).

**Overall Assessment**: Good — Approve with changes.

**Key Findings**:
- Correction 1 is correct and load-bearing: verification is a stateless SDK operation (ADR-018), differing only by injected chain-tracker and wrapped error. A "verifier collaborator" would have been an empty boundary. Approve emphatically.
- The classification under-specifies the **dependency direction between `TxBuilder` and `ChangeGenerator`** and the **shared-helper ownership** (`build_input_specs`, `resolve_locking_script`, `wire_ancestor`). These are exactly the seams #192 will lean on; leaving them as "± inside or beside" risks a shape that composes for single-tx but not for batched flows.
- `wire_ancestor` is claimed by `Hydrator` (correct) but is *also consumed by* `hydrate_known_sources!` in `BeefImporter`. That cross-collaborator call must be declared as an interface, not left implicit — it is the one place the Phase 5→6 dependency edge is bidirectional in spirit.

**Critical Actions Required**: 0 critical; 3 medium (resolve before opening the Phase 3-6 sub-HLRs).

---

## Current Implementation

**Scope reviewed**: the classification table and two corrections in the #290 refresh comment, against the code being classified (`gem/bsv-wallet/lib/bsv/wallet/engine/action.rb`, 1,202 LOC) and the governing ADRs.

**Key components in the target code**:
- `Action.create` (`engine/action.rb:22-204`) — the 4-phase orchestrator; the workflow that must survive as a thin shell.
- `run_funding_loop` / `total_input_satoshis_for` (`:847-901`) — destined for `FundingStrategy`.
- `build_transaction` / `build_inputs` / `build_outputs` / `resolve_unlocking_script` / `find_caller_input` / `derive_signing_key` (`:658-830`) — destined for `TxBuilder`.
- `generate_change` (`:940-1040`) — destined for `ChangeGenerator`; **called from inside `run_funding_loop`** (`:856`).
- `build_atomic_beef` / `wire_ancestor` (`:598-646`) — destined for `Hydrator`.
- `parse_beef` / `hydrate_known_sources!` / `save_beef_proofs` / `replace_known_ancestors!` / `resolve_internalize_output` (`:1050-1198`) — destined for `BeefImporter`.
- `validate_for_handoff!` / `verify_incoming_transaction!` (`:574-590`, `:1093-1099`) — the two ~6-line adapters Correction 1 folds.

**Pattern**: per-call collaborators reached via an `engine` back-reference, no instance state beyond the wrapped row (the `Engine::Broadcast` / `Engine::TxProof` pattern, declared at `:14-16`). The refresh extends this pattern to five more collaborators.

---

## Assessment

### Strengths

1. **Correction 1 is the right boundary call, and it is the ADR-018 test applied correctly.** Verification needs no state of its own — `Transaction::Tx#verify` is the stateless SDK operation, the chain-tracker is the wallet's injected state (ADR-018; ADR-015 egress). A "BeefVerifier" collaborator would have been a class wrapping one SDK call, parameterised by which tracker to pass — i.e. an empty boundary that adds an indirection without owning anything. Folding `verify_incoming_transaction!` (`:1093`) and `validate_for_handoff!` (`:574`) into one `verify_beef(tx, chain_tracker:, error:)` helper is a de-dup, not a phase. This is exactly the kind of *not* drawing a boundary that good decomposition requires. Removing a collaborator from the plan is a stronger result than adding one.

2. **The extraction sequence honours the real dependency edges.** `FundingStrategy` first (biggest mass, validates direction), `Hydrator` before `BeefImporter` (because `BeefImporter` consumes `Hydrator`'s chain-walking), `BRC100` module split last (cosmetic until the delegators are clean). This is dependency-direction-aware sequencing, not arbitrary ordering — the same reasoning #291 records for deferring Phase 7.

3. **Correction 2 lifts inference removal to the right moment.** ADR-023 made promotion a row with schema-enforced authorisation; `resolve_internalize_output` (`:1175`) and `build_output_specs` (`:343`) still *infer* `output_type` from field shape (`:354`, `:1194`). Removing that inference *during* the BeefImporter extraction — rather than relocating the guess and cleaning it up in a later pass — is correct: the move is the cheapest point to state `output_type` explicitly, and ADR-023's `promotions`-row backstop means the schema now catches a wrong guess that previously only application code policed. The seam and the cleanup land together.

4. **The shells that stay on `Action` are the right ones.** `self.create` / `self.internalize` as thin shells over collaborators, plus lookups and the lifecycle verbs (`sign!`, `abort!`, `apply_spends`) — this leaves `Action` reading as a workflow over named collaborators, which is the umbrella's stated goal (#291 Phase 2). The classification resists the temptation to extract the orchestration itself.

### Concerns

1. **`TxBuilder` / `ChangeGenerator` dependency direction is left unresolved, and it is the seam #192 will load.** (Severity: Medium)
   - **Issue**: The table lists `TxBuilder (± ChangeGenerator)` and `ChangeGenerator` as separate destinations, but `generate_change` (`:940`) is invoked *inside* `run_funding_loop` (`:856`), which is going to `FundingStrategy`. So the live call graph is `FundingStrategy → ChangeGenerator → build_inputs/build_outputs (TxBuilder)`. `generate_change` itself re-derives inputs and re-builds outputs (`:948-984`) — it overlaps `build_transaction` substantially. The classification does not say which way the `TxBuilder`/`ChangeGenerator` dependency points, nor whether `FundingStrategy` depends on both or only `ChangeGenerator`.
   - **Location**: `engine/action.rb:847-895` (loop), `:940-1040` (change), `:810-830` (build_transaction), `:658-732` (build helpers).
   - **Impact**: #192 (chained send) composes Actions into atomic groups, which means the funding/build/change triad runs per-leg under a batch coordinator. If `ChangeGenerator` ends up *inside* `TxBuilder` (the "±" left open) but `FundingStrategy` calls `generate_change` directly, the batch coordinator inherits a three-way knot rather than a clean `FundingStrategy(ChangeGenerator(TxBuilder))` stack. Get the direction wrong and #192 does parallel architecture — the exact failure mode #291 warns against.
   - **Fix**: The Phase 2 ADR must state the dependency direction explicitly: `TxBuilder` is the leaf (pure assembly + script resolution, no funding knowledge); `ChangeGenerator` depends on `TxBuilder` (it builds a tx to compute fee); `FundingStrategy` depends on `ChangeGenerator` (drives it to convergence). Resolve the `build_transaction`/`generate_change` overlap at the same time — they should share `TxBuilder`'s assembly, not duplicate it. Make `ChangeGenerator` a distinct collaborator, not folded into `TxBuilder`, precisely so the dependency arrow is visible and #192's batch coordinator can target it.
   - **Effort**: Small (a paragraph + a call-graph sketch in the Phase 2 ADR; the code follows in Phases 3-4).

2. **Shared class helpers have no declared owner, so the extraction will scatter them.** (Severity: Medium)
   - **Issue**: `build_input_specs` (`:327`), `build_output_specs` (`:343`), and `resolve_locking_script` (`:384`) are class methods used by *both* the create path and the internalize path; `resolve_unlocking_script` (`:738`) duplicates `resolve_locking_script`'s logic. The table assigns `build_input_specs` / `build_output_specs` / `resolve_locking_script` to `TxBuilder` but they are also called by `Action.create`'s shell (`:83`, `:112`, `:156`) and by `promote_with_outputs` (`:541`, which stays on `Action`) and by `resolve_internalize_output`'s consumers in `BeefImporter`.
   - **Location**: `engine/action.rb:327-390`, `:541`, `:738-744`.
   - **Impact**: If these land on `TxBuilder`, then `Action` (shell) and `BeefImporter` both reach into `TxBuilder` for spec translation — a dependency from the orchestrator and the import collaborator into the build collaborator that is *not* part of the build pipeline. That is an interface leak: `TxBuilder`'s public surface grows class-method spec-translators that have nothing to do with assembly. Interface instability across the very phases that are supposed to stabilise it.
   - **Fix**: Treat spec-translation (`build_input_specs`, `build_output_specs`) as a separate, stateless concern — either a small `Action::Specs` module or kept on `Action` as the shell's own translation layer (the shell owns the BRC-100→Store spec mapping; collaborators consume already-translated specs). Collapse `resolve_unlocking_script` and `resolve_locking_script` into one `resolve_script` on `TxBuilder` (they differ only in name). Decide this in Phase 2, not ad hoc during Phase 4.
   - **Effort**: Small.

3. **The `wire_ancestor` cross-collaborator dependency (Phase 5 → Phase 6) must be an explicit interface.** (Severity: Medium)
   - **Issue**: `wire_ancestor` (`:624`) is correctly assigned to `Hydrator`, but `hydrate_known_sources!` (`:1077`) — assigned to `BeefImporter` — *calls* `wire_ancestor` (`:1081`), and `build_atomic_beef` (`Hydrator`) also calls it (`:606`). The umbrella already states "BeefImporter consumes Hydrator for the incoming side" (#291 Phase 6), but the refresh table lists `hydrate_known_sources!` flatly under `BeefImporter` without noting it crosses into `Hydrator`.
   - **Location**: `engine/action.rb:624-646` (`wire_ancestor`), `:1077-1083` (`hydrate_known_sources!` calling it), `:598-612` (`build_atomic_beef` calling it).
   - **Impact**: This is the one edge where the Phase 5/6 boundary is load-bearing at runtime. If `wire_ancestor` stays a private method, `BeefImporter` cannot call it without `send` (the very `engine.send(:private_method)` smell already pervading this file — see `:58`, `:60`, `:496`). Left implicit, the extraction either re-privatises and reaches with `send`, or copies the method — both erode the boundary the refactor is buying.
   - **Fix**: In the Phase 2 ADR, declare `Hydrator#wire_ancestor(wtxid)` (or a narrower `Hydrator#ancestry_for`) as a *public* collaborator interface that `BeefImporter` depends on. This makes the Phase 5-before-Phase 6 ordering a true compile-time dependency, not a sequencing convenience. Note it in the table.
   - **Effort**: Small.

4. **The pervasive `engine.send(:private)` pattern is the latent boundary debt this refactor should retire, but the classification is silent on it.** (Severity: Low)
   - **Issue**: `Action` reaches into `Engine`'s privates throughout — `require_key_deriver!` (`:58`), `determine_broadcast` (`:60`), `enforce_limp_mode!` (`:61`), `select_inputs` (`:85`), `publish_beef_hint` (`:183`). Extracting five collaborators *multiplies* the back-references unless the Engine surface they each need is defined.
   - **Location**: `engine/action.rb` passim (`:58`, `:60`, `:61`, `:75`, `:85`, `:183`, `:496`, `:720`, `:870`).
   - **Impact**: Each collaborator that reaches `engine.send(:select_inputs)` couples to Engine's *implementation*, not its interface. Five collaborators × N private reaches = a refactor that improves Action's readability while degrading Engine's encapsulation. Dependency direction stays correct (collaborators → Engine) but the interface is undeclared, so it is unstable by construction.
   - **Fix**: For each collaborator, the Phase 2 ADR should list the Engine surface it requires and make those methods *public* (or inject the narrow dependency directly — e.g. `FundingStrategy.new(pool:, store:)` rather than reaching `engine.utxo_pool`). This is the dependency-injection discipline that makes the collaborators testable in isolation and keeps #192's coordinator able to compose them. Not blocking, but flag it now so it is designed, not discovered.
   - **Effort**: Medium (spans all extraction phases; the design decision is Small).

### Non-concerns (checked, found sound)

- **#192 return-path shape**: `Action.create` already returns three distinct shapes (`signable_transaction` deferred `:120`, `no_send` `:191`, broadcast `:203`); `sign!` returns `{txid:, tx:}` (`:444`). None of the proposed collaborators sit on the *return* path — they feed the shell, which assembles the response. The classification correctly keeps response assembly on `Action`, so #192's chained-send return path (which will add a batch-level envelope) is unobstructed. Good.
- **Inline-equals-delayed (#271)**: the broadcast dispatch (`broadcast_worker.process`, `:201`, `:442`) stays on the shell, untouched by the extraction. The parameterised-by-mode style #291 wants preserved is preserved. Good.
- **Sequencing**: `FundingStrategy` first is defensible (mass + direction validation) even though `Hydrator`→`BeefImporter` is the only hard edge. No objection.

---

## Recommendations

**Immediate (fold into the Phase 2 ADR before any sub-HLR opens)**:
1. State the `FundingStrategy → ChangeGenerator → TxBuilder` dependency direction explicitly; make `ChangeGenerator` a distinct collaborator (not folded), and resolve the `build_transaction`/`generate_change` assembly overlap to share `TxBuilder` rather than duplicate it. (Concern 1)
2. Assign spec-translation (`build_input_specs`/`build_output_specs`) and script-resolution (`resolve_locking_script`/`resolve_unlocking_script`, collapsed to one) to declared owners — not scattered onto `TxBuilder`'s public surface as incidental class methods. (Concern 2)
3. Declare `Hydrator#wire_ancestor` (or `#ancestry_for`) as a public interface `BeefImporter` depends on; record the edge in the table. (Concern 3)

**Short term (during Phases 3-6)**:
4. For each extracted collaborator, define the narrow Engine surface it needs and either make those methods public or inject the dependency directly — retire the `engine.send(:private)` reaches rather than multiplying them. (Concern 4)
5. Adopt Correction 1 as written: one `verify_beef(tx, chain_tracker:, error:)` helper, no verification collaborator.

**Long term (toward #192)**:
6. When the Phase 3-6 collaborators land, validate each against a written #192 sketch: `Engine::Batch` composing N `Action`s, each running `FundingStrategy → ChangeGenerator → TxBuilder → Hydrator`. If any collaborator's interface forces the batch coordinator to reach past it (e.g. to re-derive change across legs), the boundary is wrong — revisit before #192 starts, not during.

---

## References

- Issue #290 (Phase 2 refresh comment), #291 (umbrella roadmap), #192 (chained-send return path), #213 (lock-retry), #60 (inference removal), #296 (BEEF chain integrity), #307 (promotion-as-a-row).
- ADR-015 (egress-BEEF validation) — the verification adapters folded by Correction 1.
- ADR-018 (stateless-SDK / stateful-wallet boundary) — the test that makes "verification is the SDK's" correct.
- ADR-019 (broadcasts-intent declarative enforcement), ADR-022 (state as a FK row), ADR-023 (promotion-as-a-row) — the backstop that unblocks Correction 2.
- `gem/bsv-wallet/lib/bsv/wallet/engine/action.rb` — the code classified.
