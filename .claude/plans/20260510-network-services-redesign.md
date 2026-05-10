# Brainstorm: Network Services Redesign

**Status:** Brainstorm — not an implementation plan yet
**Subsumes:** #73 (porcelain network layer), #76 (rewrite), #36 (background lifecycle daemon)
**Date:** 2026-05-10

## The Problem

The wallet needs to perform network operations (fetch transactions, get proofs, broadcast, poll status) and manage their lifecycles (retry, fail, persist, notify). Currently these concerns are tangled:

- `BroadcastQueue` mixes lifecycle management (retry, status tracking, DB persistence) with network calls
- `ProofStore` mixes proof storage with proof harvesting (polling for proofs via network)
- `Engine` contains network fetch logic inline (`import_utxo` calls `fetch_tx_with_proof`)
- The current `BSV::Wallet::Services` is a wrong-namespace grab bag that conflates network routing with wallet orchestration

## Two Distinct Layers

### 1. `BSV::Network::Services` (SDK namespace — pure network routing)

Class is `BSV::Network::Services` (SDK namespace, because it's network infrastructure)
but the code lives in the wallet gem (because it's imperative orchestration, not
declarative protocol definitions). The SDK stays purely declarative — providers,
protocols, result types. The wallet adds the imperative layer in the same namespace.
Stateless. No database, no wallet concepts.

**Single responsibility:** "Get me data from the network, whoever can provide it."

- Same `call(command, *args, **kwargs)` interface as `Provider` — drop-in replacement
- Capability-based routing: checks `provider.commands`, dispatches to first match
- Fallback on retryable errors (5xx, 429, timeout) to next provider
- Terminal on non-retryable errors (400, 404)
- Rate limit enforcement (token bucket per provider, using `provider.rate_limit` metadata)
- JungleBus optimization: transparent memo when `get_tx` returns proof data, serves on subsequent `get_merkle_path`
- Broadcast affinity: remembers which provider handled `:broadcast`, prefers it for `:get_tx_status`

**What it does NOT do:**
- No domain methods (`fetch_tx_with_proof`, `fetch_utxos`) — those are wallet orchestration
- No database interaction
- No retry scheduling or lifecycle management
- No response normalization beyond what providers already return

**Open question:** Routing table. Currently routing is "try providers in order, skip those that don't serve the command." Should there be a semantic mapping? e.g., "for proof data, prefer JungleBus, then ARC tx_status, then WoC multi-call." This would encode knowledge about which providers are best at what, beyond just capability.

### 2. Service Objects (Wallet — lifecycle + orchestration)

Live in bsv-wallet. Own their database table, their state machine, their retry policy. Call through `Network::Services` for network operations.

#### Common Pattern

All service objects share:
- **Request lifecycle:** init → active → succeeded/failed
- **Database persistence:** own table with status, attempts, timestamps
- **Retry policy:** configurable backoff, max attempts, terminal conditions
- **Notification:** observer pattern or message sending when state changes
- **Network access:** hold a reference to `BSV::Network::Services` for network calls

#### Identified Service Objects

**`BroadcastRequest`** (outgoing — table: `broadcasts`)
- Created when a signed tx needs to go to the network
- Lifecycle: submit → poll status → confirmed/rejected
- Calls `services.call(:broadcast, raw_tx)` then `services.call(:get_tx_status, txid:)`
- On success: update broadcast row, link proof if mined, notify observers
- On failure: retry with backoff, or mark terminal (REJECTED, DOUBLE_SPEND)
- Sync option: immediate broadcast + wait for SEEN_ON_NETWORK
- Async option: queue for background processing

**`ProofRequest`** (incoming — table: `tx_reqs`)
- Created when a tx needs a merkle proof (either we broadcast it, or we received it without proof)
- Lifecycle: unmined → poll → proof found → completed
- Calls `services.call(:get_tx_status, txid:)` or `services.call(:get_merkle_path, txid:)`
- On success: write to `tx_proofs`, update tx_req, notify observers
- Observers: waiting BroadcastRequests, pending BEEF deliveries
- Could also be fulfilled reactively (callback/SSE pushes proof in, no polling needed)

**`UTXOFetch`** (incoming — no table currently, maybe doesn't need one)
- One-shot: "get UTXOs for this address"
- Calls `services.call(:get_utxos, address)`
- Normalizes response to wallet format
- Might not need full lifecycle — depends on whether we want retry/caching

**`TransactionFetch`** (incoming — no table currently)
- "Get me this raw tx, optionally with proof"
- Multi-step orchestration: get_tx, maybe get_tx_details, maybe get_merkle_path
- This is where the JungleBus-vs-WoC-multi-call logic lives — not in Network::Services
- The service object decides the strategy, Network::Services executes individual calls

#### Interaction Pattern

```
Engine                    Service Object              Network::Services          Provider
  |                           |                              |                      |
  |-- "broadcast this tx" --> |                              |                      |
  |                           |-- persist to broadcasts -->  |                      |
  |                           |-- call(:broadcast, raw_tx) ->|                      |
  |                           |                              |-- route to best ---> |
  |                           |                              |<-- result ---------- |
  |                           |<-- success/failure --------- |                      |
  |                           |-- update DB, notify -------> |                      |
  |<-- result --------------- |                              |                      |
```

### 3. Orchestrator (#36)

The daemon/background worker that drives the service objects:

- Polls for active BroadcastRequests that need status checks
- Polls for active ProofRequests that need proof fetching
- Respects backoff schedules
- Could be event-driven (SSE/callback pushes trigger immediate processing)
- Each cycle: find pending work → create/resume service objects → let them run → collect results

The orchestrator doesn't know how to broadcast or fetch proofs. It finds work and lets service objects do it.

## Notification / Observer Pattern

Service objects need to notify interested parties when state changes:

- **BroadcastRequest confirmed** → ProofRequest can check for proof; waiting recipients can be notified
- **ProofRequest completed** → pending BEEF deliveries (send_payment waiting for proof before delivering to recipient) can proceed
- **Proof arrived via callback** → ProofRequest completes without polling

Options:
- Simple observer (Ruby `Observable` or custom callbacks)
- Message queue (internal pub/sub, overkill for now?)
- Database polling (current approach — works but wasteful)

Lean toward simple observer for now, with the database as the source of truth for crash recovery.

## Response Normalization

Where does "ARC returns `txStatus`, WoC returns `tx_status`" normalization happen?

- NOT in `Network::Services` — it's a `call` passthrough
- NOT in providers — they return what the API returns
- IN the service objects — they know what format they need

Each service object normalizes the response for its own use. `BroadcastRequest` knows ARC response format. `TransactionFetch` knows WoC response format. This keeps normalization close to the consumer and avoids a one-size-fits-all normalizer.

**Alternative:** Protocols normalize. Each protocol (ARC, WoCREST, JungleBus) returns a consistent shape for each command. This is arguably more correct — the protocol knows its own API — but requires SDK changes.

## Open Questions

1. **Routing table:** Static (provider order) vs semantic (best provider per operation)?
2. **Protocol-level normalization:** Should each protocol return normalized responses, or is that the service object's job?
3. **Service object base class:** How much is shared vs how much is specific? State machine, retry, DB access seem common. Network strategy is specific.
4. **Where does `TransactionFetch` multi-call logic live?** The "try JungleBus first, fall back to WoC 3-call" is orchestration. Does it belong in the service object, or in a strategy object the service object uses?
5. **Scope of #73 vs new issue:** Does #73 get narrowed to just `BSV::Network::Services` (SDK routing layer), with service objects as a separate issue?
6. **tx_proofs as a service object?** tx_proofs is terminal storage, not a lifecycle. But proof *acquisition* has a lifecycle (tx_reqs). Keep ProofStore as storage, ProofRequest as the lifecycle?
