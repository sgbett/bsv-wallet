# Safety Rules & Gotchas

A few mechanisms behave in ways that look like bugs the first time you hit
them. They are deliberate. This page is the canonical wallet-side reference
for the thresholds and rules. Where a topic has a deeper specification —
SSRF policy, the ACK contract, two-phase delivery — this page summarises
and links to the canonical source in
[`reference/transactions.md`](../reference/transactions.md). The reference
is authoritative; this page is the operator-facing surface.

## Transmission security envelope

Peer transmission is the wallet's external egress surface. Five mechanisms
guard it; collectively they make it safe to call
`engine.transmission.transmit(endpoint: <caller URL>)` with a
caller-supplied endpoint.

### SSRF gate (`Network::EndpointPolicy`)

The peer endpoint is caller-supplied — by construction the wallet's
external attack surface. The SSRF gate rejects, by default:

- RFC1918 private space (`10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`)
- Loopback (`127.0.0.0/8`, `::1/128`)
- Link-local — **including the cloud-metadata endpoint
  `169.254.169.254`** (the canonical SSRF target for credential
  exfiltration on AWS, GCP and Azure)
- RFC 6598 carrier-grade NAT shared space (`100.64.0.0/10`)
- IPv4-mapped IPv6 (`::ffff:0:0/96`) — listed in `PRIVATE_RANGES` as
  defence-in-depth; the primary defence is `validate_ip!` unwrapping any
  IPv4-mapped address to its native IPv4 form *before* the membership
  check, so `::ffff:127.0.0.1` falls into the `127.0.0.0/8` rule.
- IPv6 unique-local (`fc00::/7`)
- Multicast (`224.0.0.0/4`), limited broadcast (`255.255.255.255/32`),
  RFC 1122 "this network" (`0.0.0.0/8` — Linux/macOS route `0.0.0.0` to
  loopback).

A rejection raises `Network::EndpointPolicy::Violation` and surfaces
through `PeerDelivery::Result#outcome` as `:endpoint_policy_violation`.
**No `transmissions` row is written.** See
[`reference/transactions.md` § Endpoint policy / SSRF defence](../reference/transactions.md#endpoint-policy-ssrf-defence)
for the canonical list and rationale.

### TLS verification on by default

`OpenSSL::SSL::VERIFY_PEER`. The wallet does not silently accept
self-signed or otherwise invalid certificates. Plain HTTP is rejected
in production (`require_https: true`).

### ACK wtxid binding (mandatory; bare HTTP 200 != delivery)

A successful peer ACK is HTTP 200 + `Content-Type: application/json` +
body `{ "accepted": true, "wtxid": "<dtxid>" }`, where `wtxid` must equal
the dtxid (64-char display-order hex) of the subject we tried to deliver.

A bare HTTP 200 alone proves nothing. A captive portal at the operator's
coffee shop, a misconfigured load balancer, a wrong host on the other end
of a typo — any of them happily returns 200 OK. Without binding the ACK
to the specific BEEF we sent, the wallet would record those as
deliveries; the BeefParty trimmer would then over-trim future BEEFs to
that "peer", and the actual peer would silently miss everything we had
already "delivered" to the portal.

Mismatch -> outcome `:wrong_acked_wtxid`; no `acked_at` written, no
`transmission_txids` written. See
[`reference/transactions.md` § ACK contract](../reference/transactions.md#ack-contract-v1).

### Two-phase delivery (`transmission_txids` only on confirmed ACK)

The parent `transmissions` row is written via
`Store#record_transmission` after the egress-validation gate passes; the
known-set `transmission_txids` rows are written only via
`Store#mark_transmission_acked`, and only when the ACK has been validated.
Transport failure, timeout, mismatched wtxid — any non-`:delivered`
outcome — leaves the peer **not** recorded as knowing the wtxids we tried
to ship. The next transmission cannot over-trim against a knowledge claim
that was never confirmed. See
[`reference/transactions.md` § Two-phase delivery](../reference/transactions.md#two-phase-delivery).

### `BSV_WALLET_ALLOW_PRIVATE_ENDPOINTS=1` — **production-dangerous**

This environment variable opens the SSRF gate, allowing transmissions to
RFC1918 / loopback / link-local destinations — **including the cloud
metadata endpoint**. It exists for the e2e harness to talk to fixture
wallets on `127.0.0.1`.

It is read **once at policy construction** when the deliverer is built,
so it cannot be flipped at runtime. But if the daemon boots with it set,
every subsequent transmit will accept private destinations.

> Audit your systemd unit, container manifest, and `.env` discipline.
> Never set this in production.

## Secrets handling (`BSV_WALLET_WIF_*`)

The wallet's WIF is read from the process environment at boot. The
fixture registry resolves `BSV_WALLET_WIF_<NAME>` to the named wallet's
private key. The value is held in memory in `KeyDeriver` for the daemon's
lifetime.

For development and CI:

- Local: `~/.zshenv` (or equivalent) is conventional.
- CI: GitHub Actions secrets injected as repository or environment
  secrets.

For **production**:

- **Do not ship `.env` files into deployed images.** Treat the WIF as a
  secret the deployer mints into the runtime environment at start time.
- Integrate with the operator's secret manager (AWS Secrets Manager,
  HashiCorp Vault, GCP Secret Manager, Kubernetes Secret + projected
  volume, etc.). The integration point is `systemd EnvironmentFile=`, a
  container init that fetches the secret and `exec`s the daemon, or a
  sidecar that materialises the env var before the wallet process
  starts.
- The wallet has no on-disk WIF store; rotating the WIF means restarting
  the daemon with a new value in the environment.

## Log redaction (`bin/transmit` discipline)

`bin/transmit` logs to stderr a deliberately redacted single-line summary:

- **Endpoint** as host only — never the full URL. Avoids leaking
  credentialled URIs into log streams.
- **Counterparty** as last 8 hex characters only.
- **BEEF body is never echoed.** Not on success, not on failure, not at
  debug level.

```
transmitted: dtxid=<64-hex> peer=...<last8> via <host> outcome=<symbol>
```

Operators wrapping the daemon in their own logging stack should preserve
this discipline. A structured logger that captures the engine-side debug
output un-redacted silently reverses the AC; scrub before emission.

## `no_send` defaults to `false`

Every porcelain method — `send_payment`, `sweep`, `consolidate_step`,
`import_wallet` — defaults to `no_send: false`, matching the BRC-100
`createAction` default: the intent is to broadcast. Pass
**`no_send: true`** to build and sign without ever reaching the network,
returning a BEEF envelope for peer-to-peer handoff instead (see
[Sending Payments](sending-payments.md) for delivering that envelope with
`transmit`).

## The binary broadcast rule

Within a run of related actions, broadcasting is all-or-nothing: **you
cannot broadcast a descendant of an un-promoted parent.** The network
would reject the child for spending an input that does not exist in the
canonical UTXO set.

The distinction that matters: "un-promoted" is not the same as
"`no_send`". The wallet recognises several broadcast intents, with the
`:none` intent reserved for internal actions (the WBIKD address-lock
self-payment, for instance) that *do* get promoted — their outputs land
in the wallet's `spendable` set and can be consumed by a broadcast child,
because the child sees them as fully-funded local UTXOs that the network
never had to know about.

The wrong framing is "no descendant of a `no_send` parent". The right
framing is **"no descendant of an un-promoted parent"** — an action that
does not yet have a `promotions` row (promotion-as-a-row, ADR-023). A
`no_send: true` caller-facing action is one such case; an aborted or
reaped action is another. Internal `:none` actions *are* promoted (a row
is written on creation) and they can be spent by broadcast children.

Keep the broadcast intent consistent across a dependent sequence when the
intent crosses the network boundary; the internal-vs-broadcast boundary
is on promotion, not on `no_send`.

## Limp mode

When spendable balance falls below the **limp threshold (default 50,000
sats)**, *all outbound operations raise* `LimpModeError`. The wallet can
still receive — only spending is blocked.

- The threshold is configurable via `LIMP_THRESHOLD`, but there is a
  **hard floor of 10,000 sats**: you cannot configure it lower.
- A related `headroom` check blocks any individual send that would drop
  the balance below the threshold after outputs and fees.
- `import_utxo` and `sweep` deliberately bypass limp mode — they are how
  the wallet gets funded and how it is intentionally drained.

If you are testing with a small balance and every send raises
`LimpModeError`, this is why. Fund above the threshold, or lower it
(down to the 10,000 floor) with `LIMP_THRESHOLD`.

## One wallet per process

The wallet binds the process-global `Sequel::Model.db`. Booting two
wallets in one process clobbers the global and routes both at the last
connection opened. Run one wallet per OS process.

## Cryptographic comparisons

Not all wallet comparisons are constant-time, and the distinction is
deliberate:

- **Secret-keyed values** are compared in constant time. `verify_hmac`
  uses `secure_compare` so a side-channel timing attack cannot extract
  the HMAC byte by byte.
- **Public values** are compared by plain equality. The ACK wtxid check
  in `Network::PeerDelivery` uses `!=` because the wtxid is non-secret:
  it is a public transaction identifier the wallet computed itself and
  expects to see echoed back. A timing leak on a value the attacker
  already knows reveals nothing.

If you add new comparison sites, the rule is: if the value is a secret
key, MAC, signature, or password, use constant-time. If it is a
non-secret identifier, plain equality is correct.

## Production deployment checklist

A pre-flight sweep before pointing the daemon at a real WIF:

- **HTTPS only.** `Network::EndpointPolicy` defaults to
  `require_https: true`; do not override.
- **TLS verify on.** `OpenSSL::SSL::VERIFY_PEER` — do not patch around
  certificate errors.
- **`BSV_WALLET_ALLOW_PRIVATE_ENDPOINTS` unset.** Inspect the systemd
  unit, container manifest, deployment script. If it is set, the SSRF
  gate is open — including the cloud-metadata endpoint.
- **WIF from a secret manager**, not a deployed `.env` file. The wallet
  reads the environment at boot; the deployer's job is to mint the
  secret into that environment.
- **Log redaction preserved.** If you wrap `bin/transmit` or
  `Engine::Transmission` in a richer logger, scrub before emission —
  host-only endpoint, counterparty last-8, no BEEF body.
- **`walletd` supervised.** A systemd unit (or equivalent) restarts the
  daemon cleanly; the crash-recovery invariants in
  [Broadcast Lifecycle](broadcast-lifecycle.md) take care of resuming
  the in-flight state.
- **One wallet per OS process.** A multi-tenancy ambition needs separate
  processes per WIF.
- **Fee rate appropriate.** Default is 100 sat/KB; override via
  `BSV_WALLET_FEE_RATE_SATS_PER_KB` only with intent.
- **Limp threshold appropriate** for the wallet's operating balance.
