# ADR-018: The stateless-SDK / stateful-wallet boundary

## Status

Accepted.

**Decided:** 2026-06-10 (commit `2854d2b`, "docs(reference): add principle-of-state + state-boundaries; retire broadcast-boundary ADR"; HLR #302) — the boundary was promoted to a first-class load-bearing principle in `reference/state-boundaries.md`, retiring the predecessor broadcast-network-boundary ADR; the underlying placements (#250 broadcast affinity, #251 SSE push) had already settled on the wallet side.

## Context

The wallet is built on the BSV Ruby SDK and ships as a separate gem from it. Two gems, two roles — and a recurring question every time new surface area is designed: does this behaviour belong in the SDK or the wallet? Asked ad hoc, it gets answered by convenience ("the SDK already has the provider, put it there"), and surface area accretes on the wrong side. We need a single test that decides the placement structurally, not by taste.

The wallet is a persistent process — a wallet node (ADR-002) — with a database that is always in a valid state (ADR-003), a reactor, long-lived connections, and a schema-enforced "valid state" invariant. The SDK is a library: pure operations, each call complete in itself. That asymmetry is not a stylistic difference; it is what each gem can structurally support. The SDK has nowhere a process-shaped concern can hang — no database, no daemon, no clock-spanning state, no connection that outlives a call.

This ADR records the decision that fixes the boundary. The living statement of the principle — its consequences, manifestations, and the worked broadcast-resolution example — lives in `reference/state-boundaries.md`; this record fixes the *decision* and what was weighed, the way ADR-003 sits alongside `reference/principle-of-state.md`.

## Decision Drivers

* **Placement was being decided by convenience.** Without a test, new surface area lands wherever it is easiest to reach, and the SDK accretes behaviour it cannot honour across calls.
* **The asymmetry is structural, not preferential.** The SDK has no place to keep state; the wallet is the only place a process-shaped concern can live. A rule grounded in that fact cannot be argued away.
* **The boundary moves in both directions over the rebuild.** Surface area has been ceded SDK → wallet (the BRC-100 interface, a `ProtoWallet` re-implementation) and held at the SDK edge (protocol-named broadcast commands rejected). A bidirectional test is needed, not a one-way "SDK owns more" or "wallet owns more" heuristic.
* **The structural ADRs need a clean seam to point at.** Fee/change math (ADR-013) and verification (ADR-015) are stateless and belong in the SDK; their persistence and lifecycle belong in the wallet. That split wants one rule, not a per-feature argument.

## Decision

Adopt the **stateless-SDK / stateful-wallet boundary** as a load-bearing principle, the sibling of the principle of state (ADR-003):

> Stateless behaviour belongs in the SDK. Stateful behaviour belongs in the wallet. Equivalently, on the temporal axis: the SDK is operations, the wallet is processes — same boundary, viewed by what spans time.

The deciding test, applied whenever surface area is placed or moved:

> **Does it need to remember anything between calls — survive a restart, maintain an invariant against the evolving chain?** Yes → wallet, by construction. No → SDK.

"Yes but only a little" (caching, affinity, retry counters) is still yes. There is no half-stateful SDK feature that works after restart; the choice is wallet or broken.

Concretely:

* **The SDK exposes pure operations only.** Cryptographic primitives, script construction, key derivation, transaction serialisation, single-call wire dispatch (provider `:broadcast` / `:get_tx_status` / `:get_block_header`), and canonical-shape normalisation of structurally identical upstream responses. None remembers anything between calls.
* **The wallet owns everything with a lifecycle.** The action lifecycle (`createAction` → `signAction` → broadcast → resolution), persisted broadcast affinity (`broadcasts.provider`), push-resolution consumption (SSE listeners with cursor management), block-driven reconciliation, UTXO selection, and daemon orchestration. Each spans calls and survives restart, so the SDK cannot own any part of it.
* **Selection is stateful, dispatch is not.** The SDK Provider abstraction owns wire dispatch for semantic verbs; choosing *which* provider for *this* transaction and remembering it across restarts is the wallet's (`BSV::Network::Broadcaster`, which records the responding provider via `Store#record_broadcast_provider`). Protocol-named commands (`:arc` / `:arcade`) and per-call protocol overrides are rejected at the SDK edge — both relocate selection into the caller, which is the tell that state has crept into the library.
* **The boundary is bidirectional and reviewable.** When surface area moves either way, it passes the same test. The BRC-100 interface and `ProtoWallet` re-implementation were ceded back from SDK to wallet during the rebuild — the SDK could not own them once they had to operate against persisted state and the wallet's own definitions of action, output, and basket.

**Architectural components affected:** the SDK/wallet gem split; `BSV::Network::Broadcaster` (selection + affinity, wallet-side over SDK providers); the SDK Provider abstraction (stateless dispatch); the daemon and every background loop (stateful, wallet-side); and every future placement decision, which defers to the test rather than relitigating it.

## Alternatives Considered

### A. Decide placement per-feature, by convenience
Let each new behaviour land in whichever gem is easiest to reach.
**Pros:** no rule to learn; fast in the moment.
**Cons:** behaviour accretes on the wrong side; the SDK ends up with features that secretly rely on the caller to persist their state or silently lose information on restart. Contributors discover the boundary only when a review rejects a misplacement.
**Rejected** — placement must be structural; "convenient" is exactly how a stateful concern leaks into a library that cannot honour it.

### B. Frame the axis as declarative (SDK) vs imperative (wallet)
An earlier internal framing.
**Pros:** close to the right line; intuitive.
**Cons:** does not fit. The SDK's surface is imperative-but-stateless (`provider.call(:broadcast, tx)` is "do this now", not declared intent), and BRC-100 `createAction` *is* user-declared intent living in the wallet. Declarative/imperative cross-cuts the real seam.
**Rejected** — operations vs processes (equivalently, state vs no-state) names the same boundary accurately; declarative/imperative misclassifies cases at the edge.

### C. Push stateful concerns into the SDK behind a caller-supplied persistence hook
Keep orchestration SDK-side; let the caller inject storage.
**Pros:** centralises orchestration in one gem.
**Cons:** the caller supplying persistence *is* the wallet — the state still lives wallet-side, now with an indirection that obscures where the invariant is enforced. The SDK gains an interface it cannot satisfy alone and which is meaningless without the wallet behind it.
**Rejected** — this is the "secretly relies on the caller to persist" failure mode named in the structural rationale; it relocates the boundary without removing it.

## Consequences

### Positive

* Every placement decision has one test to apply, so new surface area lands on the correct side without re-arguing scale or lifecycle each time.
* The SDK stays a clean library — pure operations, reusable outside this wallet, with no hidden dependence on a caller's database or daemon.
* The structural ADRs get a clean seam: ADR-013 (fee/change is a stateless SDK operation) and ADR-015 (`Transaction::Tx#verify` is stateless; `ChainTracker` is the wallet-side stateful bridge) are worked instances, not special cases.

### Negative

* **The wallet carries all the lifecycle weight** — selection, affinity, push consumption, reconciliation, daemon orchestration. By construction: there is nowhere else for it to live, but it does mean the wallet gem is where the operational complexity concentrates.
* **A behaviour that is "mostly stateless" still goes wallet-side** the moment it needs to remember anything across calls, even a retry counter. Occasional friction when a feature feels SDK-shaped but trips the test; the test wins, because the alternative is a feature that breaks on restart.

### Neutral / Reversibility

* **The boundary is reviewable and moves both ways**, but the *test* is effectively fixed — it is forced by what each gem can structurally support, not chosen. Individual placements can be revisited (re-apply the test); the principle itself is as load-bearing as the principle of state it sits beside.

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

This is a classification rule, not new machinery — it adds no code, only a test for where code goes. Its necessity is concrete: the boundary has already moved in both directions during the rebuild (BRC-100 interface and `ProtoWallet` ceded SDK → wallet; protocol-named commands held at the SDK edge), which is direct evidence that placement was a live question being answered, sometimes wrongly. Grounding the answer in what each gem can structurally support — the SDK has no database, daemon, or clock-spanning state — makes the rule cost nothing to maintain and impossible to argue away by convenience. The one cost (the wallet carries all lifecycle weight) is inherent to the asymmetry, not introduced by the rule. **Approve.**

## Validation

Acceptance criteria — each a checkable consequence of the decision (the standing compliance test lives in `reference/state-boundaries.md`):

* Nothing in the SDK persists state across calls or depends on a caller-supplied store to function — every SDK surface is a complete-in-itself operation.
* Provider selection and affinity (`broadcasts.provider`, recorded via the Store) live wallet-side in `BSV::Network::Broadcaster`; protocol-named commands (`:arc` / `:arcade`) and per-call protocol overrides are rejected at the SDK Provider edge.
* The action lifecycle, push-resolution consumers, and block-driven reconciliation are wallet-side, since each spans calls and survives restart.
* Any move of surface area across the boundary cites the "does it need state across calls?" test as its justification.

## References

* `reference/state-boundaries.md` — the living statement (canonical wording, structural rationale, broadcast-resolution worked example, test for new surface area).
* ADR-003 — schema as canonical state; the sibling load-bearing principle (*what* the wallet maintains; this ADR is *where* it lives).
* ADR-002 — design for scale, the wallet-node model; the temporal framing of the same SDK-is-operations / wallet-is-processes split.
* ADR-006 — single relational store; the wallet's state lives in one ACID boundary, and the SDK has none.
* ADR-013 — auto-fund; fee/change computation as a stateless SDK operation (a worked instance of the boundary).
* ADR-015 — chain tracker; the SDK's `Transaction::Tx#verify` is stateless, `ChainTracker` is the wallet-side stateful bridge (a worked instance of the boundary).
* `.architecture/reviews/chain-tracker-pivot.md` — the `ChainTracker` write-through bridge in full.
* HLR #302 — promoted both load-bearing principles to first-class reference docs; retired the broadcast-network-boundary ADR into `reference/state-boundaries.md`.
* #250 — `BSV::Network::Broadcaster` + persisted broadcast affinity (stateful broadcast orchestration, wallet-side). #251 — Arcade SSE push resolution (stateful push consumer, wallet-side).