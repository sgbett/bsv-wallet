# BSV Wallet — Ruby Implementation Design

**Status:** In progress
**Source spec:** [BRC-100](https://github.com/bitcoin-sv/BRCs/blob/master/wallet/0100.md)
**Gem:** `bsv-wallet` — supports SQLite and PostgreSQL via Sequel

---

## 1. Philosophy

This is a Ruby wallet, not a Ruby port of a TypeScript wallet. The BRC-100 specification defines the external contract; this document captures how we implement it idiomatically in Ruby.

### How Ruby Expresses BRC-100's Types

BRC-100 defines ~25 type aliases (`BooleanDefaultTrue`, `SatoshiValue`, `TXIDHexString`, etc.). Ruby has native mechanisms for the jobs these types serve:

| Job | Ruby mechanism |
|-----|---------------|
| Documentation | Keyword args + YARD |
| Contract enforcement | Module + shared RSpec examples |
| Defaults | `param: true` in method signature |
| Enumerations | `:mainnet` / `:testnet` (symbols) |
| Validation | Runtime validation |

For example, `BooleanDefaultTrue` becomes `param: true` in the method signature — the default is expressed directly where the parameter is declared.

### Binary Data — Binary Internally, Hex Only at Boundaries

All binary data stays binary throughout the wallet internals. Ruby has a native binary string type (`String` with `Encoding::BINARY`) — there is no reason to hex-encode values for internal use.

This applies to everything: TXIDs (32 bytes, not 64 hex chars), public keys (33 bytes), scripts, signatures, BEEF data, ciphertext, HMACs. The database stores these as `bytea` columns and queries expect binary parameters: `WHERE txid = ?` with a 32-byte value.

Hex conversion happens **only** where a specification explicitly requires it — at the external API boundary. The BRC-100 ABI section uses raw byte arrays for TXIDs (32 bytes), public keys (33 bytes), and scripts. Where the spec says hex, use hex. Where it doesn't, stay binary.

**Rule:** if a consumer can handle binary, give them binary. If they want hex, that's their conversion to make.

This eliminates double-memory overhead, removes encode/decode cycles on every operation, and keeps database queries clean.

### Async Separation

All interface methods are synchronous and return hashes. Async behavior (background broadcast, queued processing) is an infrastructure concern handled by a thin service layer wrapping the wallet — Sidekiq workers, Falcon fibres, or similar. The wallet itself doesn't solve async in its method implementations.

### Naming Conventions

- American English throughout (matching BRC-100 spec): `internalize_action`, `randomize_outputs`
- Ruby conventions: `authenticated?` (predicate), `public_key` (drop `get` prefix), `height`/`network`/`version` (drop `get`)
- String literal unions become symbols: `:mainnet`, `:any`, `:direct`, `:wallet_payment`
- Nested option hashes are flattened into keyword args — `accept_delayed_broadcast: false` rather than `options: { acceptDelayedBroadcast: false }`

---

## 2. Architecture

### Four-Layer SOA

```
┌─────────────────────────────────────────────────────────┐
│  Layer 4: Consumer / Presentation                       │
│  (out of scope — hex conversion, API formatting)        │
├─────────────────────────────────────────────────────────┤
│  Layer 3: Business Process (BRC-100)                    │
│  28 spec-mandated methods, orchestration, views         │
├─────────────────────────────────────────────────────────┤
│  Layer 2: Services                                      │
│  ┌────────────────────┬────────────────────────────┐    │
│  │  2a: Component     │  2b: Atomic                │    │
│  │  Store             │  Action model              │    │
│  │  BroadcastQueue    │  Output model              │    │
│  │  ProofStore        │  Spendable model           │    │
│  │  UTXOPool          │  Input model               │    │
│  │                    │  Broadcast model            │    │
│  │                    │  TxProof model              │    │
│  │                    │  Basket, Label, Tag...      │    │
│  └────────────────────┴────────────────────────────┘    │
├─────────────────────────────────────────────────────────┤
│  Layer 1: Operational Systems                           │
│  PostgreSQL, workers, callback endpoint, SSE daemon     │
└─────────────────────────────────────────────────────────┘
```

**Layer 1 (Operational)** — things you deploy. The 17-table PostgreSQL schema, background workers (BroadcastQueueWorker, ProofHarvester, Reaper), the ARC callback Rack endpoint.

**Layer 2b (Atomic Services)** — Sequel::Model classes. Declarative — they describe what things ARE. Each model knows its table, associations, derived attributes. A model method that coordinates across multiple tables belongs in 2a, not here.

**Layer 2a (Component Services)** — our interface modules. Imperative — they orchestrate workflows. Each component owns a concern (Store → action lifecycle, BroadcastQueue → network I/O, ProofStore → proof management, UTXOPool → selection strategy). Components don't cross-call each other — they're composed by Layer 3.

**Layer 3 (Business Process)** — the 28 BRC-100 methods. Pure orchestration. No SQL, no ARC calls, no thread management, no hex conversion. If you replaced PostgreSQL with SQLite or ARC with another broadcast service, only Layers 1 and 2 change.

**Layer 4 (Consumer)** — out of scope for the gem. This is where binary becomes hex, where responses become JSON, where user authentication is enforced.

Binary data flows through layers 1–3 without conversion. Hex encoding is a Layer 4 concern.

A concrete wallet receives Layer 2a components at construction time:

```ruby
wallet = BSV::Wallet::Engine.new(
  store:           PostgresStore.new(db),
  utxo_pool:       SimplePool.new(store),
  broadcast_queue: ArcBroadcast.new(arc_client),
  proof_store:     PostgresProofStore.new(db)
)
```

### Gem Structure

The wallet ships as a single gem (`bsv-wallet`) supporting both SQLite and PostgreSQL backends. The backend is selected at connection time based on the `DATABASE_URL` scheme — SQLite by default, PostgreSQL when the URL starts with `postgres://`.

```
gem/
  bsv-wallet/              ← the wallet gem
```

**`bsv-wallet`** contains:
- All interface modules (`BRC100`, `Store`, `UTXOPool`, `BroadcastQueue`, `ProofStore`)
- The Layer 3 engine (orchestration, BRC-100 parameter validation)
- All Sequel models (Layer 2b — Action, Output, Input, Spendable, Broadcast, TxProof, Basket, Label, Tag, etc.)
- Concrete `Store`, `ProofStore`, `BroadcastQueue` implementations (Layer 2a)
- Migrations (the 17-table schema, portable across both backends)
- Error classes
- UTXOPool tier 1 default (delegates to `Store#find_spendable`)
- Dependencies: `sequel`, `sqlite3` (hard); `pg` (optional, loaded lazily by Sequel when connecting to PostgreSQL)

### Interface Modules

Each component service (Layer 2a) is defined as an abstract module under `BSV::Wallet::Interface`:

| Interface | Purpose | Key methods |
|-----------|---------|-------------|
| `BRC100` | External API — the 28 BRC-100 methods | `create_action`, `sign_action`, `list_actions`, etc. |
| `Store` | Persistence — mirrors the schema's phase model | `create_action` (lock), `sign_action`, `promote_action`, `query_*` |
| `UTXOPool` | UTXO selection strategy | `select`, `release`, `balance` |
| `BroadcastQueue` | Broadcast lifecycle — wallet owns this, SDK owns protocol | `submit`, `process_pending`, `handle_event`, `status` |
| `ProofStore` | Merkle proofs + proof-harvesting work queue | `save_proof`, `find_proof`, `request_proof`, `process_pending` |

### Interface Derivation from BRC-100

The BRC-100 spec defines the external contract (28 methods). It says nothing about wallet internals. The four machinery interfaces are architectural decompositions inferred from what the external contract requires.

**BroadcastQueue — direct derivation.** The `acceptDelayedBroadcast` parameter describes two execution models (synchronous vs queued). The wallet needs a place to hold the queue and a worker to drive it — the spec is describing a queue without using the word. BRC-100's `noSend`/`sendWith`/`sendWithResults` chained-send primitives are not part of this base wallet (deferred to #192); when implemented they will compose with the existing BroadcastQueue rather than redefine it.

**UTXOPool — strong derivation.** Every `createAction` needs to choose inputs from the wallet's spendable set, and `abortAction` needs to release them again. The pool pattern is the architectural choice for expressing the selection-and-release semantics — independent of any chained-send primitives.

**Store — obvious but unspecified.** Every `list*` method requires persistent state. `internalizeAction` explicitly stores incoming transactions. Labels, tags, baskets, certificates — all must survive between calls. Any wallet needs a store; the spec informed the shape, not the decision.

**ProofStore — inferential.** BRC-67/62 require SPV validation. `trustSelf` implies a proof cache (*"TXIDs known to this wallet"*). `getHeaderForHeight` serves block headers. Separating proofs from the main Store is an architectural bet on different access patterns (write-once, read-many, prunable), not a spec requirement.

| Component | BRC-100 source | Derivation |
|-----------|---------------|------------|
| BroadcastQueue | `acceptDelayedBroadcast`, broadcast lifecycle on `createAction` / `signAction` | Direct |
| UTXOPool | `createAction` input selection, `abortAction`, spendable outputs | Strong |
| Store | Every `list*`/`query` method, `internalizeAction`, baskets/labels/tags | Obvious |
| ProofStore | BRC-67/62 sections, `trustSelf`, `getHeaderForHeight` | Inferential |

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

## 3. Functional Areas

### 3.1 Transaction Operations (BRC-100 codes 1–7)

**Methods:** `create_action`, `sign_action`, `abort_action`, `list_actions`, `internalize_action`, `list_outputs`, `relinquish_output`

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
6. **Output randomization** — shuffle output order unless `randomize_outputs: false`
7. **Sign** (if `sign_and_process: true` and all unlocking scripts provided)
8. **Persist** — `Store#sign_action(action_id:, txid:, raw_tx:)` attaches the txid and signed transaction

If `sign_and_process: false` or any input has `unlocking_script_length` instead of a script, return `{ signable_transaction: { tx:, reference: } }` and stop here. The caller invokes `sign_action` later.

**Phase 3 — Broadcast** (send path only):

9. **Submit** — inline: `Engine::Broadcast#submit` POSTs to ARC synchronously and returns the network result. Delayed: the broadcasts row created in Phase 2 sits with `broadcast_at IS NULL`; the daemon's push-discovery loop finds it and calls `Engine::Broadcast#submit`.
10. **Poll** — for in-flight broadcasts (`broadcast_at IS NOT NULL`, non-terminal status) the daemon's poll-discovery loop calls `Engine::Broadcast#poll_status` to converge on the terminal state via `GET /tx/{txid}`.

Internal-path actions (`broadcast: :none`) skip Phase 3 entirely.

**Phase 4 — Promote** (atomic, milliseconds):

On the **send path**, Phase 4 fires from `Engine::Broadcast#submit` or `#poll_status` when ARC returns an accepted status (`SEEN_ON_NETWORK`, `ACCEPTED_BY_NETWORK`, `MINED`, `IMMUTABLE`). The output rows already exist from Phase 2 with `promoted = false`; `Store#promote_action_outputs` flips them to `promoted = true` and inserts spendable rows for wallet-owned outputs. Idempotent — a re-poll of an already-promoted broadcast is a no-op.

On the **internal path** (`broadcast: :none`), Phase 4 commits inside the same transaction as Phases 1 and 2 (`Store#promote_action`). Output rows are written with `promoted = true` directly; spendable rows are inserted alongside.

If the broadcast response includes a merkle proof (ARC returns MINED), `ProofStore#save_proof` stores it and `Store#link_proof` marks the action as completed.

**Return:** `{ txid:, tx: }` if signed and broadcast, `{ signable_transaction: { tx:, reference: } }` if deferred.

### Two lifecycles, one schema

The `broadcast` parameter on `create_action` (and the `broadcast` enum on the `actions` table) routes each action into one of two lifecycles:

- **Send path** (`broadcast IN ('delayed', 'inline')`) — pure 4-phase. Output rows are persisted at Phase 2 with `promoted = false`. They are not in the canonical UTXO set until Phase 4 fires on broadcast acceptance.
- **Internal path** (`broadcast == 'none'`) — Phases 1, 2, and 4 commit synchronously inside `create_action`. Used by `internalize_action` (incoming BEEF), `import_utxo` (root-key UTXO), wbikd address management (slot locks), and `send_payment` (porcelain returning BEEF for out-of-band delivery). No broadcasts row is ever created.

The split is structural — the `promoted` flag on outputs is the membership marker for the canonical UTXO set, and the routing fact is when Phase 4 commits. BRC-100's `noSend` / `sendWith` chained-send primitives are deferred to #192 and not part of this base wallet.

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

#### internalize_action

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

### 3.2 Public Key Management (BRC-100 codes 8–10)

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

### 3.3 Cryptography Operations (BRC-100 codes 11–16)

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

### 3.4 Identity and Certificate Management (BRC-100 codes 17–22)

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

### 3.5 Authentication (BRC-100 codes 23–24)

**Methods:** `authenticated?`, `wait_for_authentication`

Simple lifecycle methods. `authenticated?` returns `{ authenticated: true/false }`. `wait_for_authentication` blocks until the wallet is set up and returns `{ authenticated: true }`.

Implementation-dependent — may check for the presence of a master key, a valid session, or a hardware device.

---

### 3.6 Blockchain and Network Data (BRC-100 codes 25–28)

**Methods:** `height`, `header_for_height`, `network`, `version`

Read-only queries:
- `height` — current blockchain height, typically from a network service or cached header chain
- `header_for_height` — 80-byte block header. The schema stores block hashes and merkle roots in tx_proofs but not full headers. This method may require a network lookup or a separate header cache
- `network` — `:mainnet` or `:testnet`, a configuration value
- `version` — wallet version string in `vendor-major.minor.patch` format

---

## 4. Data Layer

### Schema

Key design principles:

1. **Outputs are the primary entity** — the immutable log. Never updated, never deleted.
2. **State is derived, not stored** — no status column on actions. Status comes from structural state: `txid IS NULL` = unsigned, `tx_proof_id IS NOT NULL` = completed, etc.
3. **Inputs are the lock mechanism** — claiming a UTXO = INSERT into inputs. UNIQUE(output_id) enforces single-spend atomically. CASCADE delete from actions releases locks.
4. **The spendable table IS the wallet** — a minimal set of output_ids (~28 bytes/row). Fits in buffer cache permanently. The hot-path UTXO query scans this, then PK-joins to outputs for data.
5. **Binary data is bytea** — txids, scripts, proofs, raw transactions. The entire stack works with binary.

### Tables (FK-dependency order)

| Table | Character | INSERT | UPDATE | DELETE |
|-------|-----------|--------|--------|--------|
| tx_proofs | Append-mostly | proof arrival | upsert on re-proof | never |
| actions | Mutable lifecycle | createAction | wtxid (sign), tx_proof_id (proof) | abort, fail_broadcast, reaper |
| broadcasts | Broadcast lifecycle | Phase 2 (send path) | `broadcast_at`, ARC response | fail_broadcast, CASCADE from action |
| baskets | Reference data | on demand | never | hard delete |
| outputs | Append-only log | Phase 2 (send, `promoted=false`) / Phase 4 (internal, `promoted=true`) | `promoted` single-shot false → true at send-path Phase 4 | abort / fail_broadcast / reaper (cleanup paths only) |
| spendable | The wallet | Phase 4 (both paths) | never | spend / relinquish / cleanup |
| output_baskets | Mutable membership | Phase 2 (send) / Phase 4 (internal) | basket move | relinquish / cleanup |
| output_details | Immutable metadata | Phase 2 (send) / Phase 4 (internal) | never | cleanup |
| inputs | Lock mechanism | Phase 1 | never | CASCADE from action |
| labels / action_labels | Action categorisation | on demand | never | hard delete |
| tags / output_tags | Output categorisation | on demand | never | hard delete |
| certificates / certificate_fields | Identity (BRC-52) | acquire | never | hard delete |
| settings | Key-value config | on demand | upsert | never |

### Database

PostgreSQL, accessed via Sequel. The Sequel layer provides a low-level interface with enough flexibility and precision to implement the Store/ProofStore interface methods expressively. No ActiveRecord.

### Store Implementation

The Store mirrors the schema's phase model:

- `create_action` → Phase 1 (INSERT action + inputs atomically)
- `sign_action` → Phase 2 (UPDATE action SET wtxid, raw_tx; INSERT outputs with `promoted = false`; INSERT broadcasts row for send-path actions)
- `stage_action` → Deferred Phase 2 (same as `sign_action` for outputs, but defers the broadcasts row to a later `sign_action` call)
- `promote_action` → Internal-path Phase 4 (INSERT outputs `promoted = true` and spendable rows in one transaction; only reachable from `broadcast == 'none'` callers)
- `promote_action_outputs` → Send-path Phase 4 (flip `promoted = false → true` on existing rows and INSERT spendable rows; idempotent)
- `link_proof` → attach a tx_proof to an action
- `abort_action` → clear dependent rows under the RESTRICT FK, then DELETE the action (CASCADE frees inputs); no-op if a broadcasts row exists
- `fail_broadcast_action` → terminal cleanup on ARC rejection (drops broadcasts row and unpromoted output rows alongside the action)

The Store owns multi-table atomicity. The Engine never sees a half-committed lifecycle — every transition is a single `@db.transaction` block. The Store is a data access layer, not a business logic layer: it persists and queries, but doesn't validate BRC-100 rules or orchestrate multi-step flows. That's the wallet engine's job (Layer 3).

### Broadcast Implementation

The wallet owns broadcast — the SDK provides the ARC protocol (message formatting, status parsing), but the wallet's BroadcastQueue decides when and how to broadcast.

ARC supports three delivery mechanisms, implemented in phases:

1. **Synchronous** (Phase 1) — `POST /tx`, block for response. `BroadcastQueue#submit(immediate: true)`.
2. **Callback URL** (Phase 2) — `POST /tx` with `X-CallbackUrl`, ARC POSTs `TransactionStatus` to a Rack endpoint. `BroadcastQueue#handle_event` processes incoming updates.
3. **SSE** (Phase 3, future) — persistent connection to `GET /events?callbackToken=...`. Higher throughput, no public endpoint required.

All three deliver the same `TransactionStatus` payload to the same `broadcasts` table. Switching between them is configuration, not code change.

**Proof extraction from broadcast:** when ARC reports MINED, the response includes `merklePath`, `blockHash`, and `blockHeight` — a proof for free. The broadcast handler creates a `tx_proof` directly, eliminating a separate proof-fetching round-trip for most transactions.

**Recovery:** if a callback is missed or a process crashes, the BroadcastQueueWorker polls ARC's `GET /tx/{txid}` for stale broadcasts and completes the lifecycle.

### ProofStore Separation

Currently backed by PostgreSQL alongside the main Store (tx_proofs table). Whether proofs warrant a separate backing store is an open question:

- **For separation:** different access patterns (write-once, read-many, prunable), potential for a shared proof service across wallets, different caching strategy
- **Against:** adds interface surface for something that currently lives in the same database

The schema also has a tx_reqs table — a work queue for proof harvesting. The ProofStore interface includes `request_proof` and `process_pending` to cover this lifecycle.

---

## 5. UTXOPool Design

The interface (`select`/`release`/`balance`) is deliberately thin. It recommends which outputs to spend — the actual locking happens in `Store#create_action` via the input row INSERT. This accommodates three tiers:

### Tier 1 — Simple Coin Selection (default)

`select(satoshis:)` delegates to `Store#find_spendable` — queries the spendable table, PK-joins to outputs, returns candidates ordered by satoshis. No reservation at this tier — the database lock (Phase 1 INSERT ON CONFLICT) handles contention. Adequate for single-user, low-frequency use.

### Tier 2 — Pre-Split Pool

Same as tier 1 but scoped to a dedicated basket. The schema's baskets table with `target_count` and `target_value` columns supports replenishment policies. Less contention because each consumer has its own basket.

### Tier 3 — In-Memory TxCache

Pre-warmed, in-memory queue of already-locked UTXOs. `select(satoshis:)` dequeues from memory — the dequeue IS the reservation. No database query, no lock contention, sub-millisecond latency. `release(outputs:)` re-enqueues on abort. Required for millions-of-transactions-per-second throughput.

The schema's spendable table (~28 bytes/row, fits in buffer cache) gives tier 1 a strong starting position. The baskets table with replenishment policy gives tier 2 a clear upgrade path. The interface doesn't mention storage or queries — that's what keeps tier 3 viable.

---

## 6. Cross-Cutting Concerns

### Binary-First Data Flow

```
Layer 1: PostgreSQL bytea columns → pg gem binary strings
Layer 2: Sequel models return binary → components pass binary
Layer 3: BRC-100 methods work with binary internally
Layer 4: Consumer converts to hex if needed
```

No hex encoding anywhere in layers 1–3.

### Error Translation Across Layers

```
Layer 1: PostgreSQL constraint violations (UNIQUE, FK, CHECK)
Layer 2: Wallet::Error subclasses (InsufficientFundsError, PoolDepletedError, etc.)
Layer 3: BRC-100 error codes and messages
Layer 4: HTTP status codes and JSON error responses (if applicable)
```

A UNIQUE constraint violation in Layer 1 becomes an `InsufficientFundsError` in Layer 2 (contention failure on inputs) which becomes a BRC-100 error code in Layer 3.

### State Derivation

Status is never stored. It's derived at query time from structural state. The `promoted` flag on outputs distinguishes the send path's "signed but not yet broadcast-accepted" state from the post-promotion states:

| Structural state | Derived status |
|---|---|
| `wtxid IS NULL` | unsigned |
| `wtxid IS NOT NULL`, `tx_proof_id IS NOT NULL` | completed |
| `wtxid IS NOT NULL`, `broadcast = 'none'`, no proof | internal |
| `wtxid IS NOT NULL`, send path, at least one output with `promoted = true`, no proof | unproven |
| `wtxid IS NOT NULL`, send path, broadcast `tx_status = 'REJECTED'` | failed |
| `wtxid IS NOT NULL`, send path, broadcast row exists, no promoted outputs | sending |
| `wtxid IS NOT NULL`, send path, no broadcast row | unprocessed |

`:internal` replaces the previous `:nosend` label — the new name disambiguates from BRC-100's chained-send concept (deferred to #192).

### Concurrency

The database handles concurrency, not the application. Two concurrent `create_action` calls competing for the same outputs are resolved by PostgreSQL's UNIQUE constraint on `inputs.output_id`. No application-level mutexes, locks, or coordination — delegated to the database.

---

## 7. Dependencies

| Gem | Purpose | Required |
|-----|---------|----------|
| `bsv-sdk` | Low-level BSV primitives — keys, scripts, transactions, crypto, ARC protocol | yes |
| `sequel` | Database access — models, migrations, query building | yes |
| `sqlite3` | SQLite driver (default backend) | yes |
| `pg` | PostgreSQL driver (optional backend, loaded lazily by Sequel) | no |

---

## 8. Open Questions

1. **ProofStore separation** — keep as a separate interface or merge into Store? Both backed by the same PostgreSQL instance currently, but the interface separation preserves optionality.
2. **Block headers** — `header_for_height` needs 80-byte headers. The schema stores block_hash and merkle_root in tx_proofs but not full headers. Needs a header source (network lookup, separate cache, or header table).
3. **Certificate discovery** — `discover_by_identity_key` and `discover_by_attributes` may need external network lookups beyond local storage. How is this wired?
4. **Permission system** — `seek_permission` and `originator` appear on many methods. How does the wallet decide whether to allow an operation? Is this a separate component?
