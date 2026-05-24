# Daemon Lifecycle Events

**Issue:** #167 (HLR); closes the "Lifecycle events logged for observability" criterion on #36
**Related:** #126 (e2e on-chain — consumes these events for its logfile), #113 (status polling — will adopt the same conventions when implemented), #111 (broadcast push outcome policy — events make the policy observable)
**Branch:** `feat/167-daemon-lifecycle-events`
**Date:** 2026-05-24
**Status:** Implemented (PR #175). Also addresses #176 (OMQ bind visibility), #177 (placeholder-proof linking), #178 (reason-value harmonization).

## Overview

walletd today emits ad-hoc log lines via `BSV.logger&.info/warn/error` at three places (`Daemon`, `Scheduler`, `Engine::Broadcast`). The lines are human-readable strings, inconsistent in shape, and sparse in coverage — mostly only errors. The #126 e2e test and ongoing operational observability both need:

> **Architecture note (current):** `Store` is a class (`BSV::Wallet::Store`) with `SQLite < Store` and `Postgres < Store` concrete implementations. ProofStore methods (`save_proof`, `link_proof`, `find_proof`) live directly on Store — no separate ProofStore class. All engine ↔ Store interactions go through the Store interface (`@store.xxx`); engines never access Store models directly.

- Structured, grep-friendly events
- Coverage of the full task lifecycle (not just errors)
- A consistent shape that doesn't require bespoke parsing per task type

The solution is a tiny helper (`BSV::Wallet.emit`) plus a documented event taxonomy and emit points across the existing daemon code paths. No framework, no observer registry, no typed event classes — just discipline backed by a one-method API.

## Scope

### In scope

1. `BSV::Wallet.emit(name, **payload)` helper — single method, formats `key=value`, writes via `BSV.logger` at `:info` level
2. Canonical event taxonomy (10 names across daemon / fiber / task layers — see Design)
3. Emit points in:
   - `Daemon#run!` and `Daemon#stop!`
   - `Scheduler#schedule` (discovery, enqueue) — requires a new `name:` parameter
   - `Engine::Broadcast#process` (dispatch, success, fail, abort, skip) — requires ARC response categorisation
   - `Engine::TxProof#process` (dispatch, success, skip — the simpler subset)
4. Tests for the helper plus event-assertion updates in daemon/scheduler/broadcast/tx_proof specs
5. Documentation comment on `emit` listing canonical event names and the payload convention

### Out of scope (deferred)

- Status polling task instrumentation — comes with #113 implementation
- WBIKD scanning task instrumentation — comes with #114
- Dedicated event log stream (separate from `BSV.logger`) — for v1, the walletd `--log-file` already lets the operator route everything to a file; e2e test does the same
- Event schema validation / registry — convention only at v1
- Metrics aggregation / dashboards
- ~~Backfilling `task.aborted` to existing Engine::Broadcast paths if `abort_action` is not yet called on definitive rejections (see Risk #2)~~ — **done** in commit `bf031fe`; Risk #2 resolved

## Design

### The helper

```ruby
# gem/bsv-wallet/lib/bsv/wallet.rb (or a small new lib/bsv/wallet/events.rb)
module BSV
  module Wallet
    # Structured event emission.
    #
    # Writes a single line to BSV.logger at :info level. Format:
    #   "[event] <name> key=value key=value ..."
    #
    # Convention: values must be "shell word" shaped (no spaces). The
    # helper will quote values containing whitespace for safety, but
    # callers should normalise (e.g. reason=arc_rejected, not
    # reason="ARC rejected the tx"). No secrets or binary blobs in
    # payloads.
    #
    # Canonical event names — keep in sync with this comment as the
    # taxonomy evolves:
    #
    #   daemon.started       wallet=X network=Y
    #   daemon.stopped       reason=signal
    #   fiber.crashed        task=X error=...
    #   task.discovered      task=X count=N
    #   task.enqueued        task=X id=N
    #   task.dispatched      task=X id=N
    #   task.succeeded       task=X id=N latency_ms=M outcome=...
    #   task.failed          task=X id=N latency_ms=M reason=...
    #   task.aborted         task=X id=N reason=... arc_status=...
    #   task.skipped         task=X id=N reason=...
    def self.emit(name, **payload)
      return unless BSV.logger
      fields = payload.map { |k, v| format_field(k, v) }.compact.join(' ')
      BSV.logger.info("[event] #{name}#{fields.empty? ? '' : ' '}#{fields}")
    end

    def self.format_field(key, value)
      return nil if value.nil?
      str = value.to_s
      str = "\"#{str.gsub('"', '\\"')}\"" if str.match?(/\s/)
      "#{key}=#{str}"
    end
  end
end
```

Sized to fit on a screen. Lives under `BSV::Wallet` rather than `BSV.` — these are wallet-specific events; we don't pollute the upstream `BSV` namespace.

### Event taxonomy

Three layers, verb-noun dotted snake_case:

**Daemon lifecycle** (2 events):

| Event | Payload | When |
|---|---|---|
| `daemon.started` | `wallet`, `network` | end of `Daemon#run!` setup, before blocking |
| `daemon.stopped` | `reason` (signal / shutdown / error) | start of `Daemon#stop!` |

**Fiber lifecycle** (1 event):

| Event | Payload | When |
|---|---|---|
| `fiber.crashed` | `task`, `error` | inside a fiber's rescue when an unrecoverable error escapes |

**Task lifecycle** (7 events):

| Event | Payload | When |
|---|---|---|
| `task.discovered` | `task`, `count` | Scheduler — after discovery query returns ≥1 items |
| `task.enqueued` | `task`, `id` | Scheduler — per item pushed onto OMQ socket |
| `task.dispatched` | `task`, `id` | Logical model — entry to `#process(id)` |
| `task.succeeded` | `task`, `id`, `latency_ms`, `outcome` | Logical model — completed successfully |
| `task.failed` | `task`, `id`, `latency_ms`, `reason` | Logical model — transient failure (will be re-discovered) |
| `task.aborted` | `task`, `id`, `reason`, `arc_status?` | Logical model — terminal failure (no re-discovery; for broadcast push, `abort_action` is invoked per #111) |
| `task.skipped` | `task`, `id`, `reason` | Logical model — work no longer applicable (e.g. action already broadcast, no raw_tx) |

**Distinction between `failed`, `aborted`, `skipped`** — load-bearing:

- `failed` = transient. Re-discoverable next cycle. e.g. rate-limited, transport error, stale BEEF (suck-it-and-see per #126).
- `aborted` = terminal. Permanently failed. `abort_action` invoked. Will never be re-discovered.
- `skipped` = benign no-op. Idempotency catch — discovery found something that's already done by the time we got to it.

### Emit points (concrete)

#### `Daemon#run!`

```ruby
def run!
  Async do |task|
    @task = task
    setup_signal_traps

    broadcast = Engine::Broadcast.new(store: @store, services: @services)
    broadcast.pull!(task: task)
    broadcast.reply!(task: task)

    tx_proof = Engine::TxProof.new(store: @store, services: @services)
    tx_proof.pull!(task: task)

    scheduler = Scheduler.new(store: @store)
    scheduler.run!(task: task)

    BSV::Wallet.emit('daemon.started', wallet: @wallet_name, network: @network)
  end
end

def stop!
  BSV::Wallet.emit('daemon.stopped', reason: 'signal')
  @task&.stop
end
```

Implication: `Daemon#initialize` needs to accept (or derive) `wallet:` and `network:` so the started event can include them. Today these aren't passed in (walletd has them in scope but doesn't pass through). Small constructor change.

#### `Scheduler#schedule` (introduce `name:`)

```ruby
def run!(task:)
  schedule(task: task, name: 'broadcast_push', endpoint: 'inproc://broadcasts.pull', interval: 5) do
    Engine::Broadcast.pending(@store, limit: 10)
  end

  schedule(task: task, name: 'proof_acquisition', endpoint: 'inproc://proofs.pull', interval: 30) do
    Engine::TxProof.pending(@store, limit: 10)
  end
end

private

def schedule(task:, name:, endpoint:, interval:, &discovery)
  task.async do
    push = OMQ::PUSH.connect(endpoint)
    loop do
      ids = discovery.call
      BSV::Wallet.emit('task.discovered', task: name, count: ids.size) if ids.any?
      ids.each do |id|
        push << id.to_s
        BSV::Wallet.emit('task.enqueued', task: name, id: id)
      end
      sleep interval
    rescue StandardError => e
      BSV::Wallet.emit('fiber.crashed', task: name, error: e.message)
    end
  end
end
```

#### `Engine::Broadcast#process`

```ruby
def process(action_id)
  BSV::Wallet.emit('task.dispatched', task: 'broadcast_push', id: action_id)
  started_at = Time.now

  action = @store.find_action(id: action_id)
  unless action && action[:raw_tx]
    BSV::Wallet.emit('task.skipped', task: 'broadcast_push', id: action_id, reason: 'no_raw_tx')
    return
  end

  response = @services.call(:broadcast, action[:raw_tx])
  latency_ms = ((Time.now - started_at) * 1000).round

  if response.http_success?
    # Success responses are normalized by BSV::Network::Services to
    # symbol + snake_case keys (:tx_status, :block_hash, etc.).
    data = response.data
    @store.record_broadcast_result(
      action_id: action_id,
      tx_status: data[:tx_status],
      arc_status: data[:status],
      block_hash: data[:block_hash],
      block_height: data[:block_height],
      merkle_path: data[:merkle_path],
      extra_info: data[:extra_info],
      competing_txs: data[:competing_txs]
    )
    BSV::Wallet.emit('task.succeeded',
                     task: 'broadcast_push', id: action_id,
                     latency_ms: latency_ms,
                     outcome: categorize_outcome(data[:tx_status]))
  elsif terminal_failure?(response)
    # Failure responses are returned raw (unnormalized) — string +
    # camelCase keys from the provider's JSON.parse.
    @store.abort_action(action_id: action_id)
    BSV::Wallet.emit('task.aborted',
                     task: 'broadcast_push', id: action_id,
                     reason: categorize_reason(response),
                     arc_status: response.data['txStatus'])
  else
    BSV::Wallet.emit('task.failed',
                     task: 'broadcast_push', id: action_id,
                     latency_ms: latency_ms,
                     reason: categorize_reason(response))
  end

  @store.broadcast_status(action_id: action_id)
end
```

> **Critical implementation note (learned via Copilot review on PR #175):**
> `BSV::Network::Services#call` normalizes **success** responses to symbol + snake_case keys (`:tx_status`, `:merkle_path`, etc.) via `normalize_broadcast_response`. **Failure** responses bypass normalization and carry raw provider keys (string + camelCase: `'txStatus'`, `'merklePath'`). The success and failure paths MUST use different key conventions. This distinction applies to Engine::Broadcast AND Engine::TxProof.

This requires three new helpers in `Engine::Broadcast`:

- `categorise_outcome(tx_status)` → `:accepted` (one of ACCEPTED_STATUSES) | `:pending` (intermediate) | `:rejected` (terminal — though this branch likely won't fire on http_success)
- `categorise_reason(response)` → `:rate_limited` | `:transport_error` | `:stale_beef` | `:malformed` | `:double_spend` | `:policy_violation` | `:unknown`
- `terminal_failure?(response)` → boolean, derived from response status + reason category. Aligns with #111's outcome policy.

Categorisation is the biggest substantive change in this PR — it's where #111's outcome policy stops being aspirational and becomes code. **See Risk #2 below**: this work surfaces whether `abort_action` is currently called on terminal failures; if it isn't, that's a #111 gap we need to address as part of this work (or split out).

#### `Engine::TxProof#process`

Same shape as Engine::Broadcast but simpler:

- `task.dispatched` on entry
- `task.skipped` if action has no `wtxid` or proof already present
- `task.succeeded` on proof acquired (`outcome=acquired`) or transient (`outcome=not_yet_mined`)
- `task.failed` only on actual transport/provider failure
- No `task.aborted` for proof acquisition — there's no "definitive rejection" for proof requests; you just keep asking until the proof exists

### Open design decision: `BSV.emit` vs `BSV::Wallet.emit`

Two options:

| Option | Pros | Cons |
|---|---|---|
| `BSV.emit` | Shortest call site; mirrors `BSV.logger` | Pollutes upstream `BSV` namespace; "events" are wallet-specific |
| `BSV::Wallet.emit` | Honest namespace ownership; longer-lived if events evolve | Slightly longer call site |

**Recommendation:** `BSV::Wallet.emit`. The events are wallet-domain. If the SDK ever wants its own events helper, it gets `BSV.emit` separately without a namespace fight.

If this changes, the only edit is the `def self.emit` location.

## Implementation outline

Order matters; each step is testable in isolation.

1. **Add `BSV::Wallet.emit` + spec** — new file `gem/bsv-wallet/lib/bsv/wallet/events.rb` (or inline in `wallet.rb`), new spec `gem/bsv-wallet/spec/bsv/wallet/events_spec.rb`. Covers: format, empty payload, nil values skipped, value quoting, no-logger-no-op.
2. **Update Daemon** — emit `daemon.started`/`daemon.stopped`, accept `wallet:`/`network:` in constructor, walletd passes them through. Update `bin/walletd` and `daemon_spec.rb`.
3. **Update Scheduler** — add `name:` parameter, emit `task.discovered`/`task.enqueued`/`fiber.crashed`. Update `scheduler_spec.rb`.
4. **Update Engine::Broadcast** — add categorisation helpers, emit the five task events, wire `abort_action` on terminal failure if not already there. Update broadcast spec.
5. **Update Engine::TxProof** — same pattern, simpler. Update tx_proof spec.
6. **Documentation pass** — update CLAUDE.md / strategy doc / #36 to point at the canonical event taxonomy.

## Tests

### `events_spec.rb`

- emits `"[event] daemon.started wallet=alice network=mainnet"` for typical payload
- emits just `"[event] daemon.stopped"` for empty payload
- emits without `key=` for nil values (skipped)
- quotes values containing whitespace (`reason="something with spaces"`)
- no-op when `BSV.logger` is nil
- writes at `:info` level (not `:debug`)

### Daemon spec

- on `run!`, emits `daemon.started` with wallet + network
- on `stop!`, emits `daemon.stopped`

### Scheduler spec

- per cycle, with N items discovered: emits one `task.discovered` (count=N) and N `task.enqueued`
- with zero items discovered: no `task.discovered`, no `task.enqueued`
- on fiber rescue: emits `fiber.crashed` with the error message

### Engine::Broadcast spec

For each ARC response shape, assert the correct event is emitted with the expected fields:

| Scenario | Event | Key fields |
|---|---|---|
| accepted (SEEN_ON_NETWORK) | `task.succeeded` | `outcome=accepted` |
| accepted (MINED) | `task.succeeded` | `outcome=accepted` |
| rate limited (429, all providers exhausted) | `task.failed` | `reason=rate_limited` |
| transport error | `task.failed` | `reason=transport_error` |
| definitive rejection (REJECTED) | `task.aborted` | `reason=arc_rejected arc_status=REJECTED` (plus `abort_action` called on store) |
| no raw_tx | `task.skipped` | `reason=no_raw_tx` |
| action not found | `task.skipped` | `reason=action_not_found` |

### Engine::TxProof spec

- proof acquired → `task.succeeded outcome=acquired`
- still pending (no merkle path yet) → `task.succeeded outcome=not_yet_mined`
- transport error → `task.failed reason=transport_error`
- action already proven → `task.skipped reason=already_proven`

## Acceptance criteria

- [ ] `BSV::Wallet.emit(name, **payload)` exists with documented canonical event names
- [ ] Daemon emits `daemon.started` (with wallet + network) and `daemon.stopped`
- [ ] Scheduler emits `task.discovered`, `task.enqueued`, and `fiber.crashed`
- [ ] Scheduler accepts a `name:` parameter per task and uses it in events
- [ ] Engine::Broadcast emits `task.dispatched` on entry, plus exactly one of `task.succeeded`/`task.failed`/`task.aborted`/`task.skipped` per process call
- [ ] Engine::TxProof emits the appropriate subset (`task.dispatched`, `task.succeeded` or `task.skipped`, `task.failed` on transport errors)
- [ ] All task events carry `task=` and `id=` minimum
- [ ] `task.succeeded`/`task.failed` carry `latency_ms`
- [ ] `task.aborted` carries `reason=` and `arc_status=` (for broadcast push)
- [ ] On terminal-failure ARC response, `Store#abort_action` is invoked (closes the #111 gap if it exists today)
- [ ] All existing wallet specs still pass
- [ ] New events_spec covers helper format, nil/non-string values, whitespace quoting, no-logger no-op
- [ ] Daemon / Scheduler / Engine::Broadcast / Engine::TxProof specs assert expected events emitted
- [ ] Rubocop clean
- [ ] #36's "Lifecycle events logged for observability" criterion ticked

## Risks / things to watch

1. **Latency metric scope.** Measuring `dispatched → succeeded/failed` (work duration only). Queue wait is omitted; that's deliberate but worth being aware of if a queueing-bottleneck question ever arises. Adding queue-wait later means including `enqueued_at` in the message payload over OMQ — non-trivial structural change. Defer until needed.

2. **~~`abort_action` on terminal failure — possibly a #111 gap.~~ RESOLVED.** The gap was real — `abort_action` was never called on ARC rejections. Fixed in commit `bf031fe` (#171). `terminal_failure?` distinguishes ARC rejections (REJECTED, DOUBLE_SPEND_ATTEMPTED, MALFORMED, ORPHAN) from transport errors and the explicitly-transient MINED_IN_STALE_BLOCK.

3. **ARC response categorisation taxonomy.** `categorise_reason` needs a stable mapping from response shape → category. Initial set: `:rate_limited`, `:transport_error`, `:stale_beef`, `:malformed`, `:double_spend`, `:policy_violation`, `:unknown`. May need refinement as we observe real ARC responses in #126. The `:unknown` bucket is the escape hatch — anything not yet classified gets it; we sharpen the mapping over time without breaking event consumers.

4. **`task.enqueued`/`task.dispatched` symmetry under fiber interleaving.** Async reactor + OMQ inproc means events from different fibers interleave in the logger output. Per-id sequences are still derivable via `grep "id=42"`. If perfectly-ordered visualization becomes important, post-processing the log (sort by timestamp then id) handles it. No correctness issue.

5. **Sensitive data hygiene.** Payloads must not include raw_tx bytes, WIFs, full BEEF blobs, or anything else that would be unsafe in a logfile. The convention is documented in the helper's comment; reviewers should flag emit calls that violate it.

6. **Walletd config plumbing.** `Daemon` currently doesn't take `wallet:`/`network:` in its constructor — `bin/walletd` has them in scope but doesn't pass them. Minor plumbing change; non-controversial.

7. **Backward compatibility for log readers.** Anyone currently parsing the existing `[Daemon]`/`[Scheduler]`/`[Engine::Broadcast]` log lines will see them disappear. There aren't known consumers (these are dev-time diagnostics), but a one-line note in CHANGELOG or commit message is appropriate.

## Sequencing

This PR closes the lifecycle-events acceptance criterion on #36 and provides the substrate that #126's e2e logfile depends on. After this lands:

1. **#36** — almost complete; the only remaining substantive child is #113 (status polling) + #114 (WBIKD, deferred per current focus).
2. **#113** — when implemented, adopts the same `task.*` event vocabulary with `task=status_poll`. Status transitions captured in a `transition=QUEUED→SEEN_ON_NETWORK` field per the convention.
3. **#114** — same pattern; trivial event surface (likely just `task.dispatched`/`task.succeeded`/`fiber.crashed`).
4. **#126** — the e2e test's `tmp/e2e-{timestamp}.log` is now a thin sink around `BSV::Wallet.emit` events. The test harness sets `BSV.logger` to a file logger; the event lines fall out for free.

The work after this is observation, not instrumentation: do the events tell the story we need them to? If `:unknown` reasons dominate, sharpen the categorisation. If `latency_ms` clusters show unexpected patterns, investigate. The event substrate makes those questions answerable.

## Verification

```bash
cd gem/bsv-wallet
bundle exec rspec
bundle exec rubocop

# Smoke test — start walletd briefly, capture events
LOG_FILE=/tmp/walletd-events.log BSV_WALLET_BACKEND=sqlite bundle exec bin/walletd default &
sleep 5
kill %1
grep "^\[event\]" /tmp/walletd-events.log    # should show daemon.started, possibly task.discovered with count=0, daemon.stopped
```

## Discovered during implementation

Three follow-up issues raised and resolved within the same PR:

1. **#176 — Silent OMQ bind failure** (`ad62394`). `Engine::Broadcast#pull!`/`#reply!` and `Engine::TxProof#pull!` could silently go deaf when a bind raised (e.g. inproc endpoint already registered). Fix: `bind_or_die` helper emits `fiber.crashed` + re-raises. OMQ inproc reset lifted to shared `spec_helper` hook.

2. **#177 — Placeholder-proof linking in internalize** (`8c60cf1`). `save_beef_proofs` called `link_proof` whenever it saw the subject in the BEEF, regardless of merkle_path presence. Fix: gate on `merkle_path` existence. Also added `tx_proof_id` to `action_to_hash` and wired the `already_proven` skip branch in `Engine::TxProof#process`.

3. **#178 — Reason value type inconsistency** (`86d0992`). Skip-branch reasons were strings; `categorize_reason` returned symbols. Harmonized to symbols throughout (`.to_s` in the emit helper means identical log output).

4. **Copilot review — Services normalization key shape** (`024cac1`). Success responses from `BSV::Network::Services` are normalized to symbol + snake_case keys; failure responses are raw string + camelCase. The initial implementation read camelCase strings everywhere (matching broken test stubs, not production behavior). Fix: success-path reads now use normalized keys; failure-path reads kept raw. Test fixtures corrected to match the normalized shape for success stubs.

## Out of scope

- Status polling task instrumentation (own issue: #113)
- WBIKD scanning task instrumentation (own issue: #114)
- Dedicated event logger separate from `BSV.logger`
- Event schema registry / validation
- Metrics aggregation
- Backfilling old log readers — the diagnostic strings are replaced wholesale
