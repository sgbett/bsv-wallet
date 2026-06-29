---
title: Transmission
parent: Concepts
nav_order: 4
---

# Transmission: wallet-to-peer BEEF delivery

Broadcast and transmission look superficially similar — both ship a transaction somewhere — but they are different operations with different recipients, different wire shapes, and different state. **Broadcast** ships Extended Format to the miner network for consensus validation; **transmission** ships Atomic BEEF to a *named peer* for SPV verification. The recipient's *job* fixes the wire shape, and the per-peer accounting that makes trimming possible is the deciding difference. It lives in its own domain.

This page is the operational narrative. The canonical wire envelope, ACK contract, SSRF list, error taxonomy and per-table responsibilities are in [Transactions (reference)](../reference/transactions.md) under "Two domains over one substrate". This page defers to that for normative claims.

## Where it sits

`Engine::Transmission` is a sibling to `Engine::Broadcast` and `Engine::TxProof`, all built over the shared `Engine::Hydrator` substrate. The Engine accessor is `engine.transmission`; transmission is a wallet-vocab operation — peer delivery is not part of the BRC-100 standard surface.

Background-worker shape, like its siblings: no `Interface::Transmission` contract module. Transmissions are not a cross-replaceable service the way `Store` or `Hydrator` are; the deciding axis is per-counterparty state, owned in one place.

## The `transmit` operation

```ruby
engine.transmission.transmit(
  counterparty:         "02f0...",   # BRC-43 compressed pubkey, lowercase hex
  action_id:            42,
  outputs:              [{ vout: 0, satoshis: 500,
                           derivation_prefix: "...", derivation_suffix: "..." }],
  sender_identity_key:  "03ab...",
  endpoint:             "https://bob.example/internalize"   # optional
)
# => { transmission_id:, beef:, sent_wtxids:, outputs:,
#      sender_identity_key:, delivery: }
```

Two modes from one operation:

- **With `endpoint:`** — the trimmed BEEF is POSTed synchronously by `Network::PeerDelivery`, the ACK is validated against the subject wtxid, and a successful delivery flips the transmission to *acked*.
- **Without `endpoint:`** — the trimmed BEEF is returned for the caller to shuttle out-of-band (a queue, an email attachment, a file). The transmission row is recorded; ACK arrives later through whatever path the deployment uses.

Validation order is deliberate: **counterparty hex shape is checked at the engine boundary before any database write or BEEF construction**. A typo'd pubkey must never produce a phantom `transmissions` row. Shape matches the Postgres CHECK constraint exactly (`/\A0[23][0-9a-f]{64}\z/`), so engine and schema reject the same inputs.

## The ACK contract — a wtxid in the field, a dtxid on the wire

A successful peer ACK is HTTP 200 + `Content-Type: application/json`. The body is exactly:

```
{
  "accepted": true,
  "wtxid":    "<64-char hex, display order>"
}
```

**The field is named `wtxid` but its value is a `dtxid` — a 64-character display-order hex string of the subject transaction**, not 32 raw wire-order bytes hex-encoded. This is a load-bearing detail. A peer implementer reading `wtxid` literally — emitting `wtxid.unpack1('H*')` (32 wire-order bytes hex-encoded, 64 chars in reversed order from what the wallet expects) — would produce 200 OKs that look correct but mismatch the wallet's subject every time. The wallet would record `:wrong_acked_wtxid` on every delivery; trimming would never engage; over-shipping the same ancestors would scale linearly with the relationship.

The convention in this codebase: the field name on the wire is `wtxid` for backwards-compatibility, but the **value** is the 64-character display-order hex string (`dtxid` in our vocabulary). The wallet computes it as `subject_wtxid.reverse.unpack1('H*')` before emitting; a peer's ACK must do the equivalent. The reference document is unambiguous about this — see [Transactions (reference) — ACK contract (v1)](../reference/transactions.md#ack-contract-v1).

`PeerDelivery` treats a mismatch as a crypto gate failure (`:wrong_acked_wtxid`), exactly as if the body were malformed or the status non-200. This is what prevents a captive portal, a misconfigured load balancer, or a wrong-host typo from being recorded as a successful delivery: a bare HTTP 200 proves nothing about which BEEF reached the peer; the wtxid binding makes the ACK a statement about *this* delivery.

## EndpointPolicy: the SSRF gate

A wallet that POSTs to a URL supplied by the caller is one URL away from being asked to scan the deployer's private network. `EndpointPolicy` is the gate that prevents it.

`EndpointPolicy#validate!(endpoint)` performs, in order:

1. **Scheme** — `https://` required by default (`http://` rejected unless `require_https: false` is passed for fixture endpoints).
2. **Hostname present and resolvable** — DNS resolution happens *once*, inside `validate!`; the resolved IP is returned and PeerDelivery dials it directly while setting the `Host:` header for SNI. This closes the DNS TOCTOU window where a name resolves to a public IP at check time and a private one at connect time.
3. **IPv4-mapped IPv6 unwrap** — `validate_ip!` calls `.native` on the resolved address before any range comparison. `::ffff:127.0.0.1` is reduced to `127.0.0.1` so the loopback range matches. This is the **primary** defence against mapped-address evasion.
4. **Private-range refusal** — the resolved IP is rejected if it falls in any of the canonical SSRF ranges. The reference list (`127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `100.64.0.0/10`, `169.254.0.0/16` — includes the cloud-metadata endpoint at `169.254.169.254` —, `224.0.0.0/4`, `255.255.255.255/32`, `::1/128`, `fc00::/7`, and `::ffff:0:0/96`) is canonicalised in [Transactions (reference) — Endpoint policy / SSRF defence](../reference/transactions.md#endpoint-policy-ssrf-defence). The `::ffff:0:0/96` entry on that list is a **belt-and-braces** defence: a mapped IPv6 address that somehow bypassed the step-3 `.native` reduction would still match here. The first line of defence is the unwrap; the membership check is the second.
5. **Body size cap** — defaults to 32 MiB; large responses are truncated to bound exposure if a peer misbehaves.

For e2e harnesses that genuinely need to deliver to a loopback fixture, `BSV_WALLET_ALLOW_PRIVATE_ENDPOINTS=1` opens the policy explicitly. **This variable is production-dangerous.** Setting it disables every range check in step 4 — the wallet will deliver to `127.0.0.1`, `169.254.169.254`, and anything else the caller supplies. It is the only way through the gate, and it is intended for development and CI fixtures, not production. A production wallet leaves it unset; an operator who flips it on is choosing to accept the SSRF-credential-exfiltration risk that the gate was built to prevent.

## Per-peer trim: BeefParty

Each peer ought to receive only the parts of the ancestor graph they do not already hold. The two-phase write of `transmission_txids` is what makes that knowable.

For every transmission, the engine:

1. Fetches the peer's already-known wtxids in one query (`transmission_known_wtxids(counterparty:)`).
2. Builds the *full* Atomic BEEF via `Hydrator#build_atomic_beef`.
3. Hands the full BEEF and the known-set to a fresh `BSV::Transaction::BeefParty`. Known ancestors are demoted to `TxidOnlyEntry` via `make_txid_only`; the SDK's `trimmed_beef_for_party` then drops those entries.
4. Re-asserts the **subject** is still present and still a real entry — defence against a poisoned `transmission_txids` row that would otherwise demote the subject to a TXID-only stub and ship an unverifiable bundle.

A fresh `BeefParty` per call matters. `BeefParty#merge_txid_only` mutates the receiving party's state; reusing an instance across counterparties would leak TXID-only entries from one peer's bundle into another's.

## Egress SPV-honesty: `validate_for_handoff!`

After trim and *before* recording the transmission, the trimmed bytes are re-parsed and handed to `Hydrator#validate_for_handoff!(allow_txid_only: true)`. The kwarg is essential — trim deliberately produces TXID-only entries — but everything else is a strict SPV check: every input resolvable in the bundle, every proof anchored, the subject not demoted. Failure raises `EgressBeefInvalidError`, distinct from `InvalidBeefError` (which is for incoming peer data) so an operator can tell at a glance whether the wallet's own state or a peer's bundle is the cause.

The check uses `TrustedSelfChainTracker` — a tracker that returns `true` for all header lookups, because the wallet's stored proofs were validated against real headers at import time. This is structural completeness against the wallet's own truth, not chain validation; the chain has been consulted already.

## The `transmissions` table: two-phase write on ACK

```
transmissions          transmission_txids
┌──────────────┐       ┌────────────────────┐
│ id           │◀──────│ transmission_id    │
│ action_id    │       │ wtxid              │
│ counterparty │       └────────────────────┘
│ acked_at     │            ▲ populated only
│ ack_signature│            │ in mark_transmission_acked
│ timestamps   │            │
└──────────────┘
   UNIQUE(action_id, counterparty)
```

Grain is one row per `(action_id, counterparty)`: a re-transmission to the same peer updates in place rather than fanning. `acked_at` is null until the peer's ACK is recorded. `transmission_txids` — the set of wtxids the peer has now seen — is populated **only** when an ACK arrives, never at record time. That ordering is the gate: a transmission the peer did not accept does not enlarge the wallet's view of the peer's known-set, so the next trim cannot accidentally strip a transaction the peer never actually received.

`ack_signature` is reserved for Phase 2 (BRC-31 signed ACK); v1 leaves it null. The detailed per-table responsibilities are in [Transactions (reference) — Per-table responsibilities](../reference/transactions.md#per-table-responsibilities).

## CLI

```bash
# alice builds an action but does not broadcast, then transmits to bob
bin/create alice "$BOB_IDENTITY_KEY" 500 --no-send \
  | bin/transmit alice --to "$BOB_IDENTITY_KEY" --endpoint https://bob.example/internalize
```

`bin/transmit` reads the BEEF envelope on stdin, looks up the matching action, and calls `engine.transmission.transmit` with the supplied counterparty and endpoint. Logs are redacted: the endpoint host but not the full URL, the counterparty's last 8 hex chars but not the whole key, and the BEEF body never. The JSON result on stdout is `{ transmission_id, outcome, delivered, http_status, dtxid }`.

The complete delivery-outcome taxonomy (`:delivered`, `:endpoint_policy_violation`, `:dns_failure`, `:tls_failure`, `:non_200`, `:transport_error`, `:timeout`, `:body_too_large`, `:malformed_ack`, `:wrong_acked_wtxid`) is canonicalised in [Transactions (reference) — Delivery outcomes](../reference/transactions.md#delivery-outcomes). The transmission row is recorded for every outcome; only `:delivered` flips it to acked.

## Related

- [Transactions (reference)](../reference/transactions.md) — canonical wire envelope, ACK contract, SSRF list, error taxonomy, per-table responsibilities.
- [Transactions & BEEF](transactions-and-beef.md) — the egress Atomic BEEF construction this domain consumes.
- [Action lifecycle](action-lifecycle.md) — the action whose BEEF is being transmitted.
- [Schema](../reference/schema.md) — `transmissions` and `transmission_txids` table reference.
