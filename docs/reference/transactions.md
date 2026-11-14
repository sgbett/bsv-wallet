---
title: Transactions
parent: Reference
nav_order: 6
---

# Transaction egress: broadcast vs transmit

There are **two** ways a signed transaction leaves the wallet, and conflating them is a recurring source of bugs (each "fix" to one wire shape silently broke the other). They are different *processes* with different recipients, wire formats, outcome taxonomies, and state. This document fixes the distinction.

| | **Broadcast** | **Transmit** |
|---|---|---|
| Recipient | the miner network (anonymous, fungible) | a *named* peer wallet (identity key) |
| Wire format | **Extended Format (EF)** | **Atomic BEEF (BRC-95)** |
| What the recipient does | consensus validation (scripts + fees) | SPV verification (BRC-67) |
| Domain | `Engine::Broadcast` | `Engine::Transmission` |
| Verb | broadcast | transmit (`Engine::Transmission#transmit`) |
| HTTP POST inside it | submit (the private `Engine::Broadcast#submit`, to ARC) | deliver (`Network::PeerDelivery#deliver`, to the peer) |
| Outcome | ARC `txStatus`: MINED, REJECTED, DOUBLE_SPEND_ATTEMPTED, … | `:delivered`, or one of nine failure outcomes (see *Delivery outcomes*) |
| Resolution | SSE + status polling (global chain state) | the peer's HTTP ACK, bound to the wtxid (point-to-point) |
| Per-recipient memory | none — a tx is a tx | **`transmission_txids`** — what has peer X already acknowledged |
| Cardinality per action | 0..1 | 0..N (one per counterparty) |

## The distinction is the recipient's *job*, not its *knowledge*

The tempting wrong model is "a peer knows nothing so needs everything; a miner has most of it so needs less." That is not the driver. The driver is **what the recipient does with the transaction**:

- **A miner does consensus validation.** It checks scripts and fees, and confirms the inputs are unspent against its own UTXO/mempool state. For that it needs the *immediate* input scripts and amounts — **one level deep** — and **no** merkle proofs, because a miner does not re-verify history; it is the thing that establishes it. That is exactly what **EF** carries: the raw tx plus, for each input, the source satoshis and source locking script inlined. EF exists so the node need not do a UTXO lookup per input — supply the prevout data and it validates statelessly. Arcade rejects a raw-tx submit with `'PreviousTx' not supplied`.

- **A receiving wallet does SPV.** It must prove to itself, trusting no one, that every ancestor was really mined. That requires the **full proven ancestry** back to anchors, carrying **merkle proofs (BUMPs)**. Even a peer that already knew every txid would still need the proofs to verify. That is **BEEF**.

So depth and proofs are fixed by the validation model, not by recipient knowledge.

## Two formats, built separately over one cache

EF and BEEF are built separately, each from the action's signed `raw_tx`; neither is derived from the other. They differ in how far they wire the inputs:

- **EF, for a miner.** `Engine::Broadcast#hydrated_transaction_for` parses the `raw_tx` into a `Transaction::Tx` and attaches one level of source data to each input: the satoshis and locking script of the output it spends. When every input's parent is in the `Engine::HydratedTxCache`, it takes them from the parents' cached raw-tx bytes; on any miss it takes them all from the spent `outputs` rows instead (`Store#resolve_inputs_for_signing`), which exist for every action the wallet built. The SDK's ARC and Arcade protocols serialise the result with `Transaction::Tx#to_ef_hex`. Broadcast never calls the Hydrator.
- **BEEF, for a peer.** `Engine::Hydrator#build_atomic_beef` wires each input's `source_transaction` recursively (`Engine::Hydrator#wire_ancestor`) until each branch reaches an ancestor with a merkle path, merges the graph into a `BSV::Transaction::Beef` and serialises it with `BSV::Transaction::Beef#to_atomic_binary`, passing the subject's wtxid. It reads ancestors through the same cache, falling back to `Store#find_proof` and filling the cache on a miss.

What the two share is the cache: raw-tx and merkle-path bytes keyed by wtxid, never `Transaction::Tx` objects, so a parent loaded by one path is a hit for the other. The BEEF that `build_action` and `sign_action` return also reaches walletd's Broadcast as a hint: when a hints socket is configured and the action is to be broadcast, the Engine pushes the BEEF to walletd, and `Engine::Broadcast#cache_beef_transactions` breaks it into one cache entry per transaction, with the raw-tx bytes and, where the BEEF carries a proof, the merkle-path bytes. Those entries are trusted only as far as the hints socket is (#556).

A BEEF holds everything its subject's EF needs, the subject and each input's parent, which is why a hint lets walletd skip the `outputs` JOIN. That holds only while the BEEF is untrimmed: trimming reduces known ancestors to TXID-only entries, which carry no bytes to cache (#552).

## Trimming is an orthogonal axis (BEEF only)

"How much does the recipient already hold?" *is* a real dimension — but it is **orthogonal** to the format choice and applies only to BEEF. It is the **trimming** optimisation: ancestors a counterparty already has are reduced to TXID-only entries (`make_txid_only`), so the wire carries only what is new. A TXID-only entry resolves only at a receiver that has agreed to fill it from its own store, and none does by default (`bin/wallet receive` doesn't pass `trust_self: 'known'`; wallet-toolbox's `internalizeAction` rejects TXID-only entries), so transmit sends full ancestors and trimming waits for the receiver's agreement (#552). It rides *on top of* BEEF and never applies to EF — EF is already minimal for a miner's job, with nothing to trim against the miner's knowledge.

Trimming is the one place the "peer knows X, send less" instinct is correct.

## Two domains, one cache

Broadcast and transmit are separate stateful *processes* (wallet side, per the stateless→SDK / stateful→wallet axis in `state-boundaries.md`) that, within an Engine, share one in-memory cache, the `Engine::HydratedTxCache`. Broadcast reads it directly for its EF build and fills it from eager broadcast-response proofs (walletd's Broadcast, over its own cache, also fills it from producers' hints); Transmission reaches it only through the Hydrator, which assembles the peer's BEEF:

```
       Engine::HydratedTxCache   ← shared: wtxid-keyed raw-tx + merkle-path bytes
          /                \
         /              Engine::Hydrator   ← wires Transaction::Tx ancestry, assembles Atomic BEEF
        /                       |
  Engine::Broadcast    Engine::Transmission
   #submit  → EF→miner   #transmit → BEEF→peer
   resolve: SSE/polls    resolve: peer HTTP ACK (wtxid-bound)
   stateless-about-who   stateful-about-who (transmission_txids, per counterparty)
```

The per-recipient-memory row is the deciding difference: broadcast is stateless about *who* (a tx is global), transmission is stateful about *who* (what each peer has acknowledged is inherently per-counterparty). That state cannot be bolted onto `Engine::Broadcast` without smuggling a foreign model in — hence a sibling domain, not a flag.

`Engine::Transmission` is thinner than it first looks: it is transport + per-peer accounting + delivery-outcome, *on top of* the Hydrator's BEEF assembly. It is not a fork of Broadcast.

A note on the verb: `transmit`, not `send` — `send` is poisoned by Ruby's `Object#send`. `Broadcast` and `Transmission` are the domain nouns, and broadcast and transmit their verbs. Each wraps an HTTP POST with a verb of its own: *submit* inside a broadcast (to ARC) and *deliver* inside a transmit (to the peer). See the [glossary](glossary.md#sending-out).

## Broadcast and transmit are parallel, not sequential

They are independent edges off the same action, not a pipeline. BEEF/SPV exists precisely so a peer can verify an *unconfirmed-subject* transaction from its ancestry proofs without waiting for the subject to mine — so a transmit need not follow a broadcast (or vice versa). An action may be broadcast and never transmitted (a self-spend), transmitted and never broadcast by us (the peer broadcasts), both, or neither (a purely internal action). The trust/timing stance — whether and when to transmit relative to broadcasting — is a Transmission-domain decision, not an ordering baked into the action.

## Relationship to BRC-100

BRC-100 specifies the *interface* (`createAction` returns the BEEF, `internalizeAction` consumes it) and is **deliberately silent on transport**. The spec's model is "the wallet hands you the tx object; how it reaches the peer is your concern." So transmit intent `none` — return the BEEF and let the caller deliver it, as the `bin/wallet send <identity key> <sats> | bin/wallet receive` pipe does — **is** the BRC-100-compliant baseline, and it remains available alongside `bin/transmit`. `Engine::Transmission` is an **original, beyond-spec extension** — there is no reference implementation; the peer acceptance/rejection taxonomy and delivery semantics are the wallet's to design. Conceptual lineage: peer-to-peer / IP-to-IP direct payments (the whitepaper's "direct" channel).

A design constraint that follows: **transmit intent is an invocation mode, not a property of `transmit`.** In v1 the wallet delivers `inline` (the caller awaits a self-contained `transmit`) or, with intent `none`, leaves delivery to the caller; the same operation must be drivable `delayed` by the daemon later (#385 Phase 2). This mirrors `broadcast_intent` (`inline` and `delayed` over one code path) — see `Engine::Broadcast`.

## Current state (2026-11)

Both edges are now first-class processes; the historical asymmetry — broadcast fully built, transmit a CLI pipe — was the subject of HLR #385 (PR #408) and is closed:

- **Broadcast (→ network).** `Engine::Broadcast`, OMQ PULL sockets, SSE resolution, callback handlers, crash-recovery — the daemon is built around it. Both the inline and daemon paths ship EF (#252 closed the daemon-side raw-hex gap).
- **Transmit (→ peer).** `Engine::Transmission#transmit` sits as a sibling to `Engine::Broadcast` and `Engine::TxProof`, assembling the peer's BEEF through `Engine::Hydrator`. The `transmissions` and `transmission_txids` tables hold per-peer knowledge at grain (action × counterparty); status is **derived** from the presence of `acked_at` (no status column — principle-of-state). It sends full ancestors; per-peer trimming waits for the receiver's agreement (#552). Delivery is synchronous HTTP POST of a JSON envelope to a caller-supplied endpoint (`Network::PeerDelivery`), guarded by `Network::EndpointPolicy` (SSRF gate); the ACK is wtxid-bound so a captive portal cannot impersonate delivery. The CLI surface is `bin/transmit` (see *CLI surface* below). #464 proposes separating the BEEF transport from the BRC-29 envelope in `Engine::Transmission`, so that `transmit` ships only BEEF and the conformance layer builds the envelope.

What v1 deliberately omits, and what stays for Phase 2: an identity-key → endpoint directory (peers must be reached by URL today), a daemon-driven `delayed` transmit (`#transmit` is shaped to be drivable both ways over one code path — same invariant as `broadcast_intent`), a peer-signed ACK protocol (the `transmissions.ack_signature bytea NULL` column is reserved now so Phase 2 lands without a schema migration), retry/backoff, and knowledge-revocation when a peer prunes.

### Per-table responsibilities

- `transmissions` — one row per (action, counterparty); `acked_at` set on confirmed delivery; `ack_signature` reserved nullable for Phase 2; CASCADE on the action FK (reaper-parity with the rest of the schema).
- `transmission_txids` — pure membership: which wtxids each transmission's BEEF carried. The known-set per-peer trimming will read (#552). Populated only by `mark_transmission_acked`, never by `record_transmission` — see *Two-phase delivery* below.

## The egress completeness check is a transmit precondition

`Engine::Hydrator#validate_for_handoff!` (the structural-only verify with `TrustedSelfChainTracker`) answers exactly one question: *is this BEEF fit to hand to a peer?* It is therefore a **Transmission precondition**, and is now called from `Engine::Transmission#transmit` over the wire bytes it is about to ship, before the row is written. The method stays on `Hydrator` (it works on bytes and a subject wtxid; it has no per-peer state), but the call site that matters at runtime is Transmission's.

The check takes an `allow_txid_only:` kwarg, and every call site keeps the default `allow_txid_only: false`: the BEEF the wallet hands back to its own caller (`Engine#build_action`, `#sign_action`) and the BEEF it transmits are both full bundles, so any `TxidOnlyEntry` is a defect. The flag is for per-peer trimming a receiver has agreed to (#552), where TXID-only entries are legitimate; the verifier stays one method.

The wallet trusts its own persisted proofs (validated against a real `Network::ChainTracker` at proof-arrival time), so structural completeness — every input path terminates at a `merkle_path` or wires through to one — is the only thing left to assert at egress. Failure raises `EgressBeefInvalidError` and means an upstream proof-closure gap, not a chain-validity problem.

Note also that the check fails the **delivery**, not the wallet's state: the DB transition has already committed atomically; the BEEF is a read-only projection over committed state, so a failed projection raises to the caller without rolling anything back (principle-of-state — `principle-of-state.md`). The transmission row itself is **only** written after this check passes — see *Two-phase delivery* below.

## Wire envelope (v1)

The peer-to-peer transport is an HTTP POST of a JSON envelope. The shape follows the envelope the `bin/wallet send` → `bin/wallet receive` stdout/stdin pipe carries (see *Wallet-internal envelope shape* below) — v1 is "the existing pipe, but over HTTP" — without its `dtxid` and with an explicit version tag so Phase 2 can negotiate additions.

```
POST <endpoint>
Content-Type: application/json

{
  "beef":                 "<hex>",         // Atomic BEEF (BRC-95), hex-encoded
  "outputs":              [ … ],           // BRC-29 remittance metadata
  "sender_identity_key":  "<hex>",         // BRC-43 compressed pubkey, 66 chars
  "protocol_version":     1
}
```

- **`beef`** — Atomic BEEF binary, **hex-encoded for JSON transport**. The wallet's convention is binary internally (wtxid, raw bytes, BUMPs) and hex only at boundaries where a spec or wire format mandates it; JSON is one such boundary. The peer's decoder hex-decodes before handing to `internalize_action`.
- **`outputs`** — BRC-29-style entries. Without this, the peer has bytes but cannot recover the locking key for any output (the BRC-42 derivation needs `derivation_prefix` + `derivation_suffix` + the sender's identity key); the ACK would always have to fail or the peer would have to silently drop the payment. v1 carries them explicitly.
- **`sender_identity_key`** — BRC-43 compressed pubkey hex (the identity pubkey carve-out from CLAUDE.md applies: hex everywhere this value appears, no binary representation). The peer needs it to complete BRC-42 derivation on each output.
- **`protocol_version: 1`** — forward-compat. Phase 2 will add `certificates`, `ack_signature` and similar fields; bumping this field is the negotiation point.

The wallet ships the envelope through `Network::PeerDelivery` (the v1 transport seam — `Engine::Transmission` takes a `delivery:` kwarg, so the Phase 2 deliverer for a `delayed` transmit drops in by constructor argument without touching the engine). The transport follows no redirects, and defaults to a 5-second connect timeout, a 30-second read timeout, and TLS verification on.

## ACK contract (v1)

A successful peer ACK is **HTTP 200 + `Content-Type: application/json`**, with a body of exactly this shape:

```
{
  "accepted": true,
  "wtxid":    "<dtxid>"      // 64-char hex, display order
}
```

The `wtxid` field MUST match the subject's dtxid. Mismatch → the wallet records the delivery outcome as `:wrong_acked_wtxid` and **does not write `acked_at`** (nor the known-set txids — see *Two-phase delivery*).

**The wtxid binding is mandatory and load-bearing.** A bare HTTP 200 alone proves nothing: a captive portal at the operator's coffee shop, a misconfigured load balancer, a wrong host on the other end of a typo — any of them happily returns 200 OK. Without binding the ACK to the specific BEEF we sent, the wallet would record those as deliveries; its known-set for that "peer" would then claim wtxids the actual peer never received, and once per-peer trimming lands (#552) the actual peer would silently miss everything we'd already "delivered" to the portal. The wtxid binding is what makes the ACK a statement about *this* delivery, not about the existence of an HTTP 200 somewhere on the network.

**Phase 2: signed ACK.** The peer signs over `(wtxid, transmission_attempt_id)` with its identity key. The `transmissions.ack_signature bytea NULL` column is reserved from day one (migration 001 §20) so Phase 2 lands without a schema migration: v1 ACKs leave the column NULL, Phase 2 ACKs write the signature. The bare HTTP-200-plus-wtxid contract is the v1 honest minimum; the signed variant is the eventual cryptographic minimum.

### Delivery outcomes

`Network::PeerDelivery#deliver` returns a `Result` struct whose `outcome` is one of: `:delivered`, `:endpoint_policy_violation`, `:tls_failure`, `:dns_failure`, `:transport_error`, `:timeout`, `:non_200`, `:body_too_large`, `:malformed_ack`, `:wrong_acked_wtxid`. Each is a distinct symbol so an operator (or a future daemon) can choose a different remediation per case (alert vs. silent retry-eligible vs. mark-bad-endpoint). Only `:delivered` drives `mark_transmission_acked`.

## Endpoint policy / SSRF defence
{: #endpoint-policy-ssrf-defence }

`Network::EndpointPolicy` is the SSRF gate. The peer endpoint is caller-supplied — by construction the wallet's external attack surface — so the defaults are deliberately strict:

- **HTTPS only in production** (`require_https: true`). Plain HTTP gives an on-path attacker the BEEF, the BRC-29 `sender_identity_key`, and the ability to forge a 200 ACK.
- **TLS verification on.** No silent acceptance of self-signed certificates.
- **Private/loopback/link-local destinations rejected.** The reject list (`EndpointPolicy::PRIVATE_RANGES`): `0.0.0.0/8`, `127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `100.64.0.0/10`, `169.254.0.0/16` (includes the cloud-metadata endpoint at `169.254.169.254` — the canonical SSRF target for credential exfiltration on AWS / GCP / Azure), `224.0.0.0/4`, `255.255.255.255/32`, `::1/128`, `fc00::/7` and `::ffff:0:0/96`; an IPv4-mapped IPv6 address is unwrapped and checked against the IPv4 ranges. A misconfigured wallet shipping its BEEF and its identity key to the metadata service is a credible loss-of-funds path; this list closes it by default.
- **No redirects followed.** A 3xx is a `:non_200` outcome, so a peer cannot 302 the bundle into the metadata range.
- **Body size cap.** Default 32 MiB; defence against a runaway hydration walk or a deliberately oversized payload.
- **DNS TOCTOU mitigation.** The policy resolves the host once at `validate!` time and the deliverer dials the resolved IP, with `Host:` set to the original hostname so TLS SNI and virtual-host routing still work. This closes the window where `Net::HTTP` would re-resolve and land on a different (private) IP than the one the policy approved.
- **Dev/test opt-out.** `BSV_WALLET_ALLOW_PRIVATE_ENDPOINTS=1` allows the e2e harness to talk to fixture wallets on `127.0.0.1`. The variable is read once at policy construction; production wallets leave it unset.

A rejection raises `Network::EndpointPolicy::Violation` (a `BSV::Wallet::Error` subclass), which `Network::PeerDelivery#deliver` returns as an `:endpoint_policy_violation` outcome. Transmit has already written the `transmissions` row by then (see *Two-phase delivery*), but sets no `acked_at` and records no known-set wtxids.

## Two-phase delivery

The wallet writes the parent `transmissions` row at one point and the `transmission_txids` known-set rows at a different point. The boundary is the crypto-safety property that keeps the known-set honest.

- **`Store#record_transmission(action_id:, counterparty:)`** writes (or upserts) the parent row. Re-transmit refreshes `updated_at` and returns the same id (atomic `INSERT … ON CONFLICT (action_id, counterparty) DO UPDATE … RETURNING id`). This method **never** writes `transmission_txids`.
- **`Store#mark_transmission_acked(action_id:, counterparty:, wtxids:)`** writes `acked_at` AND the `transmission_txids` rows, in a single DB transaction. Batched `INSERT … ON CONFLICT (transmission_id, wtxid) DO NOTHING` — no N+1, no loops.

Failure between record and ACK — transport error, timeout, mismatched wtxid, anything that isn't `:delivered` — leaves the peer **not** recorded as knowing the wtxids we tried to ship. Once per-peer trimming lands (#552), the next transmission to the same peer cannot over-trim against a knowledge claim that was never confirmed; the peer SPV-verifies cleanly, because every entry it needs is still on the wire. This is the cure for over-trim-on-failed-delivery, and it is the reason the two writes live in two methods rather than one transaction.

`Engine::Transmission#transmit` orchestrates both phases: `record_transmission` runs after the egress-validation gate passes; `mark_transmission_acked` runs iff the `PeerDelivery::Result#delivered?` predicate is true. When the endpoint kwarg is nil (transmit intent `none` — the caller takes the returned BEEF and arranges its own delivery), only the first phase fires and the caller is responsible for invoking `mark_transmission_acked` on confirmed delivery.

## CLI surface

`bin/transmit` reads the envelope `bin/wallet send <identity key> <sats>` writes to stdout, finds the action by its `dtxid` and transmits it — a `bin/wallet send … | bin/transmit --to <identity_key> --endpoint <url>` pipe. See `bin/transmit --help` for the current flag set.

It is a binary of its own rather than a `bin/wallet` command because `bin/wallet transmit` waits on #464. Today `transmit` takes the BRC-29 envelope's `outputs` and `sender_identity_key` alongside the BEEF; #464 proposes that the engine layer ship only the BEEF and the conformance layer build the envelope.

## BRC-29 derivation convention

Every BRC-29-shaped payment derivation in the wallet — outbound to a counterparty *or* internal self-payment that uses the same protocol envelope — composes its BRC-43 invoice number from the spec-mandated literals. The protocol identifier is `[2, '3241645161d8']` (security level 2, the BRC-29 magic) and the key id is `"#{derivation_prefix} #{derivation_suffix}"` — a single ASCII space between the two tokens, per the spec invoice-number format ([BRC-29 §Key Derivation Scheme](https://github.com/bitcoin-sv/BRCs/blob/master/payments/0029.md#key-derivation-scheme)). The composed string is the input the [BRC-42](https://github.com/bitcoin-sv/BRCs/blob/master/key-derivation/0042.md) derivation algorithm consumes.

Two symbols are the only sanctioned producers:

- `BSV::Wallet::BRC29::PROTOCOL_ID` — the protocol identifier. Currently aliases `BSV::Auth::AuthFetch::PAYMENT_PROTOCOL_ID`; if/when the SDK moves the constant out of the `AuthFetch` namespace (one consumer of BRC-29, not its owner) the alias absorbs the move.
- `BSV::Wallet::BRC29.key_id(prefix, suffix)` — the only sanctioned `key_id` composer. Inline `"#{prefix} #{suffix}"` at call sites is banned. The helper validates each token against the base64url subset `[A-Za-z0-9+/=_-]`, rejects empty tokens, and caps each at 128 bytes. The validation is a cryptographic correctness check, not defensive padding: an NBSP or two-space typo would silently parse on the sender side and break key recovery on the receiver — the failure surfaces only as an unspendable output, no exception.

The same protocol identifier is reused for internal self-payments — change outputs, WBIKD slot derivation, sweep self-pays — because the wallet uses one BRC-42 protocol envelope for all P2PKH derivation rather than minting a parallel internal-only protocol. The `counterparty` parameter is what distinguishes the two regimes.

| Site | Role | `counterparty` |
|---|---|---|
| `Engine#send_payment` | Outbound BRC-29 payment | `recipient` identity key |
| `Engine::TxBuilder#derive_signing_key` | Spending an inbound BRC-29 output | `sender_identity_key` (or `'self'` for internal-origin) |
| `CLI::Commands::Send#call_identity_key` | Outbound BRC-29 payment (CLI) | `recipient` identity key |
| `Engine::TxBuilder#build_change` | Change output back to wallet | `'self'` |
| `Engine#generate_receive_address` | WBIKD receive-address derivation | `'self'` |
| `Engine#list_receive_addresses` | WBIKD slot enumeration | `'self'` |
| `Engine#find_or_create_wbikd_slot` | WBIKD slot creation | `'self'` |
| `Engine#internalize_wbikd_utxo` | WBIKD UTXO recovery | `'self'` |

The first three are BRC-29 payments in the spec sense — the counterparty is the recipient or sender identity key. The remaining five are internal self-payments riding on the same protocol envelope.

## Wallet-internal envelope shape

The JSON shape `bin/wallet send <identity_key>` emits on stdout, and `bin/wallet receive` consumes from stdin, is wallet-internal:

```json
{
  "beef":                "<hex>",
  "dtxid":               "<dtxid>",
  "sender_identity_key": "<hex>",
  "outputs": [
    { "vout": 0, "satoshis": 1234,
      "derivation_prefix": "<prefix>", "derivation_suffix": "<suffix>",
      "basket": "<optional>" }
  ]
}
```

It is not the spec's `{ derivationPrefix, derivationSuffix, transaction: <base64 AtomicBEEF> }` shape ([BRC-29 §Current Payment Message Construction](https://github.com/bitcoin-sv/BRCs/blob/master/payments/0029.md#current-payment-message-construction)). It is snake_case, the BEEF is hex (not base64), it carries `sender_identity_key` at the top level, and `outputs` is an array — multi-output payments are first-class. The current shape was kept deliberately:

- The native CLI pipe (`bin/wallet send … | bin/wallet receive`) is the canonical surface and is not a ts-stack carrier; pulling it toward the BRC-100/ts-stack envelope shape would lose the agnosticism we want from the native CLI.
- The strict-spec envelope is reserved for a future `bin/brc100` CLI carrier — the place where ts-stack interop will live.
- The spec itself defers the outer envelope: BRC-29 §Current Payment Message Construction explicitly notes that "the exact outer envelope may be defined by the higher-level protocol carrying the payment, such as BRC-105 for HTTP service monetization." The wallet's snake_case JSON is one such higher-level protocol — a *wallet-CLI carrier*, scoped to the native pipe.

The BRC-29 spec compliance lives at the **derivation layer** (protocol identifier, invoice number composition, counterparty) — that is what makes a payment cross-compatible. The envelope is the transport choice on top, and the strict-spec transport is a separate, deferrable concern.

## Threat model (CLI BRC-29 receive)

**Sender identity is unauthenticated.** The CLI receive path shape-validates `sender_identity_key` — checks the compressed pubkey hex shape — but performs no cryptographic signature check. An on-path attacker who substitutes their own identity key in the envelope (rewriting the same `beef`) causes the receiver to derive the BRC-42 child key for the *attacker's* identity, not the genuine sender's. The receiver's internalize then targets an output whose locking-script pubkey hash matches a key the attacker can spend — funds delivered to the attacker on next broadcast. The wallet-internal envelope is therefore suitable for *trusted-channel* delivery only (a piped stdin/stdout under one operator's control, or a hand-copied JSON file). Wire-level use over an untrusted network needs BRC-31 transport authentication wrapping the envelope; that is #498.

**Derivation token entropy is sufficient at every BRC-29 send site.** `BSV::Wallet.random_derivation` produces eight cryptographically random bytes (64 bits) per token, base64-encoded to a 12-character string. Both BRC-29 send paths — the outbound CLI (`CLI::Commands::Send#call_identity_key`) and the Engine porcelain `Engine#send_payment` — draw prefix and suffix independently from `random_derivation`, giving 128 bits of combined per-output entropy. That is ample for output unlinkability against a chain-watching observer. Internal self-payment sites use deterministic suffixes (`vout.to_s`, `(i+1).to_s` for change indexing, static `'1'` for WBIKD); their counterparty is `'self'`, so no third party can derive the locking-script pubkey hash from a public input regardless, and the entropy concern does not apply at those sites.

**`paymentRemittance` is engine-internal, not wire shape.** The receiver's `internalize_action` call shape — `protocol: 'wallet payment'` plus the `payment_remittance: { derivation_prefix, derivation_suffix, sender_identity_key }` triple — matches the BRC-29 spec's `internalizeAction` example exactly ([BRC-29 §Recipient Validation](https://github.com/bitcoin-sv/BRCs/blob/master/payments/0029.md#recipient-validation)). It is the call shape between `CLI::Commands::Receive` and `Engine::BeefInternalizer`, not a wire shape — the wire envelope is the JSON above. The distinction matters: a future strict-spec wire envelope (per the bullet below) would still emit the same `payment_remittance` triple to the engine at the internalize boundary.

## Future work

Tracked as follow-up HLRs filed post-merge of #460:

- Strict BRC-29 wire envelope (camelCase, base64 BEEF, `paymentRemittance` triple per the spec) for a `bin/brc100` CLI carrier — Q1 of #460 deferred (#497).
- BRC-31 transport authentication of the wallet-internal envelope — closes the sender-identity-unauthenticated gap above (#498).
- Move SDK `PAYMENT_PROTOCOL_ID` out of `BSV::Auth::AuthFetch::*` — `AuthFetch` is one consumer of BRC-29, not its owner; a BRC-29 namespace would be the right home. `BSV::Wallet::BRC29::PROTOCOL_ID` is the wallet seam for that move (#499).
- Identity-key case canonicalisation on receive — downcase inbound hex before DB compare. Pre-existing latent issue, surfaced more by BRC-29 (#500).

## References

- Format specs: BRC-12 (Raw Transaction), BRC-62 (BEEF), BRC-74 (BUMP), BRC-95 (Atomic BEEF), BRC-67 (SPV). EF (Extended Format) inlines per-input source satoshis + locking script onto the raw tx; it is the ARC submission shape, not a peer-interchange format.
- BRC-29 — sender-identity-key remittance metadata that the wire envelope carries alongside the BEEF; BRC-43 — counterparty identity-key derivation (the `sender_identity_key` / `counterparty` shape).
- `state-boundaries.md` — the stateless/stateful axis that puts both processes in the wallet.
- `principle-of-state.md` — why delivery status is derived from `acked_at`, not stored as a column.
- [`.architecture/reviews/20260619_noSend-sendWith-design-notes.md`](../../.architecture/reviews/20260619_noSend-sendWith-design-notes.md) — `noSend`/`sendWith` batching. This is a **Broadcast** concern, not Transmission: #192 builds a chain of transactions *locally* (spending not-yet-broadcast change) then flushes the batch to the **network** atomically. Its "chained-send" is intra-wallet UTXO chaining, distinct from the inter-wallet BEEF cascade that motivates transmission.
- `.architecture/decisions/adrs/20260619_ADR-025-transmission-distinct-domain.md` — the decision record establishing Transmission as a sibling domain to Broadcast (not a method or mode flag on it).
- HLR #385 / PR #408 — the Transmission domain implementation (`transmissions` + `transmission_txids` schema, `Engine::Transmission`, BeefParty trim, egress validation, `Network::PeerDelivery` + `Network::EndpointPolicy`, `bin/transmit`).
- #551 — transmit sends full ancestors. It had trimmed through `Transaction::BeefParty` (BSV Ruby SDK), whose `trimmed_beef_for_party` dropped known ancestors rather than leaving TXID-only entries, and no receiver resolves TXID-only entries by default anyway. #552 brings trimming back once the receiver agrees to it.
- #296 — BEEF chain integrity + hydration: the egress check `validate_for_handoff!` (Phase B, now on `Engine::Hydrator`, which #343 extracted) and the wtxid-keyed `Engine::HydratedTxCache` the Hydrator shares with `Engine::Broadcast` (Phase D).
- #192 — noSend/sendWith subsystem (Broadcast-domain extension). The only mechanic shared with Transmission is `knownTxids` trimming (deferred for Transmission until #552), which is the SDK's `Transaction::BeefParty`, not either process's. The two domains stay separate; a future Transmission composes alongside #192's batch broadcast rather than absorbing it.
