# ADR-008: Binary internally, hex only at boundaries (+ the identity-pubkey carve-out)

## Status

Accepted.

**Decided:** 2026-05-05 (`d08edd3`, HLR #1 — the PostgreSQL schema and Sequel models). Both sub-decisions below were made together at the original schema/binary decision: `bytea` for hash-shaped data and `:text` for the identity-shaped pubkey columns were set in the one migration. The Engine integration shortly after (PR #18) shipped `KeyDeriver#identity_key` as hex, realising (b) in code.

## Context

Hash-shaped data — transaction IDs, block hashes, merkle paths, raw transactions, locking scripts — is fixed-width binary. The reference implementation hex-encodes it everywhere, because in JavaScript strings are UTF-16 and `Buffer` is a second-class citizen; hex strings are the path of least resistance there. Ruby has first-class binary strings, and the SDK produces binary. Hex is a display format, not a data format.

But not every byte-string in the wallet is hash-shaped content. Public keys split into two classes with different representation rules, and the schema-design decision had to settle both at once: the hash-shaped data that the principle governs, and the identity-shaped public keys that are a deliberate exception to it. The schema therefore declares `bytea` for txids/scripts/hashes *and* `:text` for `sender_identity_key` and the certificate fields in the same migration — two decisions, one moment, recorded here as (a) and (b).

## Decision Drivers

* Ruby works naturally with binary strings end to end; nothing forces hex internally.
* Binary is smaller and faster to store and compare (a txid is 32 bytes vs 64 hex chars), and no relationship JOINs key on a txid — foreign keys are surrogate `bigint`s.
* A spec sometimes *mandates* a hex string at its boundary; that is the only place hex is data.
* Identity-shaped public keys are protocol identifiers, not binary content: their canonical internal form is a `PublicKey` curve-point object, and they cross BRC JSON boundaries on nearly every interface call. For that class, hex is the form that lives off the hot conversion path.

## Decision

Two distinct decisions, made together at the schema design and labelled (a) and (b).

### (a) Binary-internal, hex only at boundaries

Store and pass hash-shaped data as binary (`bytea`) throughout — database, models, wallet, SDK. Convert to hex **only** where a specification explicitly requires a hex string: the BRC-100 API boundary, logs, CLI output. The naming convention enforces it: wire-order binary is `wtxid` (internal); display-order hex is `dtxid` (boundary). Display hex is *derived* from the canonical binary only at the point of emission (logs, JSON, CLI) — never stored, never read back into the data path.

### (b) The identity-pubkey carve-out — identity-shaped public keys stay hex

A deliberate exception to (a). Identity-shaped public keys — the BRC interchange identifiers — are hex throughout: storage, wire, and internal. They are stable identity tokens that cross BRC JSON boundaries constantly, and their canonical internal form is a `PublicKey` curve-point object of which hex and binary are both serialisations; the wallet rarely manipulates their bytes directly. This class is:

* the wallet's own identity key — `KeyDeriver#identity_key` returns 66-char hex (`gem/bsv-wallet/lib/bsv/wallet/key_deriver.rb:51-53`, `@root_key.public_key.to_hex`), the BRC-100 `getPublicKey` emission value;
* BRC-43 counterparty references — `'self'`, `'anyone'`, or a hex public key;
* the BRC-29 `outputs.sender_identity_key` column — `:text` (`gem/bsv-wallet/db/migrations/001_create_schema.rb:150`);
* BRC-52 certificate fields — `certificates.{subject, certifier, verifier, signature}` and `certificate_fields.{value, master_key}`, all `:text` (`001_create_schema.rb:264, 266, 267, 269, 285, 286`).

Crypto-op consumers that genuinely need the 33 raw bytes call `KeyDeriver#identity_key_bytes` (`key_deriver.rb:60-62`, `@root_key.public_key.compressed`) — never a `[hex].pack('H*')` round-trip.

**Derived / transient public keys stay binary, following (a).** BRC-42 outputs feed straight into the next crypto operation (a `hash160` to a locking script, an ECDH input) and never cross a BRC boundary *as themselves*. `KeyDeriver#derive_public_key` returns 33-byte binary (`key_deriver.rb:80-92`, `.compressed`); `Engine#get_public_key(identity_key: false, …)` returns binary. If these ever need to cross a JSON boundary, conversion to hex happens at that emit point — the same way `dtxid` conversion happens at the txid boundary.

This carve-out was later **lost** and then **rediscovered** in an audit (HLR #300, PR #303) that nearly flipped the identity columns to binary before the reasoning was recovered. That rediscovery is recorded in HLR #300 / PR #303 (and re-stated here); ADR-021 (the BRC-100 interface design) is where carve-out (b)'s hex/binary boundary is *applied* at the interface, not where it was rediscovered. ADR-008(b) is the *original* statement of the exception. It is a settled, spec-driven carve-out — not a question to relitigate as binary.

## Alternatives Considered

### A. Hex / `text` for hash-shaped data (the reference's habit)
**Rejected.** Hex is a display encoding, not data; `bytea` is smaller and faster, conversion hides at the boundary, and no JOINs key on these values anyway. The hex-everywhere habit is an artifact of JavaScript's string model, not a design choice to inherit.

### B. Hex in the data path (a stored hex column, or a hex value passed between internal calls)
**Rejected** — it puts a second, derivable representation inside the canonical layer, the drift (a) exists to prevent. A *derived display* reader is fine: `Store::Models::DisplayTxid#dtxid` computes display-order hex from the binary `wtxid` for emission and is never read internally. (That derivation is currently also open-coded at ~15 log/CLI sites; centralising it into one `BSV::Primitives::Hex` converter is #311.)

### C. Identity-shaped pubkeys as binary too (fold them into (a))
**Rejected** — and rejected again, the hard way, in the HLR #300 audit. Identity pubkeys are protocol identifiers whose canonical form is a curve-point object, they cross BRC boundaries constantly, and the BRC-29/BRC-52/BRC-100 specs mandate hex at the wire — which (a)'s own "hex only where the spec says hex string" rule carves out directly. Flipping them to binary trades a settled, spec-aligned form for needless conversion on the boundary-heavy path.

## Consequences

### Positive
* The internal stack — database, models, wallet, SDK — is uniformly binary for hash-shaped data; no conversion layer threads through it.
* Smaller, faster storage and comparison on the hash-shaped columns.
* Identity pubkeys live in their boundary-native form, so the interface-heavy path carries no per-call hex↔binary conversion for them; crypto consumers reach for `identity_key_bytes` when they need bytes.

### Negative
* A reader scanning the database sees bytes for hash-shaped columns, not hex; conversion happens at the edge (and is where `dtxid` exists).
* The identity-pubkey carve-out (b) is an exception to (a) that has to be remembered — it is documented and named, and it was once lost (HLR #300) precisely because the reasoning was not recorded at decision time.

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

(a) plays to Ruby's binary strength rather than inheriting a JavaScript limitation; it is simpler (no conversion layer) and faster. (b) is a deliberate, spec-driven exception, not drift: identity pubkeys are interchange identifiers whose canonical form is a curve-point object, and the spec mandates hex at every BRC boundary they cross. Splitting the one schema-design moment into two labelled sub-decisions records both faithfully without inventing a second decision date. **Approve.**

## Validation

* (a) Hash-shaped columns are `bytea`; display hex is derived on demand (`DisplayTxid#dtxid`), not stored. Hex appears only at the BRC-100 boundary, logs, and CLI (`dtxid`).
* (b) Identity-shaped pubkeys are hex throughout: `identity_key` returns hex; `sender_identity_key` and the certificate fields are `:text`. Derived pubkeys (`derive_public_key`, `get_public_key(identity_key: false)`) are binary. Crypto consumers use `identity_key_bytes`, not a hex round-trip.

## References

* ADR-001 — schema designed from the domain (binary is the domain's form), not the reference's hex habit.
* ADR-021 — BRC-100 interface design; the conversion boundary where carve-out (b) is *applied* (identity pubkeys hex, derived pubkeys binary).
* CLAUDE.md — "Public Key Convention: identity hex, derived binary" (the four supports for (b)) and the wtxid/dtxid convention (a).
* HLR #300 / PR #303 — the audit that recovered (b) and added `identity_key_bytes`.
* `gem/bsv-wallet/lib/bsv/wallet/key_deriver.rb:51-92` — `identity_key` (hex), `identity_key_bytes` (binary), `derive_public_key` (binary).
* `gem/bsv-wallet/db/migrations/001_create_schema.rb:150, 264-269, 285-286` — `sender_identity_key` and the certificate fields as `:text`.
* `docs/reference/schema.md`.

## Unverified claims

None.
