# Wallet Daemon Events

walletd emits structured lifecycle events for every background task it processes. Events are written to `BSV.logger` at `:info` level in a grep-friendly `key=value` format.

## Emit API

```ruby
BSV::Wallet.emit(name, **payload)
```

Writes a single line:

```
[event] <name> key=value key=value ...
```

No-op when `BSV.logger` is nil. See `lib/bsv/wallet/events.rb` for the helper implementation.

### Payload conventions

- **No secrets.** Never include WIFs, raw transaction bytes, BEEF blobs, or any cryptographic material.
- **No binary.** All values must be human-readable strings or numbers.
- **No spaces in values.** Use underscored identifiers (`action_not_found`, not `action not found`). The helper quotes values containing whitespace as a safety net, but callers should normalize.
- **Nil values are omitted.** A nil payload value produces no `key=` field in the output.
- **Symbols stringify.** `outcome: :accepted` renders as `outcome=accepted`.

## Event Taxonomy

Ten canonical events across three layers.

### Daemon lifecycle (2 events)

| Event | Payload | When |
|---|---|---|
| `daemon.started` | `wallet` `network` | End of `Daemon#run!` setup, after all fibers are scheduled |
| `daemon.stopped` | `reason` | Start of `Daemon#stop!`, before the reactor halts |

`reason` values: `signal` (SIGINT/SIGTERM).

### Fiber lifecycle (1 event)

| Event | Payload | When |
|---|---|---|
| `fiber.crashed` | `task` `error` | Unrecoverable `StandardError` escapes a fiber — bind failure or processing error |

`error` is the first line of the exception message (newlines stripped). Emitted by:
- **OMQ bind failures** — `bind_or_die` in `Engine::Broadcast#pull!`, `#reply!`, and `Engine::TxProof#pull!` (via `OmqSupport` module). Fires when the inproc endpoint is already bound.
- **Scheduler discovery loops** — on unhandled exceptions during discovery or enqueue.
- **TxProof PULL handler** — on unhandled exceptions during message processing.

### Task lifecycle (7 events)

| Event | Payload | When |
|---|---|---|
| `task.discovered` | `task` `count` | Scheduler discovery returned >= 1 items |
| `task.enqueued` | `task` `id` | Per item pushed onto OMQ PUSH socket |
| `task.dispatched` | `task` `id` | Entry to the logical model's `#process(id)` |
| `task.succeeded` | `task` `id` `latency_ms` `outcome` | Work completed successfully |
| `task.failed` | `task` `id` `latency_ms` `reason` | Transient failure (re-discoverable next cycle) |
| `task.aborted` | `task` `id` `reason` `arc_status` | Terminal failure (action aborted, no re-discovery) |
| `task.skipped` | `task` `id` `reason` | Benign no-op (work no longer applicable) |

`task` identifies the task type. Three values are emitted:

- `broadcast_push_submission` — push-discovery loop (Scheduler). Found a broadcast row with `broadcast_at IS NULL` (never attempted). Emitted on `task.discovered` and `task.enqueued` only.
- `broadcast_push` — poll-discovery loop (Scheduler) and the broadcast processing engine (`Engine::Broadcast#process`, both push and poll paths). Emitted on all task lifecycle events for broadcasts.
- `proof_acquisition` — proof discovery loop and the proof engine (`Engine::TxProof#process`). Emitted on all task lifecycle events for proofs.

Operators tracing one broadcast through the daemon will see `task=broadcast_push_submission` on the discovery line and `task=broadcast_push` on the dispatch/outcome lines. See [Discovery streams](#discovery-streams) below.

`latency_ms` measures work duration only (dispatched to completion), not queue wait.

## Failed vs Aborted vs Skipped

This distinction is load-bearing for operators:

- **`task.failed`** — Transient. The work can be retried. The Scheduler will re-discover the item on the next cycle. Examples: rate limiting (429), transport errors (5xx), stale BEEF (see below).

- **`task.aborted`** — Terminal. The transaction was definitively rejected by the network. The action is removed via `Store#fail_broadcast_action` (deletes the action and its broadcasts row in a single transaction, releasing locked UTXOs via cascade). Used by both the submit path and the poll path under #182's atomic invariant — the broadcasts row exists by the time `#process` runs, so `Store#abort_action` (which only deletes actions lacking a broadcasts row) would be a no-op. `abort_action` is the separate BRC-100 surface for aborting unsigned/unbroadcast actions; not used here. The item will never be re-discovered. Examples: double spend, policy violation, malformed transaction.

- **`task.skipped`** — Benign no-op. The item was discovered but is no longer actionable by the time `#process` runs. No failure occurred. Examples: action not found, no raw transaction, no wtxid, proof already acquired.

`reason` values for `task.skipped`:

| `reason` | Task | Cause |
|---|---|---|
| `action_not_found` | both | The action row was deleted between discovery and dispatch (e.g. aborted) |
| `no_raw_tx` | `broadcast_push` | The action has no `raw_tx` — was never signed |
| `no_wtxid` | both | The action has no `wtxid` — broadcast poll path cannot derive a txid for ARC; proof path cannot identify the transaction |
| `already_proven` | `proof_acquisition` | A proof was linked between discovery and dispatch (race window) |

## ARC Response Categorization

`Engine::Broadcast` categorizes ARC responses into reason buckets via `categorize_reason`:

| Reason | Trigger | Terminal? |
|---|---|---|
| `:rate_limited` | HTTP 429 | No |
| `:transport_error` | HTTP 5xx or other retryable failure | No |
| `:stale_beef` | `txStatus: MINED_IN_STALE_BLOCK` | No |
| `:malformed` | `txStatus: MALFORMED` or malformed 2xx (no data) | Yes (when data present) |
| `:double_spend` | `txStatus: DOUBLE_SPEND_ATTEMPTED` | Yes |
| `:policy_violation` | `txStatus: REJECTED` or ORPHAN marker | Yes |
| `:unknown` | Data present but no pattern matched | No |

The `:unknown` bucket is the escape hatch — transient, not terminal. Any ARC response shape not yet classified lands here. The daemon re-discovers the broadcast and retries rather than aborting an action for a response we don't understand. When `:unknown` appears in production logs, it signals a categorization gap — inspect the response and add a specific reason.

### Stale-block is transient

`MINED_IN_STALE_BLOCK` emits `task.failed reason=stale_beef`, **not** `task.aborted`. This is deliberate:

The transaction itself is valid — it was mined, just on a chain branch that lost the race. The underlying transaction is not rejected; it is a chain-side timing artifact. The daemon will re-discover the broadcast on the next Scheduler cycle, and ARC will accept it once the proof refreshes onto the active chain.

`REJECTED_STATUSES` (which drive `task.aborted`) explicitly excludes `MINED_IN_STALE_BLOCK`. The constant is defined in `Engine::Broadcast`:

```ruby
REJECTED_STATUSES = %w[REJECTED DOUBLE_SPEND_ATTEMPTED MALFORMED].freeze
```

A second, broader constant — `Models::Broadcast::TERMINAL_STATUSES` — lists the statuses that stop poll discovery (the accepted set plus the rejected set, but not `MINED_IN_STALE_BLOCK`). `Store#pending_polls` uses it to decide which rows are still worth polling.

### Outcome buckets (success path)

On `response.http_success?`, `categorize_outcome` classifies the `txStatus`:

| Outcome | Statuses |
|---|---|
| `:accepted` | `SEEN_ON_NETWORK`, `ACCEPTED_BY_NETWORK`, `MINED`, `IMMUTABLE` |
| `:rejected` | `REJECTED`, `DOUBLE_SPEND_ATTEMPTED`, `MALFORMED` (unlikely on success path) |
| `:pending` | Any other intermediate status (`QUEUED`, `RECEIVED`, etc.) |

## Emit Points by Component

### Daemon (`daemon.rb`)

- `daemon.started` — after all fibers are scheduled in `run!`
- `daemon.stopped` — on `stop!` before halting the reactor

### Scheduler (`scheduler.rb`)

Runs three independent discovery loops as Async fibers. Each polls the Store on its own interval, enqueues action IDs onto an OMQ inproc PUSH socket, and emits:

- `task.discovered` — once per cycle when pending items exist
- `task.enqueued` — once per item pushed to the OMQ socket
- `fiber.crashed` — on `StandardError` in a discovery loop

| Loop name (`task=`) | Source query | Endpoint | Interval | Purpose |
|---|---|---|---|---|
| `broadcast_push_submission` | `Store#pending_pushes` (rows where `broadcast_at IS NULL`) | `inproc://broadcasts.pull` | 5s | Push discovery — find newly signed broadcasts and submit them to ARC |
| `broadcast_push` | `Store#pending_polls` (rows where `broadcast_at IS NOT NULL` and `tx_status` is non-terminal) | `inproc://broadcasts.pull` | 5s | Poll discovery — re-check in-flight broadcasts for status changes |
| `proof_acquisition` | `Store#pending_proofs` (actions with `wtxid` and no linked `tx_proof_id`) | `inproc://proofs.pull` | 30s | Find mined actions awaiting proof acquisition |

#### Discovery streams

Both broadcast loops feed the **same** PULL socket (`inproc://broadcasts.pull`). `Engine::Broadcast#process` routes each enqueued ID by inspecting the row's `broadcast_at`:

- `broadcast_at IS NULL` → `submit` path — initial broadcast to ARC.
- `broadcast_at IS NOT NULL` → `poll_status` path — `GET /tx/{txid}` for status convergence.

The two loops are kept separate at the discovery layer so each scans a single-column predicate without joins; combining them into one query would force a `UNION` or `OR` and lose the index-friendly shape. Operators tracing one broadcast row through the daemon will see `task=broadcast_push_submission` on the discovery line followed by `task=broadcast_push` on the dispatch and outcome lines — the engine emits with a single canonical name regardless of which loop enqueued the ID.

### Engine::Broadcast (`engine/broadcast.rb`)

Per `#process(action_id)` call:

1. `task.dispatched` — always, on entry
2. Routing on the broadcast row:
   - `broadcast_at IS NULL` → `submit` path (initial broadcast to ARC)
   - `broadcast_at IS NOT NULL` → `poll_status` path (`GET /tx/{txid}` for status convergence)
3. Exactly one of:
   - `task.skipped` — `action_not_found`, `no_raw_tx` (submit path), or `no_wtxid` (poll path)
   - `task.succeeded` — ARC accepted the broadcast or returned a non-terminal status
   - `task.failed` — transient failure (rate limit, transport, stale BEEF)
   - `task.aborted` — terminal rejection (double spend, policy, malformed); `fail_broadcast_action` invoked (both submit and poll paths — the broadcasts row exists by the time `#process` runs, so `abort_action` would be a no-op)

#### Pre-POST `broadcast_at` invariant

`Engine::Broadcast#submit` stamps `broadcast_at = Time.now` in a committed transaction **before** the ARC call (via `Store#mark_broadcast_attempted`). This is the daemon-side counterpart to the synchronous `:inline` broadcast path, which performs the same stamp before its own ARC call.

The invariant: **`broadcast_at` is set before any network call to broadcast the transaction**, never after. A row with `broadcast_at IS NULL` has never been submitted.

#### Crash-recovery state: `broadcast_at IS NOT NULL AND tx_status IS NULL`

A mid-POST crash (process exit between the stamp commit and the ARC response being persisted) leaves the broadcast row in a recognisable "attempted, outcome unknown" state:

```
broadcast_at IS NOT NULL AND tx_status IS NULL
```

This is intentional and recoverable. The row satisfies `Store#pending_polls`, so the next scheduler tick discovers it and routes it through `poll_status`. ARC's `GET /tx/{txid}` then resolves whether the transaction was received: a successful status response converges the row, a 404 (not received) leaves it for another tick. Operators investigating a crash can also query ARC directly with the action's `dtxid` to determine outcome before the next poll cycle.

This is distinct from a *queued* state (`broadcast_at IS NULL`) — the pre-POST stamp is the boundary between the two discovery streams.

### Engine::TxProof (`engine/tx_proof.rb`)

Per `#process(action_id)` call:

1. `task.dispatched` — always, on entry
2. Exactly one of:
   - `task.skipped` — `action_not_found`, `no_wtxid`, or `already_proven` (proof linked between discovery and dispatch)
   - `task.succeeded outcome=acquired` — proof saved and linked
   - `task.succeeded outcome=not_yet_mined` — tx exists but no merkle proof yet
   - `task.failed` — transport error fetching status

No `task.aborted` — proof acquisition has no terminal-rejection mode. A proof either exists or doesn't yet.

## Example Log Output

A delayed broadcast (push discovery → submit → succeed), an in-flight broadcast picked up by the poll loop (poll discovery → poll_status → succeed), and a proof acquisition:

```
[event] daemon.started wallet=alice network=mainnet
[event] task.discovered task=broadcast_push_submission count=2
[event] task.enqueued task=broadcast_push_submission id=42
[event] task.enqueued task=broadcast_push_submission id=43
[event] task.dispatched task=broadcast_push id=42
[event] task.succeeded task=broadcast_push id=42 latency_ms=127 outcome=accepted
[event] task.dispatched task=broadcast_push id=43
[event] task.aborted task=broadcast_push id=43 reason=double_spend arc_status=DOUBLE_SPEND_ATTEMPTED
[event] task.discovered task=broadcast_push count=1
[event] task.enqueued task=broadcast_push id=44
[event] task.dispatched task=broadcast_push id=44
[event] task.failed task=broadcast_push id=44 latency_ms=3012 reason=rate_limited
[event] task.discovered task=proof_acquisition count=1
[event] task.enqueued task=proof_acquisition id=42
[event] task.dispatched task=proof_acquisition id=42
[event] task.succeeded task=proof_acquisition id=42 latency_ms=89 outcome=acquired
[event] daemon.stopped reason=signal
```

Filter with grep:

```bash
# All events for a specific action
grep "id=42" walletd.log

# All failures
grep "task.failed\|task.aborted" walletd.log

# All broadcast outcomes (dispatch + outcome events; the engine emits with
# task=broadcast_push for both submit and poll paths)
grep "task=broadcast_push " walletd.log | grep -v "task.dispatched"

# All discoveries from the push-discovery loop only (newly queued broadcasts)
grep "task=broadcast_push_submission" walletd.log
```
