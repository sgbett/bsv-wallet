---
title: Events
parent: Reference
nav_order: 7
---

# Events — wire format and taxonomy

> Canonical reference for the wallet's structured-event emission. The line format, the payload conventions, and the taxonomy below are normative — specs cite this page, and operator tooling parses against it.
>
> For the narrative shape — why a bus, what the failed/aborted/skipped distinction means, how the events form a daemon-shutdown control plane — see [Events (concepts)](../concepts/events.md).

## Emit API

```ruby
BSV::Wallet.emit(name, **payload)
```

Writes a single line:

```
[event] <name> key=value key=value ...
```

The implementation lives in `gem/bsv-wallet/lib/bsv/wallet/events.rb`. The emit short-circuits when no sink and no observer are registered.

### Payload conventions

- **No secrets.** Never include WIFs, raw transaction bytes, BEEF blobs, or any cryptographic material.
- **No binary.** All values must be human-readable strings or numbers.
- **No spaces in values.** Use underscored identifiers (`action_not_found`, not `action not found`). The helper quotes values containing whitespace as a safety net, but callers must normalise.
- **Nil values are omitted.** A nil payload value produces no `key=` field in the output.
- **Symbols stringify.** `outcome: :accepted` renders as `outcome=accepted`.

### Sinks

Three destinations fan out from one emit:

- **`BSV.logger`** — SDK-level logger; event lines interleave with `[Store]` / `[Engine]` / `[Protocol]` debug output.
- **`BSV::Wallet.event_log`** — opt-in wallet-scoped sink; `EVENT_LOG_FORMATTER` strips the standard Logger prefix and emits a clean `<ISO-8601> [event] name key=value` line.
- **Observer registry** — in-process callables registered with `on_event`, removed with `off_event`. Observers run synchronously on the emitting fibre; an observer that raises is caught at `:warn` and the remaining observers still run.

## Taxonomy

Ten canonical events across three layers.

### Daemon lifecycle (2 events)

| Event | Payload | When |
|---|---|---|
| `daemon.started` | `wallet` `network` | End of `Daemon#run!` setup, after all fibres are scheduled |
| `daemon.stopped` | `reason` `drained` | In `Daemon#stop!`, after the Scheduler's drain and before the reactor halts |

`reason` values: `signal` (SIGINT/SIGTERM). `drained` is `true` when in-flight tasks settled before the shutdown timeout and `false` when the timeout fired first.

### Fibre lifecycle (1 event)

| Event | Payload | When |
|---|---|---|
| `fiber.crashed` | `task` `error` | Unrecoverable `StandardError` escapes a fibre — bind failure or processing error |

`error` is the first line of the exception message (newlines stripped). Emitted by:

- **OMQ bind failures** — `bind_or_die` (the `OmqSupport` module) in `Engine::Broadcast#pull!`, `#reply!`, `#statuses_pull!` and `#hints_pull!`, `Engine::TxProof#pull!` and `Engine::Reaper#pull!`. Fires when a socket can't bind, for example because its endpoint is already bound, or because `Engine::HintsEndpoint` refuses the hints socket's endpoint.
- **Scheduler discovery loops** — on unhandled exceptions during discovery or enqueue. The loop carries on to its next cycle.
- **TxProof PULL handler** — on unhandled exceptions during message processing.

### Task lifecycle (7 events)

| Event | Payload | When |
|---|---|---|
| `task.discovered` | `task` `count` | Scheduler discovery returned >= 1 items |
| `task.enqueued` | `task` `id` | Per item pushed onto OMQ PUSH socket |
| `task.dispatched` | `task` `id` | Entry to the logical model's `#process(id)` |
| `task.succeeded` | `task` `id` `latency_ms` `outcome` | Work completed successfully. For the broadcast tasks, Phase 4 promotion (inserting the action's `promotions` row and the `spendable` rows for its wallet-owned outputs) happens atomically inside `Store#record_broadcast_result` whenever ARC returns a `tx_status` outside `ArcStatus::REJECTED`. This event is emitted by `Engine::Broadcast` immediately after that recording transaction commits, so any subscriber observing `task.succeeded` with `outcome: :accepted` can rely on the promotion having already taken effect. |
| `task.failed` | `task` `id` `latency_ms` `reason` | Transient failure (re-discoverable next cycle) |
| `task.aborted` | `task` `id` `reason` `arc_status` `arc_reason` | Terminal failure (action torn down, no re-discovery) |
| `task.skipped` | `task` `id` `reason` | Benign no-op (work no longer applicable) |

Payload fields that don't apply are omitted. `task.failed` carries `error` (the exception's first line) instead of, or alongside, `reason` when an exception ended the work, and `height` with `reason=reorg_detected`. `task.aborted` carries `arc_status` when ARC returned a `txStatus` and `arc_reason` when Arcade returned an `{error, reason}` rejection body. The reaper's events carry only `task`, `id` and `reason` or `error`.

`task` identifies the task type. Four values are emitted, each by one Scheduler discovery loop and by the logical model that processes what it finds:

- `broadcast_submission` — broadcasts never attempted (`broadcast_at IS NULL`), submitted by `Engine::Broadcast#process`.
- `broadcast_resolution` — broadcasts already attempted and not yet terminal, polled by `Engine::Broadcast#process`.
- `proof_acquisition` — actions awaiting a merkle proof (`Engine::TxProof#process`).
- `reaper` — abandoned actions to reclaim (`Engine::Reaper#process`).

`Engine::Broadcast#process` labels its events by the row it finds: `broadcast_submission` when `broadcast_at` is NULL, `broadcast_resolution` when it is set. Operators tracing one broadcast through the daemon therefore see the same task name on its discovery, dispatch and outcome lines.

`latency_ms` measures work duration only (dispatched to completion), not queue wait.

## Failed vs aborted vs skipped

This distinction is load-bearing for operators:

- **`task.failed`** — Transient. The work can be retried. The Scheduler will re-discover the item on the next cycle. Examples: rate limiting (429), transport errors (5xx), Arcade backpressure (503), stale BEEF (see below), a re-org detected during proof acquisition (`reorg_detected`), and a terminal rejection whose teardown reached an internal action (`cannot_reject_internal_action`, which also bumps `broadcasts.retry_count` and leaves the row for the next pass).

- **`task.aborted`** — Terminal. The transaction was definitively rejected by the network. The action is torn down by `Store#reject_action` in one transaction: any descendant actions that spent its outputs first, then its promotion, outputs, broadcasts row and the action itself, releasing locked UTXOs via cascade. Used by both the submit path and the poll path under #182's atomic invariant — the broadcasts row exists by the time `#process` runs, so `Store#abort_action` (which only deletes actions lacking a broadcasts row) would be a no-op. `abort_action` is the separate BRC-100 surface for aborting unsigned/unbroadcast actions; not used here. The item will never be re-discovered. Examples: double spend, policy violation.

- **`task.skipped`** — Benign no-op. The item was discovered but is no longer actionable by the time `#process` runs. No failure occurred. Examples: action not found, no raw transaction, no wtxid, proof already acquired, action no longer reapable.

`reason` values for `task.skipped`:

| `reason` | Task | Cause |
|---|---|---|
| `action_not_found` | broadcast tasks, `proof_acquisition` | The action row was deleted between discovery and dispatch (e.g. aborted) |
| `no_raw_tx` | broadcast tasks | The action has no `raw_tx` — was never signed |
| `no_wtxid` | `broadcast_resolution`, `proof_acquisition` | The action has no `wtxid` — the poll cannot derive a txid for ARC; proof acquisition cannot identify the transaction |
| `already_proven` | `proof_acquisition` | A proof was linked between discovery and dispatch (race window) |
| `not_reapable` | `reaper` | The action was promoted or signed between discovery and dispatch |

## ARC response categorisation

`Engine::Broadcast` categorises ARC responses into reason buckets via `categorize_reason`:

| Reason | Trigger | Terminal? |
|---|---|---|
| `:rate_limited` | HTTP 429 with no body | No |
| `:transport_error` | Any other retryable failure with no body (5xx, timeouts) | No |
| `:stale_beef` | `txStatus: MINED_IN_STALE_BLOCK` | No |
| `:malformed` | A non-retryable failure with no body | No |
| `:double_spend` | `txStatus: DOUBLE_SPEND_ATTEMPTED` | Yes |
| `:policy_violation` | `txStatus: REJECTED`, an ORPHAN marker in `txStatus` or `extraInfo`, or Arcade's `{error, reason}` rejection body | Yes |
| `:unknown` | Body present but no pattern matched | No |

An HTTP 503 on submit is Arcade's backpressure signal: `Engine::Broadcast` checks for it before categorising, clears `broadcast_at` so the row returns to the submission queue, and emits `task.failed reason=backpressure`. A malformed transaction reaches the wallet as an HTTP error, not as a `txStatus` (see `BSV::Wallet::ArcStatus`); it is terminal only when the body is Arcade's rejection shape.

The `:unknown` bucket is the escape hatch — transient, not terminal. Any ARC response shape not yet classified lands here. The daemon re-discovers the broadcast and retries rather than aborting an action for a response we don't understand. When `:unknown` appears in production logs, it signals a categorisation gap — inspect the response and add a specific reason.

### Stale-block is transient

A `MINED_IN_STALE_BLOCK` failure on submit emits `task.failed reason=stale_beef`, **not** `task.aborted`; on a poll the status is recorded and reported as `outcome=pending`. This is deliberate:

The transaction itself is valid — it was mined, just on a chain branch that lost the race. The underlying transaction is not rejected; it is a chain-side timing artefact. The resolution loop keeps polling the broadcast until it re-enters the main chain.

`BSV::Wallet::ArcStatus::REJECTED`, the set that drives `task.aborted`, doesn't include `MINED_IN_STALE_BLOCK`:

```ruby
REJECTED = %w[REJECTED DOUBLE_SPEND_ATTEMPTED].freeze
```

A second, broader constant — `ArcStatus::TERMINAL` — lists the statuses that stop polling: the rejected set plus the final accepted statuses `SEEN_ON_NETWORK`, `SEEN_MULTIPLE_NODES`, `MINED` and `IMMUTABLE`, but not `ACCEPTED_BY_NETWORK` or `MINED_IN_STALE_BLOCK`. `Store#pending_resolutions` uses it to decide which rows are still worth polling.

### Outcome buckets (success path)

On `response.http_success?`, `categorize_outcome` classifies the `txStatus`:

| Outcome | Statuses |
|---|---|
| `:accepted` | `ArcStatus::ACCEPTED`: `SEEN_ON_NETWORK`, `SEEN_MULTIPLE_NODES`, `ACCEPTED_BY_NETWORK`, `MINED`, `IMMUTABLE` |
| `:rejected` | `ArcStatus::REJECTED`: `REJECTED`, `DOUBLE_SPEND_ATTEMPTED` (submit path only; the poll path routes these to `task.aborted` first) |
| `:pending` | Any other status (`QUEUED`, `RECEIVED`, etc.), or none |

## Emit points by component

### Daemon (`daemon.rb`)

- `daemon.started` — after all fibres are scheduled in `run!`
- `daemon.stopped` — on `stop!` before halting the reactor

### Scheduler (`scheduler.rb`)

Runs four independent discovery loops as Async fibres. Each polls the Store on its own interval, enqueues action IDs onto an OMQ inproc PUSH socket, and emits:

- `task.discovered` — once per cycle when pending items exist
- `task.enqueued` — once per item pushed to the OMQ socket
- `fiber.crashed` — on `StandardError` in a discovery loop

| Loop name (`task=`) | Source query | Endpoint | Interval | Purpose |
|---|---|---|---|---|
| `broadcast_submission` | `Store#pending_submissions` (rows where `broadcast_at IS NULL`) | `inproc://broadcasts.pull` | 5s | Find newly signed broadcasts and submit them to ARC |
| `broadcast_resolution` | `Store#pending_resolutions` (rows where `broadcast_at IS NOT NULL` and `tx_status` is NULL or outside `ArcStatus::TERMINAL`) | `inproc://broadcasts.pull` | 30s | Re-check in-flight broadcasts for status changes |
| `proof_acquisition` | `Store#pending_proofs` (send-path actions with a `wtxid` and no linked `tx_proof_id`) | `inproc://proofs.pull` | 30s | Find mined actions awaiting proof acquisition |
| `reaper` | `Store#stale_action_ids` (actions older than `reap_threshold` with no `promotions` or `broadcasts` row that are either send-path or unsigned) | `inproc://reaper.pull` | 60s | Reclaim abandoned actions and release their locked inputs |

#### Discovery streams

Both broadcast loops feed the **same** PULL socket (`inproc://broadcasts.pull`). `Engine::Broadcast#process` routes each enqueued ID by inspecting the row's `broadcast_at`:

- `broadcast_at IS NULL` → `submit` path — initial broadcast to ARC.
- `broadcast_at IS NOT NULL` → `poll_status` path — `GET /tx/{txid}` for status convergence.

The two loops are kept separate at the discovery layer so each scans `broadcasts` alone, without joins; combining them into one query would force a `UNION` or `OR` and lose the index-friendly shape. `#process` labels its events with the name of the stream the row belongs to, so the discovery, dispatch and outcome lines for one broadcast carry the same `task=`.

### Engine::Broadcast (`engine/broadcast.rb`)

Per `#process(action_id)` call:

1. `task.dispatched` — always, on entry
2. Routing on the broadcast row:
   - `broadcast_at IS NULL` → `submit` path (initial broadcast to ARC)
   - `broadcast_at IS NOT NULL` → `poll_status` path (`GET /tx/{txid}` for status convergence)
3. Exactly one of:
   - `task.skipped` — `action_not_found`, `no_raw_tx`, or `no_wtxid` (poll path)
   - `task.succeeded` — ARC accepted the broadcast or returned a non-terminal status
   - `task.failed` — transient failure (rate limit, transport, backpressure, stale BEEF, an exception, or `cannot_reject_internal_action`)
   - `task.aborted` — terminal rejection (double spend, policy); `Store#reject_action` invoked (both submit and poll paths — the broadcasts row exists by the time `#process` runs, so `abort_action` would be a no-op)

#### Pre-POST `broadcast_at` invariant

`Engine::Broadcast#submit` stamps `broadcast_at = Time.now` in a committed transaction **before** the ARC call (via `Store#mark_broadcast_attempted`). The `inline` broadcast intent runs the same `Engine::Broadcast#process` in the caller's process, so it stamps the same way and emits the same events.

The invariant: **`broadcast_at` is set before any network call to broadcast the transaction**, never after. A row with `broadcast_at IS NULL` has never been submitted.

#### Crash-recovery state: `broadcast_at IS NOT NULL AND tx_status IS NULL`

A mid-POST crash (process exit between the stamp commit and the ARC response being persisted) leaves the broadcast row in a recognisable "attempted, outcome unknown" state:

```
broadcast_at IS NOT NULL AND tx_status IS NULL
```

This is intentional and recoverable. The row satisfies `Store#pending_resolutions`, so the next scheduler tick discovers it and routes it through `poll_status`. ARC's `GET /tx/{txid}` then resolves whether the transaction was received: a successful status response converges the row, a 404 (not received) leaves it for another tick. Operators investigating a crash can also query ARC directly with the action's `dtxid` to determine outcome before the next poll cycle.

This is distinct from a *queued* state (`broadcast_at IS NULL`) — the pre-POST stamp is the boundary between the two discovery streams.

### Engine::TxProof (`engine/tx_proof.rb`)

Per `#process(action_id)` call:

1. `task.dispatched` — always, on entry
2. Exactly one of:
   - `task.skipped` — `action_not_found`, `no_wtxid`, or `already_proven` (proof linked between discovery and dispatch)
   - `task.succeeded outcome=acquired` — proof saved and linked
   - `task.succeeded outcome=not_yet_mined` — tx exists but no merkle proof yet
   - `task.failed` — transport error fetching status, or `reorg_detected` (with `height`) when the acquired proof's block header conflicts with the wallet's `blocks` row

No `task.aborted` — proof acquisition has no terminal-rejection mode. A proof either exists or doesn't yet.

### Engine::Reaper (`engine/reaper.rb`)

Per `#process(action_id)` call:

1. `task.dispatched` — always, on entry
2. Exactly one of:
   - `task.succeeded` — the action was reclaimed (`Store#reap_action`)
   - `task.skipped reason=not_reapable` — it was promoted or signed since discovery
   - `task.failed` — an exception, carried as `error`

## Example log output

A delayed broadcast (submission discovery → submit → succeed), a rejected one, an in-flight broadcast picked up by the resolution loop (resolution discovery → poll_status → rate-limited), and a proof acquisition:

```
[event] daemon.started wallet=alice network=mainnet
[event] task.discovered task=broadcast_submission count=2
[event] task.enqueued task=broadcast_submission id=42
[event] task.enqueued task=broadcast_submission id=43
[event] task.dispatched task=broadcast_submission id=42
[event] task.succeeded task=broadcast_submission id=42 latency_ms=127 outcome=accepted
[event] task.dispatched task=broadcast_submission id=43
[event] task.aborted task=broadcast_submission id=43 reason=double_spend arc_status=DOUBLE_SPEND_ATTEMPTED
[event] task.discovered task=broadcast_resolution count=1
[event] task.enqueued task=broadcast_resolution id=44
[event] task.dispatched task=broadcast_resolution id=44
[event] task.failed task=broadcast_resolution id=44 latency_ms=3012 reason=rate_limited
[event] task.discovered task=proof_acquisition count=1
[event] task.enqueued task=proof_acquisition id=42
[event] task.dispatched task=proof_acquisition id=42
[event] task.succeeded task=proof_acquisition id=42 latency_ms=89 outcome=acquired
[event] daemon.stopped reason=signal drained=true
```

Filter with grep:

```bash
# All events for a specific action
grep "id=42" walletd.log

# All failures
grep "task.failed\|task.aborted" walletd.log

# All broadcast outcomes, from both broadcast loops
grep -E "task=broadcast_(submission|resolution) " walletd.log | grep -v "task.dispatched"

# Discoveries from the submission loop only (newly queued broadcasts)
grep -E "task\.(discovered|enqueued) task=broadcast_submission" walletd.log
```

## Related

- [Events (concepts)](../concepts/events.md) — the narrative shape, why the bus exists, the drain-counter control plane.
- [Schema](schema.md) — the `broadcasts.tx_status` column and ARC status ENUM that drive the categorisation table.
- [Action lifecycle](action-lifecycle.md) — how each task event maps onto the action's lifecycle progress.
