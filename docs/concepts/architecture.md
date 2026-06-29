---
title: Architecture
parent: Concepts
nav_order: 1
---

# Architecture

The wallet is built as a set of layers with a strict dependency direction. Understanding that shape is the fastest way to understand the whole gem, because almost every design decision falls out of it.

This page is the narrative shape of the system. For canonical principle statements see [Principle of state](../reference/principle-of-state.md) and [State boundaries](../reference/state-boundaries.md); for the schema, see [Schema](../reference/schema.md).

## The layers

```
                 ┌─────────────────────────────────────────────┐
   Layer 3       │                  Engine                      │
  orchestration  │   wallet-vocab primitives + composed         │
                 │   collaborators (no SQL · no I/O · no threads)│
                 └───────────────┬─────────────────────────────-┘
                                 │ depends on (via Interface::*)
        ┌────────────┬───────────┴────────┬─────────────┬──────────────┐
        ▼            ▼                    ▼             ▼              ▼
  ┌───────────┐ ┌────────────┐  ┌────────────────┐ ┌──────────┐ ┌──────────┐
  │   Store   │ │  UTXOPool  │  │ FundingStrategy│ │ TxBuilder│ │ Hydrator │
  │persistence│ │  selection │  │  input loop    │ │  build   │ │ BEEF egr │
  └───────────┘ └────────────┘  └────────────────┘ └──────────┘ └──────────┘
  ┌────────────┐
  │BeefImporter│
  │  ingress   │
  └────────────┘
   Layer 2a — six contracted collaborators behind Interface::* modules

  ┌────────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
  │Network::Services│ │Network::    │ │Network::     │ │Engine::      │
  │  chain queries │ │ Broadcaster │ │ ChainTracker │ │ Transmission │
  └────────────────┘ └──────────────┘ └──────────────┘ └──────────────┘
   Layer 2b — four concrete collaborators (no Interface::* — single implementation)

                 ┌─────────────────────────────────────────────┐
    runtime      │   Daemon · Scheduler · Engine::Broadcast     │
                 │   Engine::TxProof · Engine::Reaper           │
                 │   Network::SSEListener (Arcade push)         │
                 └─────────────────────────────────────────────┘
```

**Layer 3 — `Engine`.** The wallet-vocab primitive surface. It exposes BRC-100's spec-aligned primitive methods (`build_action`, `sign_action`, `encrypt`, `get_public_key`, …) plus a handful of porcelain operations (`send_payment`, `sweep`, `import_wallet`, …). It is the only place the wallet's policy lives, and it contains no SQL strings, no HTTP calls, and no thread or fibre management. BRC-100 spec compliance lives one layer up, in `BSV::Wallet::BRC100`, a class composed over an Engine instance.

**Layer 2a — six contracted collaborators.** Engine receives these at construction time, each behind an abstract `Interface::*` contract module. They are the *stable seams* of the system — points where an alternative implementation is a first-class possibility, not a fork.

- **`Store`** — persistence. Owns the schema, the action / output / broadcast / promotion / transmission lifecycle, and the cascade logic. Contract in `Interface::Store`; concrete subclasses `Store::SQLite` and `Store::Postgres`. See [Persistence](persistence.md).
- **`UTXOPool`** — UTXO selection and pool health. Contract in `Interface::UTXOPool`; default concrete implementation delegates to `Store#find_spendable`.
- **`FundingStrategy`** — input acquisition and the build fixpoint. Contract in `Interface::FundingStrategy`.
- **`TxBuilder`** — store-free transaction construction, fee balancing, and signing. Contract in `Interface::TxBuilder`.
- **`Hydrator`** — proof-store hydration, egress BEEF assembly, and the egress SPV-honesty check. Contract in `Interface::Hydrator`. See [Transactions & BEEF](transactions-and-beef.md).
- **`BeefImporter`** — incoming BEEF parsing, SPV verification, proof persistence, and output promotion. Contract in `Interface::BeefImporter`. See [Transactions & BEEF](transactions-and-beef.md).

**Layer 2b — four concrete collaborators.** These have a single implementation and no `Interface::*` module. Per-counterparty state or sole provider routing means they aren't replaceable in the same way.

- **`Network::Services`** — provider routing for chain queries, fallback, rate limiting, and response normalisation.
- **`Network::Broadcaster`** — the broadcast boundary. Owns submit + status lookup, persists per-tx provider affinity in `broadcasts.provider`.
- **`Network::ChainTracker`** — a write-through cache of block headers used for SPV. See [Transactions & BEEF](transactions-and-beef.md).
- **`Engine::Transmission`** — wallet-to-peer BEEF delivery. The deciding axis is per-counterparty state, owned in one place. See [Transmission](transmission.md).

**Runtime — `Daemon`, `Scheduler`, the worker fibres.** The background process (`walletd`) that drives delayed broadcasts, proof acquisition, and abandoned-action cleanup. It wraps the same `Store` and `Broadcaster`, runs in its own Async reactor, and never touches `Engine` directly.

## Dependency injection, and why

Engine receives every Layer 2 collaborator through its constructor:

```ruby
engine = BSV::Wallet::Engine.new(
  store:            store,            # Interface::Store
  utxo_pool:        utxo_pool,        # Interface::UTXOPool
  broadcaster:      broadcaster,      # Network::Broadcaster (required)
  services:         services,         # Network::Services
  key_deriver:      key_deriver,      # KeyDeriver
  chain_tracker:    chain_tracker,    # Network::ChainTracker
  network_provider: network_provider, # direct-lookup SDK provider
  network:          :mainnet,
  limp_threshold:   50_000,
  callback_token:   token             # Arcade SSE routing (optional)
)
```

Engine then constructs the rest of the collaborators in its own initialiser from those building blocks: `TxBuilder`, `Hydrator`, `BeefImporter`, `FundingStrategy`, `Transmission`, the inline `Broadcast` worker, the shared `HydratedTxCache`, the `Policy` guard.

Two consequences matter:

1. **The orchestration logic is testable in isolation.** Because Engine talks to interfaces, a test can substitute an in-memory store or a stub network without a database or a socket. The `Interface::*` contracts exist precisely so that an alternative implementation is a first-class possibility, not a fork.
2. **Backends are swappable at the seam.** Postgres versus SQLite is a constructor choice (`Store.connect(url)` picks the subclass from the URL scheme), not a code change in the Engine. The same is true of network providers, and of the broadcast and chain-tracker seams.

`CLI.boot` is the canonical example of wiring these pieces together for a single-process tool.

## No ORM leakage across the boundary

The `Store` is implemented with [Sequel](https://sequel.jeremyevans.net/), and its models (`Action`, `Output`, `Broadcast`, `Promotion`, `Transmission`, …) are Sequel classes. But **no Sequel object ever crosses the interface boundary**. Every `Store` method returns plain Ruby hashes and arrays:

```ruby
action = store.find_action(id: 42)
# => { id: 42, reference: "...", wtxid: "...", broadcast_intent: "delayed", ... }
```

This keeps the Engine free of persistence concerns — it cannot accidentally trigger a lazy-loaded association or depend on Sequel semantics — and means the contract is expressible by any backend that can return the same hashes. It is the boundary that makes the layering real rather than nominal.

## Structural state, not stored status

The single most distinctive decision in the codebase: **an action has no status column.** Its BRC-100 status is computed from the structural facts of the database every time it is asked for, by `Action#derived_status` — the rationale and canonical derivation table live in [Principle of state](../reference/principle-of-state.md).

If a merkle proof *is* the definition of "completed" and a promotions row *is* the definition of "unproven", there is nothing to keep in sync, nothing to migrate when the rules change, and no way for a crash between "do the thing" and "record that we did the thing" to leave a lie in the database. The structure *is* the state. This idea recurs throughout — see [Action lifecycle](action-lifecycle.md) for the full operational narrative, [Persistence](persistence.md) for the promotion row's role.

## Designed for scale

The structural decisions in the schema — immutable outputs, the spendable partition, derived state, the tiered UTXOPool, the broadcast/transmit split — are warranted by a specific scale target: BSV's thesis of unbounded on-chain throughput, codified as a wallet-node design target of **millions of transactions per second**. The decision and its consequences are recorded in [ADR-002](../../.architecture/decisions/adrs/20260505_ADR-002-design-for-scale-wallet-node.md).

That target is not a marketing claim; it is the constraint that shapes specific mechanisms. The most concrete instance is the **~10k tx/s trigger ceiling**: a `plpgsql` trigger that runs per affected row on a hot path costs roughly the same per-row time, which caps the path at the same magnitude. The wallet's two cross-table invariants on the send hot path — broadcast-intent integrity and promotion authorisation — both started life as candidate-trigger proposals and were both reformulated as **declarative composite-FK gates** instead, precisely so the hot send path runs no procedural code per write. ADR-019 (broadcast-intent) and ADR-023 (promotion-as-a-row, superseding ADR-011's promoted-UPDATE flag) record both moves; the mechanism they share is the same:

### The composite-FK gate

A *named pattern* in the schema, appearing twice:

- **broadcasts (action_id, intent) → actions (id, broadcast_intent), `ON UPDATE RESTRICT`** (ADR-019). The denormalised `intent` column on `broadcasts` makes the cross-table invariant — "an internal action holds no broadcast row" — visible to a single-row CHECK plus a composite FK. The FK forces equality with the parent; the CHECK `intent != 'none'` forbids the denormalised value being internal. Composed, the schema declaratively forbids the contradictory state, with no trigger on the hot path.
- **promotions (action_id, authorising_status) → broadcasts (action_id, tx_status), `ON UPDATE CASCADE`** (ADR-023). Promotion is itself represented as a *row* rather than a flag on outputs. The FK gates that row's existence on the broadcast actually holding a non-rejected status; the `auth_not_rejected` CHECK forbids `REJECTED` / `DOUBLE_SPEND_ATTEMPTED`. A flip to `REJECTED` while a promotions row exists is rejected by the cascade; `reject_action` must delete the promotions row first. Same principle, same shape — applied to a different cross-table predicate.

Both gates take a cross-table rule a single-row CHECK cannot reach and reformulate it so the schema *can* enforce it declaratively. The principle is: enforcement stays in the database (ADR-003), and the mechanism is chosen with the scale target in mind. The same denormalised-column + composite-FK + CHECK pattern recurs in HLR #467: `spendable_intent` is denormalised onto `spendable`, the composite FK targets `outputs(id, spendable_intent)`, and the CHECK pins the row to `'spendable'` — declaratively replacing the prior `prevent_outbound_spendable` trigger. The remaining hot-path trigger (`prevent_internal_action_delete`) sits on a path with no declarative analogue and a low per-row cost.

## The BRC100 wrap layer

`BSV::Wallet::BRC100` is a class that holds an Engine reference and translates the BRC-100 specification's vocabulary into wallet primitives:

```ruby
engine.brc100.create_action(description: 'pay bob', outputs: [...])
# → validates spec shape → engine.build_action(...) → wraps result
```

The split is deliberate (ADR-026):

- The wrap layer owns spec-shape validation, BRC-100 vocab (`txid:` ↔ `wtxid:`, `tx:` ↔ `atomic_beef:`, `signableTransaction:` ↔ `signable:`), and the `originator:` parameter — which never propagates into Engine.
- The primitives carry their own *operation* invariants (`require_key_deriver!`, parameter-combination semantics) so any caller that isn't going through `BRC100` — the daemon, the batch APIs, an internal porcelain method — cannot bypass them.

`Engine#brc100` memoises a single wrap instance. Engine has no `BRC100` in its ancestry; the wrap layer is composition, not inheritance.

## What the Engine actually exposes

The public surface is the BRC-100 interface (via `brc100`) plus a layer of **porcelain** — higher-level convenience operations composed from the primitives:

- **BRC-100 primitives** (via `engine.brc100.*` or directly via `engine.build_action`, `engine.encrypt`, etc.): `create_action`, `sign_action`, `abort_action`, `internalize_action`, `list_actions`, `list_outputs`, `relinquish_output`, the cryptographic methods (`encrypt`, `decrypt`, `create_hmac`, `create_signature`, `get_public_key`, …), the certificate methods (`acquire_certificate`, `prove_certificate`, `discover_by_identity_key`, …), and the chain queries (`get_height`, `get_header_for_height`, …).
- **Porcelain**: `send_payment`, `import_utxo`, `import_wallet`, `generate_receive_address`, `scan_receive_addresses`, `list_receive_addresses`, `consolidate_step`, `sweep`, `sweep_to_root`. These are not part of BRC-100; they are the ergonomic operations the wallet adds on top, and they are what the `bin/` tools mostly call.

The split matters when reading the code: the primitives map to the standard via the wrap layer, while the porcelain encodes this wallet's opinions about how to use it well.

## Related

- [Principle of state](../reference/principle-of-state.md) — the canonical statement of the schema-as-truth principle that everything in this page rests on.
- [State boundaries](../reference/state-boundaries.md) — the stateless-SDK / stateful-wallet axis that puts these components on the right side of the line.
- [Action lifecycle](action-lifecycle.md) — the operational narrative.
- [Persistence](persistence.md) — the schema's role.
- [Schema](../reference/schema.md) — table-by-table reference.
