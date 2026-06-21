# ADR-026: Engine primitive surface — per-domain-operation granularity, thin wrappers admissible

## Status

Accepted. Tracked by #397 (Stage 2a of #396 Manageable → Machined).

**Decided:** 2026-06-19 (#397 classification round).

## Context

#291 made the Engine's collaborators visible by extraction (`FundingStrategy`, `TxBuilder`, `Hydrator`, `BeefImporter`). #396 ("Manageable → Machined") moves the next axis: the boundaries between Interface (BRC100), Machinery (Engine + collaborators), and Implementation (Action + Store) become enforceable and composable. Stage 3 of #396 converts the BRC100 mixin to a composition (`BSV::Wallet::BRC100.new(engine)`); the load-bearing pre-question is *what shape does Engine's public surface take so that BRC100 can talk to it without reaching into internals?*

Three concrete consumers anchor the question:

- **#223** — a BRC-103 HTTP wrapper that constructs a `BRC100` over an Engine per request and routes JSON-shaped calls through it.
- **#192** — `Engine::Batch` composing whole Actions over the same machinery (the deferred `noSend`/`sendWith` quadrants from ADR-024).
- **#385** — `Engine::Transmission` as a sibling domain to `Engine::Broadcast` over the shared Hydrator substrate.

Each consumes Engine primitives, not BRC-100 methods. The surface must be designed against all three, not against BRC100 alone — otherwise the second and third consumers force duplication or smuggle their concerns into BRC100 method bodies.

Classification (#397) walked the 28 BRC-100 methods + Action's 5 `engine.send(:_)` reach-backs from #370 to determine the surface's shape. Two findings drove the rule:

1. **Reach-backs name internals, not primitives.** All five collapsed to engine-internal homes (`Engine::Policy` for limp/headroom; `Engine#dispatch_broadcast` for hint + worker dispatch; precondition + intent-mapping folded into the primitives that need them). The Action overreach was always *into Engine internals*, not a signal of missing public surface.
2. **Most BRC-100 methods are thin wrappers around an indivisible domain op.** 24 of the 28 (crypto, pubkey, cert, store-read, auth, static) wrap one collaborator method. Pushing these through `engine.collaborator.<m>` calls from BRC100 would leak collaborator topology; coarser primitives would fuse independent verbs (`encrypt`/`decrypt` are *not* the same operation viewed from different angles).

## Decision Drivers

* **BRC100 must not know which collaborator owns what.** "Use only primitives, no internal reach" is the discipline Stage 3 needs to enforce structurally (mixin → composition). The surface either enables that or doesn't.
* **The surface must serve consumers other than BRC100** (HTTP wrapper, Engine::Batch, Transmission). Shaping it for BRC100 alone produces a vehicle that only one consumer fits.
* **Interface-layer vocabulary must not leak into Machinery.** BRC-100 names (`originator`, the hash-wrapped return shapes) belong at the interface; Engine speaks the wallet's own language.
* **Granularity sits between two traps.** Per-BRC100-method-with-a-different-name ("BRC-100 at one remove") buys nothing; per-lifecycle-step forces callers to orchestrate the workflow. Neither composes for #192 / #223 / #385.

## Decision

**Engine exposes a public primitive surface at per-domain-operation granularity. BRC100 (and every other consumer) calls into it exclusively — collaborators are never reached through BRC100.**

The shape, with corollaries:

1. **Per-domain-operation granularity.** Primitives are verbs at the granularity of `build_action`, `import_beef`, `transmit`, `broadcast_or_defer`. *Not* per-BRC100-method names where a method orchestrates a workflow (the workflow lives in the primitive). *Not* per-lifecycle-step (would force callers to sequence). Indivisible domain operations (`encrypt`, `get_public_key`, `list_outputs`) are themselves the natural granularity — a 1:1 primitive over `@key_deriver` or `@store` is *not* "BRC-100 at one remove"; it is the indivisible verb expressed once.
2. **Thin wrappers are admissible** for indivisible ops. The cost is 1–3 lines per wrapper; the value is (a) decision-1 consistency with no exceptions, (b) the consistent home for operation preconditions (`require_key_deriver!` per primitive that derives, not per BRC100 method), (c) a future seam for observability/audit/rate-limit applied at the primitive.
3. **External consumers reach Engine through its public primitive surface; not past it.** This is standard encapsulation, applied at the Engine subsystem boundary. BRC100 (today's external consumer), #223's HTTP wrapper, and any future consumer outside Engine call `engine.<primitive>` — they do not reach into Engine's collaborators (`engine.hydrator.<m>`, `engine.store.<m>`, etc.). Code *inside* the boundary — Engine's own methods, its collaborator instance variables, and modules co-located in the Engine namespace (`Engine::Policy`, `Engine::Broadcast`, future `Engine::Transmission`) — is the subsystem's implementation and moves freely. The rule is the boundary; whether a particular consumer happens to be BRC100 is incidental. The reason BRC100 features prominently in this ADR's prose is that BRC100 is the *first* consumer being subjected to the discipline as part of Stage 3's composition, not because the discipline is bespoke to it.
4. **`Engine::Policy` is strictly internal.** Limp-mode and headroom guards are not BRC100-visible primitives. BRC100 requests; Engine fulfils; Policy guards the fulfilment at the right sequence points.
5. **BRC100 returns hashes; Engine returns raw values.** Each primitive returns the simplest sufficient value (a `String`, an `Integer`, a `Hash` only when intrinsic to the operation), keyed by wallet vocabulary — never BRC-100 vocabulary. BRC100 wraps in spec shape at the interface layer. Read-side: `engine.get_public_key(...) → pubkey_hex` becomes BRC100's `{ public_key: pubkey_hex }`; `engine.encrypt(...) → ciphertext_bytes` becomes `{ ciphertext: ciphertext_bytes }`. Write-side: `engine.build_action(...) → { wtxid:, atomic_beef: }` becomes BRC100's `{ txid:, tx: }` — the `:txid` key is BRC-100 spec vocabulary carried at the interface; the value remains a wtxid binary until JSON serialisation dtxid-converts at the wire boundary. This keeps the primitive surface usable from non-BRC100 consumers without unwrapping ceremony.
6. **Operation invariants live on the operation; BRC-spec-shape validation stays at BRC100.** Two kinds of preconditions exist and they live in different places. *Operation invariants* — wallet configuration (`require_key_deriver!`), parameter-combination semantics (the no_send+deferred check, the sign_and_process+inputs check), state guards — raise from inside the primitive that needs them; BRC100 does not pre-check on the primitive's behalf, and non-BRC100 consumers cannot bypass them by calling Engine directly. *BRC-100 spec-shape validation* — does this input meet BRC-100's contract (description present, wtxid format conformant — 32-byte binary wire-order per the wallet convention, output shape valid) — stays at BRC100; it is part of the interface's job to enforce its own protocol contract. Engine doesn't know about BRC-100's input shape rules and shouldn't.
7. **`originator:` does not propagate into Engine.** It is BRC-100 vocabulary (the application asking the wallet to do something) without a meaningful equivalent in other consumers (Transmission has a counterparty; the daemon has no caller). If Engine ever needs a generic "caller context" for Policy or audit, it takes a generic name introduced at the point of need — not BRC-100's term adopted speculatively.

The full primitive surface ratified under this rule is recorded in the #397 classification table (28 public primitives: 4 thick write-side + 24 thin read-side, plus 2 internal — `Engine::Policy#guard_balance!`, `Engine#dispatch_broadcast`).

## Alternatives Considered

### A. BRC100 reaches collaborators directly (`engine.key_deriver.encrypt(...)`)

**Rejected.** It is the cheapest in line-count (no wrappers needed) but it pins BRC100 to the collaborator topology — every future re-shuffle of which collaborator owns what becomes a BRC100 edit. Stage 3's composition discipline ("BRC100 uses only what Engine chooses to expose") becomes unenforceable: the engine *did not choose to expose* the collaborator, and yet BRC100 reaches it.

### B. Coarser primitives that group BRC-100 methods

**Rejected.** A `engine.cryptographic_operation(op:, args:)` collapses 6 distinct verbs into method-dispatch-with-extra-steps. `encrypt` and `decrypt` are independent operations whose only commonality is the configuration substrate (`@key_deriver`). Grouping them produces a primitive that callers have to demultiplex anyway.

### C. Per-lifecycle-step granularity (`engine.create_action_step_1`, etc.)

**Rejected.** Forces every caller (BRC100, Batch, HTTP wrapper) to orchestrate the workflow. The workflow IS the primitive's responsibility; exposing its steps is "BRC-100 at one remove" in the literal sense the trap names — same shape, different name, no reduction in caller knowledge.

### D. Sub-namespace grouping (`engine.crypto.encrypt`)

**Rejected for now.** Tidier-reading, but introduces *some* attribute of Engine (`engine.crypto`) that is publicly callable — bending decision 2 in a way that's hard to police later. Flat surface accepted; if 28 methods on Engine becomes painful in practice, sub-namespacing is a non-breaking change deferred to that point.

## Consequences

### Positive

* **Stage 3's composition discipline becomes structurally enforceable.** External consumers calling only public engine primitives is verifiable by inspection — no `instance_variable_get`, no calls to private methods, no reach into `engine.<collaborator>`. Reviewable as a line in the diff, for BRC100 today and for every consumer added later.
* **#223's HTTP wrapper falls out cheaply.** `BRC100.new(engine)` per request; one endpoint per BRC100 method; primitive surface is JSON-friendly given the wrapper's binary↔base64 seam.
* **#192's `Engine::Batch` composes whole Actions over `build_action(no_send: true) → ... → flush(send_with:)`** without forking a parallel send path (the ADR-024 commitment).
* **#385's Transmission lives as a sibling Engine domain** over the shared Hydrator substrate; its primitives sit alongside `build_action` rather than being smuggled into a BRC100 method body.
* **Action sheds orchestration** — the 5 #370 reach-backs evaporate, the broadcast-dispatch tail moves to Engine, target LOC 200–300 (from 484).

### Negative

* **24 thin wrappers add line-count** Engine wouldn't have under alternative A. Each is 1–3 lines; the aggregate is real but small versus the alternatives' costs.
* **Engine's namespace widens** to ~28 public methods at the flat surface. Sub-namespace grouping is the relief valve if this proves painful (alternative D, deferred).

## Implementation notes

Stage 2 of #396 extracts the primitives by name; Stage 3 converts mixin → composition. The classification table (#397 deliverable) is the per-primitive specification Stage 2 builds against. Worked-example sketches (`createAction`, `internalizeAction`, `noSend`) live at `.claude/plans/20260619-stage-2a-classification.md`.

This ADR does not specify primitive implementations — only the granularity rule and the discipline that flows from it. The classification table specifies signatures + responsibilities; implementations follow during Stage 2.

**Stage 2 naming scaffold (history).** Stage 2 (#402) shipped Engine's 28 primitives under a `do_` prefix because BRC100 was a mixin and 26 of the 28 primitive names shared a method name with the BRC-100 spec — bare invocation from BRC100 method bodies would have recursed via MRO. Stage 3 (#405) reverted the prefix as the same commit that converted BRC100 from a mixin into a class composed over Engine: with BRC100 no longer in Engine's ancestry, the same name can live on both classes (one returning wallet vocab, one returning BRC-100 vocab) without collision. The destination this ADR specified — `Engine#sign_action`, `Engine#encrypt`, etc. — landed in #405 commit 4. The Stage 3 plan (`.claude/plans/20260620-stage-3-composition.md`) records the per-commit shape of the migration.
