# Plan: BSV::Network::Services — Porcelain Layer

## Context

The wallet currently wires network providers directly: `BroadcastQueue` takes an `arc_client` (wrapped in ArcAdapter), `ProofStore` takes an optional `arc_client`, and `Engine` takes a `network_provider`. Each component knows which provider to use and how. This creates three problems:

1. **No routing intelligence** — the wallet can't fall back to another provider on failure
2. **No rate limit enforcement** — providers declare `rate_limit` but nothing enforces it
3. **No call optimisation** — JungleBus returns tx+proof in one call, but the wallet doesn't know this

Services replaces this with a single network abstraction that routes by capability, falls back on retryable errors, enforces rate limits, and optimises call patterns.

**Implements:** sgbett/bsv-wallet#73

## Design Decisions

| Decision | Rationale |
|----------|-----------|
| Lives in bsv-wallet, not SDK | Imperative orchestration, not declarative |
| Same `call` interface as Provider | Drop-in replacement for `network_provider` |
| No `fetch_tx_with_proof` method | Transparent optimisation via memo — caller doesn't know about JungleBus |
| Token bucket per provider | Independent rate limits, simple implementation |
| Broadcast affinity (single provider) | ARC only knows about txs it processed |
| Provider order = priority | Explicit, predictable, matches existing first-registered-wins pattern |
| NotFound is terminal, no fallback | If one provider says it doesn't exist, trying others wastes requests |
| Retryable errors trigger fallback | 429/5xx move to next provider |
| ArcAdapter becomes unnecessary | ARC protocol already handles raw binary strings directly |

## Implementation

### New Files

**`gem/bsv-wallet/lib/bsv/network/services.rb`** — Core class:
- `initialize(providers:)` — accepts ordered array of `BSV::Network::Provider`
- `call(command, *args, **kwargs)` — routes to best provider, falls back on retryable errors
- `commands` — union of all provider commands
- `providers` — frozen copy
- Inner class `TokenBucket` — per-provider rate limiter (~15 lines, mutex-safe)
- JungleBus memo — stashes `merkle_proof` from `get_tx` responses, serves it on `get_merkle_path` calls for same txid (one-shot, 5s TTL)
- Broadcast affinity — records which provider last handled `:broadcast`, prioritises it for `:get_tx_status`

**`gem/bsv-wallet/spec/bsv/network/services_spec.rb`** — Unit tests (no database):
- Basic routing (single provider, success)
- Capability filtering (only providers that serve the command)
- Fallback on retryable error (429/5xx → next provider)
- No fallback on non-retryable error (400 → terminal)
- NotFound is terminal (no fallback)
- All providers fail → last error returned
- Unknown command → ArgumentError
- Rate limiting (token bucket delays)
- Broadcast affinity (get_tx_status prefers broadcast provider)
- JungleBus memo (get_tx stashes proof, get_merkle_path uses it)
- Memo expiry and one-shot behaviour
- `commands` aggregation

### Modified Files

**`gem/bsv-wallet/lib/bsv/wallet.rb`**
- Add `require_relative '../network/services'`

**`gem/bsv-wallet/lib/bsv/wallet/engine.rb`** (backward-compatible)
- Add `services:` kwarg to constructor
- `@network_provider = services || network_provider`
- No other changes — Engine already calls `@network_provider.call(:get_tx, txid:)` etc.

**`gem/bsv-wallet-postgres/lib/bsv/wallet/postgres/broadcast_queue.rb`** (backward-compatible)
- Add `services:` kwarg alongside `arc_client:`
- `@arc_client = services || arc_client`
- Existing `@arc_client.call(:broadcast, raw_tx)` works unchanged

**`gem/bsv-wallet-postgres/lib/bsv/wallet/postgres/proof_store.rb`** (backward-compatible)
- Add `services:` kwarg alongside `arc_client:`
- Same pattern as BroadcastQueue

### Routing Logic (call method)

```
call(:command, args, kwargs)
  ├── if :get_merkle_path → check JungleBus memo first
  ├── find providers that serve this command (ordered by priority)
  ├── for :get_tx_status → move broadcast-affinity provider to front
  ├── for each provider:
  │   ├── acquire rate limit token (may sleep)
  │   ├── dispatch call
  │   ├── if Success:
  │   │   ├── if :broadcast → record affinity
  │   │   ├── if :get_tx and data has 'merkle_proof' → stash in memo
  │   │   └── return Success
  │   ├── if NotFound → return NotFound (terminal)
  │   ├── if Error(retryable) → try next provider
  │   └── if Error(non-retryable) → return Error (terminal)
  └── all exhausted → return last error
```

### Usage (target wiring)

```ruby
services = BSV::Network::Services.new(providers: [
  BSV::Network::Providers::GorillaPool.mainnet(auth: { bearer: ENV['GP_TOKEN'] }),
  BSV::Network::Providers::WhatsOnChain.mainnet(auth: { api_key: ENV['WOC_KEY'] }),
])

engine = BSV::Wallet::Engine.new(
  store: store,
  utxo_pool: utxo_pool,
  broadcast_queue: BroadcastQueue.new(db: db, services: services),
  proof_store: ProofStore.new(db: db, services: services),
  services: services,
  network: :mainnet,
)
```

### Task Sequence

1. **Services class + TokenBucket + tests** — core deliverable, no wallet changes
2. **Wire into Engine** — add `services:` param (backward-compatible)
3. **Wire into BroadcastQueue/ProofStore** — add `services:` param (backward-compatible)
4. **Update on_chain integration spec** — construct Services, pass everywhere

### Verification

1. `bundle exec rspec gem/bsv-wallet/spec/bsv/network/services_spec.rb` — unit tests pass
2. `bundle exec rake` — full suite passes (backward-compatible changes)
3. Manual: construct Services with GorillaPool + WoC providers, verify routing:
   - `services.call(:broadcast, tx)` → routes to GorillaPool ARC
   - `services.call(:get_tx, known_txid)` → routes to GorillaPool (JungleBus or Ordinals)
   - `services.call(:get_merkle_path, same_txid)` → served from JungleBus memo
   - `services.call(:get_utxos, address)` → routes to available provider
