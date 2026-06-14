# ADR-008: Binary internally, hex only at boundaries

## Status

Accepted.

## Context

Hash-shaped data — transaction IDs, block hashes, merkle paths, raw transactions, locking scripts — is fixed-width binary. The reference implementation hex-encodes it everywhere, because in JavaScript strings are UTF-16 and `Buffer` is a second-class citizen; hex strings are the path of least resistance there. Ruby has first-class binary strings, and the SDK produces binary. Hex is a display format, not a data format.

## Decision Drivers

* Ruby works naturally with binary strings end to end; nothing forces hex internally.
* Binary is smaller and faster to store and compare (a txid is 32 bytes vs 64 hex chars), and no relationship JOINs on a txid — foreign keys are surrogate `bigint`s.
* A spec sometimes *mandates* a hex string at its boundary; that is the only place hex is data.

## Decision

Store and pass hash-shaped data as binary (`bytea`) throughout — database, models, wallet, SDK. Convert to hex **only** where a specification explicitly requires a hex string: the BRC-100 API boundary, logs, CLI output. The naming convention enforces it: wire-order binary is `wtxid` (internal); display-order hex is `dtxid` (boundary). Display hex is *derived* from the canonical binary only at the point of emission (logs, JSON, CLI) — never stored, never read back into the data path.

**Carve-out — identity-shaped public keys stay hex.** The wallet's own identity key, BRC-43 counterparty references, BRC-29 `sender_identity_key`, BRC-52 certificate fields are stable interchange identifiers that cross BRC boundaries as JSON; they are hex throughout. Derived/transient public keys (BRC-42 outputs feeding straight into a crypto op) stay binary. The full rationale lives in CLAUDE.md and HLR #300.

## Alternatives Considered

### A. Hex / `text` for hash-shaped data (the reference's habit)
**Rejected.** Hex is a display encoding, not data; `bytea` is smaller and faster, conversion hides at the boundary, and no JOINs key on these values anyway. The hex-everywhere habit is an artifact of JavaScript's string model, not a design choice to inherit.

### B. Hex in the data path (a stored hex column, or a hex value passed between internal calls)
**Rejected** — it puts a second, derivable representation inside the canonical layer, the drift this ADR exists to prevent. A *derived display* reader is fine: `Store::Models::DisplayTxid#dtxid` computes display-order hex from the binary `wtxid` for emission and is never read internally. (That derivation is currently also open-coded at ~15 log/CLI sites; centralising it into one `BSV::Primitives::Hex` converter is #311.)

## Consequences

### Positive
* The internal stack — database, models, wallet, SDK — is uniformly binary; no conversion layer threads through it.
* Smaller, faster storage and comparison on the hash-shaped columns.

### Negative
* A reader scanning the database sees bytes, not hex; conversion happens at the edge (and is where `dtxid` exists).
* The identity-pubkey carve-out is an exception to "binary internally" that has to be remembered (it is documented and named).

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

This plays to Ruby's binary strength rather than inheriting a JavaScript limitation; it is simpler (no conversion layer) and faster. The pubkey carve-out is a deliberate, spec-driven exception, not drift. **Approve.**

## Validation

* Hash-shaped columns are `bytea`; display hex is derived on demand (`DisplayTxid#dtxid`), not stored.
* Hex appears only at the BRC-100 boundary, logs, and CLI (`dtxid`).
* Identity-shaped pubkeys are the documented hex exception; derived pubkeys are binary.

## References

* ADR-001 — schema designed from the domain (binary is the domain's form), not the reference's hex habit.
* CLAUDE.md (wtxid/dtxid and pubkey conventions); HLR #300 (the pubkey hex exception).
* `reference/schema.md`.
