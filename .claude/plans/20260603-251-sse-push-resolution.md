# Plan — #251 Arcade SSE push resolution

- **Date:** 2026-06-03
- **Status:** ready for implementation (analyst phase to break down)
- **Issue:** sgbett/bsv-wallet#251
- **Parent:** #249 (umbrella), [ADR 20260603-broadcast-network-boundary](../../.architecture/decisions/adrs/20260603-broadcast-network-boundary.md)
- **Sibling already shipped:** #250 (Broadcaster + persisted affinity)

## TL;DR

Make Arcade's `/events` SSE stream the primary push channel for mempool resolution (Edge 2: SEEN / REJECTED / DOUBLE_SPEND_ATTEMPTED). In the same HLR, reshape `Engine::Broadcast#submit` to be the canonical broadcast entrypoint with explicit 202/400/503 dispatch and X-CallbackToken on every POST, so the listener has something to listen for. Validate end-to-end with on-chain tests in `spec/e2e/broadcast_spec.rb` — the double-spend scenario is the load-bearing acceptance bar; if SSE doesn't reliably surface REJECTED in bounded time, the ADR §5 decision must be revisited.

## 1. Architecture: Layer 1 / Layer 2 split

The SSE consumer is two layers, separated by an in-process bus:

**Layer 1 — raw SSE listener.** Connects to `https://arcade.gorillapool.io/events?callbackToken=<token>`, parses frames, emits onto an in-proc OMQ socket. Stateless beyond connection + cursor. No DB writes. Fast specs, no on-chain funds required.

**Layer 2 — event-application core.** The transport-agnostic logic extracted from `store/broadcast_callback.rb`: `decode → find_action(wtxid:) → reject_action | record_broadcast_result`, with the three invariant guards. Consumes the bus, applies events to the Store. Reused by both the SSE listener (new) and the ARC webhook receiver (already at `store/broadcast_callback.rb` — retained, not deleted).

For specs, Layer 1 assertions are deterministic and fast ("a frame with txid X and status Y arrived within window"); Layer 2 assertions are the few that require DB-state semantics ("after REJECTED, are inputs released?").

## 2. OMQ shape

```
[Arcade] --SSE--> [Network::Statuses fiber] --inproc PUSH--> [Engine::Broadcast pull!] --> Store
```

**Why PUSH/PULL over PUB/SUB:**

- A status update is a **state transition** (pending → SEEN → MINED), not a notification. Want exactly one worker applying it atomically through the Store — aligns with "Store owns atomicity" + "no invalid state" invariants.
- PUSH gives backpressure if the worker is slow; PUB silently drops, which is exactly the wrong failure mode for state-machine inputs.
- Second-subsystem reactions (e.g. proof retrieval kick-off) chain inside the worker after the Store transition commits — chained side-effects from a known-good state, not parallel reactions to a raw event.

**Tradeoff:** PUSH/PULL means one consumer. A future debug tap (log every event without affecting the worker) either tees inside the SSE fiber before pushing, or fronts the worker with a small PUB relay. Premature today.

**Nuance:** Arcade callback token is per-instance, so each wallet process owns its own SSE connection. Multi-worker-per-wallet (if it ever happens) makes the SSE consumer the single connection-holder process and PUSHes to a `tcp://` or `ipc://` PULL bound by the workers — same pattern, different transport on the same socket pair.

## 3. SSE transport

`async-http` Client streaming the response body. We're already in the Async reactor for `pull!`/`reply!` (per #250's daemon work), and async-http handles SSE naturally:

```ruby
client.get(url, {'Accept' => 'text/event-stream'})
  # returns a streaming body, iterate chunk-by-chunk
```

SSE framing (`event:`, `data:`, `\n\n` separator) is trivial to parse inline; no dedicated SSE gem needed. The consumer lives in the Network/Services layer alongside the Broadcaster — **receiving status callbacks is symmetric with sending raw_tx**.

## 4. Submit-side changes (canonical broadcast)

`Engine::Broadcast#submit` becomes the canonical broadcast mechanism for both inline (called synchronously from `create_action`) and daemon (called from the OMQ PULL loop after dequeue). The shape changes:

### 4.1 X-CallbackToken on every POST

The SSE listener is scoped by callback token (`?callbackToken=…`). Every broadcast must POST with a matching `X-CallbackToken` header so Arcade can correlate. Token is per-wallet (likely stored in a wallet-level config or derived deterministically — analyst phase to decide).

### 4.2 Three-codepath dispatch with pre-POST stamp + null-on-503

`mark_broadcast_attempted` runs **before** the POST (preserving today's timing). The 503 path explicitly nulls `broadcast_at` back out before returning, returning the row to the queued / push-discovery set for clean retry.

| Status | Action | Effect on `broadcast_at` |
|--------|--------|--------------------------|
| (pre-POST) | `mark_broadcast_attempted` stamps | NULL → now() |
| `202`  | `record_broadcast_results` (status fields, await callback for terminal) | stays stamped |
| `400`  | `reject_action` cascade (terminal failure — ARC saw and rejected synchronously) | stays stamped (row then deleted by cascade) |
| `503`  | **Null `broadcast_at`, return.** Daemon re-pulls next cycle. | reverted to NULL |

### 4.3 Why this shape (vs the alternative we considered)

We considered post-receipt timing (stamp only on 202/400, never on 503). The trade is **crash-during-POST safety vs duplicate-submit risk**:

- **Post-receipt timing:** clean state semantics, but a process crash between POST completion and response handling leaves `broadcast_at IS NULL` → daemon re-pulls → **duplicate submit**. Behaviour depends on how ARC responds to a duplicate wtxid. If ARC returns 400 ("already known"), our dispatch interprets that as terminal rejection → `reject_action` cascade unwinds a transaction that is actually in the mempool. That's a wallet correctness bug whose mitigation depends on an external contract (ARC's idempotency semantics) we haven't tested.
- **Pre-call + null-on-503 (this design):** crash-mid-POST leaves `broadcast_at IS NOT NULL, tx_status IS NULL` — the recognisable "submitted, awaiting outcome" state that the callback path and poll fallback already handle. No duplicate submit, no dependency on ARC's idempotency for correctness. Cost: one extra UPDATE per 503 occurrence (rare, on the slow path).

The 503 null-on-return is a single SQL statement against a single row; the window between receiving 503 and nulling `broadcast_at` is microseconds. A crash inside that window leaves the row stuck in "submitted, awaiting outcome" until callback / poll discovers it — slower recovery, not a correctness issue. Bounded, contained, explicit cost over invisible, unbounded, undocumented risk.

### 4.4 Set-once invariant softens to "state flag"

Today's schema.md describes `broadcast_at` as set-once (stamped on first attempt, never re-written). Under the null-on-503 path, that invariant softens to: `broadcast_at` is a **state marker** — NULL means the row is queued for submission, non-NULL means it has been submitted and is awaiting outcome. The `where(broadcast_at: nil)` predicate still prevents racing re-stamps within a single in-flight attempt; null-on-503 returns the row to the queued state. After a 503 + retry, `broadcast_at` reflects the retry timestamp, not the first attempt.

This is a documentation update that lands with #251 (schema.md and the store.rb comment both want softening).

### 4.5 `inline_broadcast` NOT deleted in this HLR

### 4.6 `inline_broadcast` NOT deleted in this HLR

Deletion depends on #252 (EF for daemon path). Until daemon-submit can produce EF from `action_id` alone, the inline path keeps the `tx:` kwarg shape (since the caller still has the live `Transaction` object). Once #252 lands, `inline_broadcast` collapses into `submit(action_id)` — a sibling HLR closes that loop.

## 5. Arcade status taxonomy

From [Arcade docs](https://docs.gorillapool.io/arcade) — the authoritative event vocabulary the listener will see:

### Accepted path

```
Client → Arcade
   ↓
RECEIVED            (validated locally)
   ↓
SENT_TO_NETWORK     (submitted to Teranode via HTTP)
   ↓
ACCEPTED_BY_NETWORK (acknowledged by Teranode)
   ↓
SEEN_ON_NETWORK     (heard in subtree gossip — in mempool)
   ↓
MINED               (heard in block gossip — included in block)
```

### Rejected path

```
REJECTED                  (from rejected-tx gossip)
DOUBLE_SPEND_ATTEMPTED    (from rejected-tx gossip with specific reason)
```

**ADR §5 open item closed:** Arcade *does* distinguish `DOUBLE_SPEND_ATTEMPTED` from generic `REJECTED`. The wallet's `ArcStatus` taxonomy preserves the distinction; no granularity loss into telemetry. Update the ADR's open-items list when #251 lands.

## 6. Test plan

### 6.1 Test infrastructure

- **Rename existing `gem/bsv-wallet/spec/e2e/broadcast_spec.rb` → `e2e_workload_spec.rb`** — that file is the HLR #126 e2e on-chain workload harness (~10k tx over ~1 hour). The new name reflects the file's actual scope per #126 and avoids the naming collision with the #129 stress cascade (which lives separately at `gem/bsv-wallet/spec/integration/stress_cascade_spec.rb`). Frees up `broadcast_spec.rb` for the new SSE-driven scenarios.
- **`before(:all)` consolidate/sweep** for e2e tests: each scenario starts from a known wallet state via the existing e2e harness machinery (the sweep_to_root + import_utxos pattern).
- **MINED-event filtering**: e2e tests filter out MINED frames from assertions (block timing is out of scope per #246's domain). Log them for diagnostics; don't gate test outcomes on them.
- **Bounded windows**: e2e assertions use timeouts (default 10s for SSE delivery, configurable). The double-spend test specifically asserts on the bound — slow REJECTED defeats the purpose.

### 6.2 Layer 1 — raw SSE listener (unit, no on-chain funds)

| # | Test |
|---|------|
| L1.1 | Well-formed frame parses to expected shape (id / event / data). Multi-line `data:` handled. Keepalive comments ignored. |
| L1.2 | Reconnect with `Last-Event-ID` from persisted `sse_cursors` row. |
| L1.3 | Cursor survives listener restart (write cursor row → restart → read cursor → reconnect with it). |
| L1.4 | Slow-consumer drop is bounded; reconnect-with-cursor recovers. Spec asserts: drop a batch on the wire, reconnect, replay arrives. |
| L1.5 | Token-scoped delivery (mock Arcade locally; assert frames for other tokens don't arrive). |
| L1.6 | Malformed frame doesn't crash the listener — logs + skips + continues. |

### 6.3 Layer 2 — event-application core (unit, mocked DB or Postgres)

| # | Test |
|---|------|
| L2.1 | `SEEN_ON_NETWORK` → `record_broadcast_result` writes tx_status. |
| L2.2 | `REJECTED` → `reject_action` cascade: action deleted, inputs released, outputs un-promoted. |
| L2.3 | `DOUBLE_SPEND_ATTEMPTED` → same as REJECTED (terminal unwind) but preserves the distinct status in telemetry. |
| L2.4 | `CannotRejectInternalActionError` → `increment_broadcast_retry`, no crash. |
| L2.5 | `CannotRejectAcceptedActionError` → log + ACK, no retry (no-invalid-state invariant; reachable only via re-org). |
| L2.6 | Unknown wtxid → log + skip, no crash. |
| L2.7 | Idempotent on current-state: applying REJECTED twice doesn't double-unwind; applying SEEN then REJECTED produces same end-state as REJECTED alone. |

### 6.4 E2E on-chain — `spec/e2e/broadcast_spec.rb`

Live funds. `before(:all)` consolidate/sweep. Assertions on bounded windows. MINED filtered. Each test creates actions via `Engine#create_action(inputs: [{ output_id: N }], outputs: [...])` for explicit input control (no auto-fund magic).

| # | Name | What it tests |
|---|------|---------------|
| E1 | Basic Send | Fan-out from SDK to W1..W5 (4 delayed + 1 inline). Broadcast all 4 delayed via the Broadcaster path. Assert SSE listener observes 5 `SEEN_ON_NETWORK` events within window. |
| E2 | Send parent + child | Two actions with explicit `inputs: [{ output_id }]` selecting known UTXOs (not auto-fund). Broadcast parent then child. Assert SSE observes both SEEN within window, in arrival order. |
| E3 | Long chain | 10-deep chain with explicit inputs at each step. Broadcast in order. Assert SSE observes events for tx 1–9 (10 is inline). Listener throughput sanity. |
| E4 | **Double-spend (LOAD-BEARING)** | Pre-broadcast Action 3 (spends output A). Then attempt `broadcast(Action 1)` which also spends A. Assert SSE delivers `REJECTED` (or `DOUBLE_SPEND_ATTEMPTED`) for Action 1 within window. **If this doesn't pass reliably, ADR §5 SSE-primary decision is invalidated.** |
| E5 | Reconnect during flight | Broadcast a tx. Kill listener before its SEEN frame arrives. Wait for the frame to have been emitted server-side. Restart listener with cursor. Assert catchup delivers the (current-status) frame. |
| E6 | Long-lived connection | Open listener, idle for N minutes (configurable, default 5), broadcast a tx, assert keepalive didn't drop the connection and the event arrives. Guards against silent connection death. |
| E7 | Double-spend timing race | Broadcast Action A and conflicting Action A' in tight succession. One wins, one is REJECTED. Assert: exactly one SEEN and one REJECTED arrive. |
| E8 | Reject reason granularity capture | Capture the rejected frame's `txStatus` for the double-spend case. Document what Arcade actually emits (REJECTED vs DOUBLE_SPEND_ATTEMPTED). Closes the ADR §5 open item with concrete evidence. |

## 7. Open implementation questions (for analyst phase)

- **Idempotency of submit on duplicate** — *diagnostic value only, no longer correctness-critical.* The pre-call + null-on-503 design (§4.2/§4.3) avoids the duplicate-submit path on crash-mid-POST: a crash leaves `broadcast_at IS NOT NULL` so the daemon does not re-pull. Probe ARC's duplicate-submit behaviour anyway when convenient — useful for telemetry and for understanding what an unexpected 4xx response in the wild might mean — but it's no longer a blocker for landing #251.
- **Callback token provenance.** Per-wallet, but how generated and where persisted? Likely a settings-level value, derived from wallet key or random + persisted at init. Analyst phase decides.
- **`sse_cursors` schema.** `(token PK, last_event_id BIGINT, updated_at TIMESTAMP)` per the ADR. Confirm migration number, FK if any.
- **OMQ socket bind paths.** `inproc://statuses.push` and `inproc://statuses.pull`? Match the existing pattern from `Engine::Broadcast`.
- **Where the SSE listener constructor lives.** `BSV::Network::SSEListener.new(token:, store:, push_socket:)` — standalone class, daemon constructs it as one of its Async tasks. No daemon flag needed; the listener is just always-on when the daemon runs.
- **WoC reconciliation sweep.** Tail of the resolution story for SEEN_ON_NETWORK rows older than threshold. Sub-task within #251 or a separate follow-up?

## 8. Out of scope (explicit)

- **`inline_broadcast` deletion** — depends on #252's EF-for-daemon work. The path continues to exist post-#251; it just routes through `submit` internally.
- **Block-driven MINED resolver** — #246, parallel work.
- **EF for daemon broadcast path** — #252.
- **Multi-wallet daemon / multi-token listener** — deferred per "premature today" note.
- **Network partition / TCP-level drop testing** — overlaps with E5 reconnect; not worth extra harness machinery.
- **Block mining timing** — out of scope per user direction. Tests resilient to whether blocks come during runs.

## 9. Sequencing within the HLR

Suggested analyst-phase breakdown:

1. **Rename + scaffold** — rename existing broadcast_spec.rb → e2e_workload_spec.rb; scaffold the new broadcast_spec.rb file
2. **Layer 2 extraction** — pull the transport-agnostic core out of `store/broadcast_callback.rb`. ARC webhook spec stays green.
3. **`sse_cursors` migration** — small, additive.
4. **Layer 1 listener** — standalone class + Layer 1 unit specs.
5. **OMQ wiring** — listener PUSHes, Engine::Broadcast pulls (alongside existing broadcasts.pull).
6. **submit reshape** — X-CallbackToken header, 3-codepath dispatch, mark_broadcast_attempted timing shift.
7. **E2E tests** — implement one scenario at a time, starting with E4 (double-spend; load-bearing).

E4 should land first among the e2e tests because if it fails, everything downstream is in question — better to learn early than build out the rest of the test suite first.

## 10. Definition of done

- All Layer 1 + Layer 2 unit tests pass under Postgres and SQLite.
- All 8 e2e scenarios pass against `arcade.gorillapool.io` mainnet.
- `inline_broadcast` and daemon submit both route through `submit(action_id)` (the inline path still passes `tx:` until #252).
- ADR §5 open item on "Arcade SSE event coverage + resumption" updated to "verified live" with the captured evidence from E8.
- `Engine::Broadcast` constructor accepts (or constructs) the SSE listener as a peer; daemon wiring in `Daemon` runs the listener as one of its Async tasks.
- Documentation updated:
  - `reference/schema.md` Phase 3: soften "Set-once invariant" framing to "state flag" (per §4.4); add `sse_cursors` to the schema reference.
  - Store comment on `mark_broadcast_attempted` updated to describe null-on-503 path.
  - Rename of `broadcast_spec.rb` → `e2e_workload_spec.rb` reflected anywhere it's referenced.
