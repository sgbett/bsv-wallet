# ADR-016: walletd daemon and ZeroMQ-based concurrency

## Status

Accepted.

**Decided:** 2026-05-23 (commit `297c1ab`, PR #161 — "create Daemon with Async reactor hosting"; HLR #156, walletd daemon with OMQ logical models) — the daemon recreated on the Async/ZeroMQ-`omq` substrate after the earlier polling-loop version (PR #89, `81f30fc`, 2026-05-13) was retired; the OMQ messaging architecture itself was settled at HLR #128 (closed 2026-05-20).

## Context

The wallet has no persistent process. Between CLI invocations nothing acts on incomplete database state — pending broadcasts are not retried, proofs are not acquired, status polling never runs. Background work happens only when a CLI tool triggers it inline. The wallet-node model (ADR-002) requires a process that hosts the wallet and drives its background loops; this ADR records that process and the concurrency substrate it runs on.

The substrate question is not "which job queue". The wallet's scaling path (ADR-002) is binary messaging — `inproc://` between fibers, `ipc://` between processes, `tcp://` between machines, the same socket code at every transport, ending in a wallet-to-wallet ABI. A job-queue abstraction answers the background-task question and nothing beyond it; a ZeroMQ messaging layer answers the background-task question *and* is the same primitive the ABI endgame needs. The concurrency decision and the scaling decision are therefore one decision.

The work-discovery question is already answered by ADR-003: state is derived, there is no `status` column to poll. Finding work is a structural predicate over canonical state (`broadcast_at IS NULL`, `tx_proof_id IS NULL`), so the database query *is* the job queue — no queue table, no enqueue-side bookkeeping that could drift from the rows it describes.

## Decision Drivers

* A persistent process must drive the four-phase broadcast lifecycle (ADR-011) and proof acquisition without an inline trigger.
* The concurrency primitive should serve the binary-ABI scaling path (ADR-002), not just background jobs.
* Work discovery must follow the principle of state (ADR-003): a structural query, not a polled status flag.
* The wallet's background workloads are I/O-bound (network round-trips to ARC/Arcade), suiting fiber concurrency over threads or processes.

## Decision

**Run the wallet as a daemon — `walletd`.** `bin/walletd` resolves wallet credentials and constructs `BSV::Wallet::Daemon`, whose `#run!` opens one `Async` reactor (the `async` gem) and boots the background system as peer fibers on it. The two Engine logical models (`Engine::Broadcast`, `Engine::TxProof`; ADR per the physical/logical split) bind their sockets, the SSE listener attaches as a peer fiber when a `callback_token` is configured, and a `Scheduler` runs the discovery loops.

**Use ZeroMQ directly as the concurrency substrate — no abstract scheduler layered on top.** The `omq` gem (a ZMTP-compatible, fiber-native ZeroMQ implementation built on `Async`) is the messaging layer the way Sequel is the database layer: depended on directly, not hidden behind a pluggable interface. The earlier `PollingScheduler` / `Interface::Scheduler` abstractions were deleted; no equivalent remains in `lib`. "Pluggability" is ZeroMQ's transport abstraction (`inproc://` / `ipc://` / `tcp://`), not a Ruby indirection seam.

The socket taxonomy is small and explicit. Three `inproc://` PULL endpoints carry the background queues, one REP endpoint carries the inline request-reply path, and one optional hint receiver binds a caller-supplied path (`ipc://`-capable):

* `inproc://broadcasts.pull` — PULL, bound by `Engine::Broadcast#pull!`; submission *and* resolution both feed it, `#process` routes by `broadcast_at` presence.
* `inproc://broadcasts.rep` — REP, bound by `Engine::Broadcast#reply!`; the inline caller sends an `action_id`, gets a `tx_status` back.
* `inproc://statuses.pull` — PULL, bound by `Engine::Broadcast#statuses_pull!`; the SSE listener fiber PUSHes Marshal-encoded Arcade status events here (ADR-015 is the chain-tracker counterpart cache).
* `inproc://proofs.pull` — PULL, bound by `Engine::TxProof#pull!`.
* hint receiver — PULL, bound by `Engine::Broadcast#hints_pull!` at `BSV_WALLET_HINTS_SOCKET` when set; skipped when nil. The cross-process Atomic-BEEF hint path.

The producer side connects PUSH: the Scheduler's loops PUSH IDs to the pull endpoints, and the SSE listener PUSHes to `inproc://statuses.pull`.

**Background tasks are idempotent and stateless; the canonical query is the job queue.** Each `Scheduler` loop calls a `.pending*` discovery query — `Engine::Broadcast.pending_submissions` / `.pending_resolutions`, `Engine::TxProof.pending` — each a structural predicate over canonical state (per ADR-003), and PUSHes the returned IDs. There is no queue table and no status column; re-running a discovery query simply re-finds whatever rows still match. `#process` on both models re-reads the row and decides afresh, so redelivery is safe (a `tx_proof_id`-already-present row skips; an already-resolved broadcast no-ops).

**The framework owns the clock; tasks own their retry.** `Scheduler#schedule` owns cadence — `broadcast_submission` every 5 s, `broadcast_resolution` every 30 s, `proof_acquisition` every 30 s — and the cooperative drain (an `on_event` observer counts `task.dispatched` minus the four terminal events; `#shutdown` waits for the counter to reach zero). What to do on failure lives in the task: `Engine::Broadcast` clears `broadcast_at` on 503 backpressure and bumps `retry_count` on the no-send-descendant guard, leaving the row for the next discovery pass; `SSEListener` owns its own `RECONNECT_DELAY` and cursor-replay resumption. The Scheduler never encodes a per-task retry policy.

**This is concurrency infrastructure toward the scaling goal (ADR-002), not merely background jobs.** The same `omq` sockets that carry `inproc://` fiber traffic today carry `ipc://` between processes and `tcp://` between machines unchanged — the substrate for the wallet-to-wallet binary ABI, of which the optional `ipc://` hint receiver is the first cross-process use.

**Architectural components affected:** `bin/walletd`; `Daemon` (reactor host); `Scheduler` (discovery loops, clock, drain); `Engine::Broadcast` / `Engine::TxProof` (logical models, socket owners); `Network::SSEListener` (peer fiber, own retry); the `omq` runtime dependency.

## Alternatives Considered

### A. A job-queue dependency (Sidekiq / SolidQueue) behind an abstract scheduler
**Pros:** familiar; mature retry/scheduling machinery; a stored job table gives trivial `WHERE status = …` discovery.
**Cons:** a stored job queue is exactly the drifting status column ADR-003 rejects, duplicating canonical state in a second store; it answers only the background-task question and contributes nothing to the binary-ABI path (ADR-002), so the messaging substrate would still have to be built alongside it; an abstraction seam over it earns nothing — there is one messaging layer, not a field of candidates.
**Rejected** — `omq` *is* the messaging layer, like Sequel is the database layer; the discovery query is the queue.

### B. Thread-pool or process-pool workers instead of fibers
**Pros:** parallelism across CPU cores for compute-bound work.
**Cons:** the workloads are I/O-bound (ARC/Arcade round-trips), where fibers on one reactor thread are the better fit and avoid GVL contention; heavy crypto is FFI and releases the GVL regardless. Threads would also reintroduce the application-level locking ADR-003 designs out.
**Rejected** — fiber concurrency on the `Async` reactor matches the I/O-bound shape; `bin/walletd` enables Sequel's `fiber_concurrency` so each fiber checks out its own connection.

### C. Keep inline-only background work (no daemon)
**Pros:** no new process to operate.
**Cons:** incomplete state is only ever advanced when a CLI tool happens to run; a broadcast accepted with no later invocation never gets its proof, and a 503-deferred submit never retries. ADR-002's wallet-node model requires a persistent host.
**Rejected** — the daemon is the first persistent process and the foundation the scaling path builds on.

## Consequences

### Positive

* Incomplete database state is driven forward continuously: broadcasts retried, statuses resolved, proofs acquired, with no inline trigger.
* The concurrency substrate is the same primitive the binary-ABI endgame needs (ADR-002); `inproc://` → `ipc://` → `tcp://` is an endpoint change, not a rewrite.
* No queue table to drift from canonical state — discovery is a structural query (ADR-003), so a deleted-and-rebuilt daemon re-finds identical work.
* Redelivery is safe because tasks are idempotent and re-read the row; the cooperative drain bounds shutdown.

### Negative

* A persistent process to deploy and operate, with its own connection-pool sizing (`daemon_pool_size`) that must track Postgres `max_connections`.
* `omq` is a comparatively young dependency relative to an established job-queue gem; the bet is that owning the messaging layer outright is worth more than mature retry machinery the design does not want.
* `Marshal` is the in-process wire encoding on the statuses and hint sockets — chosen to keep binary `wtxid` / `merkle_path` binary across the bus, at the cost of a documented trust boundary on any writable socket inode (the `ipc://` hint path).
* Polling discovery loops still issue periodic queries at idle; the SSE push path (ADR-015 territory) narrows but does not remove the resolution poll.

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

The high-risk move would be reaching for a heavyweight job-queue dependency and wrapping it in a pluggable scheduler interface — and the design does the opposite: it deletes the abstraction (`PollingScheduler` / `Interface::Scheduler` are gone) and depends on the messaging layer directly, the same way it depends on Sequel. That is the cheaper, not the more elaborate, choice. The complexity that remains — a daemon, a fiber reactor, a five-socket taxonomy — is the irreducible cost of having any persistent background process at all, and the socket count is small and named, not a sprawling topology. Using ZeroMQ rather than a job queue is justified twice over: it satisfies the background-task need *and* is the binary-ABI substrate (ADR-002), so it is not paying for unused capability. The one genuine forward bet is `omq`'s relative youth versus a mature queue gem; that bet is conscious and rides on the same scaling aim ADR-002 names as load-bearing. Discovery-as-structural-query is a direct consequence of ADR-003, not new surface area. **Approve.**

## Validation

* `bin/walletd` boots a `Daemon`, runs the background system, and exits cleanly on SIGINT/SIGTERM (trap flips a flag; a watcher thread drives the off-trap drain).
* `omq` is a runtime dependency; `Engine::Broadcast` and `Engine::TxProof` own their PULL sockets; the Scheduler's loops PUSH discovered IDs to them.
* No `status`/queue table backs discovery — `.pending_submissions` / `.pending_resolutions` / proof `.pending` are structural-predicate queries over canonical state.
* Retry policy lives in the tasks (`increment_broadcast_retry`, `clear_broadcast_attempted`, `SSEListener` reconnect), not in the Scheduler; the Scheduler owns interval and the cooperative drain.
* No `PollingScheduler` / `Interface::Scheduler` remains in `lib`.

## References

* ADR-002 — design for BSV scale / the wallet-node model; ZeroMQ as scale infrastructure, the binary-ABI endgame this substrate serves.
* ADR-003 — the principle of state; query-is-job-queue follows from derived (not stored) state, no status column to poll.
* ADR-011 — the four-phase broadcast lifecycle this daemon drives (submission, resolution, promotion).
* ADR-015 — the chain-tracker as a daemon-driven write-through cache; the SSE statuses path is its push-side counterpart.
* HLR #156 (walletd daemon with OMQ logical models and scheduler), #128 (ZeroMQ / `omq` messaging architecture).
* `gem/bsv-wallet/lib/bsv/wallet/daemon.rb`, `scheduler.rb`, `engine/broadcast.rb`, `engine/tx_proof.rb`, `engine/omq_support.rb`, `events.rb`; `network/sse_listener.rb`; `bin/walletd`. `omq` v0.27.0.