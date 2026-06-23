# Network Layer

The wallet talks to the outside world through three concrete services in the `BSV::Network::*` namespace, plus a long-lived SSE consumer. They divide cleanly by purpose: chain queries (`Services`), broadcast (`Broadcaster`), block headers (`ChainTracker`), and status push (`SSEListener`). Each is its own seam; the wallet never mixes the responsibilities.

Peer delivery and the SSRF gate live in their own domain — `Engine::Transmission` plus `Network::PeerDelivery` and `Network::EndpointPolicy`. The full story is in [Transmission](transmission.md); this page does not duplicate it.

## `Network::Services` — chain queries

`Services` is the porcelain routing layer for the **read-only chain commands** the wallet uses to verify, fetch, and look things up:

```ruby
services = BSV::Network::Services.new(providers: [woc, jungle_bus])
services.call(:get_tx, txid: dtxid)
services.call(:get_utxos, address)
services.call(:get_merkle_path, txid: dtxid)
services.call(:current_height)
```

Providers are supplied in **priority order** and frozen at construction. Broadcasting does not route here — that is `Network::Broadcaster`'s seam (below).

### Capability-based routing

Different providers serve different commands. `candidates_for` builds the ordered list of providers that actually declare a given command (`provider.commands.include?(command)`), and the dispatcher tries them in order. If no provider serves a command, `call` returns a synthetic "no provider serves `:command`" error response rather than raising — the caller handles it like any other failure.

A typical deployment wires WhatsOnChain as the primary for chain queries, with JungleBus as a secondary (and as the source for the sibling memo, below).

### Fallback and backoff

`call` walks the candidate list with a clear policy:

- **Success** → normalise the response, stash any reusable sibling data, and return.
- **Not found (404)** → return immediately; a definitive "not found" is an answer, not a failure to retry elsewhere.
- **Retryable error** → try the next candidate provider.
- **Non-retryable error** → stop and return it.

Within a single provider, `call_with_backoff` retries transient failures up to `RETRYABLE_ATTEMPTS = 3` with **exponential backoff (1 s, 2 s, 4 s)**. The two layers are deliberately distinct: cross-provider fallback handles "this provider can't help"; per-provider backoff handles "this provider is briefly unhappy (a 429 or 5xx)".

### Two kinds of rate control

The layer separates *wallet-side pacing* from *provider-side pushback*:

- **`TokenBucket`** — one per provider, optional (only if the provider declares a `rate_limit`). It refills at the provider's configured rate per second, with a burst capacity of `max(rate, 1)` so sub-1 rates still work, and `acquire!` blocks until a token is free. This is the wallet politely spacing its *own* requests so it never exceeds a provider's published limit.
- **Retry-with-backoff** — the response to the provider saying "slow down" or "try again" (a retryable status). This is reactive, not preventive.

Keeping them separate means a provider's rate limit is respected proactively, while genuine transient errors get a bounded, backed-off retry.

### Response normalisation

Different providers answer the *same* logical command with different JSON shapes, and the wallet should not care. `normalize` reconciles the commands where it matters into one canonical shape with symbol, snake_case keys. `:get_tx` comes back as a hex string from WhatsOnChain but as a base64-in-JSON payload from JungleBus; `normalize_get_tx` decodes the latter to hex so downstream code always sees a hex string.

### Sibling memo: a free merkle proof

Some providers return *more* than you asked for. When `:get_tx` is served by JungleBus, the response may include a merkle proof alongside the transaction. Rather than throw that away and fetch it again, `stash_siblings` caches it keyed by txid, and a subsequent `:get_merkle_path` for the same txid is served straight from the memo with **no network call**. The cache is small and short-lived by design — **100 entries, 5-second TTL** — because its only job is to catch the common "fetch a tx, then immediately want its proof" pattern, not to be a durable store.

### `push!` / `fetch!`

Two small conveniences wrap the `call` interface around SDK *entities* that know how to broadcast or hydrate themselves. `push!(entity)` calls the entity's `push_command` / `push_payload`, dispatches, and writes the response back on success; `fetch!(entity)` does the same for `fetch_command` / `fetch_args`. They let the rest of the codebase say "push this" or "fetch this" without assembling the command and arguments by hand.

## `Network::Broadcaster` — the broadcast boundary

Broadcasting is its own seam, separate from chain queries. `Broadcaster` owns submit, status lookup, and per-tx provider affinity:

```ruby
broadcaster = BSV::Network::Broadcaster.new(store: store, providers: [arcade, taal])
broadcaster.broadcast(raw_tx, wtxid: subject_wtxid, callback_token: token)
broadcaster.get_tx_status(wtxid: subject_wtxid, dtxid: display_txid)
```

It is **required by the Engine** — the constructor takes a `broadcaster:` kwarg, and an `inline_broadcast` with no broadcaster wired raises rather than silently routing through some other path.

### Affinity, persisted

When a wallet broadcasts a transaction through one provider, that provider is the one most likely to have a fresh view of its status moments later. `Broadcaster` records the accepting provider in `broadcasts.provider`, keyed on the binary wtxid. A later `get_tx_status` for the same wtxid walks providers with that one moved to the front of the candidate list.

Persistence matters: the daemon and inline broadcast paths share a single `broadcasts` table, so a transaction submitted inline can be resolved by the daemon's polling loop on the right provider without re-discovering which one took it. Affinity lives in the database, not an in-memory hash.

A `Broadcaster#broadcast` call that succeeds also forwards the optional `callback_token` as the `X-CallbackToken` header, so Arcade knows where to publish the resulting status frames.

## `Network::ChainTracker` — block headers

`ChainTracker` is the **write-through cache** that backs SPV verification. It answers `valid_root_for_height?` and `current_height` from a local `blocks` table, fetching and persisting headers through `Services` on a miss. It subclasses the SDK's `ChainTracker` so it drops straight into `Transaction#verify`.

It **fails closed**: a header lookup that errors returns `false` (root invalid) rather than raising or guessing. See [Transactions & BEEF](transactions-and-beef.md).

For *egress* validation only, the wallet uses `TrustedSelfChainTracker` — a tracker that returns `true` for all lookups, since the wallet's own proofs were validated against the real chain at import time.

## `Network::SSEListener` — Arcade status push

ARC providers can push transaction-status changes via Server-Sent Events rather than waiting for the wallet to poll. `SSEListener` is the long-lived connection that consumes that stream:

- Connects to `https://arcade.gorillapool.io/events?callbackToken=<token>` using the callback token the daemon's submissions also carry in their `X-CallbackToken` header.
- Decodes each frame from the Arcade wire shape into the wallet's internal event hash.
- Hands the event to a block supplied by the daemon, which Marshal-encodes it and pushes onto `inproc://statuses.pull` for `Engine::Broadcast` to apply through the shared `Store::EventApplicator`.

Cursor state lives in the `sse_cursors` table keyed on the token, so on reconnect the listener sends `Last-Event-ID` and resumes from where it left off without losing or duplicating events. The reconnect delay is a constant 1 s; the idle watchdog times out at 30 s (Arcade's keepalive is every 15 s).

The listener is opt-in: the daemon only starts it when a `callback_token` is configured. With no token, status resolution falls back to the polling loop.

## A note on direct-lookup paths

Most network access goes through these services, but a few direct-lookup paths in the Engine talk to a single `network_provider` (the WhatsOnChain default) directly, bypassing the routing layer. These are simple, single-provider queries — `network_provider` is injected separately from `services` precisely so those paths have a plain provider to call.
