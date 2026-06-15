# walletd OMQ Architecture — Physical/Logical Model Split

**Date**: 2026-05-23
**Status**: Plan (brainstormed, not yet broken into implementation tasks)
**Source**: Extended brainstorm covering store consolidation, boundary violations, physical/logical model separation, OMQ wiring, daemon architecture.
**Related**: #36 (daemon), #128 (async/scheduler), .architecture/reviews/20260523_store-walletd-boundary.md, .architecture/reviews/20260523_wallet-node-architecture.md

---

## Key Insight: Physical vs Logical Models

The codebase conflates two kinds of model:

- **Physical models** (Sequel, Store-owned) — database records. Data, associations, constraints. The store enforces atomicity around them.
- **Logical models** (Engine, walletd-owned) — behavioral entities with lifecycles. They know how to talk to the network, interpret responses, and coordinate atomic writes back to the store.

Today these are mashed together: `Store::Broadcast` (a Sequel model) includes `Pushable` and `Fetchable` (network behavioral contracts). `Store::Action#write!` instantiates `ProofStore` and performs a 3-table mutation without a transaction. The physical model is doing logical model work.

The refactor separates them cleanly:
- Physical models become pure data (columns, associations, constants)
- Logical models become `Engine::Broadcast`, `Engine::TxProof`, etc.
- Each logical model owns its OMQ sockets (`pull!` for background, `reply!` for inline)
- The daemon hosts them as fibers in an Async reactor

---

## Phase 1: Consolidate Store (Eliminate Postgres Gem)

### Problem

The `bsv-wallet-postgres` gem duplicates nearly the entire store layer. After extracting shared logic into `Store::Base`, only three substantive differences remain:

1. **`try_lock_input`** — SQLite re-queries to verify; Postgres trusts `insert_conflict` return value
2. **`competing_txs` coercion** — `JSON.generate()` vs `Sequel.pg_array()`
3. **Connection setup** — SQLite PRAGMAs vs Postgres pg_enum/pg_array/pg_json extensions

Everything else — all 18 models, all 25 Store::Base methods, BroadcastQueue, UTXOPool, ProofStore, BroadcastCallback, ArcAdapter, specs — is identical logic in different namespaces.

### Approach

- Branch adapter-level differences on `db.database_type` (:sqlite vs :postgres)
- Move Postgres connection setup into the main gem's Connection class
- Delete the `gem/bsv-wallet-postgres` directory entirely
- Consolidate specs (Postgres-only model specs fold into main suite)
- Update gemspec: `sqlite3` remains default, `pg` becomes optional

### Why first

Reduces maintenance surface before the bigger refactor. Every subsequent change would otherwise need to be made twice.

---

## Phase 2: Fix Store Boundary Violations

### Problem

Several components bypass the Store's write monopoly:

| Violation | Tables | Transaction? |
|-----------|--------|-------------|
| `Action#write!` -> `ProofStore#save_proof` -> `find_or_create_block` | Action + TxProof + Block | No |
| `BroadcastQueue#submit` | Broadcast | No |
| `BroadcastQueue#handle_event` | Broadcast (multi-column) | No |
| `ChainTracker#persist_block` | Block (raw dataset) | No |
| `Setting.set` | Setting | No |

### Approach

Add atomic Store methods that replace the bypasses:

```ruby
# New Store::Base methods
store.record_broadcast_result(action_id:, tx_status:, arc_status:, ...)
store.link_proof_to_action(action_id:, wtxid:, merkle_path:, block_height:, ...)
store.update_broadcast_status(action_id:, tx_status:, ...)
store.record_block_header(height:, merkle_root:, block_hash:)
```

Each wraps its mutation in `@db.transaction`. The store doesn't know about `ProtocolResponse` or network formats — callers pass pre-digested data.

---

## Phase 3: Refactor to Logical Models

### Strip physical models

Remove `Pushable` and `Fetchable` from Sequel models:

- `Store::Broadcast` loses `include Pushable`, `include Fetchable`, `write!`, `push_command`, `push_payload`, `fetch_command`, `fetch_args`, `needs_push?`, `needs_fetch?`, `decode_hex`
- `Store::Action` loses `include Fetchable`, `write!`, `fetch_command`, `fetch_args`, `needs_fetch?`, `decode_hex`
- Physical models become: columns, associations, timestamps, constants, `derived_status` (pure computation from columns)

### Create logical models

```
lib/bsv/wallet/engine/
  broadcast.rb    — Engine::Broadcast
  tx_proof.rb     — Engine::TxProof
  (more as needed)
```

Each logical model:
- Accepts `store:` and `services:` at initialization
- Owns OMQ socket bindings (`pull!`, `reply!`)
- Has a `.pending` query (class or instance method) for discovery
- Calls `services.call(command, ...)` for network I/O
- Calls `store.record_*` methods for atomic writes
- Never touches Sequel models for writes

#### Engine::Broadcast

```ruby
module BSV::Wallet::Engine
  class Broadcast
    def initialize(store:, services:)
      @store = store
      @services = services
    end

    # Background queue — fire-and-forget
    def pull!(task:)
      task.async do
        pull = OMQ::Pull.new
        pull.bind('inproc://broadcasts.pull')
        while (msg = pull.receive)
          process(msg.first)
        end
      end
      self
    end

    # Inline request-reply
    def reply!(task:)
      task.async do
        rep = OMQ::Rep.new
        rep.bind('inproc://broadcasts.rep')
        while (msg = rep.receive)
          result = process(msg.first)
          rep.send(result.to_s)
        end
      end
      self
    end

    def process(action_id)
      model = Store::Broadcast[action_id]
      response = @services.call(:broadcast, model.action.raw_tx)
      if response.http_success?
        @store.record_broadcast_result(action_id: action_id, ...)
      end
      response
    end

    # Discovery query
    def self.pending
      Store::Broadcast.where(broadcast_at: nil)
                      .where(Store::Action.where(
                        Sequel[:actions][:id] => Sequel[:broadcasts][:action_id]
                      ).where(Sequel.~(raw_tx: nil)).select(1).exists)
    end
  end
end
```

#### Engine::TxProof

Replaces `ProofStore` + `Action#write!`. Handles:
- `process(action_id)` — fetch proof from network, atomic write to store
- `pull!` / `reply!` — OMQ patterns
- `.pending` — actions with wtxid but no tx_proof_id

### Delete / reclassify

| Current | Disposition |
|---------|------------|
| `Store::BroadcastQueue` | Delete — `submit` becomes `Engine::Broadcast`, `process_pending` replaced by `.pending` + scheduler |
| `Store::ArcAdapter` | Delete — dead code, superseded by Network::Services |
| `Store::BroadcastCallback` | Defer — concept survives as future OMQ listener for ARC events |
| `Store::ProofStore` | Refactor as `Engine::TxProof` — proof lifecycle is engine logic, physical storage stays in Store |
| `Interface::BroadcastQueue` | Delete — dissolved into logical model |
| `Interface::Scheduler` | Delete |
| `Pushable` module | Delete — contracts dissolve into logical models |
| `Fetchable` module | Delete — contracts dissolve into logical models |
| `PollingScheduler` | Rename to `Scheduler`, rewrite as OMQ discovery loops |

### What remains in Engine (the class)

`Engine` (or `Engine::Base`) remains as the composition root:
- BRC-100 synchronous operations: `create_action`, `sign_action`, `internalize_action`, `abort_action`
- Query operations: `list_actions`, `list_outputs`, `query_certificates`
- Crypto: `encrypt`, `decrypt`, `create_hmac`, `verify_hmac`, `create_signature`, `verify_signature`
- Key management: `get_public_key`, `derive_keys`
- WBIKD: `generate_receive_address`, `list_receive_addresses`, `scan_receive_addresses`
- Composes logical models + store + services

Some of these may later decompose further into their own logical models (e.g., WBIKD scanning is a background concern). That'll become obvious as the refactor progresses.

---

## Phase 4: Daemon + Scheduler

### Daemon

`BSV::Wallet::Daemon` becomes the thin process host:

```ruby
module BSV::Wallet
  class Daemon
    def initialize(store:, services:)
      @store = store
      @services = services
    end

    def run!
      Async do |task|
        # Logical models
        Engine::Broadcast.new(store: @store, services: @services)
          .pull!(task: task)
          .reply!(task: task)

        Engine::TxProof.new(store: @store, services: @services)
          .pull!(task: task)

        # Scheduler (discovery loops)
        Scheduler.new(store: @store, services: @services)
          .start(task: task)

        # External listener (Phase 2: CLI thin clients)
        # Listener.new.start(task: task)
      end
    end
  end
end
```

`bin/walletd` boots the library, constructs the daemon, calls `run!`.

### Scheduler

Replaces `PollingScheduler`. Each pending query becomes a fiber that pushes to the appropriate logical model's PULL socket:

```ruby
module BSV::Wallet
  class Scheduler
    def initialize(store:, services:)
      @store = store
      @services = services
    end

    def start(task:)
      schedule(task: task, endpoint: 'inproc://broadcasts.pull', interval: 5) do
        Engine::Broadcast.pending.limit(10).select_map(:id)
      end

      schedule(task: task, endpoint: 'inproc://proofs.pull', interval: 30) do
        Engine::TxProof.pending.limit(10).select_map(:id)
      end
    end

    private

    def schedule(task:, endpoint:, interval:, &discovery)
      task.async do
        push = OMQ::Push.new
        push.connect(endpoint)
        loop do
          discovery.call.each { |id| push.send(id.to_s) }
          sleep interval
        end
      end
    end
  end
end
```

### Delete

- `BSV::Wallet::Daemon` (current) — replaced
- `BSV::Wallet::PollingScheduler` — replaced
- `BSV::Wallet::Interface::Scheduler` — deleted

---

## Phase 5 (Future): Services as OMQ Service

`Network::Services` could become a standalone OMQ service:
- Wallet talks to it via REQ/REP sockets
- Rate limiting, provider routing, fallback — all centralized
- Multiple wallets share one Services process
- Transport upgrade: `inproc://` (Phase 4) -> `ipc://` or `tcp://`

Not in scope for this plan, but the OMQ patterns established in Phases 3-4 make this a natural evolution.

---

## Dependencies

- `omq` gem — pure Ruby ZeroMQ (built on Async)
- `async` gem — fiber-based concurrency (comes with omq)
- No Ractors needed — all workloads are I/O-bound; heavy crypto is FFI (releases GVL)

---

## Open Questions

1. **Does Engine#create_action broadcast inline via REQ/REP, or just record intent?** If walletd is running, REQ to `inproc://broadcasts.rep` makes sense. If CLI (no daemon), direct `services.call` is fine. Maybe Engine detects which mode it's in, or the caller decides.

2. **How does `Engine::Broadcast.pending` access models?** Class method that references `Store::Broadcast` directly (for reads). This is fine — the store-write monopoly is about writes, not reads. Discovery queries can hit models directly.

3. **Granularity of logical models.** Start with Broadcast and TxProof. Others (status polling, WBIKD scanning) can be extracted later as the pattern proves out.

4. **Testing strategy.** Logical models can be tested with a real store (SQLite in-memory) and stubbed services. OMQ sockets can be tested with inproc endpoints in specs. The daemon is integration-tested end-to-end.

---

## Verification

Each phase should pass:
```bash
cd gem/bsv-wallet && bundle exec rspec
cd gem/bsv-wallet && bundle exec rubocop
```

Phase 1 additionally: confirm `gem/bsv-wallet-postgres` specs migrate into the main suite and pass against both SQLite and Postgres.
