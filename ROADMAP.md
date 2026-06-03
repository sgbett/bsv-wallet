# BSV Wallet — Roadmap

A living document. Tracks where the wallet is heading, what is in flight, and which architectural decisions are made vs deferred. Issue numbers link to the canonical record on GitHub; this file is the at-a-glance overview.

The order is opinionated. Items inside a horizon do not all have to land before the next horizon begins, but they should land in roughly the listed sequence — earlier items are dependencies or foundations for later ones.

## Status of the foundations

The single-process wallet runtime is now intact:

- `Engine` exposes 26/28 BRC-100 methods, orchestrating the four-phase action lifecycle (lock, sign/stage, broadcast, promote).
- `Store` owns multi-table atomicity; the Postgres schema uses bytea everywhere hash-shaped, native UUIDs, ENUMs, CHECKs, RESTRICT FKs, and a `prevent_outbound_spendable` trigger.
- `Daemon` runs a persistent process with engine logical models (`Engine::Broadcast`, `Engine::TxProof`) plus a `Scheduler` that fans out discovery work over OMQ inproc PUSH/PULL.
- Structured event emission (`BSV::Wallet.emit`) is the observability surface; per-event log sinks are wired (#231), and `Scheduler#shutdown(timeout:)` (#230) drives a cooperative drain on SIGTERM.
- Multi-wallet identity is per-process via `.env` (`DATABASE_URL_ALICE`, `BSV_WALLET_WIF_ALICE`, etc.).

What is NOT yet intact: anything that talks to non-Ruby callers, anything that survives a chain re-org, anything that batches transactions, and anything that scales horizontally. Those are the horizons below.

## Horizon 1 — Prove the wallet against the chain

The point: real broadcasts reach ARC, real proofs confirm, real edge cases (rejection, re-org) are handled without state going to limbo. Until this is done, every other improvement is theoretical.

- **#126 — E2E on-chain test: broadcast + sweep + observability.** The big lift. Drives the wallet end-to-end against testnet: createAction → broadcast → wait for proof → internalize → assert state invariants. The drain API (#230, landed) is the prerequisite — Phase 4 sweep cannot race with in-flight work.
- **#132 — Scheduled on-chain liveness smoke (CI).** Once #126 has bones, a cheaper subset runs on a cron to catch SDK or ARC regressions between full e2e runs.

## Horizon 2 — Tighten the engine

The orchestrator is 2,120 lines of procedural lifecycle code with shared state and no structure. It works, but it is hard to extend, hard to test in isolation, and hard to reason about under concurrency. This horizon makes it boring.

- **#214 — `Engine::Action` logical model.** Encapsulate the four-phase lifecycle in a single object with explicit state transitions. This is the architectural unlock for #213, #60, and #192 — they each become small once `Engine::Action` exists.
- **#213 — Retry Phase 1 lock on contention.** TOCTOU between selection and lock currently raises `InsufficientFundsError`. With `Engine::Action` in place, the retry loop is a state transition rather than a procedural patch.
- **#60 — Wallet decides, constraints enforce.** Eliminate inference patterns (`promote_with_outputs`, `resolve_internalize_output` peering at field presence). Wallet decides intent; the schema enforces. Becomes a refactor of named state on `Engine::Action`.
- **#192 — noSend / sendWith chained-send and batching.** BRC-100 feature gap. Chained construction of multiple transactions before broadcast, atomic delivery. Maps cleanly onto `Engine::Action` once it owns lifecycle.
- **#64 — Test split: engine intent vs store invariants.** Today the 3,000-line `engine_spec.rb` conflates "did the wallet decide right?" with "is the schema consistent?" Split mirrors the responsibility split we already have in code.

## Horizon 3 — Open the wallet to the world

The Engine is callable from Ruby only. Every reference SDK ships an HTTP surface that any BRC-100 client (TS `WalletClient`, Go `HTTPWalletJSON`, Py `WalletWireTransceiver`, MetaNet Desktop) can drive. Without this, no external integration is possible.

- **#180 — Multi-adapter BRC-100 API surfaces.** One Engine, multiple call shapes: in-process Ruby (today), JSON adapter (`(args, originator)` with nested `options`), wire-encoded transport. Each adapter is a thin translation layer; the Engine stays canonical.
- **#181 — Conformance suite for the multi-adapter API.** Shared RSpec examples that every adapter must satisfy, so semantics stay identical across surfaces.
- **#223 — Expose Engine over BRC-103 HTTP (Rack server).** Concrete deliverable of #180: a Rack app that maps HTTP/BRC-103 to Engine calls with proper error-code translation. Unblocks MetaNet Desktop and every non-Ruby BRC-100 client.

## Horizon 4 — Feature breadth

Once the engine surface is stable internally and externally, fill the BRC-100 feature gaps that reference SDKs already ship.

- **#224 — Engine-backed features: LocalKVStore, StorageUploader, certificate issuance and discovery.** These all need an Engine (they pay for outputs, persist state, write certificate data), so they belong in the wallet rather than the SDK.
- **#114 — Automate WBIKD address scanning via daemon.** Blocked on re-frame: address scanning is a concrete task definition on the pluggable async-task framework, not a daemon callable.

## Horizon 5 — Scale out

This is where the multi-process discussion lives. Today the wallet is one process: one reactor, one OMQ inproc transport, all engines and the scheduler sharing fibers. That is the right shape for getting to Horizons 1–4 — simpler ops, no inter-process plumbing, faster iteration.

The scaling target (BSV's millions-TPS claims) does not require us to abandon Ruby or the single-process model immediately. The hot path is C — ECDSA, SHA256, Postgres protocol, OMQ socket recv, `io-event` for the scheduler — and Ruby is glue. The GIL barely costs us throughput on IO-bound and crypto-bound work. The throughput ceiling on MRI is the database, the network, and ARC. Not the language.

What we will need eventually:

### Process-per-concern, OMQ over IPC

Split the daemon into supervised processes — broadcast worker, proof worker, optionally a dedicated scheduler — coordinated by OMQ. Three transport tiers:

- **inproc** — engine ↔ store inside a single worker process. Fastest, no overhead beyond a function call.
- **ipc** — between worker processes on one machine. Unix domain sockets, kernel-level fast, no network stack.
- **tcp** — wire calls (ARC HTTP) and eventually cross-machine OMQ.

Each worker has clean process boundaries that already match the logical concern boundaries (`Engine::Broadcast`, `Engine::TxProof`). A worker crash isolates; redeploy and scale per concern. The cooperative drain (#230) is what makes this safe under supervisor-initiated restarts.

Two open design choices at split time:

1. **Who owns discovery?** A dedicated scheduler process fans out via OMQ PUSH/PULL, or each worker pulls from Postgres directly with `SELECT … FOR UPDATE SKIP LOCKED`, or a middle path uses Postgres `LISTEN/NOTIFY` to wake workers without a broker process. Trade-off: dispatch latency vs broker SPOF.
2. **Reply sockets.** `Engine::Broadcast#reply!` is the request/response side (BRC-100 createAction → engine). Splitting the REP socket into its own "API surface" process keeps the inbound API separate from the outbound work.

### Supervisor: Foreman/Overmind vs async-container

- **Foreman/Overmind** — Procfile-driven, language-agnostic, well-understood ops. Fine for dev and small prod.
- **`async-container`** — Ioquatix's Async-native supervisor. Supports forked processes (`Container::Forked`) with real OS isolation, hybrid forked+threaded mode, and integrates with the reactor's stop semantics. Better signal handling for reactor-hosting processes; Ruby-only.

If every supervised process is Ruby+Async, `async-container` is the more native fit. If a non-Ruby helper enters the mix, Foreman/Overmind wins on portability.

### Ruby implementation: stay on MRI

JRuby and TruffleRuby remove the GIL, but the throughput win is in-process parallelism — which we get from forked processes anyway. The cost is gem compatibility risk (the load-bearing extensions are `omq`, `io-event`, `pg`, BSV crypto bindings), higher memory floor, longer startup, and harder ops. Not worth it until profiling shows pure-Ruby code is the bottleneck. It is not.

The day TruffleRuby's GraalVM JIT measurably speeds up BSV script interpretation and that becomes the bottleneck — reconsider. Not before.

## Continuous

- **#227 — AI reviewer guidance.** Keep `.github/copilot-instructions.md` and the architecture team docs aligned with the code as it evolves.
- **Documentation accuracy.** `DESIGN.md` is the canonical architectural narrative; `README.md` is the entry point; this file is the schedule. When a horizon lands, update DESIGN to reflect the new normal and prune this file's "Status of the foundations."

## How to read this file

- **Horizons are ordered.** Earlier items unblock later ones; do not jump ahead unless the dependency analysis says otherwise.
- **Inside a horizon, items can run in parallel** if the dependency graph allows.
- **Continuous work runs alongside any horizon.**
- **Architectural decisions deferred** (e.g. JRuby/TruffleRuby, async-container vs Foreman) are listed so we do not re-litigate them every quarter without new evidence.
