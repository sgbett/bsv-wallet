# Plan: BSV::Network::Services — SDK Routing Layer

## Context

The wallet needs a network routing layer that sits above SDK providers/protocols. The SDK is purely declarative (providers configure protocols, protocols define HTTP endpoints). Services adds the imperative layer: routing decisions, fallback on failure, rate limit enforcement, response normalization, and opportunistic data caching.

**Implements:** sgbett/bsv-wallet#77 (sub-issue 1)
**Namespace:** `BSV::Network::Services` (SDK namespace, code in wallet gem)
**File:** `gem/bsv-wallet/lib/bsv/network/services.rb`
**Spec:** `gem/bsv-wallet/spec/bsv/network/services_spec.rb`

## Design

### Interface

Same `call(command, *args, **kwargs)` as `Provider` — drop-in replacement. Also exposes `commands` (union of all providers) and `providers`.

```ruby
services = BSV::Network::Services.new(providers: [gorilla_pool, woc])

services.call(:broadcast, tx)                    # → Result::Success/Error
services.call(:get_tx, txid)                     # → Result::Success (hex string)
services.call(:get_utxos, address)               # → Result::Success (array)
services.call(:get_tx_status, txid: 'abc...')    # → Result::Success (hash)
```

No domain methods. The wallet's service objects (layer 2, future work) decide what commands to call and what to do with responses.

### Routing Logic

```
call(:command, args, kwargs)
  ├── check sibling memo (may serve :get_merkle_path from stashed JungleBus data)
  ├── collect providers that serve this command
  ├── for :get_tx_status → move broadcast-affinity provider to front
  ├── for each provider:
  │   ├── acquire rate limit token (may sleep)
  │   ├── provider.call(command, *args, **kwargs)
  │   ├── if Success → normalize → stash siblings → record affinity → return
  │   ├── if NotFound → return (terminal)
  │   ├── if Error(retryable) → try next provider
  │   └── if Error(non-retryable) → return (terminal)
  └── all exhausted → return last error
```

### Normalization

Canonicalizes provider responses at the boundary — one normalization point. Services normalizes ALL responses unconditionally, regardless of which provider/protocol served the request. This is correctness over convenience.

**Principle:** Protocols return what the API returns (raw JSON, string keys). Normalization is Services' job, not the protocol's. ARC's `arc_data_from` escape hatch currently does its own normalization (symbol keys, field remapping) — this is a layering violation in the SDK. Services normalizes anyway so it never depends on protocol-level normalization being present or correct. Tracked as a separate SDK cleanup issue.

Normalization is per-command, driven by a registry:

```ruby
NORMALIZERS = {
  broadcast: method(:normalize_broadcast),
  get_tx_status: method(:normalize_tx_status),
  get_tx: method(:normalize_get_tx),
  # Commands without a normalizer pass through unchanged
}.freeze
```

**Broadcast/tx_status canonical form** (symbol keys):
```ruby
{ txid:, tx_status:, block_hash:, block_height:, merkle_path:, extra_info:, competing_txs: }
```

Regardless of whether ARC returns `{ txid: ... }` (symbol, from escape hatch) or `{ 'txid' => ... }` (string, raw JSON), Services produces the same canonical output.

**get_tx canonical form:** hex string. JungleBus base64 `transaction` is decoded. WoC hex passes through.

**Other commands:** Pass through unchanged. Service objects (future) handle further transformation as needed.

### Sibling Memo (JungleBus optimization)

When `:get_tx` returns data that includes proof information (JungleBus returns `merkle_proof` alongside `transaction`), Services stashes the proof keyed by txid. A subsequent `:get_merkle_path` for the same txid serves from the stash (one-shot, 5-second TTL).

The `:get_tx` response is normalized to hex (matching WoC's format) regardless of which provider served it. JungleBus base64 `transaction` is decoded to binary then hex.

### Broadcast Affinity

When Services dispatches `:broadcast` and gets a Success, it records which provider served it. Subsequent `:get_tx_status` calls move that provider to the front of the candidate list. ARC only knows about transactions it processed — polling a different ARC instance returns NotFound.

### Token Bucket (Rate Limiting)

Inner class `TokenBucket`. One per provider, initialized from `provider.rate_limit`. Mutex-safe. ~15 lines.

```ruby
class TokenBucket
  def initialize(rate) # tokens per second, nil = unlimited
  def acquire!         # blocks until a token is available
end
```

Providers with `rate_limit: nil` get no bucket (unlimited). Providers with e.g. `rate_limit: 3` get a bucket that refills at 3 tokens/second.

## Implementation

### New file: `gem/bsv-wallet/lib/bsv/network/services.rb`

```ruby
module BSV
  module Network
    class Services
      def initialize(providers:)
      def call(command, *args, **kwargs)
      def commands           # union of all provider commands
      def providers          # frozen copy

      private

      def route(command, *args, **kwargs)
      def candidates_for(command)
      def normalize(command, result)
      def stash_siblings(command, result, args, kwargs)
      def acquire_rate_limit!(provider)

      # Normalizers
      def normalize_broadcast(data)
      def normalize_tx_status(data)

      # Inner class
      class TokenBucket
        def initialize(rate)
        def acquire!
      end
    end
  end
end
```

### New file: `gem/bsv-wallet/spec/bsv/network/services_spec.rb`

Specs (no database, stub providers):

1. **Basic routing** — single provider, success passthrough
2. **Capability filtering** — skips providers that don't serve the command
3. **Provider ordering** — first provider wins on success
4. **Fallback on retryable error** — 429/5xx → next provider
5. **No fallback on non-retryable error** — 400 → terminal
6. **NotFound is terminal** — no fallback
7. **All providers fail** — returns last error
8. **No provider serves command** — returns error (not ArgumentError — Services is lenient, unlike Provider which raises)
9. **Rate limiting** — token bucket delays dispatch
10. **Broadcast normalization** — ARC response normalized to canonical form
11. **Broadcast normalization** — WoC response normalized (fill missing keys)
12. **tx_status normalization** — canonical form
13. **Broadcast affinity** — get_tx_status prefers broadcast provider
14. **Sibling memo** — get_tx from JungleBus stashes proof, get_merkle_path serves it
15. **Memo expiry** — stale entries not served (5s TTL)
16. **Memo one-shot** — consumed after first read
17. **commands aggregation** — union of all providers
18. **providers accessor** — returns frozen copy

### Modified file: `gem/bsv-wallet/lib/bsv/wallet.rb`

Add `require_relative '../network/services'` (opens `BSV::Network` namespace from wallet gem).

### NOT modified (yet)

Engine, BroadcastQueue, ProofStore, CLI — those are wired in a separate sub-issue (wallet integration / service objects). This PR delivers the routing layer in isolation.

## Current state on master

PR #74 (`feat/73-network-services`) is unmerged. On master:
- Engine takes `network_provider:` (a Provider instance for reads)
- BroadcastQueue/ProofStore take `arc_client:` (ArcAdapter wrapping a Provider)
- ArcAdapter exists — translates raw_tx binary → Transaction object for ARC broadcast
- `BSV::Wallet::Services` does not exist
- No response normalization anywhere

This PR adds `BSV::Network::Services` as a new, standalone class. It does NOT touch Engine, BroadcastQueue, ProofStore, or CLI. Wiring comes in a separate sub-issue when service objects replace the current callers. PR #74 should not be merged — it will be superseded.

## Verification

1. `cd gem/bsv-wallet && bundle exec rspec spec/bsv/network/services_spec.rb` — all routing/normalization/memo specs pass
2. `cd gem/bsv-wallet && bundle exec rspec` — full wallet suite still passes (no existing code modified except autoload)
3. `cd gem/bsv-wallet && bundle exec rubocop` — clean
4. `cd gem/bsv-wallet-postgres && bundle exec rspec` — postgres suite unaffected
