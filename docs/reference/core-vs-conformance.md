# Core wallet vs BRC-100 conformance

A load-bearing principle alongside [`principle-of-state.md`](principle-of-state.md) and [`state-boundaries.md`](state-boundaries.md). Where the principle of state defines *what* the wallet maintains (a schema-canonical database) and state-boundaries defines *where* statefulness can live (wallet, not SDK), this document defines *what concerns are part of the wallet at all*. It is the axis we apply to every BRC-100 concept that arrives at the wallet's boundary: is this part of being a Bitcoin wallet, or is this part of being a BRC-100 wallet-to-application interface?

The two answers carry different obligations.

## Statement

> **Core wallet** is the operations that make a single-key holder a Bitcoin participant: build, sign, broadcast, observe, account. **BRC-100 conformance** is the interface contract that lets external applications drive the wallet to do those things. The wallet implements both, but they sit on opposite sides of an internal boundary: the conformance layer adapts BRC-100 vocabulary onto core operations, the core never reaches outward into conformance vocabulary.

The wallet has been built — instinctively at first, then deliberately — by keeping these two responsibilities separable. Several BRC-100 concepts that look load-bearing in the spec turn out to be conformance concerns the core can live without. We have deferred or amputated them, and the core stays faster and simpler for it.

## Why the boundary matters

BRC-100 is titled "Wallet-to-**Application** Interface". Its design presupposes a particular operating model:

- A trusted wallet daemon serving multiple untrusted application clients.
- A human principal mediating permission grants per application.
- Each application identified by its FQDN (`originator`).
- Permission state (per-application access to baskets, protocols, certificates, spending limits) maintained by the wallet on the principal's behalf.

Most BSV wallets the spec was written for sit in this shape — desktop Metanet wallets, browser-extension wallets, mobile companion wallets. The wallet IS the security perimeter the principal trusts; applications come and go through that perimeter under principal-granted scopes.

Our wallet's deployment model is different:

- A library and (future) daemon serving exactly one consumer per instance.
- Identity is a construction parameter (the WIF), not a runtime authentication step.
- Access control is WIF-level: whoever has the key has the wallet.
- No permission UI, no per-origin sandboxing, no multi-tenant hosting.

In this model, much of the wallet-to-application interface vocabulary has no operational equivalent. There is no second tenant to defend against, no permission UI to prompt, no FQDN-scoped permission table to maintain. **Implementing the BRC-100 contract still requires accepting that vocabulary at the boundary** — the spec is the spec — **but it does not require internalising it into the wallet's data model or its operational hot paths.**

The core/conformance boundary is the rule that keeps the two separable. It is the principle that says: when a BRC-100 concept arrives at our interface, ask whether it is "what a Bitcoin wallet does" or "what a wallet-to-application interface does". The former goes into the core; the latter stays at the conformance layer (or, where structurally possible, is amputated entirely).

## Where the boundary sits

The wallet has a layered shape (see `docs/concepts/architecture.md`):

```
┌─────────────────────────────────────────────┐
│ Conformance      BSV::Wallet::BRC100        │  ← wraps Engine, speaks BRC-100 vocab
├─────────────────────────────────────────────┤
│ Core (machinery) BSV::Wallet::Engine        │  ← speaks wallet vocab, primitive surface
│                  Engine::* collaborators    │
├─────────────────────────────────────────────┤
│ Core (storage)   BSV::Wallet::Store         │  ← canonical schema, atomic transitions
│                  Sequel models              │
└─────────────────────────────────────────────┘
```

Code below the conformance layer **must not** speak BRC-100 vocabulary. The Engine has no `originator` parameter, no `seekPermission` flag, no notion of "applications". It has `build_action`, `encrypt`, `get_public_key` — verbs at the granularity of wallet operations, named in the wallet's own language. ADR-026 codified this for the Engine's primitive surface; this document generalises the principle behind it.

Code at or above the conformance layer **may** speak BRC-100 vocabulary, but is responsible for translating into core verbs before it reaches the Engine. The translation is one-way: Conformance → Core. The Core never asks Conformance for context.

## How this manifests

### Concepts implemented natively in the core

These are part of being a Bitcoin wallet. They live in the schema and the Engine, not at the conformance layer:

- **Transactions, inputs, outputs, broadcasts, proofs.** The Bitcoin substrate.
- **Action lifecycle.** Build → sign → broadcast → resolve. The 4-phase atomicity defended by the schema (`principle-of-state.md`).
- **UTXO selection, fees, change.** Funding mechanics (ADR-013).
- **Key derivation.** BRC-42/43 key derivation lives in the SDK, called by Engine collaborators. Identity-shaped pubkeys (hex) vs derived pubkeys (binary) per ADR-008.
- **BEEF construction, ancestry, SPV validation.** The wallet's relationship to the chain (ADR-015 pivot).

### Concepts accepted at the conformance boundary

These BRC-100 concepts arrive at the interface, are translated into wallet operations, and are not propagated inward:

- **`originator`** — accepted on every BRC-100 method, dropped at the boundary. See [`brc100-conformance.md`](brc100-conformance.md) and the originator ADR.
- **`seekPermission`** — accepted, no-op'd. We have no permission UI to seek from.
- **BRC-100 hash-vocabulary return shapes** — translated to/from the Engine's primitive return values at the wrap layer (`{ txid:, tx: }` ↔ `{ wtxid:, atomic_beef: }` etc.).
- **Spec-shape input validation** — BRC-100 shape rules (description length, basket name conformance, hex format) enforced at the conformance boundary, not in the Engine.

### Concepts amputated entirely

These BRC-100 concepts do not appear in our wallet at all, because they have no operational equivalent in our deployment model:

- **`users` table.** Single-tenant by construction. Identity is the WIF, not a row. (ADR-007.)
- **Per-originator permission state.** No permission UI, no per-app sandboxing. If implemented later, lives as a permissions overlay (likely admin-basket PushDrop tokens, mirroring wallet-toolbox DBAP). Does not become a column on data tables.
- **BRC-116 permission machinery.** Entire spec deferred. Stub at the conformance layer if needed; no machinery.
- **App discovery / manifest interaction.** Same.

### Concepts where we diverge from the spec's defaults

A small number of BRC-100 concepts we implement, but with semantics tuned to a single-tenant deployment:

- **Basket as user categorisation, not app sandbox.** The spec's "no basket = untracked" semantics were designed for a per-app permission model where untracked-means-orphaned-across-apps. We keep the spec contract (no basket → not surfaced by `listOutputs`) but, internally, all outputs are recorded; basket is a categorisation column, not a tenancy axis.

The full enumeration is the living register at [`brc100-conformance.md`](brc100-conformance.md).

## What this means for design decisions

When a new BRC-100 concern arrives — a new method, a new parameter, a new return shape — ask:

1. **Does this describe a Bitcoin operation, or an application-interface convention?**
   - Bitcoin operation → likely belongs in core. Engine grows a primitive; Store grows a column or table.
   - Application-interface convention → stays at the conformance layer. Engine does not learn about it.

2. **Does this presuppose multi-tenancy, permission UI, or app sandboxing?**
   - Yes → amputate or stub at the conformance layer. The mechanism it presupposes is absent in our model; reproducing it is dead weight.
   - No → translate at the conformance layer onto an existing or new core primitive.

3. **If we ever did support this concern, where would it live?**
   - In the core: it's a Bitcoin concern, build it now if needed.
   - At a permissions overlay above the core (admin-basket tokens, future `users` table, future per-DB credentials): defer. Don't denormalise the overlay's concerns into the core's data tables.

The decision filter is the same as the principle's statement: *is this what a Bitcoin wallet does, or is this what a wallet-to-application interface does?*

## Why this serves the throughput target

The core/conformance boundary isn't only a tidiness principle. It directly serves the scaling vision (ADR-002 — design for scale):

- **Per-row tenancy columns kill throughput.** Every index, every WHERE clause, every lock pays a cost. ADR-007 chose to drop `user_id`; this principle is the general rule that produced that specific decision.
- **Permission overlay tables kill throughput.** Every BRC-100 call hitting a `permissions(originator, basket)` join before reaching the Engine adds latency to the hot path. Deferring the overlay (and, when we add it, keeping it out of the data path) preserves the budget.
- **Conformance is millimetres thin.** When BRC-100 is a wrapper class translating vocabulary, not a layer that maintains state, the cost of conformance is one method call per request. The Engine speaks wallet vocab; the conformance layer is the only place that knows BRC-100 exists.

The throughput target (millions of tx/s — see ADR-002) is reachable because the core is *just* a Bitcoin wallet. Adding BRC-100-shaped state to the core — users, originators, permissions — would not break correctness, but it would foreclose the throughput goal.

## Tests for compliance

When designing or reviewing surface area, ask:

1. **Does the Engine method's signature contain BRC-100 vocabulary?** (`originator`, `seekPermission`, hash-vocabulary parameter names.) If yes, the boundary is leaking; the vocabulary belongs at the conformance layer.
2. **Does a Store table or column carry an "applications" or "originators" axis?** If yes, the permissions overlay has denormalised into the data model.
3. **Does a core operation behave differently depending on which application is calling?** If yes, conformance has reached into the core.
4. **Can the Engine be exercised without instantiating `BSV::Wallet::BRC100`?** If yes, the boundary is clean; if no, the core depends on its own wrapper.

A "yes" to 1–3 or a "no" to 4 is the principle leaking. Sometimes the leak is deliberate and worth the cost (rare); usually it isn't, and the right response is to move the concern outward to the conformance layer (or further out, into a permissions overlay that doesn't yet exist).

## What this leaves us free to do

By keeping the conformance layer paper-thin and the core BRC-100-naive:

- **Adding originator support** is additive: a permissions overlay above the core, an enforcement check at the conformance layer. Zero changes to Engine signatures, zero changes to Store columns.
- **Adding multi-user support** is additive: a central `users` database and per-user wallet databases (see the per-user-databases ADR), with the per-user database unchanged from its current shape. The wallet code that runs against a single database now is the same wallet code that runs against a per-user database in multi-user mode.
- **Adding BRC-116 permission machinery** is additive: an overlay, not a refactor.
- **Adding a new BRC-100 method** is additive: a wrap on the conformance class, translation onto Engine primitives or a new Engine primitive if no existing one fits.

None of these require disturbing the schema or the Engine's primitive surface. The core stays a Bitcoin wallet; conformance grows the new feature.

## Related

- [`principle-of-state.md`](principle-of-state.md) — *what* the wallet maintains (schema is canon).
- [`state-boundaries.md`](state-boundaries.md) — *where* statefulness lives (SDK vs wallet).
- [`brc100-conformance.md`](brc100-conformance.md) — living register: per BRC-100 concept, our stance (implemented / accepted-at-boundary / deferred / diverged).
- ADR (this branch) — the core-vs-conformance principle as a decision record.
- ADR-007 — single-tenant engine, no user table; first concrete application of this principle (retrospective).
- ADR-018 — stateless SDK / stateful wallet; companion structural boundary.
- ADR-021 — BRC-100 interface as a plain Ruby module; the conformance layer's shape.
- ADR-026 — Engine primitive surface; codified "Engine doesn't speak BRC-100" for the primitive layer.
- `docs/concepts/architecture.md` — the layered shape this principle constrains.
