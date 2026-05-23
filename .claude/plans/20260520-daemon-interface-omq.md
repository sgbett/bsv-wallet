# walletd — The Wallet Daemon (#36 + #128)

## Context

The wallet has been a library — instantiated, used, discarded. No persistent process. `walletd` changes that. It's a persistent process that runs the wallet library internally, driven by omq sockets and internal discovery loops.

This plan covers the first step: `walletd` runs the four known background tasks. CLI tools continue to boot their own library instance for now. The path to thin CLI clients, horizontal scaling, and wallet-to-wallet ABI streaming is noted but not in scope.

---

## The Big Picture (where we're heading)

```
Phase 1 (this HLR):  walletd runs background tasks internally
Phase 2:             CLI tools become thin clients (REQ → walletd REP)
Phase 3:             Multiple walletd processes (PUSH/PULL fan-out)
Phase 4:             API process binds TCP, wallets talk to each other
Phase 5:             ABI binary streaming over omq sockets
```

Each phase adds a process boundary. The library code inside doesn't change. omq handles the boundary.

---

## Phase 1 Deliverables

### `bin/walletd`

A persistent process that:
1. Boots the wallet library (CLI.boot — database, models, engine, services)
2. Runs an Async reactor with omq sockets
3. Executes background tasks via discovery loops
4. Shuts down gracefully on SIGINT/SIGTERM

### omq Integration

Add `gem 'omq'` to bsv-wallet.gemspec. The daemon runs inside `Async do` and uses omq's fiber-based concurrency for non-blocking task execution.

### The Four Background Tasks

Each task is a discovery loop inside the reactor. Discovery finds outstanding work in the database; the handler processes each entity using the library's existing methods.

```ruby
Async do |task|
  # Task 1: Push delayed broadcasts
  task.async do
    loop do
      Broadcast.where(broadcast_at: nil).all.select(&:needs_push?).each do |broadcast|
        services.push!(broadcast)
      end
      sleep interval
    end
  end

  # Task 2: Poll broadcast status
  task.async do
    loop do
      Broadcast.exclude(broadcast_at: nil)
               .exclude(tx_status: Broadcast::TERMINAL_STATUSES)
               .all.select(&:needs_fetch?).each do |broadcast|
        services.fetch!(broadcast)
      end
      sleep interval
    end
  end

  # Task 3: Acquire proofs
  task.async do
    loop do
      Action.where(outgoing: true).exclude(wtxid: nil)
            .where(tx_proof_id: nil).all.each do |action|
        services.fetch!(action)
      end
      sleep interval
    end
  end

  # Task 4: Scan WBIKD addresses
  task.async do
    loop do
      engine.scan_receive_addresses
      sleep interval
    end
  end
end
```

Each task runs in its own fiber. When one blocks on `sleep` or I/O, others run. This is cooperative concurrency — no threads, no GVL contention, no shared mutable state concerns.

### Lifecycle Events

The daemon emits structured events for observability:

```ruby
def with_lifecycle(task_name, entity = nil)
  emit(:dispatched, task_name, entity: entity)
  yield
  emit(:succeeded, task_name, entity: entity)
rescue StandardError => e
  emit(:failed, task_name, entity: entity, error: e)
end
```

Consumers subscribe via `on_event(&block)`. The E2E test (#131) wires a log sink.

### Quiescence / Drain

For cleanup coordination (#131's sweep phase):

```ruby
def quiescent?
  @active_dispatches.zero?
end

def drain(timeout: nil)
  deadline = timeout ? Time.now + timeout : nil
  loop do
    return true if quiescent?
    return false if deadline && Time.now >= deadline
    sleep 0.05
  end
end
```

---

## What Stays, What Goes

| Component | Status |
|-----------|--------|
| `BSV::Wallet::Daemon` (existing) | **Superseded** by walletd. Keep for now, deprecate later. |
| `BSV::Wallet::PollingScheduler` (PR #133) | **Delete** — wrong abstraction. |
| `BSV::Wallet::Interface::Scheduler` (PR #133) | **Delete** — no abstract interface needed. |
| `Pushable` / `Fetchable` | **Keep** — entity contracts used by Services.push!/fetch! |
| `Services.push!` / `Services.fetch!` | **Keep** — the handlers walletd calls |

---

## Files

| File | Change |
|---|---|
| `gem/bsv-wallet/bin/walletd` | **New** — the daemon process |
| `gem/bsv-wallet/bsv-wallet.gemspec` | Add `omq` dependency |
| `gem/bsv-wallet/spec/bsv/wallet/walletd_spec.rb` | **New** — tests |
| `gem/bsv-wallet/lib/bsv/wallet/interface/scheduler.rb` | **Delete** |
| `gem/bsv-wallet/lib/bsv/wallet/polling_scheduler.rb` | **Delete** |
| `gem/bsv-wallet/spec/bsv/wallet/polling_scheduler_spec.rb` | **Delete** |

---

## Testing Strategy

1. **Task discovery** — each task's query returns correct entities
2. **Task execution** — handler is called for each discovered entity
3. **Error isolation** — one entity failure doesn't stop others
4. **Lifecycle events** — dispatched/succeeded/failed emitted correctly
5. **Quiescence** — correct during and after dispatch
6. **Graceful shutdown** — stop signal exits after current cycle
7. **Cold boot** — outstanding work found and processed on startup

---

## Open Questions

1. **Should walletd accept external messages in Phase 1?** The four tasks are internal discovery loops — no socket needed yet. Adding a REP socket for external dispatch is Phase 2 territory (CLI thin clients). But having the socket infrastructure in place from day one means less rework later. Leaning toward: bind a REP socket even in Phase 1, but only the discovery loops use it initially.

2. **Interval per task or global?** Different tasks may want different polling intervals (broadcasts every 5s, proofs every 30s, WBIKD every 60s). Each fiber can have its own sleep interval.

3. **How does #131 wire its lifecycle logging?** The daemon needs to expose `on_event` before starting. The E2E test would construct the daemon, subscribe to events, then start.

---

## Verification

```bash
cd gem/bsv-wallet && bundle exec rspec
cd gem/bsv-wallet && bundle exec rubocop
```
