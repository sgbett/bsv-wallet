---
title: Glossary
parent: Reference
nav_order: 15
---

# Glossary

The wallet's vocabulary, by context. Within a context a word means one thing. Where a concept crosses from one context into another, the translation is explicit, as `txid` → `wtxid` already is at the BRC-100 boundary.

| Context | Lives in | Whose words |
|---|---|---|
| SDK | `bsv-sdk` | the SDK's |
| Core | `Engine` and `Store` | ours |
| Conformance | `BSV::Wallet::BRC100` | the BRC-100 spec's |
| CLI | `bin/wallet`, `bin/walletd` | ours, for users |

## Rules

- **Use the native term** for a concept that already has one: BRC-100's for BRC-100 concepts, the SDK's for SDK concepts.
- **Core adopts BRC-100's nouns, never its options.** Where BRC-100 names a domain concept (action, output, basket, label, tag, internalize), core uses its word. Its call-shape options (`noSend`, `sendWith`, `acceptDelayedBroadcast`, `signAndProcess`) stay in the conformance layer, and core states the same intent in its own terms (`broadcast_intent`). #548 tracks the Engine signatures that still take BRC-100 option names.
- **Qualify the layer-relative words.** "Primitive" and "porcelain" describe the same relationship at several layers, so always name the layer: SDK primitive, Engine primitive, Postgres primitive (ADR-009); CLI porcelain, Engine porcelain.
- **ADRs keep their wording.** Where an ADR uses a term in a sense this glossary retires, a dated terminology note at the end of the ADR maps it. The decision text stays as written.

## Core

### Transactions and actions

- **transaction** — a Bitcoin transaction. Bare "transaction" always means this; the other kind is always a *database transaction*. The Ruby class is `Transaction::Tx` (see CLAUDE.md).
- **action** — the wallet's record of a transaction and its metadata: in BRC-100's words, "a Bitcoin transaction augmented with descriptive metadata". A row in `actions`.
- **unpromoted** — an action with no `promotions` row, and the rows written for it (its outputs and their caller metadata). Promotion writes that row and puts the action's outputs with `spendable_intent = 'spendable'` in the UTXO set (`spendable` rows); an output with intent `none`, such as a payment to someone else, never joins it. When it happens depends on the path, and some actions are never promoted (a parked internal action, for one); see [action lifecycle](action-lifecycle.md). The row replaced the `outputs.promoted` flag of ADR-011 (post-broadcast promotion); see ADR-023.

### Engine primitives and porcelain

- **Engine primitive** — a public Engine method at per-domain-operation granularity, in wallet vocabulary (ADR-026): `build_action`, `sign_action`, `abort_action`. Not a lifecycle step.
- **Engine porcelain** — a public Engine method composed over Engine primitives for convenience, such as `send_payment` over `build_action`. [Architecture](../concepts/architecture.md#what-the-engine-actually-exposes) sorts every public Engine method into one or the other.

### Sending out

- **broadcast** — wallet → miners, carrying EF. `Engine::Broadcast`; at most one per action.
- **submit** — the HTTP POST to ARC inside a broadcast (the private `Engine::Broadcast#submit`).
- **transmit** — wallet → a named peer, carrying Atomic BEEF with every ancestor in full. `Engine::Transmission#transmit`; any number per action. Beyond BRC-100, which is silent on transport (ADR-025).
- **deliver** — the HTTP POST inside a transmit (`Network::PeerDelivery#deliver`). The outcome is `:delivered` only on a 200 with a valid ACK for the right wtxid.
- **trim** — reducing the ancestors a peer already knows to txid-only entries, on outgoing BEEF only. Transmit sends full ancestors for now: trimming needs the receiver's agreement (#552). `replace_known_ancestors!` on incoming BEEF is a different operation with the opposite trust model.
- **publish** — ADR-030's candidate name for the step that makes a persisted action public. Undecided until #192.

### Intent

Intent is stated, never inferred (ADR-019, ADR-031). Broadcast and transmit take the same three values, with the same meanings:

| Intent | Broadcast | Transmit |
|---|---|---|
| `inline` | the caller's process submits now | the wallet delivers now (an `endpoint:` is given) |
| `delayed` | `walletd` submits later | `walletd` delivers later (not built; #385 Phase 2) |
| `none` | the wallet doesn't submit | the wallet doesn't deliver; the BEEF is handed back to the caller (`endpoint: nil`) |

`delayed` changes *when*; `none` changes *who*. Never use one for the other. `broadcast_intent` is a schema enum; `transmit` doesn't take an intent argument yet (#464), so for transmit the words describe the two modes that exist.

- **deferred** — signing only: `build_action(sign_and_process: false)` leaves the signing to a later `sign_action`. Postponing a feature or a decision ("ADR-030 defers the plumbing commands") is ordinary English and fine; a broadcast or a transmit is never "deferred".
- **staged** — the state of an action awaiting deferred signing (`Store#stage_action`; "staged, awaiting `signAction`" in [action lifecycle](action-lifecycle.md)).

### Coming in

- **import** — a user-triggered, one-off bootstrap. `import_utxo` and `import_wallet` find funds held by the root key on chain and move them into the wallet with a self-payment (ADR-014).
- **internalize** — recording someone else's transaction as an incoming action and taking ownership of the named outputs: BRC-100's noun. `internalize_beef` and `internalize_wbikd_utxo`.
- **receive** — the user-level process: obtain a transaction, then internalize it. The ways in today are an envelope on stdin (`bin/wallet receive`) and a scan of receive addresses (`scan_receive_addresses`); a transmit listener in `walletd` is #544.

### Components

- **Hydrator** — the Engine component that wires a transaction's ancestry from stored proofs and assembles the Atomic BEEF the wallet hands out: the return value of `build_action` and `sign_action`, and a transmit's payload. Transmission and BeefInternalizer call it; TxProof only tells it when a proof arrives. Broadcast doesn't use it: it builds its own EF.
- **HydratedTxCache** — the in-memory, wtxid-keyed cache of raw-transaction and merkle-path bytes (not `Transaction::Tx` objects) shared by the Hydrator and Broadcast. The Hydrator's ancestry walk reads and fills it; Broadcast's EF build reads it, and Broadcast fills it from hints and eager proofs, so a parent loaded by one is a hit for the other (#296).
- **core** — Engine plus Store: build, sign, broadcast, observe, account. See [core vs conformance](core-vs-conformance.md) (ADR-027).

## Conformance (BRC-100)

- **BRC-100 method** — one of the interface's methods (`createAction`, `internalizeAction`, `getPublicKey`, …). The spec's unit is the method. Group them by the spec's own headings: transaction operations, public key management, cryptography operations, identity and certificate management, blockchain and network data, authentication. Avoid "operations" on its own, which `state-boundaries.md` uses for a stateless SDK call.
- **conformance** — the BRC-100 wallet-to-application contract, implemented only in `BSV::Wallet::BRC100`, which is composed over Engine (ADR-027).
- **send** (in `noSend`, `sendWith`) — broadcast; the spec's words are "sent to the network". `noSend` corresponds to broadcast intent `none`; `sendWith` batching is #192.
- **txid** — BRC-100's name for a transaction ID. At the boundary its value is a wtxid (see CLAUDE.md).
- **adapter** — an external binding of the BRC-100 surface: JSON, `bin/brc100` (proposed, #497), BRC-103 HTTP, ABI or OMQ (#180).

## SDK

- **SDK primitive** — a stateless building block in `bsv-sdk`, such as `BSV::Primitives::PrivateKey`.
- **operation** — a stateless call, complete in itself: "the SDK is operations; the wallet is processes" ([state boundaries](state-boundaries.md)).
- **provider command** — a semantic network command issued through the SDK's Provider (`:broadcast`, `:get_tx_status`, …).

## CLI

- **porcelain** — `bin/wallet`'s user-facing commands: `balance`, `list`, `send`, `receive`, `import`, `reject`, `sweep`, `consolidate`.
- **plumbing** — commands that would expose single Engine primitives: `build`, `sign`, `broadcast`. Not shipped; ADR-030 defers them until the Engine can hold the intermediate state.
- **send** — the user's intent to pay a recipient, fulfilled by a broadcast and/or a transmit. The command may infer part of the intent from context: given an identity key, it emits the BEEF envelope on stdout (transmit `none`); a base58 address has no peer to transmit to. It settles an explicit intent before calling the Engine and reports each part. "Sent" is never a status on its own.
- **`--broadcast=inline|async|none`** — the broadcast intent, where `async` means `delayed`. #548 renames it.

## Retired terms

| Retired | Use instead |
|---|---|
| substrate | the Hydrator, the HydratedTxCache or core's domain model, whichever is meant |
| caller-delivered, deferred-by-caller | transmit intent `none` |
| deferred broadcast; `async` as a broadcast mode | broadcast intent `delayed` |
| BRC-100 primitive | BRC-100 method |
| staged, for outputs or caller metadata written before promotion | unpromoted |
| import, for an incoming transaction | internalize |
| primitive, porcelain (unqualified) | name the layer |
