# Transaction egress: broadcast vs transmit

There are **two** ways a signed transaction leaves the wallet, and conflating them is a recurring source of bugs (each "fix" to one wire shape silently broke the other). They are different *processes* with different recipients, wire formats, outcome taxonomies, and state. This document fixes the distinction.

| | **Broadcast** | **Transmit** |
|---|---|---|
| Recipient | the miner network (anonymous, fungible) | a *named* peer wallet (identity key) |
| Wire format | **Extended Format (EF)** | **Atomic BEEF (BRC-95)** |
| What the recipient does | consensus validation (scripts + fees) | SPV verification (BRC-67) |
| Verb | `Engine::Broadcast#submit` | `Engine::Transmission#transmit` |
| Outcome | MINED / REJECTED / DOUBLE_SPEND | DELIVERED / ACK'd / refused |
| Resolution | SSE + block-watch (global chain state) | peer internalize ACK (point-to-point) |
| Per-recipient memory | none — a tx is a tx | **BeefParty** — what has peer X already seen |
| Cardinality per action | 0..1 | 0..N (one per counterparty) |

## The distinction is the recipient's *job*, not its *knowledge*

The tempting wrong model is "a peer knows nothing so needs everything; a miner has most of it so needs less." That is not the driver. The driver is **what the recipient does with the transaction**:

- **A miner does consensus validation.** It checks scripts and fees, and confirms the inputs are unspent against its own UTXO/mempool state. For that it needs the *immediate* input scripts and amounts — **one level deep** — and **no** merkle proofs, because a miner does not re-verify history; it is the thing that establishes it. That is exactly what **EF** carries: the raw tx plus, for each input, the source satoshis and source locking script inlined. EF exists so the node need not do a UTXO lookup per input — supply the prevout data and it validates statelessly. A raw-tx submit fails with `'PreviousTx' not supplied`.

- **A receiving wallet does SPV.** It must prove to itself, trusting no one, that every ancestor was really mined. That requires the **full proven ancestry** back to anchors, carrying **merkle proofs (BUMPs)**. Even a peer that already knew every txid would still need the proofs to verify. That is **BEEF**.

So depth and proofs are fixed by the validation model, not by recipient knowledge.

## Both formats are projections of one hydrated transaction

EF and BEEF are not separately constructed. Both derive from the same in-memory `Transaction::Tx` whose inputs have `source_transaction` wired (the *hydrated* object — see `Engine::Hydrator`):

- `to_ef_hex` → keep one level, drop proofs → **EF for a miner**
- `to_atomic_binary` → keep the full wired graph → **BEEF for a peer**

BEEF is a strict superset of EF for the subject transaction. This is why the broadcast daemon can prime its cache with the BEEF the producer already built for the caller's return value and simply call `to_ef` on it — no second hydration (`Engine::Broadcast#hydrated_transaction_for`).

## Trimming is an orthogonal axis (BEEF only)

"How much does the recipient already hold?" *is* a real dimension — but it is **orthogonal** to the format choice and applies only to BEEF. It is the **trimming** optimisation: ancestors a counterparty already has are reduced to TXID-only entries (`make_txid_only`), so the wire carries only what is new. The SDK's `Transaction::BeefParty` is the per-counterparty bookkeeping layer for this. It rides *on top of* BEEF and never applies to EF — EF is already minimal for a miner's job, with nothing to trim against the miner's knowledge.

Trimming is the one place the "peer knows X, send less" instinct is correct.

## Two domains over one substrate

Broadcast and transmit are separate stateful *processes* (wallet side, per the stateless→SDK / stateful→wallet axis in `state-boundaries.md`) sitting on a shared *operational* substrate:

```
            Engine::Hydrator   ← shared: wtxid-keyed bytes cache → wired Transaction::Tx
             /            \
  Engine::Broadcast    Engine::Transmission
   #submit  → EF→miner   #transmit → BEEF→peer
   resolve: SSE/blocks   resolve: peer HTTP ACK (wtxid-bound)
   stateless-about-who   stateful-about-who (BeefParty, per counterparty)
```

The per-recipient-memory row is the deciding difference: broadcast is stateless about *who* (a tx is global), transmission is stateful about *who* (BeefParty is inherently per-counterparty). That state cannot be bolted onto `Engine::Broadcast` without smuggling a foreign model in — hence a sibling domain, not a flag.

`Engine::Transmission` is thinner than it first looks: it is transport + per-peer trimming + delivery-outcome, *on top of* the shared Hydrator. It is not a fork of Broadcast.

A note on the verb: `transmit`, not `send` — `send` is poisoned by Ruby's `Object#send`. `submit` stays as the inner HTTP verb of the broadcast subsystem. `Broadcast` and `Transmission` are the domain nouns; `submit` and `transmit` are their actions.

## Broadcast and transmit are parallel, not sequential

They are independent edges off the same action, not a pipeline. BEEF/SPV exists precisely so a peer can verify an *unconfirmed-subject* transaction from its ancestry proofs without waiting for the subject to mine — so a transmit need not follow a broadcast (or vice versa). An action may be broadcast and never transmitted (a self-spend), transmitted and never broadcast by us (the peer broadcasts), both, or neither (a purely internal action). The trust/timing stance — whether and when to transmit relative to broadcasting — is a Transmission-domain decision, not an ordering baked into the action.

## Relationship to BRC-100

BRC-100 specifies the *interface* (`createAction` returns the BEEF, `internalizeAction` consumes it) and is **deliberately silent on transport**. The spec's model is "the wallet hands you the tx object; how it reaches the peer is your concern." So the return-BEEF-and-let-the-caller-deliver path (the `bin/create | bin/receive` pipe) **is** the BRC-100-compliant baseline, and it remains available alongside the `bin/transmit` porcelain. `Engine::Transmission` is an **original, beyond-spec extension** — there is no reference implementation; the peer acceptance/rejection taxonomy and delivery semantics are the wallet's to design. Conceptual lineage: peer-to-peer / IP-to-IP direct payments (the whitepaper's "direct" channel).

A design constraint that follows: **delivery synchronicity is an invocation mode, not a property of `transmit`.** v1 delivers synchronously because an inline caller awaits a self-contained `transmit`; the same operation must be drivable asynchronously by the daemon later. This mirrors `broadcast_intent` (inline/delayed over one code path) — see `Engine::Broadcast`.

## Current state (2026-06)

Both edges are now first-class processes; the historical asymmetry — broadcast fully built, transmit a CLI pipe — was the subject of HLR #385 (PR #408) and is closed:

- **Broadcast (→ network).** `Engine::Broadcast`, OMQ PULL sockets, SSE resolution, callback handlers, crash-recovery — the daemon is built around it. Both the inline and daemon paths ship EF (#252 closed the daemon-side raw-hex gap).
- **Transmit (→ peer).** `Engine::Transmission#transmit` sits as a sibling to `Engine::Broadcast` and `Engine::TxProof` over the shared `Engine::Hydrator` substrate. The `transmissions` and `transmission_txids` tables hold per-peer knowledge at grain (action × counterparty); status is **derived** from the presence of `acked_at` (no status column — principle-of-state). Per-peer trimming is wired through `Transaction::BeefParty`. Delivery is synchronous HTTP POST of a JSON envelope to a caller-supplied endpoint (`Network::PeerDelivery`), guarded by `Network::EndpointPolicy` (SSRF gate); the ACK is wtxid-bound so a captive portal cannot impersonate delivery. The CLI surface is `bin/transmit` (mirroring `bin/create` and `bin/receive`).

What v1 deliberately omits, and what stays for Phase 2: an identity-key → endpoint directory (peers must be reached by URL today), a daemon-driven async delivery path (`#transmit` is shaped to be drivable both ways over one code path — same invariant as `broadcast_intent`), a peer-signed ACK protocol (the `transmissions.ack_signature bytea NULL` column is reserved now so Phase 2 lands without a schema migration), retry/backoff, and knowledge-revocation when a peer prunes.

### Per-table responsibilities

- `transmissions` — one row per (action, counterparty); `acked_at` set on confirmed delivery; `ack_signature` reserved nullable for Phase 2; CASCADE on the action FK (reaper-parity with the rest of the schema).
- `transmission_txids` — pure membership: which wtxids each transmission's BEEF carried. The per-counterparty BeefParty trim source. Populated only by `mark_transmission_acked`, never by `record_transmission` — see *Two-phase delivery* below.

## The egress completeness check is a transmit precondition

`Engine::Hydrator#validate_for_handoff!` (the structural-only verify with `TrustedSelfChainTracker`) answers exactly one question: *is this BEEF fit to hand to a peer?* It is therefore a **Transmission precondition**, and is now called from `Engine::Transmission#transmit` over the **peer-specific, trimmed** wire bytes — i.e. after per-peer BeefParty trimming and before the row is written. The substrate method stays on `Hydrator` (it works on bytes and a subject wtxid; it has no per-peer state), but the call site that matters at runtime is Transmission's.

The check takes an `allow_txid_only:` kwarg. Transmission passes `allow_txid_only: true` because the trim step deliberately produces `TxidOnlyEntry` records — entries the peer already holds — and a structural verify must tolerate them. Build-time call sites (`Engine#build_action`, `#sign_action`) keep the default `allow_txid_only: false`, since the BEEF the wallet hands back to its own caller is the full bundle: nothing has been trimmed against any peer yet. The two regimes diverge only on this flag; the verifier is one method.

The wallet trusts its own persisted proofs (validated against a real `Network::ChainTracker` at proof-arrival time), so structural completeness — every input path terminates at a `merkle_path`, wires through to one, or is a `TxidOnlyEntry` the peer is expected to resolve from local state — is the only thing left to assert at egress. Failure raises `EgressBeefInvalidError` and means an upstream proof-closure gap (or a trim step that produced a mis-resolved bundle), not a chain-validity problem.

Note also that the check fails the **delivery**, not the wallet's state: the DB transition has already committed atomically; the BEEF is a read-only projection over committed state, so a failed projection raises to the caller without rolling anything back (principle-of-state — `principle-of-state.md`). The transmission row itself is **only** written after this check passes — see *Two-phase delivery* below.

## Wire envelope (v1)

The peer-to-peer transport is an HTTP POST of a JSON envelope. The shape is the BRC-29-aligned superset of the existing `bin/create` → `bin/receive` stdin/stdout pipe — v1 is "the existing pipe, but over HTTP" — with an explicit version tag so Phase 2 can negotiate additions.

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

The wallet ships the envelope through `Network::PeerDelivery` (the v1 transport seam — `Engine::Transmission` takes a `delivery:` kwarg, so the Phase 2 daemon-async deliverer drops in by constructor argument without touching the engine). The transport defaults to no cross-host redirects, a 5-second connect timeout, a 30-second read timeout, and TLS verification on.

## ACK contract (v1)

A successful peer ACK is **HTTP 200 + `Content-Type: application/json`**, with a body of exactly this shape:

```
{
  "accepted": true,
  "wtxid":    "<dtxid>"      // 64-char hex, display order
}
```

The `wtxid` field MUST match the subject's dtxid. Mismatch → the wallet records the delivery outcome as `:wrong_acked_wtxid` and **does not write `acked_at`** (nor the known-set txids — see *Two-phase delivery*).

**The wtxid binding is mandatory and load-bearing.** A bare HTTP 200 alone proves nothing: a captive portal at the operator's coffee shop, a misconfigured load balancer, a wrong host on the other end of a typo — any of them happily returns 200 OK. Without binding the ACK to the specific BEEF we sent, the wallet would record those as deliveries; the BeefParty trimmer would then over-trim future BEEFs to that "peer", and the actual peer (when it eventually got reached) would silently miss everything we'd already "delivered" to the portal. The wtxid binding is what makes the ACK a statement about *this* delivery, not about the existence of an HTTP 200 somewhere on the network.

**Phase 2: signed ACK.** The peer signs over `(wtxid, transmission_attempt_id)` with its identity key. The `transmissions.ack_signature bytea NULL` column is reserved from day one (migration 001 §20) so Phase 2 lands without a schema migration: v1 ACKs leave the column NULL, Phase 2 ACKs write the signature. The bare HTTP-200-plus-wtxid contract is the v1 honest minimum; the signed variant is the eventual cryptographic minimum.

### Delivery outcomes

`Network::PeerDelivery#deliver` returns a `Result` struct whose `outcome` is one of: `:delivered`, `:endpoint_policy_violation`, `:tls_failure`, `:dns_failure`, `:transport_error`, `:timeout`, `:non_200`, `:body_too_large`, `:malformed_ack`, `:wrong_acked_wtxid`. Each is a distinct symbol so an operator (or a future daemon) can choose a different remediation per case (alert vs. silent retry-eligible vs. mark-bad-endpoint). Only `:delivered` drives `mark_transmission_acked`.

## Endpoint policy / SSRF defence

`Network::EndpointPolicy` is the SSRF gate. The peer endpoint is caller- supplied — by construction the wallet's external attack surface — so the defaults are deliberately strict:

- **HTTPS only in production** (`require_https: true`). Plain HTTP gives an on-path attacker the BEEF, the BRC-29 `sender_identity_key`, and the ability to forge a 200 ACK.
- **TLS verification on.** No silent acceptance of self-signed certificates.
- **Private/loopback/link-local destinations rejected.** The reject list: `127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16` (includes the cloud-metadata endpoint at `169.254.169.254` — the canonical SSRF target for credential exfiltration on AWS / GCP / Azure), `::1/128`, `fc00::/7`. A misconfigured wallet shipping its BEEF and its identity key to the metadata service is a credible loss-of-funds path; this list closes it by default.
- **No cross-host redirects.** A peer cannot 302 the bundle into the metadata range.
- **Body size cap.** Default 32 MiB; defence against a runaway hydration walk or a deliberately oversized payload.
- **DNS TOCTOU mitigation.** The policy resolves the host once at `validate!` time and the deliverer dials the resolved IP, with `Host:` set to the original hostname so TLS SNI and virtual-host routing still work. This closes the window where `Net::HTTP` would re-resolve and land on a different (private) IP than the one the policy approved.
- **Dev/test opt-out.** `BSV_WALLET_ALLOW_PRIVATE_ENDPOINTS=1` allows the e2e harness to talk to fixture wallets on `127.0.0.1`. The variable is read once at policy construction; production wallets leave it unset.

A rejection raises `Network::EndpointPolicy::Violation` (a `BSV::Wallet::Error` subclass), surfaced through the deliverer as a `:endpoint_policy_violation` outcome. No row is written.

## Two-phase delivery

The wallet writes the parent `transmissions` row at one point and the `transmission_txids` known-set rows at a different point. The boundary is the crypto-safety property that makes the BeefParty trim mechanism honest.

- **`Store#record_transmission(action_id:, counterparty:)`** writes (or upserts) the parent row. Re-transmit refreshes `updated_at` and returns the same id (atomic `INSERT … ON CONFLICT (action_id, counterparty) DO UPDATE … RETURNING id`). This method **never** writes `transmission_txids`.
- **`Store#mark_transmission_acked(action_id:, counterparty:, wtxids:)`** writes `acked_at` AND the `transmission_txids` rows, in a single DB transaction. Batched `INSERT … ON CONFLICT (transmission_id, wtxid) DO NOTHING` — no N+1, no loops.

Failure between record and ACK — transport error, timeout, mismatched wtxid, anything that isn't `:delivered` — leaves the peer **not** recorded as knowing the wtxids we tried to ship. The next transmission to the same peer cannot over-trim against a knowledge claim that was never confirmed; the peer SPV-verifies cleanly, because every entry it needs is still on the wire. This is the cure for over-trim-on-failed-delivery, and it is the reason the two writes live in two methods rather than one transaction.

`Engine::Transmission#transmit` orchestrates both phases: `record_transmission` runs after the egress-validation gate passes; `mark_transmission_acked` runs iff the `PeerDelivery::Result#delivered?` predicate is true. When the endpoint kwarg is nil (the deferred-by-caller path — the caller takes the returned BEEF and arranges its own delivery), only the first phase fires and the caller is responsible for invoking `mark_transmission_acked` on confirmed delivery.

## CLI surface

`bin/transmit` is the porcelain. It mirrors the verb symmetry of `bin/create` (build the action + BEEF) and `bin/receive` (consume the BEEF into a wallet) — a `bin/create | bin/transmit | bin/receive` pipe, with `bin/transmit` carrying `--to <identity_key>` and `--endpoint <url>`. See `bin/transmit --help` for the current flag set.

## BRC-29 derivation convention

Every BRC-29-shaped payment derivation in the wallet — outbound to a counterparty *or* internal self-payment that uses the same protocol envelope — composes its BRC-43 invoice number from the spec-mandated literals. The protocol identifier is `[2, '3241645161d8']` (security level 2, the BRC-29 magic) and the key id is `"#{derivation_prefix} #{derivation_suffix}"` — a single ASCII space between the two tokens, per the spec invoice-number format ([BRC-29 §Key Derivation Scheme](https://github.com/bitcoin-sv/BRCs/blob/master/payments/0029.md#key-derivation-scheme)). The composed string is the input the [BRC-42](https://github.com/bitcoin-sv/BRCs/blob/master/key-derivation/0042.md) derivation algorithm consumes.

Two symbols are the only sanctioned producers:

- `BSV::Wallet::BRC29::PROTOCOL_ID` — the protocol identifier. Currently aliases `BSV::Auth::AuthFetch::PAYMENT_PROTOCOL_ID`; if/when the SDK moves the constant out of the `AuthFetch` namespace (one consumer of BRC-29, not its owner) the alias absorbs the move.
- `BSV::Wallet::BRC29.key_id(prefix, suffix)` — the only sanctioned `key_id` composer. Inline `"#{prefix} #{suffix}"` at call sites is banned. The helper validates each token against the base64url subset `[A-Za-z0-9+/=_-]`, rejects empty tokens, and caps each at 128 bytes. The validation is a cryptographic correctness primitive, not defensive padding: an NBSP or two-space typo would silently parse on the sender side and break key recovery on the receiver — the failure surfaces only as an unspendable output, no exception.

The same protocol identifier is reused for internal self-payments — change outputs, WBIKD slot derivation, sweep self-pays — because the wallet uses one BRC-42 protocol envelope for all P2PKH derivation rather than minting a parallel internal-only protocol. The `counterparty` parameter is what distinguishes the two regimes.

| Site | Role | `counterparty` |
|---|---|---|
| `Engine#send_payment` | Outbound BRC-29 payment | `recipient` identity key |
| `Engine::TxBuilder#derive_signing_key` | Spending an inbound BRC-29 output | `sender_identity_key` (or `'self'` for internal-origin) |
| `CLI::Commands::Send#call_identity_key` | Outbound BRC-29 payment (CLI) | `recipient` identity key |
| `Engine::TxBuilder#build_change` | Change output back to wallet | `'self'` |
| `Engine#create_wbikd_receive_address` | WBIKD slot derivation | `'self'` |
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

**Sender identity is unauthenticated.** The CLI receive path shape-validates `sender_identity_key` — checks the compressed pubkey hex shape — but performs no cryptographic signature check. An on-path attacker who substitutes their own identity key in the envelope (rewriting the same `beef`) causes the receiver to derive the BRC-42 child key for the *attacker's* identity, not the genuine sender's. The receiver's import then targets an output whose locking-script pubkey hash matches a key the attacker can spend — funds delivered to the attacker on next broadcast. The wallet-internal envelope is therefore suitable for *trusted-channel* delivery only (a piped stdin/stdout under one operator's control, or a hand-copied JSON file). Wire-level use over an untrusted network needs BRC-31 transport authentication wrapping the envelope; that is a follow-up HLR (TBD).

**Derivation token entropy is sufficient at every BRC-29 send site.** `BSV::Wallet.random_derivation` produces eight cryptographically random bytes (64 bits) per token, base64-encoded to a 12-character string. Both BRC-29 send paths — the outbound CLI (`CLI::Commands::Send#call_identity_key`) and the engine-side porcelain (`Engine#send_payment`) — draw prefix and suffix independently from `random_derivation`, giving 128 bits of combined per-output entropy. That is ample for output unlinkability against a chain-watching observer. Internal self-payment sites use deterministic suffixes (`vout.to_s`, `(i+1).to_s` for change indexing, static `'1'` for WBIKD); their counterparty is `'self'`, so no third party can derive the locking-script pubkey hash from a public input regardless, and the entropy concern does not apply at those sites.

**`paymentRemittance` is engine-internal, not wire shape.** The receiver's `internalize_action` call shape — `protocol: 'wallet payment'` plus the `payment_remittance: { derivation_prefix, derivation_suffix, sender_identity_key }` triple — matches the BRC-29 spec's `internalizeAction` example exactly ([BRC-29 §Recipient Validation](https://github.com/bitcoin-sv/BRCs/blob/master/payments/0029.md#recipient-validation)). It is the call shape between `CLI::Commands::Receive` and `Engine::BeefImporter`, not a wire shape — the wire envelope is the JSON above. The distinction matters: a future strict-spec wire envelope (per the bullet below) would still emit the same `payment_remittance` triple to the engine at the internalize boundary.

## Future work

Tracked as follow-up HLRs filed post-merge of #460:

- Strict BRC-29 wire envelope (camelCase, base64 BEEF, `paymentRemittance` triple per the spec) for a `bin/brc100` CLI carrier — Q1 of #460 deferred (follow-up issue TBD).
- BRC-31 transport authentication of the wallet-internal envelope — closes the sender-identity-unauthenticated gap above (follow-up issue TBD).
- Move SDK `PAYMENT_PROTOCOL_ID` out of `BSV::Auth::AuthFetch::*` — `AuthFetch` is one consumer of BRC-29, not its owner; a BRC-29 namespace would be the right home. `BSV::Wallet::BRC29::PROTOCOL_ID` is the wallet seam for that move (follow-up issue TBD).
- Identity-key case canonicalisation on receive — downcase inbound hex before DB compare. Pre-existing latent issue, surfaced more by BRC-29 (follow-up issue TBD).

## References

- Format specs: BRC-12 (Raw Transaction), BRC-62 (BEEF), BRC-74 (BUMP), BRC-95 (Atomic BEEF), BRC-67 (SPV). EF (Extended Format) inlines per-input source satoshis + locking script onto the raw tx; it is the ARC submission shape, not a peer-interchange format.
- BRC-29 — sender-identity-key remittance metadata that the wire envelope carries alongside the BEEF; BRC-43 — counterparty identity-key derivation (the `sender_identity_key` / `counterparty` shape).
- `state-boundaries.md` — the stateless/stateful axis that puts both processes in the wallet.
- `principle-of-state.md` — why delivery status is derived from `acked_at`, not stored as a column.
- [`.architecture/reviews/20260619_noSend-sendWith-design-notes.md`](../../.architecture/reviews/20260619_noSend-sendWith-design-notes.md) — `noSend`/`sendWith` batching. This is a **Broadcast** concern, not Transmission: #192 builds a chain of transactions *locally* (spending not-yet-broadcast change) then flushes the batch to the **network** atomically. Its "chained-send" is intra-wallet UTXO chaining, distinct from the inter-wallet BEEF cascade that motivates transmission.
- `.architecture/decisions/adrs/20260619_ADR-025-transmission-distinct-domain.md` — the decision record establishing Transmission as a sibling domain to Broadcast (not a method or mode flag on it).
- HLR #385 / PR #408 — the Transmission domain implementation (`transmissions` + `transmission_txids` schema, `Engine::Transmission`, BeefParty trim, egress validation, `Network::PeerDelivery` + `Network::EndpointPolicy`, `bin/transmit`).
- `Transaction::BeefParty` (BSV Ruby SDK) — the per-counterparty trim mechanism. `make_txid_only` + `trimmed_beef_for_party` drive the wire shrink; `add_known_wtxids_for_party` seeds the peer's known-set from `transmission_known_wtxids`.
- #296 — BEEF chain integrity + hydration: extracts the shared `Engine::Hydrator` substrate both domains read.
- #192 — noSend/sendWith subsystem (Broadcast-domain extension). The only mechanic shared with Transmission is `knownTxids` trimming (BeefParty), which lives on the shared substrate, not in either process. The two domains stay separate; a future Transmission composes alongside #192's batch broadcast rather than absorbing it.
