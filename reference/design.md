# BSV Wallet — Ruby Implementation Design

**Status:** In progress
**Source spec:** [BRC-100](BRC100.md)
**Gem:** `bsv-wallet` (under `gem/bsv-wallet/`)

---

## Philosophy

This is a Ruby wallet, not a Ruby port of a TypeScript wallet. The BRC-100 specification defines the external contract; this document captures how we implement it idiomatically in Ruby.

### Why Ruby Doesn't Need BRC-100's Types

BRC-100 defines ~25 type aliases (`BooleanDefaultTrue`, `SatoshiValue`, `TXIDHexString`, etc.) that are all just `boolean`, `number`, or `string` underneath. TypeScript can't enforce any of their constraints at compile time — every one says *"validate at runtime."*

Ruby doesn't bolt types onto these values because it has separate, purpose-built mechanisms for the three jobs types do simultaneously:

| Job | TypeScript | Ruby |
|-----|-----------|------|
| Documentation | Type annotations | Keyword args + YARD |
| Contract enforcement | `interface Wallet` | Module + shared RSpec examples |
| Defaults | `BooleanDefaultTrue` type alias | `param: true` in method signature |
| Enumerations | `'mainnet' \| 'testnet'` | `:mainnet` / `:testnet` (symbols) |
| Validation | "Validate at runtime" | Validate at runtime (same) |

The entire `BooleanDefaultTrue` / `BooleanDefaultFalse` / `PositiveIntegerDefault10Max10000` family of types were workarounds for a limitation Ruby doesn't have — Ruby encodes defaults directly in method signatures.

### Binary Data — Binary Internally, Hex Only at Boundaries

All binary data stays binary throughout the wallet internals. Ruby has a native binary string type (`String` with `Encoding::BINARY`) — there is no reason to hex-encode values for internal use.

This applies to everything: TXIDs (32 bytes, not 64 hex chars), public keys (33 bytes), scripts, signatures, BEEF data, ciphertext, HMACs. The database stores these as `bytea` columns and queries expect binary parameters: `WHERE txid = ?` with a 32-byte value.

Hex conversion happens **only** where a specification explicitly requires it — at the external API boundary. Even then, double-check: just because the TypeScript interface uses `HexString` doesn't mean hex is mandated. The BRC-100 ABI section uses raw byte arrays for TXIDs (32 bytes), public keys (33 bytes), and scripts. The `HexString` type alias exists in the TypeScript interface because JavaScript has no native binary type — that's a JS limitation, not a protocol requirement.

**Rule:** if a consumer can handle binary, give them binary. If they want hex, that's their conversion to make.

This is a significant departure from the TypeScript implementation, which hex-encodes everything. It eliminates double-memory overhead, removes encode/decode cycles on every operation, and keeps database queries clean.

### Async Separation

All interface methods are synchronous and return hashes. Async behaviour (background broadcast, queued processing) is an infrastructure concern handled by a thin service layer wrapping the wallet — Sidekiq workers, Falcon fibres, or similar. The wallet itself doesn't solve async in its method implementations.

### Naming Conventions

- British English throughout: `internalise_action`, `randomise_outputs`
- Ruby conventions: `authenticated?` (predicate), `public_key` (drop `get` prefix), `height`/`network`/`version` (drop `get`)
- String literal unions become symbols: `:mainnet`, `:any`, `:direct`, `:wallet_payment`
- The `options` nesting from TypeScript is flattened into keyword args — `args.options.noSend` becomes `no_send: false`

---

## Architecture

### Component Model

The wallet is composed of pluggable machinery behind the BRC-100 facade:

```
Application
    │
    ▼
┌─────────────────────┐
│  Interface::BRC100  │  ← 28 public methods (the contract)
└─────────┬───────────┘
          │ delegates to
          ▼
┌─────────────────────┐
│   Wallet (concrete) │  ← orchestrates the machinery
├──────────┬──────────┤
│  Store   │ UTXOPool │
│  Proof   │ Broadcast│
│  Store   │ Queue    │
└──────────┴──────────┘
          │
          ▼
     PostgreSQL
```

A concrete wallet receives components at construction time:

```ruby
wallet = BSV::Wallet::Engine.new(
  store:           PostgresStore.new(db),
  utxo_pool:       SimplePool.new(store),
  broadcast_queue: SyncBroadcast.new(node_client),
  proof_store:     PostgresProofStore.new(db)
)
```

Default implementations get a working wallet. Swap any component to customise behaviour.

### Interface Modules

Each component is defined as an abstract module under `BSV::Wallet::Interface`:

| Interface | Purpose | Key methods |
|-----------|---------|-------------|
| `BRC100` | External API — the 28 BRC-100 methods | `create_action`, `sign_action`, `list_actions`, etc. |
| `Store` | Persistence — mirrors the schema's phase model | `create_action` (lock), `sign_action`, `promote_action`, `query_*` |
| `UTXOPool` | UTXO selection strategy | `select`, `release`, `balance` |
| `BroadcastQueue` | Broadcast lifecycle — wallet owns this, SDK owns protocol | `submit`, `process_pending`, `status` |
| `ProofStore` | Merkle proofs + proof-harvesting work queue | `save_proof`, `find_proof`, `request_proof`, `process_pending` |

See [interface-derivation.md](interface-derivation.md) for how each component traces back to BRC-100.

### Error Handling

All errors inherit from `BSV::Wallet::Error < StandardError` and carry a numeric `code` per the BRC-100 error structure:

| Error | Code | Raised when |
|-------|------|-------------|
| `Error` (base) | 1 | Generic wallet error |
| `UnsupportedActionError` | 2 | Method not supported by this implementation |
| `InvalidHmacError` | 3 | HMAC verification fails |
| `InvalidSignatureError` | 4 | Signature verification fails |
| `InvalidParameterError` | 6 | Parameter missing, malformed, or out of range |
| `InsufficientFundsError` | — | Not enough satoshis to fund a transaction |
| `PoolDepletedError` | — | UTXOPool has no available outputs |

---

## Functional Areas

### 1. Transaction Operations (BRC-100 codes 1–7)

**Methods:** `create_action`, `sign_action`, `abort_action`, `list_actions`, `internalise_action`, `list_outputs`, `relinquish_output`

This is the core of the wallet — creating, signing, broadcasting, and querying Bitcoin transactions.

#### create_action Flow

The most complex method. Follows the schema's four-phase lifecycle. No database transaction is held open across a network call.

**Phase 1 — Lock** (atomic, milliseconds):

1. **Validate** — description present, at least one input or output, descriptions on all inputs/outputs
2. **UTXO selection** — `UTXOPool#select(satoshis:)` returns candidates
3. **Atomic persist** — `Store#create_action` inserts the action row and input rows in one transaction. Input locking uses `INSERT ON CONFLICT (output_id) DO NOTHING` — if a concurrent caller already claimed an output, the conflict is detected and the wallet retries with different candidates
4. **Verify coverage** — if not enough inputs were locked, rollback and retry or raise `InsufficientFundsError`

**Phase 2 — Sign** (in memory + atomic commit):

5. **Build transaction** — construct the transaction using the SDK, apply `lock_time`, `version`
6. **Output randomisation** — shuffle output order unless `randomise_outputs: false`
7. **Sign** (if `sign_and_process: true` and all unlocking scripts provided)
8. **Persist** — `Store#sign_action(action_id:, txid:, raw_tx:)` attaches the txid and signed transaction

If `sign_and_process: false` or any input has `unlocking_script_length` instead of a script, return `{ signable_transaction: { tx:, reference: } }` and stop here. The caller invokes `sign_action` later.

**Phase 3 — Broadcast**:

9. **Submit** — `BroadcastQueue#submit(action_id:, raw_tx:, immediate: !accept_delayed_broadcast)`
10. If inline: the broadcast happens synchronously and returns the network result
11. If delayed: the broadcast is queued for a background worker

**Phase 4 — Promote** (atomic, triggered by broadcast acceptance):

12. When the network accepts the transaction, `Store#promote_action` writes outputs to the immutable log, inserts spendable entries, basket memberships, tags, and output details — all in one atomic transaction
13. If the broadcast response includes a merkle proof (ARC returns MINED), `ProofStore#save_proof` stores it and `Store#link_proof` marks the action as completed
14. New change outputs are immediately available in the UTXO set

**Return:** `{ txid:, tx: }` if signed and broadcast, `{ signable_transaction: { tx:, reference: } }` if deferred

The `noSend` / `noSendChange` / `sendWith` mechanism enables chained transaction batching:
- `no_send: true` — construct and persist with `broadcast: :none`. Return `no_send_change` outpoints (change outputs from the unsent transaction).
- Subsequent `create_action` calls can consume those outpoints via `no_send_change`.
- `send_with: [txid1, txid2]` — submit a batch of previously unsent transactions together via `BroadcastQueue#submit`.

#### sign_action Flow

Completes a transaction previously returned as `signable_transaction` from `create_action`:

1. **Look up** the pending action by `reference` — `Store#find_action(reference:)`
2. **Apply** unlocking scripts from `spends` to the corresponding inputs
3. **Sign and persist** — `Store#sign_action(action_id:, txid:, raw_tx:)`
4. **Broadcast** — same Phase 3 logic as `create_action`

#### abort_action Flow

Cancels a pending transaction. Only valid before signing (txid IS NULL):

1. **Look up** by `reference`
2. **Delete** — `Store#abort_action(action_id:)` CASCADE deletes inputs, atomically releasing all locked UTXOs
3. **Release from pool** — `UTXOPool#release(outputs:)` for tier 3 (tier 1/2: no-op, the CASCADE handles it)

No status column to update — the action row is gone. Clean.

#### list_actions / list_outputs

Query methods. Delegate directly to `Store#query_actions` / `Store#query_outputs` with the filter parameters. The `include_*` booleans control which associated data is loaded — implementations should avoid loading what isn't requested. Action status is derived from structural state by the Store, not stored.

#### internalise_action

Accepts an incoming transaction (in Atomic BEEF format). Born completed — no lifecycle phases:

1. **Validate** the BEEF data using SPV rules (BRC-67)
2. **Save proof** — `ProofStore#save_proof` (the proof is in the BEEF)
3. **Atomic persist** — `Store#create_action` with `broadcast: :none`, `outgoing: false`, then immediately `Store#promote_action` with the outputs. All in one transaction.
4. **Process outputs** by protocol:
   - `:wallet_payment` — derive the private key using BRC-29 (derivation prefix/suffix + sender identity key), verify the locking script matches, credit to wallet balance
   - `:basket_insertion` — place the output in the specified basket with optional tags and custom instructions
5. **Link proof** — `Store#link_proof` marks the action as completed

#### relinquish_output

`Store#relinquish_output(output_id:)` — deletes the spendable row and basket membership. The output row stays in the immutable log forever.

---

### 2. Public Key Management (BRC-100 codes 8–10)

**Methods:** `public_key`, `reveal_counterparty_key_linkage`, `reveal_specific_key_linkage`

#### public_key

Two modes:
- `identity_key: true` — return the wallet's master public key. No derivation.
- Otherwise — derive a child public key using BRC-42 (BKDS) with the given `protocol_id` (security level + protocol string), `key_id`, and `counterparty`.

The `privileged: true` flag uses the secondary privileged keyring instead of the everyday keyring.

#### Key Linkage Revelations

BRC-69 defines two revelation types:

- **Counterparty linkage** (`reveal_counterparty_key_linkage`) — reveals the root ECDH shared secret between the user and a counterparty, to a specified verifier. Enables linking all interactions with that counterparty.
- **Specific linkage** (`reveal_specific_key_linkage`) — reveals the key offset for a single derived child key (specific protocol + key ID). Enables auditing one interaction without exposing others.

Both encrypt the linkage data for the verifier using BRC-72 (AES-256-GCM with a key derived via BRC-2).

---

### 3. Cryptography Operations (BRC-100 codes 11–16)

**Methods:** `encrypt`, `decrypt`, `create_hmac`, `verify_hmac`, `create_signature`, `verify_signature`

All six methods follow the same pattern:

1. **Derive a child key** using BRC-42 with the given `protocol_id`, `key_id`, and `counterparty`
2. **Perform the operation** using the derived key:
   - Encrypt/decrypt: AES-256-GCM (BRC-2) with the ECDH shared secret as the symmetric key
   - HMAC: derive the symmetric key as in BRC-2, use it for HMAC-SHA256 (BRC-56)
   - Signature: ECDSA over secp256k1 with the derived private key (BRC-3)
3. **Return** the result (ciphertext, plaintext, hmac, or signature as binary strings)

The `counterparty` parameter controls the key derivation:
- A public key hex string — two-party operation (ECDH between user and counterparty)
- `'self'` — self-derivation (sender and recipient are the same)
- `'anyone'` — uses private key `1` for public/anyone-verifiable operations

Verify methods (`verify_hmac`, `verify_signature`) raise `InvalidHmacError` / `InvalidSignatureError` on failure rather than returning a boolean.

These methods delegate entirely to `bsv-sdk` for the cryptographic primitives.

---

### 4. Identity and Certificate Management (BRC-100 codes 17–22)

**Methods:** `acquire_certificate`, `list_certificates`, `prove_certificate`, `relinquish_certificate`, `discover_by_identity_key`, `discover_by_attributes`

#### Certificate Structure (BRC-52)

A certificate contains:
- `type` — base64-encoded type identifier
- `subject` — the certificate holder's public key
- `certifier` — the issuing entity's public key
- `serial_number` — unique identifier
- `revocation_outpoint` — a UTXO that, if spent, invalidates the certificate
- `signature` — certifier's signature over the certificate
- `fields` — hash of field names to encrypted values

Field values are encrypted with keys derived via BRC-42, enabling selective revelation — the certificate holder can reveal individual fields to specific verifiers without exposing the entire certificate.

#### acquire_certificate

Two acquisition protocols:
- `:issuance` — the wallet contacts a certifier URL, requests a certificate, and the certifier issues it through a standardised exchange
- `:direct` — the certificate is provided in full (serial number, signature, keyring) and stored directly

#### prove_certificate

Selective revelation: given a certificate and a list of fields to reveal, derive revelation keys for the specified verifier using BRC-52's keyring mechanism. The verifier receives only the keys needed to decrypt the requested fields.

#### discover_by_identity_key / discover_by_attributes

Discovery methods for finding certificates issued to other users. These may involve external lookups (overlay networks, certificate registries) beyond local storage.

---

### 5. Authentication (BRC-100 codes 23–24)

**Methods:** `authenticated?`, `wait_for_authentication`

Simple lifecycle methods. `authenticated?` returns `{ authenticated: true/false }`. `wait_for_authentication` blocks until the wallet is set up and returns `{ authenticated: true }`.

Implementation-dependent — may check for the presence of a master key, a valid session, or a hardware device.

---

### 6. Blockchain and Network Data (BRC-100 codes 25–28)

**Methods:** `height`, `header_for_height`, `network`, `version`

Read-only queries:
- `height` — current blockchain height, typically from a network service or cached header chain
- `header_for_height` — 80-byte block header. The schema stores block hashes and merkle roots in tx_proofs but not full headers. This method may require a network lookup or a separate header cache
- `network` — `:mainnet` or `:testnet`, a configuration value
- `version` — wallet version string in `vendor-major.minor.patch` format

---

## Data Layer

### Schema

See [schema-WIP.md](../reference/) for the full schema. Key design principles:

1. **Outputs are the primary entity** — the immutable log. Never updated, never deleted.
2. **State is derived, not stored** — no status column on actions. Status comes from structural state: `txid IS NULL` = unsigned, `tx_proof_id IS NOT NULL` = completed, etc.
3. **Inputs are the lock mechanism** — claiming a UTXO = INSERT into inputs. UNIQUE(output_id) enforces single-spend atomically. CASCADE delete from actions releases locks.
4. **The spendable table IS the wallet** — a minimal set of output_ids (~28 bytes/row). Fits in buffer cache permanently. The hot-path UTXO query scans this, then PK-joins to outputs for data.
5. **Binary data is bytea** — txids, scripts, proofs, raw transactions. The entire stack works with binary.

### Tables (FK-dependency order)

| Table | Character | INSERT | UPDATE | DELETE |
|-------|-----------|--------|--------|--------|
| tx_proofs | Append-mostly | proof arrival | upsert on re-proof | never |
| actions | Mutable lifecycle | createAction | txid (sign), tx_proof_id (proof) | abort, reaper |
| broadcasts | Broadcast lifecycle | Phase 3 | ARC response updates | CASCADE |
| baskets | Reference data | on demand | never | soft delete |
| outputs | **Immutable log** | Phase 4 / internalise | **never** | **never** |
| spendable | The wallet | Phase 4 / internalise | never | spend / relinquish |
| output_baskets | Mutable membership | Phase 4 / internalise | basket move | relinquish |
| output_details | Immutable metadata | Phase 4 / internalise | never | never |
| inputs | Lock mechanism | Phase 1 | never | CASCADE from action |
| labels / action_labels | Action categorisation | on demand | never | soft delete |
| tags / output_tags | Output categorisation | on demand | never | soft delete |
| certificates / certificate_fields | Identity (BRC-52) | acquire | never | soft delete |
| tx_reqs | Proof work queue | on demand | status updates | never |
| settings | Key-value config | on demand | upsert | never |

### Database

PostgreSQL, accessed via Sequel. The Sequel layer provides a low-level interface with enough flexibility and precision to implement the Store/ProofStore interface methods expressively. No ActiveRecord.

### Store Implementation

The Store mirrors the schema's phase model:

- `create_action` → Phase 1 (INSERT action + inputs atomically)
- `sign_action` → Phase 2 (UPDATE action SET txid, raw_tx)
- `promote_action` → Phase 4 (INSERT outputs, spendable, baskets, details, tags)
- `link_proof` → attach a tx_proof to an action
- `abort_action` → DELETE action (CASCADE frees inputs)

The Store is a data access layer, not a business logic layer. It persists and queries — it doesn't validate BRC-100 rules or orchestrate multi-step flows. That's the wallet engine's job.

### Broadcast Ownership

The wallet owns broadcast — the SDK provides the ARC protocol (message formatting, status parsing), but the wallet's BroadcastQueue decides when and how to broadcast. The broadcasts table tracks the lifecycle. When ARC reports MINED with a merklePath, the proof arrives for free — the broadcast handler creates a tx_proof and links it to the action.

### ProofStore Separation

Currently backed by PostgreSQL alongside the main Store (tx_proofs table). Whether proofs warrant a separate backing store is an open question:

- **For separation:** different access patterns (write-once, read-many, prunable), potential for a shared proof service across wallets, different caching strategy
- **Against:** adds interface surface for something that currently lives in the same database

The schema also has a tx_reqs table — a work queue for proof harvesting. The ProofStore interface includes `request_proof` and `process_pending` to cover this lifecycle.

---

## UTXOPool Design

The interface (`select`/`release`/`balance`) is deliberately thin. It recommends which outputs to spend — the actual locking happens in `Store#create_action` via the input row INSERT. This accommodates three tiers:

### Tier 1 — Simple Coin Selection (default)

`select(satoshis:)` delegates to `Store#find_spendable` — queries the spendable table, PK-joins to outputs, returns candidates ordered by satoshis. No reservation at this tier — the database lock (Phase 1 INSERT ON CONFLICT) handles contention. Adequate for single-user, low-frequency use.

### Tier 2 — Pre-Split Pool

Same as tier 1 but scoped to a dedicated basket. The schema's baskets table with `target_count` and `target_value` columns supports replenishment policies. Less contention because each consumer has its own basket.

### Tier 3 — In-Memory TxCache

Pre-warmed, in-memory queue of already-locked UTXOs. `select(satoshis:)` dequeues from memory — the dequeue IS the reservation. No database query, no lock contention, sub-millisecond latency. `release(outputs:)` re-enqueues on abort. Required for millions-of-transactions-per-second throughput.

The schema's spendable table (~28 bytes/row, fits in buffer cache) gives tier 1 a strong starting position. The baskets table with replenishment policy gives tier 2 a clear upgrade path. The interface doesn't mention storage or queries — that's what keeps tier 3 viable.

---

## Dependencies

| Gem | Purpose |
|-----|---------|
| `bsv-sdk` | Low-level BSV primitives — keys, scripts, transactions, crypto, ARC protocol |
| `sequel` | PostgreSQL access (added when Store implementation begins) |
| `pg` | PostgreSQL driver (added with Sequel) |

---

## Open Questions

1. **ProofStore separation** — keep as a separate interface or merge into Store? Both backed by the same PostgreSQL instance currently, but the interface separation preserves optionality.
2. **Block headers** — `header_for_height` needs 80-byte headers. The schema stores block_hash and merkle_root in tx_proofs but not full headers. Needs a header source (network lookup, separate cache, or header table).
3. **Certificate discovery** — `discover_by_identity_key` and `discover_by_attributes` may need external network lookups beyond local storage. How is this wired?
4. **Permission system** — `seek_permission` and `originator` appear on many methods. How does the wallet decide whether to allow an operation? Is this a separate component?
