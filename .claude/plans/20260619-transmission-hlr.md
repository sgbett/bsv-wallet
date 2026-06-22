# [HLR] Transmission domain — wallet-to-wallet BEEF delivery

> Filed as GitHub issue #385 (label `project:hlr`) on 2026-06-19.
> Walk-through and forks settled 2026-06-19. Recorded by ADR-025.

## Problem

The wallet's two egress paths are asymmetric. **Receive** is a first-class
domain (`Engine::BeefImporter`: verify → save proofs → promote, atomic).
**Send-to-a-peer** is only a CLI pipe — `Engine#send_payment` /
`Hydrator#build_atomic_beef` build a BEEF envelope and `bin/send | bin/receive`
shuttle it as JSON over stdin/stdout. There is no transmissions table, no
transport, no per-counterparty state, and no delivery-outcome resolution.

This asymmetry is the historical root of a recurring class of bug: because
**broadcast** (→ miner, ships EF) got all the process machinery and **transmit**
(→ peer, ships BEEF) was treated as incidental, fixes aimed at one wire shape
repeatedly broke the other. The two are different *processes* — different
recipient, format, outcome taxonomy, and state — and belong in different domains.
See `docs/reference/transactions.md`.

A secondary symptom: the egress-trim logic (`replace_known_ancestors!` /
`known_txids`) currently lives in `Engine::BeefImporter` (ingress), where
"what does THIS peer already hold" does not belong.

## Approach

Introduce `Engine::Transmission` — a stateful wallet domain, sibling to
`Engine::Broadcast` and `Engine::TxProof`, sitting on the shared
`Engine::Hydrator` substrate. Verb `transmit` (not `send` — `Object#send`
collision; `submit` stays Broadcast's inner HTTP verb).

It owns, per (action × counterparty):

1. **Producing** the per-peer BEEF via the shared Hydrator.
2. **Trimming** it to what that peer has already seen — adopting the SDK's
   `Transaction::BeefParty`, with per-counterparty known-wtxids sourced from a
   persisted `transmissions` table (canonical state, **status derived not
   stored** — e.g. delivery encoded by presence of `acked_at`, never a status
   column; principle-of-state).
3. **Validating** fitness-to-ship — `Hydrator#validate_for_handoff!` relocates
   here as the Transmission precondition (it is conceptually one already).
4. **Delivering** — v1: to a **caller-supplied endpoint**, **synchronous HTTP
   ACK**. Outcome recorded structurally.

### Phasing (clean core first, door open — mirrors #192's own staging)

- **Phase 1 (this HLR):** the `Engine::Transmission` domain + `transmissions`
  table (grain action × counterparty) + per-peer BeefParty trimming +
  `validate_for_handoff!` relocation + egress-trim relocation out of
  `BeefImporter` + caller-supplied-endpoint synchronous delivery + CLI surface.
- **Phase 2 (separate, door left open):** identity-key → endpoint directory /
  overlay resolution; async / resumable delivery with a daemon fiber + OMQ socket
  and point-to-point outcome resolution (the transmit analogue of Broadcast's
  SSE/block-watch).
- **Compose with #192 later:** #192 is Broadcast-domain batching (flush N to the
  *network* atomically); Transmission sits alongside it, not inside it.

## Acceptance criteria (Phase 1)

- [ ] `Engine::Transmission` exists with `#transmit`, plus `Interface::Transmission`.
- [ ] `transmissions` table at grain (action × counterparty); per-peer
      known-wtxids are canonical DB state; delivery status is **derived**, no
      status column.
- [ ] Per-peer BEEF trimming on egress via SDK `Transaction::BeefParty`, with
      known-wtxids read from the table.
- [ ] `validate_for_handoff!` relocated to Transmission as the egress precondition.
- [ ] Egress-trim (`replace_known_ancestors!` / `known_txids`) removed from
      `Engine::BeefImporter`.
- [ ] Caller-supplied-endpoint, synchronous HTTP-ACK delivery; outcome persisted.
- [ ] CLI surface to transmit (e.g. `bin/transmit`).
- [ ] `docs/reference/transactions.md` updated from "not yet built" to implemented state.
- [ ] Specs: per-peer trim correctness; idempotent re-transmit; delivery-failure
      handling; derived-status (principle-of-state); round-trip against
      `BeefImporter` (transmit → internalize) deterministic.

## Out of scope

- identity-key → endpoint directory / overlay resolution (Phase 2).
- async / resumable / daemon delivery + SSE-style outcome resolution (Phase 2).
- #192 batching composition (separate domain; compose later).
- Any change to `Engine::Broadcast` (separate domain).
- #296 Phase D substrate extraction — a dependency/enabler, not delivered here.

## Context & dependencies

- `docs/reference/transactions.md` — broadcast vs transmit framing (this session).
- #296 — shared `Engine::Hydrator` substrate. Phase D (wtxid-keyed cache out of
  Broadcast) is the *enabler* but **not a blocker**: Transmission v1 can call
  `Hydrator#build_atomic_beef` as-is (store-backed). Phase C's egress completeness
  invariant is a Transmission precondition.
- #192 — noSend/sendWith (Broadcast-domain batching). Kept separate.
- #183 — 4-phase model that deferred chained-send; same "clean core first" path.
- SDK `Transaction::BeefParty` — the per-counterparty trimming bookkeeping adopted here.
- memory `project_transmission_domain`.
