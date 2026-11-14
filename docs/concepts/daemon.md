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
- **Resolution** — driving in-flight broadcasts to a terminal outcome (any status short of rejection → promotion; rejected → cascade-unwind), either by polling `:get_tx_status` or by consuming the live SSE status stream.
- **Proof acquisition** — once a transaction is mined, fetching its merkle proof and linking it to the action so the action becomes `:completed`.
- **Reaping** — clearing abandoned actions (inputs locked, but never signed or promoted) so their UTXOs return to the pool.

`BSV::Wallet::Daemon` is built from a `Store` and a `Network::Broadcaster`, **not** an `Engine`. It moves existing actions through their lifecycle; it never creates or signs them. The `walletd` process still reads the WIF at boot: it builds a `KeyDeriver` to derive the identity public-key hash that `Store#verify_schema!` checks, and derives the Arcade callback token from the WIF (`CallbackToken.derive`). The key is therefore in the daemon's memory, though no worker signs with it.

## Runtime model: one reactor, cooperative fibres

`Daemon#run!` starts an [Async](https://github.com/socketry/async) reactor and boots the worker fibres inside it:

```ruby
Async do |task|
  broadcast = Engine::Broadcast.new(store:, broadcaster:,
                                    callback_token:, hydrated_tx_cache:)
  broadcast.pull!(task: task)           # PULL  — delayed-submission queue
  broadcast.reply!(task: task)          # REP   — request/reply by action ID
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

The daemon is structured as a classic **producer/consumer** split, communicating over [OMQ](https://rubygems.org/gems/omq) sockets. All of them are in-process (`inproc://`) except the optional hints socket, which other processes reach:

| Producer | Message | Consumer | Socket |
|---|---|---|---|
| Scheduler: `broadcast_submission`, `broadcast_resolution` | action IDs | `Engine::Broadcast#pull!` | `inproc://broadcasts.pull` |
| none in the wallet today | an action ID, answered with its `tx_status` | `Engine::Broadcast#reply!` | `inproc://broadcasts.rep` |
| `Network::SSEListener` (Arcade SSE stream) | Marshal-encoded status events | `Engine::Broadcast#statuses_pull!` | `inproc://statuses.pull` |
| other processes' Engines (optional) | Atomic BEEF hints | `Engine::Broadcast#hints_pull!` | the `BSV_WALLET_HINTS_SOCKET` endpoint |
| Scheduler: `proof_acquisition` | action IDs | `Engine::TxProof#pull!` | `inproc://proofs.pull` |
| Scheduler: `reaper` | action IDs | `Engine::Reaper#pull!` | `inproc://reaper.pull` |

The **Scheduler** runs discovery loops that query the `Store` for pending work and push the matching IDs onto a PULL socket. The **worker fibres** (`Engine::Broadcast`, `Engine::TxProof`, `Engine::Reaper`) bind those sockets and process each ID as it arrives. The two sides are decoupled: discovery does not wait for processing, and processing does not poll the database for what to do next.

Binding is guarded by `Engine::OmqSupport#bind_or_die`, which emits a structured `fiber.crashed` event and re-raises if a socket cannot be bound — without it, a bind failure (say, an endpoint already taken) would leave the daemon silently deaf.

## The discovery loops

`Scheduler#run!` starts **four** loops, each at a cadence matched to how urgent its work is:

| Loop | Interval | Discovers | Why this cadence |
|------|----------|-----------|------------------|
| `broadcast_submission` | **5 s** | `broadcasts` rows with `broadcast_at IS NULL` | Users are waiting for outputs to become spendable — this is the responsive path, kept fast. |
| `broadcast_resolution` | **30 s** | attempted, non-terminal broadcasts | The wallet has already moved on (outputs speculatively promoted), so slower polling is fine and avoids load. |
| `proof_acquisition` | **30 s** | signed actions with a broadcast intent other than `none` and no proof | Proofs settle on block timescales; there is no point polling faster. |
| `reaper` | **60 s** | actions older than `reap_threshold` with no promotion and no `broadcasts` row, except signed ones with intent `none` | Cleanup is not latency-sensitive; run slowly off the broadcast hot path. |

Both broadcast loops feed the **same** `broadcasts.pull` socket. `Engine::Broadcast#process` then routes each ID by inspecting `broadcast_at`: absent means "first attempt — submit", present means "in flight — poll status". One consumer, two behaviours, selected by structural state.

## Submission, resolution, proof, hints

`Engine::Broadcast` is where the [crash-recovery invariant](resilience-and-recovery.md) lives: `submit` stamps `broadcast_at` in a committed transaction *before* the network POST through `Network::Broadcaster`, and `Store#record_broadcast_result` writes the `promotions` row in the same database transaction as any status short of rejection (speculative promotion, which a later rejection unwinds). Resolution polls `Broadcaster#get_tx_status` and, on a terminal rejection, calls `reject_action` to cascade-unwind. The ARC status sets (`ArcStatus::ACCEPTED`, `ArcStatus::REJECTED`, `ArcStatus::TERMINAL`) are centralised in `BSV::Wallet::ArcStatus`, the single source of truth across the wallet.

Polling always runs, but Arcade can also *push*. When the daemon has a `callback_token` (`bin/walletd` always derives one from the WIF), `Network::SSEListener` is started as a peer fibre and subscribes to the live Arcade event stream. Each event is Marshal-encoded and PUSHed onto `inproc://statuses.pull`, where `Engine::Broadcast#statuses_pull!` hands it to `Store::EventApplicator`, which makes the same `Store` writes as the polling path. The listener records the last event it handed on in the `sse_cursors` table and, on reconnect, sends it as `Last-Event-ID` so Arcade replays from there; the polling loop remains the backstop for anything the stream misses.

Alongside the fire-and-forget PULL queue, `Engine::Broadcast` also binds a **REP** socket (`inproc://broadcasts.rep`) that runs `process` for an action ID and replies with its `tx_status`. Nothing in the wallet sends to it today. An `:inline` broadcast doesn't go through the daemon: the caller's own Engine runs `Engine::Broadcast#process` in the caller's process.

`Engine::TxProof#process` fetches a transaction's status through `Broadcaster#get_tx_status` and, once it carries both a `merkle_path` and a `block_height`, normalises the proof to BRC-74 binary form via `Engine::MerklePathNormaliser`, saves it, and links it to the action. Linking the proof is what flips the action to `:completed`, and the shared `Engine::HydratedTxCache` is updated so later BEEF walks see the new proof immediately.

`Engine::Broadcast#hints_pull!` is opt-in. When `BSV_WALLET_HINTS_SOCKET` is set, `walletd` binds that `ipc://` Unix socket, and an Engine in another process (a `bin/wallet` command, an API) pushes the Atomic BEEF of each action it dispatches for broadcast. `walletd` caches the raw-transaction bytes of every full transaction in the hint under its wtxid in `HydratedTxCache`, so the broadcast worker finds the parents there at submit time and skips the `resolve_inputs_for_signing` JOIN. It never caches a hint's merkle paths, which it has not verified. Hints are best-effort: a missed one costs only the JOIN.

Each hint is an `Engine::HintEnvelope`: one frame holding a version byte, the action ID as an unsigned 64-bit integer and the BEEF, capped at 32 MiB. It is data only, so `walletd` parses it and never deserialises an object from it, and drops a malformed or oversized message with a warning. The socket queues at most 16 hints, so a fast sender waits rather than filling memory.

{: .warning }
> **Only the wallet's own processes may reach the hints socket**
>
> The hints socket is unauthenticated. `Engine::HintsEndpoint` refuses a `tcp://` endpoint, a Linux abstract socket (`ipc://@name`), a socket whose directory another user owns or can write to, and a path where anything but a stale socket of the user's own already sits, and creates the socket file owner-only (#556). A refusal crashes only the hints fibre, with a `fiber.crashed` event that names the reason; the rest of `walletd` runs on without hints.

## Sizing knobs

The daemon's hot path is sized by three environment variables. Defaults are calibrated for a single-wallet sustained-spend workload; turn them up for higher concurrency or bigger working sets. The full list of settings is in [Installation & Configuration](../getting-started/installation.md#tuning-knobs).

| Variable | Default | Effect |
|----------|---------|--------|
| `BSV_WALLET_TX_CACHE_SIZE` | `20000` | Capacity (in entries) of `Engine::HydratedTxCache`, the wtxid-keyed cache of raw-transaction and merkle-path bytes. In `walletd`, `Broadcast` reads it for its EF build and fills it from hints and eager proofs, and `TxProof` fills it through the Hydrator when a proof arrives. Larger = fewer store reads at the cost of resident memory. |
| `BSV_WALLET_DAEMON_SEQUEL_CONNECTIONS` | `16` | Size of the Sequel connection pool, sized in coordination with Sequel's `fiber_concurrency` extension so each running fibre can hold its own connection without serialising. Floor for sustained concurrency, not a max-clients knob. |
| `BSV_WALLET_REAP_THRESHOLD_S` | `3600` | Age (seconds) past which the reaper deletes an abandoned action (see the `reaper` loop above). Lower = aggressive UTXO release; higher = more tolerant of long-running deferred signing flows. |

## Shutdown and lifecycle

The daemon shuts down cooperatively: signal traps (which cannot use `Mutex` or `sleep`) flip a stop flag, and a watcher thread off-trap stops the SSE listener, drains in-flight fibres up to a timeout, and halts the reactor. `stop!` is idempotent. The lifecycle is bracketed by `daemon.started` / `daemon.stopped` events; see [Events & Observability](events.md).

For an operational walkthrough of running the process, secrets handling, the SSRF defence envelope, and the production foot-guns to audit before deploying, see [Operating the daemon](../guides/operating-the-daemon.md).
