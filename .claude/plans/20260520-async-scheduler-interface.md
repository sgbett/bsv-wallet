# Async Task Interface — Pluggable Background Work Execution (#128)

## Context

The wallet needs asynchronous background work but has no abstraction for scheduling it. The Daemon class is a valid polling loop but it's hardcoded — no interface contract, no pluggability, no lifecycle events. The wallet follows an Interface module pattern everywhere else (Store, ProofStore, BroadcastQueue, UTXOPool). Async scheduling should follow the same pattern.

The framework provides scheduling primitives. It doesn't know what tasks do. It doesn't retry failed handlers. It doesn't interpret outcomes. Tasks own their behavior; the framework owns the clock.

---

## Design

### The Interface: `BSV::Wallet::Interface::Scheduler`

```ruby
module BSV::Wallet::Interface
  module Scheduler
    # Register an entity-driven task.
    # discovery: callable returning Array of entities to process
    # handler: callable(entity) invoked once per entity per cycle
    def register_task(name:, discovery:, handler:)
      raise NotImplementedError
    end

    # Register a periodic task (runs once per cycle, no discovery).
    # handler: callable() with no arguments
    def register_periodic(name:, handler:)
      raise NotImplementedError
    end

    # Start the scheduler. Blocking or non-blocking per implementation.
    def start
      raise NotImplementedError
    end

    # Signal the scheduler to stop after the current cycle.
    def stop
      raise NotImplementedError
    end

    # Whether the scheduler has no in-flight dispatches.
    def quiescent?
      raise NotImplementedError
    end

    # Block until all in-flight dispatches complete.
    # Returns true if drained, false if timeout reached.
    def drain(timeout: nil)
      raise NotImplementedError
    end

    # Subscribe to lifecycle events.
    # Events: :enqueued, :dispatched, :succeeded, :failed
    # Block receives Hash: { event:, task:, entity:, error:, timestamp: }
    def on_event(&block)
      raise NotImplementedError
    end
  end
end
```

### How the three channel patterns emerge

The framework's mechanical behavior is uniform: each cycle, run all registered tasks. The channel semantics emerge from how the discovery query and handler interact — the framework doesn't need to distinguish them:

| Pattern | Discovery | Handler behavior | Framework action |
|---------|-----------|-----------------|-----------------|
| Fire-once | Returns entities with pending state | Handler changes state → entity drops from next discovery | Same as repeat-until mechanically |
| Repeat-until-state-change | Returns entities until upstream state changes | Handler observes external state | Same cycle loop, entities naturally leave discovery |
| Repeat-on-schedule | No discovery (periodic) | Handler runs unconditionally | `register_periodic` — no entities, just a callable |

The framework provides two registration primitives: `register_task` (entity-driven) and `register_periodic` (scheduled). The three patterns are documentation about intent, not three different framework behaviors. This is the ZeroMQ philosophy — the framework provides the primitive, the pattern emerges from usage.

### Framework does NOT interpret outcomes

On handler failure:
1. Emit `:failed` lifecycle event with the error
2. Log via BSV.logger
3. Continue to next entity / next task
4. Do NOT retry. Do NOT re-enqueue.

If the handler wants the entity retried, it leaves the entity's state unchanged — the next discovery cycle will re-find it. This is the handler's decision, not the framework's.

### Lifecycle events

Every dispatch emits structured events:

```ruby
{ event: :dispatched, task: :broadcast_push, entity: broadcast, timestamp: Time.now }
{ event: :succeeded,  task: :broadcast_push, entity: broadcast, timestamp: Time.now }
{ event: :failed,     task: :broadcast_push, entity: broadcast, timestamp: Time.now, error: e }
```

Periodic tasks emit without `:entity`:

```ruby
{ event: :dispatched, task: :address_scan, timestamp: Time.now }
{ event: :succeeded,  task: :address_scan, timestamp: Time.now }
```

Consumers subscribe via `on_event(&block)`. The E2E test's per-event logfile (#131) is a one-line listener.

---

## Default Implementation: `BSV::Wallet::PollingScheduler`

Replaces the Daemon class. Same polling loop, but implements the Scheduler interface.

```ruby
module BSV::Wallet
  class PollingScheduler
    include Interface::Scheduler

    def initialize(interval: 30)
      @interval = interval
      @tasks = {}
      @periodics = {}
      @listeners = []
      @running = false
      @dispatching = false
    end

    def register_task(name:, discovery:, handler:)
      @tasks[name] = { discovery: discovery, handler: handler }
    end

    def register_periodic(name:, handler:)
      @periodics[name] = { handler: handler }
    end

    def start
      @running = true
      run_cycle while @running
    end

    def stop
      @running = false
    end

    def quiescent?
      !@dispatching
    end

    def drain(timeout: nil)
      deadline = timeout ? Time.now + timeout : nil
      sleep 0.1 until quiescent? || (deadline && Time.now >= deadline)
      quiescent?
    end

    def on_event(&block)
      @listeners << block
    end

    private

    def run_cycle
      @dispatching = true

      @tasks.each do |name, task|
        task[:discovery].call.each do |entity|
          dispatch(name, entity) { task[:handler].call(entity) }
        end
      rescue StandardError => e
        emit(:failed, name, error: e)
      end

      @periodics.each do |name, task|
        dispatch(name) { task[:handler].call }
      end

      @dispatching = false
      sleep @interval
    rescue StandardError => e
      @dispatching = false
      BSV.logger&.error { "[Scheduler] cycle error: #{e.class}: #{e.message}" }
    end

    def dispatch(task_name, entity = nil)
      emit(:dispatched, task_name, entity: entity)
      yield
      emit(:succeeded, task_name, entity: entity)
    rescue StandardError => e
      emit(:failed, task_name, entity: entity, error: e)
    end

    def emit(event, task_name, entity: nil, error: nil)
      payload = { event: event, task: task_name, entity: entity, error: error, timestamp: Time.now }
      @listeners.each { |l| l.call(payload) }
    rescue StandardError => e
      BSV.logger&.error { "[Scheduler] listener error: #{e.class}: #{e.message}" }
    end
  end
end
```

### Wiring example (what `bin/daemon` becomes):

```ruby
scheduler = BSV::Wallet::PollingScheduler.new(interval: 30)

# Entity-driven tasks — discovery finds entities, handler processes each
scheduler.register_task(
  name: :broadcast_push,
  discovery: -> { Broadcast.where(broadcast_at: nil).all.select(&:needs_push?) },
  handler: ->(entity) { services.push!(entity) }
)

# Periodic task — no discovery, handler runs every cycle
scheduler.register_periodic(
  name: :address_scan,
  handler: -> { engine.scan_receive_addresses }
)

# Lifecycle logging
scheduler.on_event do |e|
  BSV.logger&.info { "[#{e[:task]}] #{e[:event]}#{e[:error] ? ": #{e[:error].message}" : ''}" }
end

scheduler.start
```

### What about SolidQueue, Sidekiq, etc.?

A SolidQueue adapter would implement the same interface but use `SolidQueue::RecurringTask` internally. A Sidekiq adapter would schedule recurring jobs. The task registrations are identical — only the implementation changes.

```ruby
# Hypothetical SolidQueue adapter
scheduler = BSV::Wallet::SolidQueueScheduler.new
scheduler.register_task(name: :broadcast_push, discovery: ..., handler: ...)
scheduler.start # → creates SolidQueue recurring tasks
```

---

## What Happens to the Existing Daemon?

The Daemon class stays for now. PollingScheduler is its successor with the proper interface. The Daemon could be deprecated or refactored to delegate to PollingScheduler internally. Not in scope for this HLR — the Daemon is unused anyway (#115 not merged).

Pushable and Fetchable stay unchanged — they're entity-level contracts. The scheduler uses them through Services.push!/fetch! in handler callables.

---

## Files

| File | Change |
|---|---|
| `gem/bsv-wallet/lib/bsv/wallet/interface/scheduler.rb` | **New** — interface contract |
| `gem/bsv-wallet/lib/bsv/wallet/interface.rb` | Add autoload for Scheduler |
| `gem/bsv-wallet/lib/bsv/wallet/polling_scheduler.rb` | **New** — default implementation |
| `gem/bsv-wallet/lib/bsv/wallet.rb` | Add autoload for PollingScheduler |
| `gem/bsv-wallet/spec/bsv/wallet/polling_scheduler_spec.rb` | **New** — tests |

---

## Testing Strategy

1. **Interface contract** — verify NotImplementedError on all methods
2. **PollingScheduler**:
   - `register_task` + `run_cycle` dispatches handler for each discovered entity
   - `register_periodic` + `run_cycle` dispatches handler with no entity
   - Handler failure emits `:failed` event, does NOT retry, continues to next
   - Discovery failure emits `:failed` event, continues to next task
   - `on_event` receives all four event types with correct payload shape
   - `quiescent?` returns false during dispatch, true when idle
   - `drain` blocks until quiescent
   - `stop` exits the loop after current cycle
   - Listener errors don't crash the scheduler
   - Empty discovery returns = no dispatches (but task still runs)

---

## Verification

```bash
cd gem/bsv-wallet && bundle exec rspec spec/bsv/wallet/polling_scheduler_spec.rb
cd gem/bsv-wallet && bundle exec rspec
cd gem/bsv-wallet && bundle exec rubocop
```
