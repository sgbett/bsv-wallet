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
| `fiber.crashed` | `task` `error` | Unrecoverable `StandardError` escapes a fiber |

`error` is the first line of the exception message (newlines stripped). Emitted by both Scheduler discovery loops and TxProof's PULL socket handler.

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

`task` identifies the task type: `broadcast_push` or `proof_acquisition`.

`latency_ms` measures work duration only (dispatched to completion), not queue wait.

## Failed vs Aborted vs Skipped

This distinction is load-bearing for operators:

- **`task.failed`** — Transient. The work can be retried. The Scheduler will re-discover the item on the next cycle. Examples: rate limiting (429), transport errors (5xx), stale BEEF (see below).

- **`task.aborted`** — Terminal. The transaction was definitively rejected by the network. `Store#abort_action` is invoked to mark the action as failed. The item will never be re-discovered. Examples: double spend, policy violation, malformed transaction.

- **`task.skipped`** — Benign no-op. The item was discovered but is no longer actionable by the time `#process` runs. No failure occurred. Examples: action not found, no raw transaction, no wtxid.

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
| `:unknown` | Data present but no pattern matched | Yes |

The `:unknown` bucket is the escape hatch. Any ARC response shape not yet classified lands here. When `:unknown` appears in production logs, it signals a categorization gap — inspect the response and add a specific reason.

### Stale-block is transient

`MINED_IN_STALE_BLOCK` emits `task.failed reason=stale_beef`, **not** `task.aborted`. This is deliberate:

The transaction itself is valid — it was mined, just on a chain branch that lost the race. The underlying transaction is not rejected; it is a chain-side timing artifact. The daemon will re-discover the broadcast on the next Scheduler cycle, and ARC will accept it once the proof refreshes onto the active chain.

`TERMINAL_STATUSES` (which drive `task.aborted`) explicitly excludes `MINED_IN_STALE_BLOCK`. The constant is defined in `Engine::Broadcast`:

```ruby
TERMINAL_STATUSES = %w[REJECTED DOUBLE_SPEND_ATTEMPTED MALFORMED].freeze
```

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

- `task.discovered` — once per cycle when pending items exist
- `task.enqueued` — once per item pushed to the OMQ socket
- `fiber.crashed` — on `StandardError` in a discovery loop

### Engine::Broadcast (`engine/broadcast.rb`)

Per `#process(action_id)` call:

1. `task.dispatched` — always, on entry
2. Exactly one of:
   - `task.skipped` — action not found or no raw_tx
   - `task.succeeded` — ARC accepted the broadcast
   - `task.failed` — transient failure (rate limit, transport, stale BEEF)
   - `task.aborted` — terminal rejection (double spend, policy, malformed); `abort_action` invoked

### Engine::TxProof (`engine/tx_proof.rb`)

Per `#process(action_id)` call:

1. `task.dispatched` — always, on entry
2. Exactly one of:
   - `task.skipped` — action not found or no wtxid
   - `task.succeeded outcome=acquired` — proof saved and linked
   - `task.succeeded outcome=not_yet_mined` — tx exists but no merkle proof yet
   - `task.failed` — transport error fetching status

No `task.aborted` — proof acquisition has no terminal-rejection mode. A proof either exists or doesn't yet.

## Example Log Output

```
[event] daemon.started wallet=alice network=mainnet
[event] task.discovered task=broadcast_push count=3
[event] task.enqueued task=broadcast_push id=42
[event] task.enqueued task=broadcast_push id=43
[event] task.enqueued task=broadcast_push id=44
[event] task.dispatched task=broadcast_push id=42
[event] task.succeeded task=broadcast_push id=42 latency_ms=127 outcome=accepted
[event] task.dispatched task=broadcast_push id=43
[event] task.failed task=broadcast_push id=43 latency_ms=3012 reason=rate_limited
[event] task.dispatched task=broadcast_push id=44
[event] task.aborted task=broadcast_push id=44 reason=double_spend arc_status=DOUBLE_SPEND_ATTEMPTED
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

# All broadcast outcomes
grep "task=broadcast_push" walletd.log | grep -v "task.dispatched"
```
