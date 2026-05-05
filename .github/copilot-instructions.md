# Copilot Code Review Instructions

## Project Context

bsv-wallet is a Ruby BRC-100 wallet implementation — the layer that manages UTXO lifecycle, transaction construction, broadcasting, and proof management for BSV applications. It delegates all cryptographic operations (signing, key derivation, ECDSA, script interpretation) to the `bsv-ruby-sdk` gem. The wallet itself handles **state transitions** and **data integrity**: which outputs are spendable, which inputs are locked, which transactions are proven, and which proofs are valid.

Key architecture (four-layer SOA):
- `BSV::Wallet::Engine` — Layer 3: orchestrates the 28 BRC-100 methods. Pure logic, no SQL, no I/O.
- `BSV::Wallet::Postgres::Store` — Layer 2a: PostgreSQL persistence, action lifecycle (create → sign → promote)
- `BSV::Wallet::Postgres::BroadcastQueue` — Layer 2a: ARC communication lifecycle
- `BSV::Wallet::Postgres::ProofStore` — Layer 2a: merkle proof storage and retrieval
- Sequel models (Action, Output, Input, Spendable, TxProof, etc.) — Layer 2b: atomic DB operations

Two gems:
- `bsv-wallet` — core interfaces and Engine (no database dependency)
- `bsv-wallet-postgres` — PostgreSQL adapter implementing the interfaces

## Critical Convention: Transaction ID Byte Order

This codebase enforces a strict binary/string type discipline for transaction IDs:

| Name | Format | Usage |
|------|--------|-------|
| `wtxid` | 32-byte binary, wire order | All internal code: method params, variables, hash keys, DB columns |
| `dtxid` | 64-char hex string, display order | ARC API calls, JSON responses, logs, CLI output |
| `txid` | Varies | BRC-100 spec names only (`:txid` return key, `known_txids:` param) |

**Conversion:** `dtxid = wtxid.reverse.unpack1('H*')` — the `DisplayTxid` module provides this on models.

**Validation:** `BSV::Primitives::Hex.validate_wtxid!` rejects hex strings passed where binary is expected (and vice versa for `validate_dtxid_hex!`). These fire at all entry points.

**Review rule:** Any code that calls `.reverse`, `.unpack1('H*')`, or `[x].pack('H*')` on a transaction ID is a byte-order boundary. Verify the direction is correct for the context (internal = wire-order binary, external = display-order hex).

## Threat Model

**Funds at risk** is the guiding principle. The wallet manages real UTXOs — bugs cause stuck funds, double-spends, or lost outputs.

### UTXO Lifecycle (Critical — funds at risk)

- **Input locking atomicity**: `Store#create_action` locks inputs via `INSERT ON CONFLICT`. If locking is not atomic with action creation, two concurrent transactions could spend the same UTXO (double-spend). Verify any change to input locking preserves the single-transaction guarantee.
- **Promote timing**: Outputs become spendable only after `promote_action`. Premature promotion (before broadcast acceptance) creates UTXOs that reference transactions miners may reject. Verify promotion only occurs after broadcast confirmation or in `no_send` paths.
- **Reaper safety**: `reap_stale_actions` deletes old actions via CASCADE. Verify it never deletes actions that have been broadcast (the guard checks for absence of a broadcast entry, not absence of wtxid).
- **Spendable integrity**: The `spendable` table IS the UTXO set. Any row present is considered available for spending. Verify that spent outputs are removed from `spendable` atomically with input creation.

### Input Resolution (Critical — funds at risk)

- **Source outpoint correctness**: `resolve_inputs_for_signing` joins inputs → outputs → source_actions to get `source_wtxid` and `source_vout`. If the join is wrong, the transaction is constructed against the wrong source output → invalid sighash → unspendable UTXO.
- **Key derivation parameters**: The resolved `derivation_prefix`, `derivation_suffix`, and `sender_identity_key` are passed to `KeyDeriver` to derive the signing key. Wrong parameters → wrong private key → invalid signature → funds stuck.
- **Wire order consistency**: `source_wtxid` from the database is passed directly to `TransactionInput#prev_wtxid`. Both must be wire-order binary. A byte-reversal here means the transaction references a non-existent UTXO.

### BEEF / SPV Validation (High — counterfeit transaction risk)

- **Structural validation**: `validate_beef!` must run before any outputs are promoted. Skipping validation means accepting counterfeit transactions.
- **trustSelf semantics**: `replace_known_ancestors!` only replaces ancestors (never the subject transaction) and only when `trust_self == 'known'`. Replacing the subject would bypass fee adequacy checks.
- **Fee adequacy**: `validate_fee_adequacy!` ensures inputs > outputs. Without this check, the wallet could accept transactions that miners would reject, creating unspendable outputs.

### Broadcast Lifecycle (High — transaction loss)

- **ARC callback byte order**: ARC sends `txid` as display-order hex. The callback handler must `decode_hex` then `.reverse` to get wire-order binary for DB lookup. Getting this backwards means callbacks are silently ignored — the wallet never learns a transaction was mined.
- **process_pending polling**: Uses `action.dtxid` (display-order) for ARC API calls. Using wire-order hex would query ARC for a non-existent transaction.

### Proof Management (Medium — completeness)

- **save_beef_proofs subject linking**: The subject transaction's proof must be linked to the action via `link_proof`. Missing this link means the action never reaches `:completed` status.
- **Merkle path normalization**: ARC may return merkle paths as binary, hex, or TSC format. `normalize_merkle_path` must handle all three without corruption.

## Review Focus Areas

### Transaction ID Boundaries

Any code touching `wtxid`, `dtxid`, or performing hex/binary conversion:
- Verify `.reverse` direction matches the context (display = reversed wire)
- Check that database lookups use `Sequel.blob(wtxid)` (not raw string)
- Ensure `validate_wtxid!` guards entry points that accept binary txids
- Verify ARC-facing code uses `dtxid` (display-order hex)

### Database Atomicity

The action lifecycle requires multi-table atomicity:
- `create_action`: action + inputs in one transaction
- `promote_action`: outputs + spendable + baskets + details + tags in one transaction
- `sign_action`: action update + tx_proofs upsert in one transaction

Verify `@db.transaction do ... end` wraps all multi-table operations. Breaking atomicity means partial state that subsequent operations cannot recover from.

### Interface Boundary Contracts

Engine↔Store communication uses plain hashes — no Sequel models cross the boundary. Verify:
- Store methods return `Hash` / `Array<Hash>`, never `Sequel::Model`
- Engine never calls `.reload`, `.dataset`, `.update` (those are model methods)
- Binary columns (`wtxid`, `raw_tx`, `locking_script`) stay `Encoding::BINARY` through the boundary

## What NOT to Flag

- **`txid:` key in BRC-100 return hashes**: `{ txid: wtxid, tx: beef }` — the key name is spec-mandated, the value is wire-order binary. This is correct.
- **`PathElement.new(txid: true)`**: SDK's boolean flag indicating a merkle path element is a transaction (not a hash). Not a naming violation.
- **`known_txids` parameter name**: BRC-100 spec name. Values inside ARE validated as wire-order binary.
- **ARC payload `txid:` field**: ARC's JSON schema uses this field name for display-order hex. It's their API contract.
- **`action.dtxid` for ARC calls**: Display-order hex is what ARC expects. This is the correct conversion.
- **No ActiveRecord**: This project uses Sequel deliberately. Don't suggest AR patterns.
- **American English**: The project uses American English (`internalize`, `randomize`) to match BRC-100 spec method names.
- **Derived status (no status column)**: `Action#derived_status` computes state from structure. There is no stored `status` field — this is by design.
- **`Gemfile.lock` not committed**: Standard practice for gems.

## Style

- Be specific: cite file paths and line numbers.
- Lead with **funds impact** or **data integrity impact**, not style concerns.
- Provide fix recommendations with code, not just problem statements.
- Skip cosmetic issues unless they have a correctness implication.
- Focus on the diff, not the entire codebase. Pre-existing patterns are not new findings.
