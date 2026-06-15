# Specialist Review — Maintainability Expert

**Reviewer:** Aisha Rahman, Maintainability Expert (`maintainability_expert`)
**Target:** Issue #290, comment *"Phase 2 refresh — classification after #307 + #296 egress landed (2026-06-15)"*
**Scope:** The refreshed `Engine::Action` re-classification feeding the #291 Engine refactor. Design-only review from the maintainability lens.
**Date:** 2026-06-15

---

## Perspective

I read this as a newcomer would: can someone who has never seen this codebase open `engine/action.rb` after the split and understand the system as *a workflow over named collaborators*, rather than a procedural body wearing a class name? My test for every proposed boundary is "would a reader guess this method lives here?" and for the sequence, "could each step be reverted on its own if it turned out wrong?" Clarity over cleverness; the abstraction must not lie.

## Assessment

**Strong, and materially better than the original.** The refresh does the rare thing of *removing* a collaborator rather than adding one (Correction 1), and it grounds each move in a settled ADR rather than aspiration. The collaborator names are intuitive — `FundingStrategy`, `TxBuilder`, `ChangeGenerator`, `Hydrator`, `BeefImporter` each answer "what is this for?" before you read a line. The extraction *sequence* is the best part: biggest-mass-first to validate direction, protocol-layer siblings next, and the dependency-forced `Hydrator → BeefImporter` ordering is correct (BeefImporter genuinely consumes `wire_ancestor` via `hydrate_known_sources!`, confirmed at action.rb:1077–1082). BRC100-split-last is right — splitting it earlier yields a file of half-delegators-half-stubs, pure churn.

I verified the two load-bearing claims against the source. Both hold, with one caveat each below.

## Strengths

1. **Correction 1 is correct and is the highest-value call in the refresh.** `verify_incoming_transaction!` (action.rb:1093–1099) and `validate_for_handoff!` (action.rb:574–590) are both thin shells over `tx.verify(chain_tracker:)`, differing only in the injected tracker (`@engine.chain_tracker` vs `TrustedSelfChainTracker.new`) and the wrapped error class (`InvalidBeefError` vs `EgressBeefInvalidError`). Refusing to manufacture a "verification collaborator" out of two adapters is exactly the discipline this phase needs — a newcomer reading a `Verifier` class would expect verification logic *inside it* and find only delegation. A shared `verify_beef` helper tells the truth.

2. **The "what stays on Action" set now reads as a coherent slice.** Factories + lifecycle transitions (`sign!`, `abort!`) + lookups + BRC-100 shape. That is a legible model: "the action's own row is its scope." After extraction, `self.create` becoming an orchestration body over `engine.funding` / `engine.tx_builder` is the legibility payoff the whole roadmap is chasing.

3. **Correction 2 is principled, not cosmetic.** Tying #60 inference removal to #307/ADR-023 (promotion-as-a-row, now schema-enforced) means the removal *can* state `output_type` explicitly instead of guessing — verified against ADR-023 (promotions row + composite-FK authorisation). Removing inference here genuinely simplifies: it replaces "guess ownership from field shape" with a declared fact the schema already backs.

## Concerns

### C1 — "Fold into one `verify_beef` helper" understates the egress preamble (severity: low)

The refresh says the two adapters "differ only in" tracker and error class. Read literally, that implies a clean 3-line fold. But `validate_for_handoff!` (action.rb:574–583) does work the incoming path does *not*: it parses the BEEF binary (`Beef.from_binary`), locates the subject entry, and raises a distinct `EgressBeefInvalidError` *before* it ever reaches `verify`. Only the tail (lines 583–589) is the shared adapter.

**Why it matters for maintainability:** if the extraction HLR takes "fold into one helper" at face value, it will either (a) push the parse/locate preamble into the helper and make it not-actually-shared, or (b) leave a subtly asymmetric pair and call it deduped. Either way the next reader inherits a "shared" helper that two callers use differently.

**Fix:** state the shared surface precisely in the extraction HLR — `verify_beef(tx, chain_tracker:, error:)` covers the `verify`-and-rewrap tail only; the egress-side parse + subject-locate is `Hydrator`/`BeefImporter` preamble, not part of the shared helper. One sentence in the sub-HLR prevents the misread.

### C2 — #60 inference removal is scoped to one of two inference sites (severity: medium)

The refresh names `resolve_internalize_output` (action.rb:1175–1198) as carrying #60's engine-side half. But the table routes that method to `BeefImporter`, and its inference (line 1194, `output_type = 'root' unless derivation_prefix`) is *already* explicitly disclaimed in the code as "a protocol-level decision, not inference from field absence."

The genuinely inference-shaped site is elsewhere: `self.build_output_specs` (action.rb:354) — `out[:output_type] || (out[:derivation_prefix] ? nil : 'outbound')` — which the table routes to **`TxBuilder`**, not `BeefImporter`. That is the line that "guesses from field shape" to satisfy the NULL-type-requires-derivation constraint. The refresh's #60 paragraph points at the already-honest site and is silent on the inference-shaped one, which lands in a *different* collaborator (Phase 4, not Phase 6).

**Why it matters:** a reader following the refresh will remove inference from `BeefImporter` (Phase 6) and believe #60 is discharged, while the `outbound` inference rides along into `TxBuilder` (Phase 4) untouched and unmentioned. The intent gets hidden, not removed — the exact failure mode the original #290 problem statement warns about ("the abstraction now lies").

**Fix:** the design doc should enumerate *both* inference sites, assign each to its collaborator (`build_output_specs` → TxBuilder/Phase 4; `resolve_internalize_output` → BeefImporter/Phase 6), and state for each whether #60 removal applies or whether the comment already certifies it as a protocol decision. Otherwise the #60 acceptance criterion is ambiguous about what "done" means.

### C3 — `apply_spends` "stays on Action" but its body is mostly outbound protocol (severity: low)

`apply_spends` (action.rb:470–531) is in the stays-on-Action set, yet it calls `derive_signing_key` (→ slated for KeyDeriver/TxBuilder) and `resolve_unlocking_script` (→ TxBuilder), and InputSource-attaches resolved inputs. After Phases 3–4 land, `apply_spends` will be a stay-resident method reaching into two departed collaborators. The original #290 flagged this exact method as "judgement call." The refresh inherits the original verdict without re-stating the judgement.

**Why it matters:** "what stays on Action" is the slice that must read cleanly *forever*; one method that reaches across three collaborators erodes that. It is a real call to make, not a default.

**Fix:** the design doc should make the `apply_spends` decision explicit (stay, with the protocol helpers injected back via the collaborators it now calls — or move the script-resolution body to TxBuilder and leave a thin lifecycle shell). Document the reasoning so the next reader doesn't re-litigate it.

## Recommendations

1. **Adopt the refresh's structure and sequence as-is** — direction, naming, and ordering are sound and I would not reshape them.
2. **Resolve C2 before opening the extraction sub-HLRs.** Enumerate both `output_type` inference sites in the design doc and bind each to a collaborator + a #60 verdict. This is the one concern that can silently leave the original problem unfixed.
3. **Tighten the C1 wording in the eventual `verify_beef` sub-HLR** — name the shared tail vs the egress preamble so "one shared helper" isn't taken too literally.
4. **Record the `apply_spends` judgement (C3) in the design artifact**, not just the table cell, so the stays-on-Action slice stays coherent under reading.

Net: a clarifying, debt-reducing refresh. C2 is the only item I would gate the sub-HLRs on; C1 and C3 are precision notes for the design doc.
