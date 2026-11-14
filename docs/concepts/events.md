---
title: Events
parent: Concepts
nav_order: 6
---

# Events & observability

A long-running daemon that quietly broadcasts and resolves transactions in the background is only trustworthy if you can *see* what it is doing. The wallet emits a small, structured **event taxonomy** through one choke point — `BSV::Wallet.emit` — and fans each event out to as many as three destinations: a human-facing logger, an opt-in machine-readable log, and an in-process observer registry that other components subscribe to.

The design goal is that the *same* event serves an operator tailing a logfile, a test harness asserting on a run, and the daemon's own shutdown logic — with no separate instrumentation for each.

This page is the narrative. The canonical wire format — the `[event]` line shape, the field-value conventions, the taxonomy table — is in [Events (reference)](../reference/events.md). When the two disagree, the reference wins.

## One emit, three sinks

`emit(name, **payload)` builds a single canonical line and writes it to whichever sinks are active:

```ruby
BSV::Wallet.emit('task.dispatched', task: 'broadcast_submission', id: 42)
# → [event] task.dispatched task=broadcast_submission id=42
```

- **`BSV.logger`** — the SDK-level logger. The event line is interleaved with the `[Store]` / `[Engine]` / `[Protocol]` debug output, which is exactly what you want during interactive development.
- **`BSV::Wallet.event_log`** — an opt-in, wallet-scoped sink. Setting it auto-applies `EVENT_LOG_FORMATTER`, which strips the standard Logger date/severity/PID prefix and emits a clean `<ISO-8601> [event] name key=value` line suitable for `tail -f` and `grep` over a sustained run.
- **The observer registry** — in-process callables that receive `(name, payload)` for every event (see below).

`emit` short-circuits when there is nothing listening: if `BSV.logger` is nil, `event_log` is nil, *and* no observers are registered, it returns immediately without building the line.

## Why a bus?

Three different audiences read the same emit:

- **Operators** want a logfile they can `grep` and `tail`. The clean `key=value` shape on `event_log` is for them.
- **Test harnesses and e2e suites** want to assert "this action reached `task.succeeded` with `outcome=accepted`". The observer registry gives them a programmatic hook without parsing a logfile.
- **The daemon itself** is one of those observers. The `Scheduler` registers a callback that increments and decrements a drain counter — the same events you read in a logfile *are* the signal the daemon uses to decide when it is safe to stop. See below.

Because all three read from one `emit`, you can run any combination at once without the call sites knowing or caring which are active.

## Why three terminal events, not one

The taxonomy splits work that *ended* into three categories — `task.failed`, `task.aborted`, `task.skipped`. The distinction is load-bearing for operators reading a run:

- **`task.failed`** — Transient. The work can be retried. The Scheduler will re-discover the item on the next cycle. Examples: rate limiting (HTTP 429), transport errors (5xx), Arcade backpressure (503), stale BEEF (a `MINED_IN_STALE_BLOCK` from ARC).

- **`task.aborted`** — Terminal. The transaction was definitively rejected by the network. `Store#reject_action` tears the action down in a single transaction — any descendants that spent its outputs, then its promotion, outputs, broadcasts row and the action — releasing locked UTXOs via cascade. The item will never be re-discovered. Examples: double spend, policy violation. `abort_action` (BRC-100 surface) is a separate concept — it aborts actions that have no broadcasts row yet and is used by callers, not by the broadcast engine.

- **`task.skipped`** — Benign no-op. The item was discovered but is no longer actionable by the time `#process` runs. No failure occurred. Examples: action not found (deleted between discovery and dispatch), no raw transaction, no `wtxid`, proof already acquired, action no longer reapable.

The triad is what lets an operator scan a log file and triage: failed rows are transient (wait), aborted rows are terminal (investigate or accept), skipped rows are noise (ignore). Conflating any pair of them would lose the distinction. The canonical taxonomy is in [Events (reference) — Failed vs aborted vs skipped](../reference/events.md#failed-vs-aborted-vs-skipped).

## ARC categorisation buckets

`Engine::Broadcast` categorises ARC responses into reason buckets via `categorize_reason`. The buckets distinguish *transient* outcomes (worth retrying — re-discovered next tick) from *terminal* ones (action aborted, never re-discovered):

| Bucket | Trigger | Terminal? |
|---|---|---|
| `:rate_limited` | HTTP 429 with no body | No |
| `:transport_error` | Any other retryable failure with no body (5xx, timeouts) | No |
| `:stale_beef` | `txStatus: MINED_IN_STALE_BLOCK` | No |
| `:malformed` | A non-retryable failure with no body | No |
| `:double_spend` | `txStatus: DOUBLE_SPEND_ATTEMPTED` | Yes |
| `:policy_violation` | `txStatus: REJECTED`, an ORPHAN marker, or Arcade's `{error, reason}` rejection body | Yes |
| `:unknown` | Body present but no pattern matched | No |

The `:unknown` bucket is the escape hatch — **transient, not terminal**. Any ARC response shape not yet classified lands here. The daemon re-discovers the broadcast and retries rather than aborting an action for a response we don't understand. When `:unknown` appears in production logs, it signals a categorisation gap — inspect the response and add a specific reason.

### Stale-block is transient by design

`MINED_IN_STALE_BLOCK` is never `task.aborted`: on submit it emits `task.failed reason=stale_beef`, and on a poll it is recorded as a non-terminal status. The transaction itself is valid — it was mined, just on a chain branch that lost the race. The underlying transaction is not rejected; it is a chain-side timing artefact. The resolution loop keeps polling the broadcast until it re-enters the main chain. `ArcStatus::REJECTED` (which drives `task.aborted`) doesn't include `MINED_IN_STALE_BLOCK`, and neither does `ArcStatus::TERMINAL` (which stops polling).

## Who emits what

Four components emit through the same `BSV::Wallet.emit` choke point: the Daemon, the Scheduler, and the logical models it feeds (`Engine::Broadcast`, `Engine::TxProof` and `Engine::Reaper`). The normative emit-points table is in the [reference](../reference/events.md#emit-points-by-component); the shape:

### Daemon

`daemon.started` after all fibres are scheduled in `run!`; `daemon.stopped` in `stop!`, after the drain and before halting the reactor. Two events, the lifecycle bookends.

### Scheduler

Four independent discovery loops as Async fibres. Each polls the Store on its own interval, enqueues action IDs onto an OMQ inproc PUSH socket, and emits `task.discovered` (once per cycle when pending items exist) and `task.enqueued` (once per item pushed). `fiber.crashed` fires on a `StandardError` in a discovery loop.

The four loops are `broadcast_submission` (newly-signed broadcasts where `broadcast_at IS NULL`), `broadcast_resolution` (in-flight broadcasts past their first attempt, polling for status), `proof_acquisition` (actions awaiting a merkle proof) and `reaper` (abandoned actions to reclaim). `Engine::Broadcast#process` labels its events with the name of the stream the row belongs to, so operators tracing one broadcast see the same `task=` on its discovery, dispatch and outcome lines.

### Engine::Broadcast

Per `#process(action_id)` call, emits exactly one terminal event after `task.dispatched`:

- `task.skipped` — `action_not_found`, `no_raw_tx`, or `no_wtxid` (poll path)
- `task.succeeded` — ARC accepted the broadcast or returned a non-terminal status. When `outcome: :accepted`, the Phase 4 promotion has already taken effect — `Store#record_broadcast_result` commits the status update and the promotion in one transaction, and the emit fires after that commit. A subscriber observing `task.succeeded outcome=accepted` can rely on the promotion being visible.
- `task.failed` — transient failure (rate limit, transport, backpressure, stale BEEF)
- `task.aborted` — terminal rejection (double spend, policy); `Store#reject_action` invoked

### Engine::TxProof

Per `#process(action_id)` call:

- `task.skipped` — `action_not_found`, `no_wtxid`, or `already_proven`
- `task.succeeded outcome=acquired` — proof saved and linked
- `task.succeeded outcome=not_yet_mined` — tx exists but no merkle proof yet
- `task.failed` — transport error fetching status

No `task.aborted` — proof acquisition has no terminal-rejection mode. A proof either exists or doesn't yet.

### Engine::Reaper

Per `#process(action_id)` call: `task.succeeded` when the action was reclaimed, `task.skipped reason=not_reapable` when it was promoted or signed since discovery, `task.failed` on an exception.

## Events as control plane: the drain counter

The most important observer is the daemon's own. The `Scheduler` needs to know when the system is *quiesced* — every dispatched task settled — so that a clean shutdown can wait for in-flight work rather than killing it mid-broadcast. Rather than reach into the logical models' internals, it derives this purely from the event stream:

<!-- generated from gem/bsv-wallet/lib/bsv/wallet/scheduler.rb#record_lifecycle -->
```ruby
TERMINAL_EVENTS = %w[task.succeeded task.failed task.aborted task.skipped].freeze

@observer = BSV::Wallet.on_event { |name, _payload| record_lifecycle(name) }

def record_lifecycle(name)
  case name.to_s
  when 'task.dispatched'
    @in_flight_mutex.synchronize { @in_flight += 1 }
  when *TERMINAL_EVENTS
    @in_flight_mutex.synchronize { @in_flight -= 1 }
  end
end
```

`task.dispatched` increments the counter; any of the four terminal events decrements it. When the counter reaches zero, nothing is in flight. `Scheduler#shutdown` stops the discovery loops enqueuing new work and polls this counter until it drains (or a timeout fires), then deregisters the observer with `off_event`. The shutdown logic and the observability stream are *the same data* — the events you read in a logfile are exactly the signal the daemon uses to decide it is safe to stop.

This is why the taxonomy's dispatched/terminal pairing is load-bearing rather than cosmetic: an event that opened a unit of work without a matching terminal event would leave the drain counter stranded above zero, and a clean shutdown would block until its timeout. The reference page enforces the pairing as a normative rule.

## Broadcast-status events are a separate stream

ARC and Arcade emit *their own* broadcast-status events (over HTTP callback or Arcade SSE). Those are a separate stream: they are *consumed* by the wallet rather than emitted from it, and are handled by `Store::EventApplicator`, which decodes the wire formats into a uniform internal hash and routes to `Store#record_broadcast_result` or `Store#reject_action`. The wallet's own `emit` taxonomy on this page covers what the daemon does *in response* to those external events (`task.dispatched`, `task.succeeded`, …); it does not include the raw provider notifications themselves.

## Related

- [Events (reference)](../reference/events.md) — canonical line format, payload conventions, taxonomy table.
- [Action lifecycle](action-lifecycle.md) — what each task event corresponds to in the action's progress.
- [Persistence](persistence.md) — the `record_broadcast_result` atomic write that pairs with `task.succeeded`.
- [Schema](../reference/schema.md) — the `broadcasts.tx_status` lifecycle these events report on.
