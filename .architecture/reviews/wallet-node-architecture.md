# Wallet Node Architecture — Vision Document

**Date**: 2026-05-22
**Status**: Architectural direction (not implementation spec)
**Source**: Extended brainstorm session covering chain tracker pivot, WBIKD, async framework, ZeroMQ integration, and process architecture.

---

## The Realization

The wallet is not a web application that uses Bitcoin. It is a **Bitcoin wallet node** that happens to have web-compatible interfaces for convenience.

The BRC-100 specification defines two interfaces:
- **API** — JSON, human-readable, designed for web browsers and developer ergonomics
- **ABI** — fixed-width binary, wire-order bytes, designed for wallet-to-wallet communication

The TypeScript SDK implements the API. It runs in browsers, speaks JSON, handles occasional end-user transactions. That is a valid product — but it is not what this wallet is.

This wallet targets BSV's scaling claims. Thousands to millions of transactions per second. Persistent processes. Binary protocols. Socket-based communication. The API is a convenience layer on top; the ABI is the real interface.

---

## The Model: Node, Not Web App

```
Bitcoin Core:                     This wallet:

Persistent process (bitcoind)     Persistent process (walletd)
Binary wire protocol (P2P)        Binary ABI over omq sockets
Peer discovery                    Wallet discovery (future)
Mempool (pending state)           Spendable set + pending actions
Block validation                  SPV verification (chain tracker)
UTXO set                          Output table + spendable set
RPC interface (bitcoin-cli)       JSON API / CLI tools (convenience)
```

The JSON BRC-100 interface is the RPC layer — like `bitcoin-cli` talking to `bitcoind`. Useful for developers, debugging, testing, thin clients. But the real work happens over binary protocols between wallet processes.

---

## Process Architecture

### What exists today

The wallet is a library. No persistent process. CLI tools boot the library, run a method, exit. The database accumulates state but nothing acts on it between invocations.

```
[ CLI tool ] → boots library → runs method → exits
                                    ↓
                              [ Database ]
```

### Where we're heading

```
                    ┌─────────────────────────────┐
                    │          walletd             │
                    │                             │
                    │  Engine (application logic)  │
                    │  Store (persistence)         │
                    │  Services (network routing)  │
                    │  ChainTracker (SPV)          │
                    │  Background loops (fibers)   │
                    │                             │
                    │  omq sockets:               │
                    │    REP ← CLI tools (REQ)    │
                    │    REP ← HTTP layer (REQ)   │
                    │    REP ← other wallets (REQ)│
                    │    SUB ← ARC events         │
                    │    SUB ← block notifications│
                    │    PULL ← worker pipeline   │
                    │                             │
                    └─────────────┬───────────────┘
                                  │
                            [ Database ]
```

### Evolution phases

| Phase | State | Description |
|-------|-------|-------------|
| **Now** | Library | CLI tools boot full library, run method, exit |
| **Phase 1** | Daemon | walletd runs background loops (broadcasts, proofs, scanning). CLI tools still boot their own library. |
| **Phase 2** | Thin clients | CLI tools become REQ clients to walletd's REP socket. No library boot — just send message, get response. |
| **Phase 3** | Horizontal | Multiple walletd workers via PUSH/PULL fan-out. Database contention managed by UNIQUE constraints. |
| **Phase 4** | API process | HTTP/JSON layer runs as separate process, REQs to walletd. Or runs inside walletd as a bound HTTP socket. |
| **Phase 5** | Wallet-to-wallet | Two walletd processes connected over TCP. Binary ABI frames. create_action on one side, internalize_action on the other. Discovery, channel negotiation, bound sockets. |
| **Phase 6** | Network | Multiple wallets forming a mesh. The BSV wallet network operating at protocol speed. |

---

## The Stack

```
Layer 0:  bsv-sdk             Blockchain primitives, cryptography, transaction
                               construction, script interpreter, BEEF, merkle
                               proofs. The "libbitcoin."

Layer 1:  bsv-wallet           BRC-100 interface. Engine, Store, ProofStore,
                               BroadcastQueue, UTXOPool, KeyDeriver, ChainTracker.
                               The application logic. Analogous to a Rails app's
                               models and business logic.

Layer 2:  walletd              Process host. Boots the library, binds sockets,
                               runs background loops, manages lifecycle.
                               Analogous to Unicorn/Puma — the thing that
                               daemonizes the application.

Layer 3:  Interfaces           Thin layers that translate external protocols
                               to Engine method calls:
                               - CLI tools (bin/create, bin/receive, etc.)
                               - HTTP/JSON (x100-rack, x402-rack)
                               - Binary ABI (omq sockets, wallet-to-wallet)
                               - Rails integration (x100 gem)
```

Layer 3 interfaces are **surfaces**. They expose the wallet to the outside world in whatever protocol the consumer speaks. They are thin — translation only, no business logic. They are useful for testing, development, webhooks, specs. They are NOT the wallet.

The wallet is Layers 0-2. walletd is what makes it run.

---

## Why omq

omq (pure Ruby ZeroMQ) was chosen as the messaging layer because:

1. **Binary native** — all frames are raw bytes. Maps directly to BRC-100 ABI.
2. **Transport agnostic** — inproc:// (fibers), ipc:// (processes), tcp:// (machines). Same code, different endpoint. This IS the scaling lever.
3. **Pattern-based** — REQ/REP, PUB/SUB, PUSH/PULL, ROUTER/DEALER. Each task picks the pattern that fits its nature. Not a job queue — a messaging toolkit.
4. **Zero infrastructure** — no broker, no server, no config files. The "SQLite of messaging."
5. **Wire compatible** — ZMTP 3.1. Interoperates with libzmq, pyzmq, czmq. Other languages can talk to walletd.
6. **Fiber-native** — built on Ruby Async. Non-blocking I/O without threads.
7. **Zero native dependencies** — pure Ruby. `gem install omq` just works.

omq is not just for background jobs. It is the wallet's communication backbone — between fibers, between processes, between machines, between wallets.

---

## The Four Known Background Tasks

These are the first workload for walletd. They drove the discovery of the architecture but they are not the architecture itself.

| Task | What it does | Pattern |
|------|-------------|---------|
| Broadcast push | Push delayed broadcasts to ARC | Discovery loop (PUSH/PULL when scaled) |
| Status polling | Poll ARC for broadcast status updates | Discovery loop (eventually SUB to ARC SSE) |
| Proof acquisition | Fetch merkle proofs for mined transactions | Discovery loop (eventually SUB to block events) |
| WBIKD scanning | Check outstanding receive addresses for UTXOs | Periodic sweep |

These are all "database has incomplete state, fix it" tasks. They exist because the wallet currently has no push-based event sources. When ARC SSE and block notification subscriptions are wired up (PUB/SUB), some of these become event-driven instead of poll-driven.

---

## What the Interfaces Provide

The CLI tools, HTTP layers, and future ABI sockets are **surfaces** — ways into the wallet. They let us:

- Write specs against a clean API boundary
- Build webhooks and integrations
- Provide developer-friendly JSON access
- Test individual components in isolation
- Prove the concept works (like the ts-sdk does)

They are the "easy way in." The wallet node underneath is tighter, faster, binary. The surfaces translate.

---

## Open Architectural Questions

1. **Where does the "Rack equivalent" live?** Is there a universal callable interface between walletd and the Engine? Or does walletd call Engine methods directly? The Rack model exists because HTTP is one transport — you need middleware composition. If the wallet speaks multiple protocols (omq, HTTP, ABI), a common internal dispatch layer might emerge.

2. **Engine's role.** Is Engine the "Application" that walletd hosts? Or does Engine need to be decomposed? Engine is currently ~1800 lines orchestrating everything. At scale, different facets (transaction creation, internalization, key management, certificate handling) might be separate workers.

3. **Ruby's ceiling.** Ruby (MRI) has the GVL. For I/O-bound work (network calls, database queries), fibers and omq handle concurrency well. For CPU-bound work (ECDSA signing at scale), the GVL is a bottleneck unless libsecp256k1 FFI releases it. At extreme scale, the core transaction processing might need to drop to a compiled language. Ruby remains right for now — the architecture should not prevent that migration.

4. **Database as shared state.** Multiple walletd workers sharing a database works for Postgres (connection pooling, row-level locking, UNIQUE constraints). It's less clear for SQLite (single-writer). The store abstraction handles this at the connection level, but the concurrency model differs.

5. **Wallet identity and discovery.** For wallet-to-wallet communication, wallets need to find each other. DNS? DHT? A registry? BRC-28 Paymail hints at this (host discovery via well-known URLs). The identity key is the wallet's address; the discovery mechanism tells you where it's listening.

---

## Guiding Principles for Development

1. **Build surfaces, not the core, for now.** The CLI tools, specs, HTTP layer — these prove the concept and test the machinery. The core (walletd, binary ABI, socket communication) comes when the surfaces have validated the business logic.

2. **Don't block the binary path.** Every interface we build should be a thin translation layer. No business logic in the surface. No assumptions about transport. If a CLI tool embeds logic that should be in Engine, that's a design smell.

3. **The database is truth.** All state is derivable from the database. No in-memory-only state. Crash and restart = scan and resume. This enables horizontal scaling (multiple workers, same database) and crash recovery.

4. **omq is infrastructure, not abstraction.** Use omq directly. Don't wrap it in an abstract "messaging interface" with pluggable implementations. The transport-level pluggability (inproc/ipc/tcp) is sufficient. If someone wants SolidQueue for their Rails app, they wire it up alongside omq — they don't replace it.

5. **The ABI is the real interface.** JSON is convenience. Binary is performance. Design for binary first; derive JSON from it. When the ABI layer lands, it should feel like the natural interface, not an optimization bolted on.

6. **Ruby is the prototype.** It's the right language for now — expressive, fast to develop, rich ecosystem. The architecture should not assume Ruby forever. Clean interfaces between layers (SDK ↔ wallet ↔ walletd ↔ surfaces) mean any layer could be rewritten without disrupting the others.

---

## Related Issues and Work

| Issue | Role |
|-------|------|
| #36 | Daemon — first persistent process, first walletd |
| #128 | ZeroMQ/omq integration and messaging architecture |
| #131 | E2E on-chain test — proves the system works end-to-end |
| #115 | Earlier daemon PR — to be reworked as walletd |
| #133 | Earlier scheduler PR — superseded by this direction |
| bsv-ruby-sdk#493 | UTXO pool concurrency — future walletd workload |

---

**This document captures architectural direction, not implementation detail. It should be carried into future sessions to maintain continuity. The implementation will evolve; the model — wallet as node, not web app — should persist.**
