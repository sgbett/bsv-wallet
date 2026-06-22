# Operating the Daemon

`walletd` is the background runtime that turns queued work into on-chain
results. The Engine itself runs no threads; everything asynchronous lives
here.

## What `walletd` does

```sh
bin/walletd [wallet_name] [network]
bin/walletd alice mainnet
```

It boots a `Store` and `Network::Services` (it needs neither the Engine nor
a key deriver — it only schedules work) and runs an Async reactor hosting:

- `Engine::Broadcast` — submits queued transactions to ARC and polls their
  status.
- `Engine::TxProof` — acquires merkle proofs once a transaction is mined.
- `Scheduler` — three discovery loops that poll the Store and push work
  over OMQ in-process sockets:

| Loop | Interval | Picks up |
|---|---|---|
| Broadcast submission | 5 s | Newly queued broadcasts (`broadcast_at IS NULL`) |
| Broadcast resolution | 30 s | Attempted, non-terminal broadcasts |
| Proof acquisition | 30 s | Mined transactions awaiting a proof |

Submission runs fastest because users wait on outputs becoming spendable.

## When you need it

You need `walletd` running whenever you use **delayed broadcast** (the
default) or rely on proof acquisition. With inline broadcast
(`accept_delayed_broadcast: false`) the ARC call happens synchronously
inside `create_action` and the daemon is not required for the send itself —
but proofs are still acquired in the background. See
[Broadcast Lifecycle](broadcast-lifecycle.md).

## Network services

Two collaborators split the network surface:

- **`BSV::Network::Broadcaster`** owns the broadcast path —
  broadcast-only providers (Arcade/ARC via GorillaPool). The Engine receives
  it as the `broadcaster:` collaborator.
- **`BSV::Network::Services`** routes chain queries (`get_tx`,
  `get_utxos`, `get_merkle_path`, `get_block_header`) to WhatsOnChain, with
  rate limiting and fallback. It is also the Engine's `network_provider`
  for direct lookups.

The routing and rate-limiting internals are reference-grade — see the
[API reference](../reference/api/index.md). `BSV::Network::ChainTracker` is
the store-backed component that validates merkle roots against the wallet's
local view of block headers.

## Peer transmission

`Engine::Transmission` is the wallet-to-peer BEEF delivery domain — a
sibling to `Broadcast` and `TxProof` over the shared `Hydrator` substrate.
It is **not driven by the daemon** in v1: when a caller invokes
`engine.transmission.transmit(endpoint:, ...)`, the HTTP POST runs
inline and the caller awaits the ACK. A daemon-driven async path is shaped
to drop in at Phase 2, mirroring the broadcast inline/delayed split, but is
not implemented today. See [Sending Payments](sending-payments.md#deliver-to-a-peer)
for the caller-side surface.

## Production security envelope

The daemon's outbound HTTP surface is locked down by default; understanding
those defaults is the difference between "production-ready" and "shipped a
foot-gun".

### SSRF defence (`Network::EndpointPolicy`)

The peer endpoint is **caller-supplied** — by construction the wallet's
external attack surface. An attacker who can influence the endpoint string
can attempt a Server-Side Request Forgery (SSRF): redirecting an outbound
BEEF to a network destination the operator never intended.

The canonical SSRF target on cloud platforms is the **link-local
metadata endpoint at `169.254.169.254`**, which AWS, GCP and Azure all
expose for instance credential vending. A wallet talked into POSTing its
BEEF + identity key to that address is a credible
*credential-exfiltration / loss-of-funds* path. `Network::EndpointPolicy`
rejects it by default, alongside RFC1918 private space, loopback,
link-local more broadly, CGNAT, multicast, broadcast, IPv6 unique-local,
IPv6 loopback, and IPv4-mapped IPv6 (so `::ffff:127.0.0.1` cannot bypass
the IPv4 rules on dual-stack hosts).

Defaults:

- **HTTPS only** (`require_https: true`). Plain HTTP gives an on-path
  attacker the BEEF, the BRC-29 `sender_identity_key`, and the ability to
  forge a 200 ACK.
- **TLS verification on** (`VERIFY_PEER`). No silent acceptance of
  self-signed certificates.
- **No cross-host redirects.** A peer cannot 302 the bundle into the
  metadata range.
- **5-second connect / 30-second read timeouts.** A slow peer must not
  silently wedge the wallet.
- **32 MiB body cap.** Defence against a runaway hydration walk or a
  deliberately oversized payload.
- **DNS resolved once at policy time**, with the deliverer dialling the
  resolved IP and `Host:` set to the original hostname. Closes the DNS
  TOCTOU window where `Net::HTTP` would re-resolve and land on a different
  (private) IP than the one the policy approved.

### `BSV_WALLET_ALLOW_PRIVATE_ENDPOINTS` — production foot-gun

```
BSV_WALLET_ALLOW_PRIVATE_ENDPOINTS=1
```

This variable opens the SSRF gate. It exists so the e2e harness can talk
to fixture wallets bound on `127.0.0.1`. **It is read once at policy
construction** (when the deliverer is built), so it cannot be flipped at
runtime — but if it is set in the process environment at daemon boot, every
subsequent transmit will accept private destinations including the cloud
metadata endpoint.

> **Never set this in production.** Audit your systemd unit, container
> manifest, and `.env` discipline before deploying.

### Secrets handling (`BSV_WALLET_WIF_*`)

The wallet's WIF is read from the process environment at boot. The
fixture registry resolves `BSV_WALLET_WIF_<NAME>` to the named wallet's
private key (`BSV_WALLET_WIF_ALICE`, `BSV_WALLET_WIF_SDK`, etc.).
`CLI.boot` triggers the read; the value is held in memory in
`KeyDeriver` for the daemon's lifetime.

For development and CI:

- Local: `~/.zshenv` (or equivalent shell-init) is the conventional home.
- CI: GitHub Actions secrets injected as repository or environment
  secrets.

For **production**:

- **Do not ship `.env` files into a deployed image.** Treat the WIF as a
  secret the deployer mints into the runtime environment at start time.
- Integrate with the operator's secret manager (AWS Secrets Manager,
  HashiCorp Vault, GCP Secret Manager, Kubernetes Secret + projected
  volume, etc.). The integration point is the systemd `EnvironmentFile=`
  directive, a container init that fetches the secret and `exec`s the
  daemon, or a sidecar that materialises the env var before the wallet
  process starts.
- The wallet has no on-disk WIF store; rotating the WIF means restarting
  the daemon with a new value in the environment.

### Log redaction

`bin/transmit` logs to stderr a deliberately redacted single-line summary:

- **Endpoint** surfaces as host only — never the full URL (avoids leaking
  credentialled URIs that some operators paste through CI variables).
- **Counterparty** is last 8 hex characters only.
- **BEEF body is never echoed.** Not on success, not on failure, not at
  debug level.
- The `dtxid` is the primary log key (matches existing CLI convention).

```
transmitted: dtxid=<64-hex> peer=...<last8> via <host> outcome=<symbol>
```

Operators wrapping the daemon in their own logging stack should preserve
this discipline. Pulling `Engine::Transmission` debug output and surfacing
it un-redacted (via a structured logger that captures all keys) silently
reverses the AC: the BEEF and full counterparty re-enter the log stream.
If you need richer telemetry, scrub before emission.

## ARC callbacks

`BSV::Wallet::Store::BroadcastCallback` is a Rack endpoint (`call(env)`)
that receives ARC `TransactionStatus` callbacks and persists them. Mount it
in any Rack-compatible server; it requires `rack` (not a gem dependency, so
add it yourself if you use callbacks).

## Shutdown and recovery

Signal handling is careful: `INT`/`TERM` traps only flip a stop flag
(mutexes and sleeps are illegal in trap context), and a watcher thread
drives a cooperative drain — waiting for in-flight tasks to reach zero
before exiting. Combined with the crash-recovery invariants in
[Broadcast Lifecycle](broadcast-lifecycle.md) (pre-POST `broadcast_at`
stamping, atomic promote-with-result, the reaper), a daemon that is killed
and restarted resumes cleanly from whatever state it left behind.
