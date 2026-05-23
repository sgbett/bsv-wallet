# Phase 3+4: OMQ Logical Models, Daemon, and Scheduler

**Date**: 2026-05-23
**Status**: Plan
**Depends on**: Phase 2+3 strip (merged as PR #155)
**Related**: .claude/plans/20260523-walletd-omq-architecture.md, .architecture/reviews/store-walletd-boundary.md

---

## Context

Phase 2+3 stripped Pushable/Fetchable from models and absorbed ProofStore/BroadcastQueue into Store. Engine now calls services directly for inline broadcasts. But between CLI invocations, nothing acts on incomplete database state — no background retries, no proof acquisition, no status polling.

**Outcome**: `bin/walletd` runs an Async reactor hosting logical models connected via OMQ sockets, with a Scheduler running discovery loops. walletd is a separate concern from CLI tools — it needs store + services, not Engine.

---

## Architecture

```
walletd process:
  Async do |task|
    Engine::Broadcast.new(store, services)
      .pull!(task:)                        # PULL inproc://broadcasts.pull
      .reply!(task:)                       # REP  inproc://broadcasts.rep

    Engine::TxProof.new(store, services)
      .pull!(task:)                        # PULL inproc://proofs.pull

    Scheduler.new(store:)
      .start(task:)                        # PUSH to logical model endpoints
  end
```

**walletd ≠ CLI.boot**. walletd boots store + services directly. It doesn't need Engine — logical models handle the background tasks that Engine doesn't (retries, polling, proof acquisition). CLI tools use Engine for user-facing BRC-100 operations.

---

## Task Breakdown

### Task 1: Add `omq` dependency + `pending_proofs` Store method

- Add `omq` to `bsv-wallet.gemspec` (brings `async` transitively)
- Add `pending_proofs(limit:)` to Store — returns actions that are outgoing, have wtxid, but no tx_proof_id
- Add to `Interface::Store`
- Add specs

Files: `bsv-wallet.gemspec`, `store.rb`, `interface/store.rb`, `persistence_spec.rb`

### Task 2: Create `Engine::Broadcast`

Background broadcast handler with OMQ sockets:
- `pull!(task:)` — binds PULL on `inproc://broadcasts.pull`, processes background work
- `reply!(task:)` — binds REP on `inproc://broadcasts.rep`, inline request-reply
- `process(action_id)` — looks up action, calls `services.call(:broadcast)`, writes result via `store.record_broadcast_result`
- `self.pending(store, limit:)` — discovery query wrapping `store.pending_broadcasts`

Files: `lib/bsv/wallet/engine/broadcast.rb`, `spec/bsv/wallet/engine/broadcast_spec.rb`

### Task 3: Create `Engine::TxProof`

Background proof acquisition handler:
- `pull!(task:)` — binds PULL on `inproc://proofs.pull`
- `process(action_id)` — fetches tx status from ARC, saves proof + links to action if mined
- `self.pending(store, limit:)` — discovery query wrapping `store.pending_proofs`

Files: `lib/bsv/wallet/engine/tx_proof.rb`, `spec/bsv/wallet/engine/tx_proof_spec.rb`

### Task 4: Create `Scheduler`

Discovery loops that push work IDs to logical model PULL sockets:

```ruby
class Scheduler
  def initialize(store:)
    @store = store
  end

  def start(task:)
    schedule(task: task, endpoint: 'inproc://broadcasts.pull', interval: 5) do
      Engine::Broadcast.pending(@store, limit: 10)
    end

    schedule(task: task, endpoint: 'inproc://proofs.pull', interval: 30) do
      Engine::TxProof.pending(@store, limit: 10)
    end
  end

  private

  def schedule(task:, endpoint:, interval:, &discovery)
    task.async do
      push = OMQ::PUSH.connect(endpoint)
      loop do
        discovery.call.each { |id| push << id.to_s }
        sleep interval
      rescue StandardError => e
        BSV.logger&.error { "[Scheduler] #{endpoint}: #{e.message}" }
      end
    end
  end
end
```

WBIKD scanning deferred — it requires Engine, which walletd doesn't need. Can be added later as a periodic task when/if walletd gains an Engine.

Files: `lib/bsv/wallet/scheduler.rb`, `spec/bsv/wallet/scheduler_spec.rb`

### Task 5: Create `Daemon`

Thin Async reactor host:

```ruby
class Daemon
  def initialize(store:, services:)
    @store = store
    @services = services
  end

  def run!
    Async do |task|
      Engine::Broadcast.new(store: @store, services: @services)
        .pull!(task: task)
        .reply!(task: task)

      Engine::TxProof.new(store: @store, services: @services)
        .pull!(task: task)

      Scheduler.new(store: @store)
        .start(task: task)
    end
  end
end
```

Files: `lib/bsv/wallet/daemon.rb`, `spec/bsv/wallet/daemon_spec.rb`

### Task 6: Create `bin/walletd`

Boots store + services directly (not via CLI.boot). Constructs Daemon. Runs.

```ruby
#!/usr/bin/env ruby
require 'dotenv/load' rescue LoadError
require 'sequel'
require 'logger'
require 'bsv-wallet'

wallet_name = ARGV[0]
network = (ARGV[1] || :mainnet).to_sym

BSV.logger ||= Logger.new($stderr, level: Logger::INFO)

wif = BSV::Wallet::CLI.send(:env_fetch, 'WIF', wallet_name)
db_url = BSV::Wallet::CLI.send(:env_fetch_optional, 'DATABASE_URL', wallet_name)
db_url ||= BSV::Wallet::CLI.send(:default_sqlite_url, wallet_name)

store = BSV::Wallet::Store.connect(db_url)
store.migrate!

provider = BSV::Network::Providers::WhatsOnChain.send(network)
services = BSV::Network::Services.new(providers: [provider])

BSV.logger.info { "[walletd] Starting for #{wallet_name || 'default'}..." }

daemon = BSV::Wallet::Daemon.new(store: store, services: services)

trap('INT') { daemon.stop! }
trap('TERM') { daemon.stop! }

daemon.run!
```

Note: Daemon needs a `stop!` method that cancels the Async reactor task.

Files: `bin/walletd`

### Task 7: Update autoloads + delete PollingScheduler

- Add autoloads for `Daemon`, `Scheduler` in `wallet.rb`
- Add autoloads for `Engine::Broadcast`, `Engine::TxProof` in `engine.rb`
- Delete `PollingScheduler` and `Interface::Scheduler`
- Delete corresponding specs
- Remove autoload entries

Files: `wallet.rb`, `engine.rb`, delete `polling_scheduler.rb`, `interface/scheduler.rb`, specs

---

## Dependency Graph

```
Task 1 (omq dep + pending_proofs) ──┬── Task 2 (Engine::Broadcast) ──┐
                                     └── Task 3 (Engine::TxProof) ────┤
                                                                      ├── Task 4 (Scheduler)
                                                                      │        │
                                                                      └── Task 5 (Daemon)
                                                                               │
                                                                        Task 6 (bin/walletd)
                                                                               │
                                                                        Task 7 (autoloads + cleanup)
```

Tasks 2+3 parallel after Task 1. Tasks 4+5 after 2+3. Task 6 after 5. Task 7 last.

---

## Testing Strategy

- **Engine::Broadcast.process**: Stubbed store/services, verify services.call(:broadcast) and store.record_broadcast_result
- **Engine::TxProof.process**: Stubbed store/services, verify services.call(:get_tx_status) and store.save_proof + link_proof
- **OMQ sockets**: Short-lived Async reactor with inproc endpoints. Push a message, verify process is called.
- **Scheduler**: Bind PULL on the endpoints, start scheduler, verify IDs arrive.
- **Daemon**: Integration test — boot with in-memory SQLite store, run reactor briefly with a Async timeout, verify fibers started.
- All specs on SQLite (default) and Postgres.

---

## What This Does NOT Include

- WBIKD scanning in walletd (needs Engine — deferred)
- CLI tools as thin REQ clients to walletd (Phase 2 of wallet-node-architecture)
- Horizontal scaling (PUSH/PULL fan-out)
- ARC SSE subscription (PUB/SUB replaces status polling)
- Services as standalone OMQ service

---

## Verification

```bash
cd gem/bsv-wallet && bundle exec rspec spec/bsv spec/bin
cd gem/bsv-wallet && bundle exec rubocop
DATABASE_URL=postgres://postgres:postgres@localhost:5433/bsv_wallet_test bundle exec rspec spec/bsv spec/bin

# Manual daemon test
cd gem/bsv-wallet && bin/walletd alice
# Should log startup, poll for pending work
# Ctrl-C should exit cleanly
```
