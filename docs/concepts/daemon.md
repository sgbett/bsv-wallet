---
title: Daemon
parent: Concepts
nav_order: 10
---

# The Daemon (`walletd`)

Broadcasting a transaction and waiting for it to be mined is slow, and it can fail in ways that need patient retrying. Forcing the foreground caller to block on that would make the wallet unusable for anything high-throughput. So the wallet pushes all of it into an optional background process, `walletd`, and the foreground `Engine` simply records *intent* (a `:delayed` action) and returns immediately.

This page is the **architectural** view — the runtime model, the producer/consumer pattern, the discovery cadences, the OMQ topology, and the sizing knobs that shape throughput. For operator-facing instructions — how to run it, where to put keys, what to monitor, which production flags are foot-guns — see [Operating the daemon](../guides/operating-the-daemon.md).

## What it does

`walletd` is responsible for everything that happens to a transaction *after* the wallet decides to send it:

- **Submission** — picking up queued (`:delayed`) actions and broadcasting them via `Network::Broadcaster`.
- **Resolution** — driving in-flight broadcasts to a terminal outcome (accepted → write promotion; rejected → cascade-unwind), either by polling `:get_tx_status` or by consuming the live SSE status stream.
- **Proof acquisition** — once a transaction is mined, fetching its merkle proof and linking it to the action so the action becomes `:completed`.
- **Reaping** — clearing abandoned actions (locked inputs but never sealed) so their UTXOs return to the pool.

Notably, the daemon needs only a `Store` and a `Network::Broadcaster` — **not** an `Engine` or a `KeyDeriver`. It moves existing actions through their lifecycle; it never creates or signs them. That keeps the most security-sensitive component (the key) out of the long-running process entirely.

## Runtime model: one reactor, cooperative fibres

`Daemon#run!` starts an [Async](https://github.com/socketry/async) reactor and boots the worker fibres inside it:

```ruby
Async do |task|
  broadcast = Engine::Broadcast.new(store:, broadcaster:,
                                    callback_token:, hydrated_tx_cache:)
  broadcast.pull!(task: task)           # PULL  — delayed-submission queue
  broadcast.reply!(task: task)          # REP   — inline broadcast
  broadcast.statuses_pull!(task: task)  # PULL  — Arcade SSE status events
  broadcast.hints_pull!(task: task,
                        socket_path: hints_socket)  # PULL — cross-process hints

  tx_proof = Engine::TxProof.new(store:, broadcaster:, hydrator:)
  tx_proof.pull!(task: task)            # PULL  — proof queue

  reaper = Engine::Reaper.new(store:)
  reaper.pull!(task: task)              # PULL  — reaper queue

  start_sse_listener(task: task) if @callback_token

  Scheduler.new(store:).run!(task: task) # discovery loops
end
```

Everything runs as cooperative fibres in a single reactor — no thread pool, no shared-memory locking on the hot path. Concurrency comes from fibres yielding on I/O, which suits a workload that is almost entirely "wait on the network". The one `Mutex` in `HydratedTxCache` is uncontended under Async: a single-threaded reactor only ever has one fibre running at a time, so the acquire never parks.

## Producer/consumer over OMQ

The daemon is structured as a classic **producer/consumer** split, communicating over in-process [OMQ](https://rubygems.org/gems/omq) sockets:

```
   Scheduler (producer)                 Consumer fibres
  ┌─────────────────────┐              ┌────────────────────────────────────┐
  │ broadcast_submission│──┐           │ Engine::Broadcast                  │
  │ broadcast_resolution│──┼─ IDs ───▶ │   inproc://broadcasts.pull          │
  │                     │  │           │   inproc://broadcasts.rep           │
  │                     │  │           │   inproc://statuses.pull   (events) │
  │                     │  │           │   inproc://hints.pull      (hints)  │
  │                     │  │           └────────────────────────────────────┘
  │ proof_acquisition   │──┤           ┌────────────────────────────────────┐
  │                     │  └─ IDs ───▶ │ Engine::TxProof  inproc://proofs.pull│
  │ reaper              │──── IDs ───▶ │ Engine::Reaper   inproc://reaper.pull│
  └─────────────────────┘              └────────────────────────────────────┘
                              ▲
                              │  Marshal-encoded events
   Network::SSEListener ──────┘
   (Arcade SSE stream)
```

The **Scheduler** runs discovery loops that query the `Store` for pending work and push the matching IDs onto a PULL socket. The **worker fibres** (`Engine::Broadcast`, `Engine::TxProof`, `Engine::Reaper`) bind those sockets and process each ID as it arrives. The two sides are decoupled: discovery does not wait for processing, and processing does not poll the database for what to do next.

Binding is guarded by `Engine::OmqSupport#bind_or_die`, which emits a structured `fiber.crashed` event and re-raises if a socket cannot be bound — without it, a bind failure (say, an endpoint already taken) would leave the daemon silently deaf.

## The discovery loops

`Scheduler#run!` starts **four** loops, each at a cadence matched to how urgent its work is:

| Loop | Interval | Discovers | Why this cadence |
|------|----------|-----------|------------------|
| `broadcast_submission` | **5 s** | actions with `broadcast_at IS NULL` | Users are waiting for outputs to become spendable — this is the responsive path, kept fast. |
| `broadcast_resolution` | **30 s** | attempted, non-terminal broadcasts | The wallet has already moved on (outputs speculatively promoted), so slower polling is fine and avoids load. |
| `proof_acquisition` | **30 s** | actions with a `wtxid` but no proof | Proofs settle on block timescales; there is no point polling faster. |
| `reaper` | **60 s** | actions older than `reap_threshold` with no promotion | Cleanup is not latency-sensitive; run slowly off the broadcast hot path. |

Both broadcast loops feed the **same** `broadcasts.pull` socket. `Engine::Broadcast#process` then routes each ID by inspecting `broadcast_at`: absent means "first attempt — submit", present means "in flight — poll status". One consumer, two behaviours, selected by structural state.

## Submission, resolution, proof, hints

`Engine::Broadcast` is where the [crash-recovery invariant](resilience-and-recovery.md) lives: `submit` stamps `broadcast_at` in a committed transaction *before* the network POST through `Network::Broadcaster`, and `record_broadcast_result` writes the `promotions` row atomically with recording an accepted status. Resolution polls `Broadcaster#get_tx_status` and, on a terminal rejection, calls `reject_action` to cascade-unwind. The ARC status vocabulary (`ACCEPTED_STATUSES`, `REJECTED_STATUSES`) is centralised in `BSV::Wallet::ArcStatus`, the single source of truth across the wallet.

Polling is the default, but ARC providers can also *push*. When a daemon is configured with a `callback_token`, `Network::SSEListener` is started as a peer fibre and subscribes to the live Arcade event stream. Each event is Marshal-encoded and PUSHed onto `inproc://statuses.pull`, where `Engine::Broadcast#statuses_pull!` consumes it through the same `Store::EventApplicator` the polling path uses. Cursor state lives in the `sse_cursors` table; on reconnect the listener sends `Last-Event-ID` and resumes without loss or duplication.

Alongside the fire-and-forget PULL queue, `Engine::Broadcast` also binds a **REP** socket (`broadcasts.rep`). This is the synchronous path: an `:inline` action gets broadcast within the originating call rather than handed to the discovery loop — same `process` method, reached request/reply instead of queue.

`Engine::TxProof#process` fetches a transaction's status through `Broadcaster#get_tx_status` and, once it carries both a `merkle_path` and a `block_height`, normalises the proof to BRC-74 binary form via `Engine::MerklePathNormaliser`, saves it, and links it to the action. Linking the proof is what flips the action to `:completed`, and the shared `Engine::HydratedTxCache` is updated so later BEEF walks see the new proof immediately.

`Engine::Broadcast#hints_pull!` is opt-in: a producer outside the daemon (a CLI tool, an API) that has already built an Atomic BEEF can hint that to the daemon over a Unix socket (`BSV_WALLET_HINTS_SOCKET`), warming `HydratedTxCache` so the broadcast worker skips the `resolve_inputs_for_signing` JOIN at submit time.

## Sizing knobs

The daemon's hot path is sized by four environment variables. Defaults are calibrated for a single-wallet sustained-spend workload; turn them up for higher concurrency or bigger working sets.

| Variable | Default | Effect |
|----------|---------|--------|
| `BSV_WALLET_TX_CACHE_SIZE` | `20000` | Capacity (in entries) of `Engine::HydratedTxCache`, the shared wtxid-keyed cache that hydrated transactions live in across `Broadcast`, `TxProof`, and `Transmission`. Larger = fewer rehydrations at the cost of resident memory. |
| `BSV_WALLET_DAEMON_SEQUEL_CONNECTIONS` | `16` | Size of the Sequel connection pool, sized in coordination with Async's `fiber_concurrency` extension so each running fibre can hold its own connection without serialising. Floor for sustained concurrency, not a max-clients knob. |
| `BSV_WALLET_REAP_THRESHOLD_S` | `3600` | Age (seconds) past which the reaper deletes unpromoted actions. Lower = aggressive UTXO release; higher = more tolerant of long-running deferred signing flows. |
| `BSV_WALLET_FEE_RATE_SATS_PER_KB` | `100` | Default fee rate. The same value is used by `estimate_sweep_fee` and the funding loop's `SatoshisPerKilobyte` model, so the wallet never charges more or less than it quotes. |

## Shutdown and lifecycle

The daemon shuts down cooperatively: signal traps (which cannot use `Mutex` or `sleep`) flip a stop flag, and a watcher thread off-trap stops the SSE listener, drains in-flight fibres up to a timeout, and halts the reactor. `stop!` is idempotent. The lifecycle is bracketed by `daemon.started` / `daemon.stopped` events; see [Events & Observability](events.md).

For an operational walkthrough of running the process, secrets handling, the SSRF defence envelope, and the production foot-guns to audit before deploying, see [Operating the daemon](../guides/operating-the-daemon.md).
