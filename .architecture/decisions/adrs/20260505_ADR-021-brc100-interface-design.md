# ADR-021: BRC-100 interface as a plain Ruby module over the schema

## Status

Accepted.

**Decided:** 2026-05-05 (commit `7049f27`, PR #35 — "feat!: align to SDK's canonical BRC-100 interface and error classes (#28)") — the interface as a plain Ruby module owned by the SDK and `include`d by the Engine, realising the design recorded here. The Engine's BRC-100 realisation first appeared at the initial scaffolding (`b355dc8`, 2026-04-30); the later pubkey-hex carve-out doc (PR #303/#300, 2026-06-11) refines ADR-008, not this interface design.

## Context

BRC-100 defines a wallet-to-application interface: 28 methods spanning transaction creation, signing, encryption, certificates, key linkage, and chain queries (`docs/reference/external/BRC100.md`). The wallet must present that interface. The question is what shape it takes in Ruby.

The specification is written against a TypeScript reference, where the interface arrives as a type system — interfaces, type aliases, and the class hierarchy that carries them. Ruby is not statically typed, and the rebuild is clean-room from the spec, not a port (ADR-001). So the spec's *behaviour* is the requirement; the spec's *encoding* in another language's type system is not. A second question rides alongside: several BRC-100 methods describe long-running work (broadcast, proof acquisition, authentication waits), and the spec's reference models some of it asynchronously. Whether that asynchrony belongs *in the interface* or *underneath it* shapes every signature.

## Decision Drivers

* **Idiomatic Ruby, designed from the spec.** Ruby expresses an abstract contract as a module of methods with keyword arguments and hash returns. There is no need to reconstruct a foreign type system to satisfy a behavioural specification.
* **The schema is canon; the interface is presentation (ADR-003).** BRC-100 is the RPC skin over the canonical database. It orchestrates the components that read and write the schema; it is not itself a source of truth. This is the Layer-3 role in the SOA (`docs/design.md`).
* **Asynchrony is an infrastructure property, not a method property (ADR-018).** Stateful, clock-spanning work belongs to the wallet's runtime (the daemon), not to the interface contract. A method that returns a value is simpler to reason about and to test than one that returns a promise.
* **One conversion edge (ADR-008).** Hex ↔ binary conversion happens at this boundary and nowhere inside it, so the interface is where the spec's hex strings meet the wallet's internal binary.

## Decision

The BRC-100 interface is a **plain Ruby module** — `BSV::Wallet::Interface::BRC100`, defined in the SDK (`bsv-sdk ~> 0.24`) and consumed by the wallet. It declares the 28 abstract methods, each with keyword-argument signatures and documented hash returns; an unimplemented method raises `NotImplementedError`. There is no ported type hierarchy, no replicated type aliases, no struct-per-message layer — the contract is the method set, and Ruby's keyword arguments carry the parameter shape the spec documents.

`BSV::Wallet::Engine` realises the interface by `include BSV::Wallet::Interface::BRC100`. The Engine is **Layer 3 — BRC-100 business process orchestration**: it receives the Layer-2a components (Store, UTXOPool, services, key deriver, chain tracker) at construction and composes them to fulfil each method. It holds no SQL, no ARC calls, and no thread management — it orchestrates the canonical-state machinery beneath it, consistent with ADR-003 (schema is canon, BRC-100 is the presentation layer).

**The methods are synchronous.** Each returns its result hash directly (e.g. `get_public_key` returns `{ public_key: … }`; `create_action` returns `{ txid:, tx: }`, a deferred `{ signable_transaction: … }`, or the internal-path variant). The Engine itself contains no reactor, fibre, or thread. Asynchrony is an infrastructure concern owned by the daemon (`BSV::Wallet::Daemon` hosts the Async reactor); a synchronous BRC-100 call may *enqueue* clock-spanning work (a broadcast for the daemon to push), but the call itself completes and returns. This is the ADR-018 boundary applied to the interface: synchronous methods, async as runtime.

**Conversion lives at this boundary.** Per ADR-008, the interface is where hex strings (the spec's wire form for scripts, txids, and identity-shaped public keys) meet the wallet's internal binary. `get_public_key` with `identity_key: true` returns hex (the identity-pubkey carve-out); derived public keys return binary.

The current method names are snake_case Ruby renderings of the spec's camelCase identifiers — `create_action` for `createAction`, `internalize_action` for `internalizeAction`, `get_public_key` for `getPublicKey`, with the chain-query methods carrying their `get_` prefixes (`get_height`, `get_header_for_height`, `get_network`, `get_version`) and the authentication predicate as `authenticated?`. The full set is the 28 methods listed in the SDK module.

**Namespace ownership.** The SDK owns the BRC-100 contract module and the BRC-100 error classes; the wallet owns its internal contracts (`Interface::Store`, `Interface::UTXOPool`), the Engine, and the key deriver. A planned refinement (fixing calling conventions and finalising names as the SDK settles) is recorded in HLR/issue terms and is **not** asserted here as complete — this ADR records the interface *design*, and the names above are what the code carries today.

**Architectural components affected:** `BSV::Wallet::Engine` (the realisation); the SDK's `Interface::BRC100` (the contract); the daemon (owns the asynchrony the interface deliberately excludes); the conversion edge (ADR-008).

## Alternatives Considered

### A. Port the reference's type system (interfaces, type aliases, message structs)
Reconstruct the spec's TypeScript types as Ruby structs / `Data` classes, one per request and response shape.
**Pros:** mirrors the published interface one-to-one; a reader who knows the reference finds the same names.
**Cons:** rebuilds a static type layer Ruby does not need or check at runtime; the structs duplicate what keyword arguments and documented hashes already express; it imports the encoding of a different language rather than designing from the spec (ADR-001, clean-room).
**Rejected** — the spec's *behaviour* is the requirement; its encoding in another language's type system is not. A plain module with keyword arguments carries the same contract idiomatically.

### B. Asynchronous interface methods (promise/awaitable returns)
Make the long-running methods (`create_action` on the send path, proof acquisition, `wait_for_authentication`) return futures, baking concurrency into the contract.
**Pros:** surfaces the long-running nature in the signature; matches an async reference model.
**Cons:** pushes a runtime concern into the contract, so every consumer and every test inherits the reactor; couples the interface to one concurrency strategy; contradicts the stateless/synchronous-method, async-as-infrastructure boundary (ADR-018).
**Rejected** — asynchrony is the daemon's concern. The interface stays synchronous; a method may enqueue work for the reactor, but the contract returns a value.

### C. Interface as its own state-holding layer
Let the interface own caches or session state beside the database.
**Pros:** could memoise across calls.
**Cons:** the database is the canonical source of truth (ADR-003); a second state holder beside it is exactly the drift the schema-as-canon principle forbids. The interface is presentation, not a store.
**Rejected** — the interface orchestrates canonical state; it does not hold state beside it.

## Consequences

### Positive

* The contract is one readable module of method signatures — no type layer to maintain in parallel with the implementation, and idiomatic to any Ruby reader.
* Synchronous methods are straightforward to call and to test: a method returns its result; no reactor is required to exercise the interface in a unit spec.
* The interface stays a thin presentation layer over the schema (ADR-003) — orchestration only, with no SQL, ARC, or threads leaking into Layer 3.
* A single, well-known conversion edge (ADR-008): hex meets binary here and nowhere else inside the stack.

### Negative

* A method that enqueues clock-spanning work returns *before* that work completes; the caller observes the outcome through the database or events, not the return value. This is the deliberate per-phase atomicity of the lifecycle (ADR-003), and it means "the method returned" is not "the broadcast landed".
* Naming is mid-settlement: snake_case Ruby names render the spec's camelCase, and a planned convention/calling-convention pass (deferred until the SDK settles) may still adjust signatures. The names recorded here are current, not final.

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

A plain Ruby module is the minimum that satisfies a behavioural specification in a dynamically-typed language — reconstructing a foreign type system (Alternative A) is speculative complexity that the runtime would never check. Keeping the methods synchronous (Alternative B rejected) refuses to couple the contract to a concurrency strategy, and pushes the genuinely hard part — clock-spanning work — to the one place equipped for it (the daemon, ADR-018). The presentation-over-schema framing (ADR-003) keeps the layer thin rather than letting it grow a second state holder (Alternative C rejected). Necessity is high (the wallet must present BRC-100); complexity added beyond the bare method set is near zero. **Approve.**

## Validation

* `BSV::Wallet::Interface::BRC100` is a plain Ruby module of abstract methods (keyword args, hash returns); it contains no struct/type-alias layer.
* `BSV::Wallet::Engine` does `include BSV::Wallet::Interface::BRC100` and holds no SQL, ARC, or thread code.
* Interface methods return their result hashes synchronously; the Async reactor lives in `BSV::Wallet::Daemon`, not in the Engine.
* Hex appears at this boundary only (ADR-008): identity-shaped public keys hex, derived public keys binary.

## References

* ADR-001 — clean-room rebuild; design from the spec, not a port.
* ADR-003 — schema as canonical state; BRC-100 is the presentation layer over it.
* ADR-007 — single-tenant engine; identity is a construction parameter, not an interface concern.
* ADR-008 — binary internally, hex at the boundary; this interface is that boundary.
* ADR-018 — stateless SDK / stateful wallet; synchronous methods, asynchrony as infrastructure.
* `docs/reference/external/BRC100.md` — the 28-method specification.
* `gem/bsv-wallet/lib/bsv/wallet/engine.rb` — the Layer-3 realisation; `gem/bsv-wallet/lib/bsv/wallet/daemon.rb` — the Async runtime.
* `bsv-sdk` (`~> 0.24`) `lib/bsv/wallet/interface/brc100.rb` — the contract module.
* `docs/design.md` — four-layer SOA; BRC-100 is Layer 3 (business-process orchestration).
* HLR/issue trail for the deferred name/calling-convention pass (interface move to the SDK), not asserted complete here.

## Implementation evolution

**#405 (Stage 3 of #396).** The Decision section above ("Engine realises the interface by `include BSV::Wallet::Interface::BRC100`", line 26) and the Validation section's corresponding bullet ("`BSV::Wallet::Engine` does `include BSV::Wallet::Interface::BRC100`") both describe the original implementation and should be read as historical, not current guidance. Stage 3 of #396 swapped the mixin for composition:

- `BSV::Wallet::BRC100` was promoted from `module` to `class` with `initialize(engine)` constructor (no longer mixed into Engine).
- `Engine#brc100` is a memoised lazy accessor returning a `BSV::Wallet::BRC100` instance wrapping `self`.
- Engine exposes 28 wallet-vocab primitives (`#sign_action`, `#encrypt`, etc.) at the spec-aligned names; BRC100's instance methods translate to BRC-100 hash vocab at the wrap layer.
- `Interface::BRC100` is included by the `BRC100` class (not by `Engine`); contract resolution flows through the class instance.

The decisions in this ADR (plain Ruby module for the SDK contract; no struct/type-alias layer; synchronous return; hex-at-boundary) all still hold — the implementation evolution is purely about where the contract is included and how it's reached. Full rationale: ADR-026 (engine primitive granularity) + HLR #405 (mixin → composition).
