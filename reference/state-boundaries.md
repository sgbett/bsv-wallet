# State Boundaries — SDK and Wallet

A companion principle to [`principle-of-state.md`](principle-of-state.md). Where the principle of state defines *what* the wallet maintains (a database that is always in a valid state), this document defines *where* that maintenance lives — and, by negation, what cannot live there.

The rule it states is load-bearing for every "should this belong in the SDK or the wallet?" decision. It is the test we apply when surface area moves in either direction, and it has moved in both directions historically (the original BRC-100 interface and a re-implementation of ProtoWallet on the wallet gem's definitions were ceded back from SDK to wallet during the rebuild).

## Statement

> **Stateless behaviour belongs in the SDK. Stateful behaviour belongs in the wallet.**

Equivalently, viewed on the temporal axis:

> **The SDK is operations; the wallet is processes.** Each SDK call is complete in itself — no closure over time, no continuation, no invariant maintained between calls. The wallet maintains invariants between calls, across restarts, against an evolving external truth (the chain).

The two statements describe the same boundary from two angles. State / no-state is the spatial framing (where does data live); operations / processes is the temporal framing (what spans time). The temporal angle is the useful one when deciding new surface area: if the thing being designed needs to *outlive a single call*, it cannot live in the SDK by construction.

## Why this is structural, not a preference

The SDK has no database, no clock-spanning state, no long-lived connections, no daemon. There is nowhere in the SDK that stateful behaviour *can* live — a stateful "feature" added to the SDK either secretly relies on the caller to persist its state (in which case the caller is the wallet) or silently loses information on restart (in which case it is broken).

Conversely, the wallet has a database, a process lifetime, a reactor, and a schema-enforced "valid state" invariant (see [`principle-of-state.md`](principle-of-state.md)). It is the only place a process-shaped concern can hang.

So the rule is not "we have chosen this division" — it is "the division is forced by what each gem can structurally support." Anything that violates it is broken in one of the two ways above.

## Consequences

1. **Stateless operations belong in the SDK.** Pure computations (cryptographic primitives, script construction, key derivation, transaction serialisation), single-call wire dispatch (provider `:broadcast` / `:get_tx_status` / `:get_block_header`), canonical-shape normalisation of structurally identical responses across upstreams. None of these need to remember anything between calls.

2. **Stateful processes belong in the wallet.** Anything with a lifecycle: persisted affinity (which provider handled a given tx), push-resolution consumption (SSE / webhook listeners with cursor management), background reconciliation (existence sweeps, block-driven resolvers), action lifecycle (4-phase invariant), UTXO selection, daemon orchestration, multi-endpoint selection and bookkeeping.

3. **The boundary is bidirectional and reviewable.** Surface area moves both ways over time. The wallet gem's BRC-100 interface and `ProtoWallet` re-implementation were given back from SDK to wallet during the rebuild — the SDK could not own them once we required them to operate against persisted state and the wallet's own definitions of action, output, basket. Future moves should pass the same test: *does this need state across calls? If yes, wallet. If no, SDK.*

## How this manifests

### What the SDK exposes

Pure operations only. The SDK Provider abstraction owns wire dispatch for semantic commands (`:broadcast`, `:get_tx_status`, `:get_block_header`, `:get_utxos`) — the consumer issues a verb without knowing the wire protocol. Per-call protocol overrides (`call(:broadcast, tx, via: :arc)`) and protocol-named commands (`:arc` / `:arcade`) are rejected: both relocate protocol-awareness into the caller, which is the tell that selection has left the Provider abstraction. Selection — choosing *which* provider for *this* tx, remembering it across restarts — is stateful, so it lives in the wallet (`BSV::Network::Broadcaster`).

### What the wallet owns by construction

- **Action lifecycle.** `createAction` → `signAction` → broadcast → resolution is a process that spans calls, persists at every step, and survives restart. The SDK cannot own any part of it.
- **Affinity persistence.** Which provider broadcast a given tx is recorded in `broadcasts.provider` so the resolution path re-asks the right instance after daemon restart (#250).
- **Push-resolution consumption.** SSE listeners with cursor management (#251) — long-lived outbound connections, durable `Last-Event-ID` checkpoints, idempotent event application. By definition stateful.
- **Block-driven reconciliation.** Matching new block contents against in-flight wtxids to drive → MINED transitions. Requires the in-flight set, which only the wallet has.

### Broadcast resolution physics — a worked example

The broadcast subsystem makes the boundary concrete:

| Edge | Transition | Mechanism | Why this mechanism |
|------|------------|-----------|--------------------|
| 1 | → MINED | Block-driven resolver | Block data is globally shared across all ARC instances — immune to the per-instance problem by construction. |
| 2 | → SEEN_ON_NETWORK / REJECTED / DOUBLE_SPEND_ATTEMPTED | Push (SSE) from the metamorph instance that holds the tx | Mempool outcomes never land in a block; the block resolver is structurally blind to them. Only a push signal from the holding instance can deliver them. |

The structural fact behind the table — block data globally shared, mempool outcomes per-instance — is a property of BSV's protocol surface, not a design choice. It dictates that **the wallet must run a push consumer** (only it can own that long-lived connection + cursor) and that **the wallet must run a block reconciler** (only it knows what is in flight). Both are stateful, both live in the wallet for that reason. See issues #250 and #251 for the implementation that landed on this basis.

## Test for new surface area

When deciding where a new behaviour lives, the question is not "which gem is more convenient" but: **does it need to remember anything between calls?**

- *No* → SDK. Pure operation, stateless dispatch, response normalisation.
- *Yes* → wallet. By construction.

If the answer is "yes but only a little" (caching, affinity, retry counters), it is still yes. There is no half-stateful SDK feature that works after restart; the choice is wallet or broken.

## Related

- [`principle-of-state.md`](principle-of-state.md) — *what* the wallet maintains (the database is canon).
- [`schema-intent.md`](schema-intent.md) — how the schema encodes the wallet's stateful invariants.
- #250 — `BSV::Network::Broadcaster` + persisted broadcast affinity (worked example: stateful broadcast orchestration in the wallet).
- #251 — Arcade SSE push resolution (worked example: stateful push consumer in the wallet, with the resolution-physics rationale).
