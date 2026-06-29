---
title: Keys & cryptography
parent: Concepts
nav_order: 8
---

# Keys & Cryptography

All of the wallet's cryptography lives behind a single facade, `KeyDeriver`. The Engine never touches elliptic-curve primitives directly; it asks `KeyDeriver` for a derived key, a ciphertext, an HMAC, or a signature. This keeps the cryptographic surface small, auditable, and in one place.

Every operation is built on a published BRC standard. This page maps the standards onto the methods and explains the two ideas that tie them together: **invoice-number key derivation** and the **counterparty model**.

## The root keys

A `KeyDeriver` wraps one or two root private keys:

```ruby
kd = BSV::Wallet::KeyDeriver.new(private_key: wif_key)            # everyday only
kd = BSV::Wallet::KeyDeriver.new(private_key: wif_key,
                                 privileged_key: high_security_key) # + privileged
```

- The **everyday** key is the wallet's identity. `identity_key` returns the compressed public key as a **66-character hex string** — the value other parties use as your "counterparty". For crypto-op consumers that need raw bytes (`hash160`, ECDH input), `identity_key_bytes` returns the **33-byte binary** form; never round-trip `identity_key` through `[hex].pack('H*')` — the binary accessor exists for exactly that need (see `gem/bsv-wallet/lib/bsv/wallet/key_deriver.rb`, line 78 and onward).
- The optional **privileged** key is a separate root for higher-assurance operations. Every cryptographic method takes a `privileged: true` flag; when set, `select_key` uses the privileged root and raises if one was never configured. The separation means a routine operation can never accidentally exercise the privileged key.

`root_private_key_bytes` is exposed for keyed operations such as the WBIKD recovery markers described below.

### Identity-hex carve-out

This wallet stores and surfaces *identity-shaped* public keys as hex throughout the data path, not binary. That is a deliberate carve-out from the wallet's general "binary internal, hex only at spec boundaries" principle. Identity pubkeys cross BRC boundaries on almost every call (BRC-100 `identity_key`, BRC-43 counterparty, BRC-29 sender identity, BRC-52 certifier/subject/verifier), and storing them hex keeps the boundary cheap. **Derived** BRC-42 outputs are different — they are intermediates fed directly into the next crypto op, never crossing a JSON boundary as themselves, so they stay binary. The full reasoning lives in the "Public Key Convention" section of `CLAUDE.md`.

## BRC-42 / BRC-43: invoice-number derivation

The heart of the scheme. Rather than a BIP-32 tree of accounts, keys are derived from an **invoice number** computed from a protocol identifier and a key identifier, in the BRC-43 format:

```
"{security_level}-{protocol_name}-{key_id}"
```

`protocol_id` is a `[security_level, protocol_name]` pair, and `key_id` is a free-form string:

```ruby
pub = kd.derive_public_key(
  protocol_id: [1, "my protocol"],   # security level 1, named protocol
  key_id:      "1",
  counterparty: "self"
)
```

The power of this approach is that **two parties can derive matching keys without exchanging them.** Using the same invoice number, the sender derives the recipient's child *public* key to lock an output, and the recipient derives the corresponding child *private* key to spend it. `derive_public_key` and `derive_private_key` are the two halves; the wallet uses them everywhere it needs a fresh, unlinkable key — including its own change (see [UTXO Management](utxo-management.md)).

Invoice-number components are validated (`validate_security_level!`, `validate_protocol_name!`, `validate_key_id!`) so a malformed protocol can never silently derive the wrong key.

## The counterparty model

Every derivation, encryption, and signature is *relative to a counterparty*. `resolve_counterparty` accepts three forms:

| Counterparty | Resolves to | Use |
|--------------|-------------|-----|
| `"self"` | your own public key | keys only you can derive and use (e.g. change) |
| `"anyone"` | the well-known public key of private key `1` | "public" operations anyone can reverse — broadcast-style encryption where the point is *not* secrecy but authenticated derivation |
| hex string | that public key (validated) | a specific named party |

`"anyone"` deserves a note: it is the public key corresponding to the private key `1`, a value everyone can compute. Encrypting "to anyone" therefore does not hide anything — it standardises a derivation that any party can follow, which is the right primitive for publicly readable but wallet-authored data.

## BRC-2: encryption and HMACs

`encrypt` / `decrypt` implement BRC-2. ECDH between your key and the counterparty's produces a shared *elliptic-curve point*; SHA-256 over that point's x-coordinate is the **AES-256-GCM** key used to seal the payload. AES-256-GCM is authenticated encryption — tampering is detected at decryption rather than producing plausible garbage.

`create_hmac` keys an **HMAC-SHA-256** with the same ECDH-derived symmetric key, giving a 32-byte tag that proves the data was authored by a holder of the shared secret. The Engine exposes `encrypt`, `decrypt`, `create_hmac`, and `verify_hmac` directly as BRC-100 methods.

## Signatures: ECDSA on secp256k1, deterministic-k, low-s

`create_signature` / `verify_signature` sign either a message (`data:`) or a pre-computed digest (`hash_to_directly_sign:`) under a derived key, again relative to a counterparty.

The underlying primitive is ECDSA on secp256k1 with two non-negotiable hygiene rules baked into the SDK:

- **RFC 6979 deterministic-k.** The nonce is derived from the message and private key, not from a CSPRNG. The same `(key, message)` always produces the same signature; a buggy or compromised entropy source cannot leak the key through nonce reuse, because there is no entropy source involved at signing time.
- **Low-s normalisation.** ECDSA admits two valid `s` values for the same signature; BSV consensus requires the lower one. The SDK normalises on the fly, so a signature emitted by this wallet is canonical and not vulnerable to third-party `s`-flipping malleability.

When the signature lands inside a transaction, the final byte is the sighash flag. For BSV that flag is **`0x41` = `SIGHASH_ALL | SIGHASH_FORKID`**: `SIGHASH_ALL` (the default coverage — every input and output is bound) OR'd with `SIGHASH_FORKID`, the replay-protection bit mandated by the 2017 fork. A signature without `SIGHASH_FORKID` is rejected by miners; the SDK sets it implicitly so wallet code never has to.

This is how the wallet authenticates messages and satisfies the BRC-100 signing methods, distinct from the transaction signing done during the [action lifecycle](action-lifecycle.md).

## BRC-52: certificates and selective revelation

Identity certificates are stored with **per-field encryption**: each field's value is encrypted under its own master key, so fields can be revealed *selectively* without exposing the rest. `derive_revelation_keyring` (BRC-52) builds the keyring a verifier needs to read exactly the fields the holder chooses to reveal — using the certifier as the counterparty — which the Engine surfaces as `prove_certificate`. The `certificates` and `certificate_fields` tables persist them; see [Persistence](persistence.md).

## BRC-69: key-linkage revelation

Sometimes a holder needs to *prove* that two keys are linked — that a derived key really does descend from their identity — without handing over the private key. `reveal_counterparty_linkage` and `reveal_specific_linkage` (BRC-69) produce verifiable revelations of that linkage for a named verifier. The Engine exposes these as `reveal_counterparty_key_linkage` and `reveal_specific_key_linkage`. They are the controlled, explicit escape hatch from the privacy that BRC-42 derivation otherwise provides: linkage is never leaked, only deliberately revealed.

## WBIKD recoverable receive addresses

The wallet also supports a **legacy P2PKH receive scheme** for parties that cannot process BEEF or derived-key payments — but it makes those addresses *recoverable from the key alone*. The pattern (the code calls it WBIKD):

1. `generate_receive_address` finds or creates a pre-funded UTXO **slot** in the `'p wbikd'` basket and locks it with a zero-output internal action (`broadcast_intent: :none`, labelled `wbikd`).
2. The receive address is derived not from a stored secret but from the slot's **on-chain coordinates** — its source `txid` (the derivation prefix) and `vout` (the suffix). Anyone holding the identity key can re-derive the same address from those public coordinates.
3. Recovery markers written as `OP_RETURN` outputs are `HMAC-SHA-256(key = root_private_key_bytes, data = satoshis.to_s)` — the satoshi amount keyed with the root private key. Argument order matches `Engine#compute_wbikd_marker` exactly. Only the holder of the root key can produce or recognise the marker, so to anyone else it is indistinguishable from random 32 bytes.

Because the address is a deterministic function of the identity key and public on-chain data, the set of outstanding addresses can be *rebuilt* after data loss: `list_receive_addresses` re-derives them from the labelled locks, `scan_receive_addresses` looks for incoming payments to them, and `internalize_wbikd_utxo` ingests each discovered UTXO and recycles the slot for re-use. This is the receive-side counterpart to the root sweep — see [Resilience & Recovery](resilience-and-recovery.md).

## BRC test vectors

The specs and their reference vectors live under `/opt/BRCs/`. Each of the cryptographic surfaces above maps to a numbered spec; the test-vector tables on those pages are the canonical fixtures the SDK and this wallet are checked against:

- **BRC-2** (`/opt/BRCs/wallet/0002.md`) — encryption and HMAC vectors.
- **BRC-42** (`/opt/BRCs/key-derivation/0042.md`) — invoice-number key derivation vectors.
- **BRC-43** (`/opt/BRCs/key-derivation/0043.md`) — invoice-number format.
- **BRC-52** (`/opt/BRCs/peer-to-peer/0052.md`) — certificate revelation.
- **BRC-69** (`/opt/BRCs/key-derivation/0069.md`) — key-linkage revelation.

When a derivation or signature looks wrong, the BRC vector for that surface is the first thing to diff against.
