# Next Phase (DRAFT — PARKED): Manageable → Machined

> **Status:** First-draft skeleton, parked for a fresh session. Successor roadmap to #291 ("Monolith to Manageable", now complete bar the #290 wrap-up). Intended to reload context, not to ossify before the analysis/classification round runs. No umbrella HLR opened yet — see "Resuming".

## Premise

#291 made the Engine's components **visible** by extracting collaborators (FundingStrategy, TxBuilder, Hydrator, BeefImporter) and slicing the 28 BRC-100 methods into a mixin. "Machined" makes the boundaries between them **enforceable and composable** — the precondition for the two concrete consumers below. This is a behaviour-*changing* phase (unlike #291's mechanical moves); the spec suite pins the public BRC-100 surface as the safety net, and we stage mechanical-first to de-risk.

## Anchors (why now, not speculative)

- **#223 — expose the Engine over BRC-103 HTTP.** A genuine *second interface/transport*. BRC100 with JSON-like constructors + JSON-like responses means a thin HTTP wrapper can present endpoint-per-method, routing text/json straight to a method and back. This is the concrete payoff that justifies the interface/machinery split (answers the YAGNI objection: BRC-100 is no longer the *only* consumer).
- **#192 — restore the `noSend`/`sendWith` quadrants (batched/chained-send).** ADR-024: the composable unit is the whole Action/transaction; `Engine::Batch` composes Actions *over the same machinery primitives* rather than forking a parallel send path. The machinery this phase extracts is what makes that DRY instead of duplicated.

## Three-layer target

1. **Interface — `BSV::Wallet::BRC100`** (relocated sibling of Engine, `lib/bsv/wallet/brc100.rb`). The 28 spec methods. Translates BRC-100 in/out: JSON-like in → compose Engine primitives → JSON-like (hash) out in the shape BRC-100 specifies. *An* interface, currently the only one; #223 adds a second binding over the same object.
2. **Machinery — `Engine`** (+ collaborators). Interface-agnostic. Provides **modular building blocks** that BRC100 composes — NOT machinery expressed at BRC-100 granularity. The coordinator; it cannot provide itself.
3. **Implementation — `Action` + logical models + `Store`.** Row-level mutations; the logical model over the physical (Store) model.

## The resolved fork: BRC100 becomes a COMPOSITION, not a mixin

#364 made `Engine::BRC100` a **mixin** (`include`d; `self` *is* the engine). That was the correct *interim* — composition would have been circular then (`engine.create_action → @brc100.create_action → engine.@store`). It is **not** the end state: a mixin's `self` is the engine, so "use only primitives, never reach into internals, never touch storage" is **unenforceable** — `@store` is right there and no reviewer can point to a language-enforced boundary.

End state: **`BSV::Wallet::BRC100.new(engine)`** — a composition that delegates to **public** `engine.*` primitives. The boundary is then real and reviewable: BRC100 can only call what Engine chooses to expose. This becomes non-circular *once the machinery primitives exist* (`brc100.create_action → engine.build_action` is a clean one-way call), which is why it is the **last** stage. #223's HTTP layer constructs a `BRC100` over an engine per request/session — composition is exactly the shape it wants.

BRC100 discipline (enforced by composition):
- Accepts JSON-like constructors (HTTP-wrapper-friendly).
- Returns JSON-like responses (hash) in BRC-100 shape.
- Uses Engine primitives only; no reach into Engine internals; no knowledge of storage.

## Action overreach → give responsibilities back (the AC3 residue from #290 / #370)

Heuristics (from the notes):
- **`engine:` param followed by `engine.send(:<m>, …)` ⇒ `<m>` is the Engine's responsibility.** The *calling logic* moves out of Action into Engine. The five reach-backs enumerated on **#370**: `require_key_deriver!`, `determine_broadcast`, `enforce_limp_mode!`, `enforce_headroom_against!`, `publish_beef_hint`.
- **`engine.store.<m>` ⇒ stays in Action.** Action is the logical model; it legitimately needs the physical model, and Engine just provides the store.
- **Other components (`@engine.utxo_pool.release`, `engine.broadcast_worker.process`) ⇒ case-by-case.** Usually Engine; occasionally a *necessary* collaboration passed in. Judge for necessity, not opportunism.

Worked example — `engine.broadcast_worker.process(id) if broadcast == :inline` carries two responsibilities: the *decision* to broadcast inline, and the *call* to process it. Resolution: **both belong to Engine** (separation of concerns — Action should not know about broadcasting). Safety net: the schema design means a missed inline broadcast is picked up by the daemon, so handing this to Engine carries no correctness risk.

## `Engine::Policy` collaborator (Q3 resolved)

`enforce_limp_mode!` and `enforce_headroom_against!` are a coherent **guard/policy** concern. Pencil them into a new `Engine::Policy` collaborator: the Engine *upholds* policy (calls into it at the right lifecycle points) without *defining* the implementation details — consistent with how store / utxo_pool / the other collaborators already abstract their internals away from Engine.

## Staging (Q2 — approved, mechanical-first)

1. **Mechanical, behaviour-preserving.** Relocate the module to sibling `BSV::Wallet::BRC100` (`lib/bsv/wallet/brc100.rb`), still a mixin. An #364-style move; MRO/spec guard travels.
2. **The core.** Define the Engine machinery primitives (`build_action`, `broadcast_or_defer`, …). Push Action's `engine.send` overreach back into Engine — some calls *become* those primitives; the `enforce_*` guards go to `Engine::Policy`. Spec-guarded; behaviour-preserving where possible.
3. **Recompose.** Repoint BRC100's 28 methods onto the primitives and **convert mixin → composition** (`BRC100.new(engine)`), enforcing the no-internal-reach boundary. #223 (HTTP wrapper) and #192 (`Engine::Batch`) become buildable on top.

## Open questions for the fresh-session analysis/classification round

- The **primitive API surface**: exact set + signatures of `engine.build_action` / `broadcast_or_defer` / … — the granularity that is "modular building blocks", not "BRC-100 at one remove". This is the heart of the classification round (the "#290 for this phase").
- What **slim Action** looks like after the overreach returns (target was #290's 200–300 LOC logical model).
- How the **#223 HTTP wrapper** consumes `BRC100.new(engine)` (per-request vs per-session lifetime; error-code mapping — #223 already scopes some of this).
- Sequencing vs **#192**: precursor, concurrent, or merged. (#192 needs the machinery; likely machinery-first.)
- Whether `determine_broadcast` / `publish_beef_hint` are plain public Engine methods or join a collaborator.

## Carries forward / dependencies

- **#290 wrap-up** (AC1 #368, AC4 #369, AC3-enumeration #370) should close first — this phase executes the AC3 *migration* that #370 defers.
- **ADR-024** records the why (decomposition as the precondition for restoring deferred sends). A new ADR for "Machined" likely warranted once the primitive boundaries are decided.
- Source notes folded in from `tmp/manageable-machined.md` (transient; can be removed once this plan is the system of record).

## Resuming

Open an umbrella HLR ("[HLR] Manageable → Machined") + a Phase-2-style classification HLR (the primitive-API-surface decision), mirroring the #291/#290 structure. Then sequence the three stages as sub-HLRs.
