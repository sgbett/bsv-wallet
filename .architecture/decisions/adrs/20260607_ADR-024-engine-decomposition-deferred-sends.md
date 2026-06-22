# ADR-024: Decompose the Engine — the precondition for restoring the deferred sends

## Status

Accepted. Tracked by #291 (umbrella); sequenced by #290 (classification).

**Decided:** 2026-06-07 (#291 "Monolith to Manageable"; the direction began with #214, 2026-05-31).

## Context

This ADR records *why this particular monolith must be decomposed* — not the truism that monoliths should be refactored. The reasoning is specific and load-bearing, and it begins with a deliberate amputation.

BRC-100's send surface is a 2×2 of `noSend` × `sendWith`: plain immediate send, batched submit (`sendWith`), chained-send (`noSend`/`noSendChange`), and both together. **HLR #183 chopped three of those four quadrants**, keeping only plain immediate send, and **#197 locked the strict four-phase lifecycle** (Lock → Sign → Broadcast → Promote) that the simplification bought. The cut was the right call: prior attempts to support chained-send — whose premise is that outputs are referenceable *before* broadcast — had repeatedly caused architectural drift against a wallet whose strength is the immutable outputs log promoted only after acceptance.

Crucially, the cut purchased a **structural** win, not merely less code: phases 1–3 were cleanly separated from phase 4, so **one robust code path handles both inline and delayed broadcast** (the `broadcast_intent` enum: `inline` / `delayed` / `none`). That inline-equals-delayed robustness is the asset the eventual restoration (#192) must not erode.

But the *orchestration* of the (now-cut) sends was never cleanly separable, because it lives tangled inside a procedural `Engine` — 2,333 LOC, reduced to ~1,400 only once #214 gathered `create_action`'s machinery onto an (oversized) `Engine::Action`. Two consequences follow:

1. **You cannot see the components while it is one mass.** As the #214 work put it: when the lifecycle code was sprinkled through 2,333 LOC you could not see "this is all `create_action`'s machinery as a coherent thing" — and the misclassifications only became obvious *after* gathering it in one place.
2. **The abstractions lie.** `Action#build_atomic_beef` implies an action builds its own BEEF; it actually walks the ProofStore ancestry graph using nothing from the action row. Names that mislead are a symptom of responsibilities that have not been named.

#192 will bring the cut quadrants back. The question this ADR settles is *what must happen first*.

## Decision Drivers

* **Restoration must not reintroduce the drift #183 reverted.** The four-phase invariants and the inline-equals-delayed path are load-bearing; bringing back batching/chained-send must preserve them.
* **You cannot classify or extract what you cannot see.** Visibility of the component boundaries is a prerequisite for any clean restoration.
* **Restoring on top of the monolith forces duplication.** Without extracted collaborators, the cut sends come back as a *parallel* implementation rather than a composition — the opposite of DRY.
* **Batching and chained-send are orthogonal.** `sendWith` ("submit N signed actions atomically") and `noSend`/`noSendChange` ("let action N+1 spend action N's change before it is on-chain") are independent capabilities that BRC-100's ABI happens to fuse into one option struct. The decomposition must serve both as composition, not special-case each.

## Decision

**Decompose the `Engine` into focused collaborators (#291), as the structural precondition for restoring the deferred BRC-100 sends (#192) without eroding four-phase robustness.**

* The collaborators (`FundingStrategy`, `TxBuilder`, `Hydrator`, `BeefImporter`, and the `BRC100` module) are identified and sequenced by #290's classification. Each extraction preserves the four-phase invariants (#183/#197) and the single inline-equals-delayed code path.
* **Refactor toward composition, not toward a parallel send path.** The composable unit is the whole Action/transaction. When #192 lands it is a new `Engine::Batch` collaborator **composing Actions over the same collaborators** — reading a built transaction's change outputs to thread a chain — not a second orchestrator duplicating the first. (Worked example: `ChangeGenerator` is *folded into* `TxBuilder` rather than split out, because a chain link needs tx N's change placed → shuffled → signed atomically before N+1 can reference its outpoint; a separate collaborator would put a seam inside that finalisation.)

This is the test for every extraction: does it make the restoration of the cut sends a *composition* of existing collaborators? If an extraction's shape works for a single transaction but would force #192 into parallel architecture, it is the wrong shape.

## Alternatives Considered

### A. Restore #192 now, on top of the monolith
Bring back `noSend`/`sendWith` before decomposing.
**Rejected** — there are no component boundaries to compose against, so the chained-send/batch orchestration comes back as a parallel implementation tangled into the same procedural mass. This is the drift #183 reverted; doing it again would forfeit the four-phase robustness the cut was made to secure.

### B. Leave the Engine monolithic
Accept the 1,400-LOC orchestrator and layer #192 on later.
**Rejected** — the boundaries stay invisible (you cannot extract what you cannot see), the misleading abstractions persist, and #192 is structurally forced to duplicate rather than compose.

### C. Refactor generically, without the #192-composition lens
Decompose "because monoliths are bad," choosing boundaries on aesthetic grounds.
**Rejected** — risks extracting shapes that work for single-tx flows but break under batching (#291's "refactored in the wrong direction" failure). The restoration target (`Engine::Batch` composing whole Actions) is what disciplines the boundaries; without it, a plausible-looking split (e.g. a standalone `ChangeGenerator`) fractures the per-transaction finalisation a chain depends on.

## Consequences

### Positive
* The components become visible, named, and independently testable; the abstractions stop lying.
* #192's restoration becomes a composition (`Engine::Batch` over the collaborators), preserving the inline-equals-delayed robustness rather than re-litigating it.
* The decomposition is disciplined by a concrete downstream capability, so each boundary has a falsifiable test (does it compose for batched flows?).

### Negative / trade-offs
* **The intermediate state is briefly worse than the monolith.** The oversized `Engine::Action` (post-#214) is harder to reason about than the original procedural body until the extractions land. The named risk is Phase 2 (#290) ossifying into "someday," leaving the wallet stuck in the worse intermediate. The accepted mitigation is committed follow-through on the sequenced extraction HLRs — not an architectural safeguard but a scheduling one.
* The refactor touches the hot path; every extraction must hold the four-phase invariants and the round-trip budget (see #290's acceptance criteria).

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

The refactor earns its place not as generic monolith-cleanup but as the precondition for a specific deferred capability (#192) that would otherwise arrive as duplication. The two real risks are over-decomposition and mid-way stall: the first is held in check by the composition lens (which positively *removed* a collaborator — `ChangeGenerator` folded), the second by #290's sequenced HLRs and the explicit acknowledgement that the intermediate state is worse. The decision is justified, and the justification is specific to this Engine, this cut, and this restoration. **Approve.**

## Validation

* #290 produces the classification + the ordered extraction sub-HLRs; each preserves the four-phase invariants (#183/#197) and the single inline/delayed broadcast path.
* When #192 lands, the wallet is "same Action + same collaborators + a new `Engine::Batch` composing Actions into atomic groups" (#291) — not a parallel send path. That is the success test for this decision.

## References

* #291 — "Monolith to Manageable" (the refactor roadmap this ADR justifies).
* #290 — Phase 2 re-classification (the collaborator boundaries + sequence).
* #214 — `Engine::Action` skeleton (gathered the machinery; made the boundaries visible).
* #183 / #197 — the cut of three send quadrants and the locking of the strict four-phase lifecycle.
* #192 — the deferred `noSend` / `sendWith` chained-send and batching subsystem (the restoration this refactor enables).
* ADR-011 — post-broadcast promotion; the four-phase lifecycle the cut secured.
* ADR-018 — stateless SDK / stateful wallet; the boundary the collaborators respect.
* `.architecture/reviews/20260619_noSend-sendWith-design-notes.md` — the design analysis for the cut; `docs/reference/state-boundaries.md`.

## Implementation evolution

**#405 (Stage 3 of #396).** This ADR refers to "the `BRC100` module" (line 35) — accurate at write time, when BRC100 was a `module` included into Engine as a mixin facade (#364 Phase 7 of #291). #405 promoted it from `module` to `class` composed over an engine instance (`BSV::Wallet::BRC100.new(engine)`; reached via `Engine#brc100`). The extraction sequence + four-phase invariants this ADR records are unchanged; only BRC100's runtime shape evolved. See ADR-026 + HLR #405 for the composition rationale.
