# Wallet Storage Schema — Clean-Room Design

## Design Principles

1. **Outputs are the primary entity.** The outputs table is the wallet's ledger — the source of truth for "what does this wallet own?" Actions are the events that create and consume outputs.
2. **State is derived, not stored.** An output's spendability is structural: no `spendable` boolean, no `state` enum. Spendable = has a row in `spendable` AND no input row claims it. Spent = an input row exists. Relinquished = no `spendable` row and no input row. Action status is derived from structural state + the `broadcast_intent` flag — no status column.
3. **The inputs table is the lock mechanism.** Claiming an output for a transaction = INSERT into inputs. Releasing it = DELETE (via cascade). The UNIQUE constraint on `output_id` enforces single-spend atomically.
4. **Outputs are immutable (append-only).** The `outputs` table is the log — a permanent record of every output the wallet has ever participated in, including derivation data, locking script, and output type. It is never UPDATE'd or DELETE'd. All mutable state lives in relationship tables: basket membership in `output_baskets`, spending claims in `inputs`, tags in `output_tags`. The `spendable` table is the wallet — a minimal set of output_ids representing the current UTXO set. Outputs is the log; spendable is the wallet.
5. **The spendable table is the UTXO set.** A row in `spendable` means "this output can be spent." Pure set membership: `{id, output_id, action_id}` — no data columns. The presence of a row IS the spendable state. DELETE = spent or relinquished. The hot-path query scans this tiny table, then PK-joins to outputs for data.
6. **Display metadata is vertically partitioned.** Application metadata lives in `output_details` (including the cosmetic `change` flag). Basket membership lives in `output_baskets`.
7. **BRC-100 drives the vocabulary.** Transactions are called "actions" (BRC-100 term). The 28 wallet methods define what the storage must serve.
8. **Proofs are settlement receipts.** A merkle proof proves an action's transaction is in a block. `action.tx_proof_id IS NOT NULL` means settled. Block-level data (height, merkle root, block hash) is normalized into the `blocks` table — one row per known block height, shared across all proofs from that block.
9. **No user table.** The wallet is an engine, not a user-facing service. Identity and authentication are layers above. The wallet knows who it is because it was constructed with a key — that's a runtime parameter, not a database row. Multi-tenant hosting (many users, one database) is a separate concern that can be added via a user-centric schema above the core wallet tables.
10. **Binary data is bytea.** Transaction IDs, block hashes, merkle paths, raw transactions, and locking scripts are stored as `bytea`. Sequel models return binary strings (Ruby `Encoding::BINARY`). The entire internal stack — database, models, wallet code, SDK primitives — works with binary. Hex conversion is a presentation concern at the BRC-100 API boundary, not a storage or model concern. No relationships JOIN on txid — all FKs use surrogate bigint PKs.
11. **The database is the last line of defense.** Every invariant enforced in code must be backed by a database constraint. Code can be bypassed, refactored, or have bugs. The schema cannot be bypassed. NOT NULL is the default stance; a column should be nullable only with an explicit reason. CHECK constraints encode cross-column invariants, binary field sizes, and range validity.

## Enums

```sql
CREATE TYPE broadcast_intent AS ENUM ('delayed', 'inline', 'none');
CREATE TYPE output_type AS ENUM ('root', 'outbound');
CREATE TYPE tx_status AS ENUM (
  'UNKNOWN', 'QUEUED', 'RECEIVED', 'STORED',
  'ANNOUNCED_TO_NETWORK', 'REQUESTED_BY_NETWORK', 'SENT_TO_NETWORK',
  'ACCEPTED_BY_NETWORK', 'SEEN_IN_ORPHAN_MEMPOOL', 'SEEN_ON_NETWORK',
  'DOUBLE_SPEND_ATTEMPTED', 'REJECTED', 'MINED_IN_STALE_BLOCK', 'MINED', 'IMMUTABLE'
);
```

**broadcast_intent:** Immutable, set at action creation. Controls when/whether the transaction is broadcast to the network. Three values, two lifecycles:

| value | lifecycle | meaning |
|---|---|---|
| `delayed` | send path | daemon submits to ARC asynchronously (default) |
| `inline` | send path | wallet submits to ARC synchronously and surfaces the network result |
| `none` | internal path | this action is not destined for the network — incoming BEEF, imported root UTXOs, wbikd address locks, `send_payment` returning BEEF for out-of-band delivery |

The send path runs the full 4-phase lifecycle (lock → sign → broadcast → promote). The internal path runs Phases 1, 2, and 4 synchronously at create_action time — there is no Phase 3 because the transaction is never broadcast. See **Action Lifecycle** below for the database-level detail.

**output_type:** Classifies outputs by ownership and derivation. Three constraint profiles:

| output_type | derivation fields | spendable allowed | use case |
|-------------|:-:|:-:|---|
| NULL | required | yes | derived output — wallet-owned via BRC-42 keys |
| root | forbidden | yes | identity key — imported UTXOs, transitional shim |
| outbound | forbidden | **no** (trigger enforced) | payment to others |

`change` is NOT in the enum. Change outputs are structurally identical to derived outputs (NULL type with derivation fields). The `change` flag is cosmetic metadata on `output_details`.

## Migration Order

Tables listed in FK-dependency order — this is the creation sequence.

---

## 1. Blocks

Known block headers — the wallet's local view of the chain. One row per block height. Populated as a write-through cache: the chain tracker checks here first, fetches from the network on miss, and inserts the result. The `blocks` table is the single source of truth for "what is the merkle root at height N?"

| col | type | attributes |
| --- | --- | --- |
| id | bigint | GENERATED ALWAYS AS IDENTITY PRIMARY KEY |
| height | integer | NOT NULL UNIQUE |
| merkle_root | bytea | NOT NULL |
| block_hash | bytea | |
| created_at | timestamptz | NOT NULL DEFAULT now() |
| updated_at | timestamptz | NOT NULL DEFAULT now() |

**Constraints:**
- `CHECK height >= 0`
- `CHECK length(merkle_root) = 32`
- `CHECK block_hash IS NULL OR length(block_hash) = 32`

```ruby
class Wallet::Block < Sequel::Model
  one_to_many :tx_proofs
end
```

---

## 2. Tx Proofs

Merkle inclusion proof — evidence that a transaction is in a block. Independent of whether a wallet action references it (ancestor proofs exist for BEEF construction). Block-level data (height, merkle root, block hash) lives in the `blocks` table; the proof references it via `block_id`.

| col | type | attributes |
| --- | --- | --- |
| id | bigint | GENERATED ALWAYS AS IDENTITY PRIMARY KEY |
| wtxid | bytea | NOT NULL UNIQUE |
| block_id | bigint | REFERENCES blocks (id) |
| block_index | integer | |
| merkle_path | bytea | |
| raw_tx | bytea | NOT NULL |
| created_at | timestamptz | NOT NULL DEFAULT now() |
| updated_at | timestamptz | NOT NULL DEFAULT now() |

**Constraints:**
- `CHECK length(wtxid) = 32` — wtxid is always 32 bytes
- `CHECK length(raw_tx) >= 20` — minimum valid transaction size (version + input_count + output_count + amount + script_len + OP_1 + locktime)
- `CHECK merkle_path IS NULL OR block_id IS NOT NULL` — a path is unverifiable without block context. The reverse (`block_id` known, `merkle_path` pending) is allowed — that's the "confirmed but unproven" intermediate state when ARC reports MINED with `blockHeight` ahead of the path.

```ruby
class Wallet::TxProof < Sequel::Model
  many_to_one :block
end
```

---

## 3. Actions

A BRC-100 Action — a Bitcoin transaction throughout its lifecycle from conception to settlement. The wallet's audit log of "what happened and why."

| col | type | attributes |
| --- | --- | --- |
| id | bigint | GENERATED ALWAYS AS IDENTITY PRIMARY KEY |
| tx_proof_id | bigint | REFERENCES tx_proofs (id) |
| wtxid | bytea | UNIQUE WHERE NOT NULL |
| reference | uuid | NOT NULL UNIQUE DEFAULT uuidv7() |
| description | text | NOT NULL |
| version | integer | |
| nlocktime | bigint | |
| broadcast_intent | broadcast_intent | NOT NULL DEFAULT 'delayed' |
| raw_tx | bytea | |
| input_beef | bytea | |
| created_at | timestamptz | NOT NULL DEFAULT now() |
| updated_at | timestamptz | NOT NULL DEFAULT now() |

**Constraints:**
- `CHECK wtxid IS NULL OR length(wtxid) = 32`
- `CHECK length(description) BETWEEN 5 AND 50`
- `CHECK (wtxid IS NULL) = (raw_tx IS NULL)` — an action is either unsigned (both NULL) or signed (both set)

**`reference` UUIDv7:** Time-ordered UUID (#198/#222). Postgres uses the native `uuidv7()` function (PG 18+) as the column default. SQLite calls `SecureRandom.uuid_v7` (Ruby 3.3+) from `Action#before_create`. Sequential inserts on the UNIQUE index — no B-tree page splits or fragmentation that random UUIDv4 caused.

**Indexes:**
- `idx_actions_broadcast_intent` on `(broadcast_intent)` — worker queries scan for actions pending broadcast
- `UNIQUE (id, broadcast_intent)` — composite FK target for `broadcasts.intent` (atomically ties broadcast rows to their action's intent; see **Broadcasts** below)

**No status column.** Status is derived from structural state. The send path (`broadcast_intent IN ('delayed', 'inline')`) and the internal path (`broadcast_intent = 'none'`) share the table, and the derivation distinguishes them via the `promoted` flag on outputs (see **Outputs** below):

| Structural state | Derived status |
|---|---|
| `wtxid IS NULL` | unsigned — waiting for signAction |
| `wtxid IS NOT NULL`, `tx_proof_id IS NOT NULL` | completed |
| `wtxid IS NOT NULL`, `broadcast_intent = 'none'`, no `tx_proof_id` | internal — non-network action (incoming, wbikd, import, send_payment) |
| `wtxid IS NOT NULL`, send path, at least one output with `promoted = true`, no `tx_proof_id` | unproven — waiting for proof |
| `wtxid IS NOT NULL`, send path, broadcast row has `tx_status = 'REJECTED'` | failed — network rejected |
| `wtxid IS NOT NULL`, send path, broadcast row exists, no promoted outputs | sending — broadcast in progress |
| `wtxid IS NOT NULL`, send path, no broadcast row | unprocessed — broadcast pending |

```ruby
class Wallet::Action < Sequel::Model
  many_to_one :tx_proof
  one_to_one  :broadcast_entry, class: :BroadcastQueue
  one_to_many :outputs
  one_to_many :inputs
  many_to_many :labels, join_table: :action_labels

  def derived_status
    return :unsigned   if wtxid.nil?
    return :completed  if tx_proof_id
    return :internal   if values[:broadcast_intent] == 'none'
    # Send-path outputs are persisted at sign time with promoted: false.
    # A row flips to promoted: true only when broadcast was accepted —
    # the :unproven gate.
    return :unproven   if outputs_dataset.where(promoted: true).any?
    return :failed     if broadcast_entry&.tx_status == 'REJECTED'
    return :sending    if broadcast_entry
    :unprocessed
  end
end
```

`:internal` replaces the earlier `:nosend` label (the rename is a breaking change for consumers of `list_actions`). `'none'` is a load-bearing enum value distinct from the BRC-100 chained-send concept; it marks actions whose transaction is never going to ARC because it doesn't need to (incoming BEEF, imported root UTXOs, wbikd address locks, `send_payment` returning BEEF for out-of-band delivery). The BRC-100 noSend / sendWith primitives are deferred to #192 and are not part of this base wallet.

## 4. Broadcasts

Evidence that a broadcast has been initiated. One row per action. The broadcast record and the network call are tightly coupled — the `BroadcastQueue` model owns both the row and the POST to ARC. The action doesn't know or care about broadcast mechanics.

When ARC reports MINED with a `merklePath`, the broadcast handler creates a `tx_proof` and links it to the action — the proof arrives for free via the broadcast response.

| col | type | attributes |
| --- | --- | --- |
| id | bigint | GENERATED ALWAYS AS IDENTITY PRIMARY KEY |
| action_id | bigint | NOT NULL |
| broadcast_at | timestamptz | |
| callback_token | text | |
| arc_status | integer | |
| tx_status | tx_status | |
| intent | broadcast_intent | NOT NULL |
| block_hash | bytea | |
| block_height | integer | |
| merkle_path | bytea | |
| extra_info | text | |
| competing_txs | text[] | |
| created_at | timestamptz | NOT NULL DEFAULT now() |
| updated_at | timestamptz | NOT NULL DEFAULT now() |

**Constraints:**
- `UNIQUE (action_id)` — one broadcast record per action
- `FOREIGN KEY (action_id, intent) REFERENCES actions (id, broadcast_intent) ON UPDATE RESTRICT` — composite FK ties the broadcast row to its parent action's intent atomically; `ON UPDATE RESTRICT` makes the immutability of `actions.broadcast_intent` an enforced schema invariant rather than a code-only convention
- `CHECK intent != 'none'` — actions with `broadcast_intent = 'none'` are internal-path and cannot have a broadcast row
- `CHECK block_hash IS NULL OR length(block_hash) = 32`
- `CHECK block_height IS NULL OR block_height >= 0`

**`intent` column:** Duplicates `actions.broadcast_intent` for the composite FK target. The pair `(intent != 'none', composite FK)` is the trigger-free equivalent of "an action with `broadcast_intent = 'none'` cannot have a broadcasts row" (#198/#221) — chosen over a trigger to avoid per-row procedural overhead at high throughput.

**`callback_token`:** Wallet-generated opaque string sent to ARC in the `X-CallbackToken` header at submission time. ARC's `/events` SSE endpoint echoes the token on each status event — the listener uses it to look up the originating broadcast row without round-tripping a txid lookup. Nullable: rows broadcast before the SSE listener landed have none.

**`tx_status`:** ARC's transaction lifecycle status. Postgres uses the `tx_status` ENUM (`CREATE TYPE` above) — the canonical vocabulary lives in ARC's `metamorph_api.proto`. SQLite gets an equivalent CHECK constraint with the same set. `IMMUTABLE` is appended for the wallet's terminal-status set (anticipates an ARC addition; referenced by `Broadcast::TERMINAL_STATUSES`). Column positioned after `arc_status` for efficient row padding in Postgres.

**ARC tx_status lifecycle:**
```
UNKNOWN → RECEIVED → SENT_TO_NETWORK → ACCEPTED_BY_NETWORK → SEEN_ON_NETWORK → MINED → IMMUTABLE
                                                               ↘ DOUBLE_SPEND_ATTEMPTED
                                                               ↘ REJECTED
```

```ruby
class Wallet::BroadcastQueue < Sequel::Model
  many_to_one :action
end
```

### Action Lifecycle — The Database Perspective

Every `createAction` is a series of small atomic database transactions. No database transaction is ever held open across a network call.

#### Phase 1: Lock (atomic, milliseconds)

```
BEGIN
  INSERT INTO actions (broadcast_intent, nlocktime, description, ...)
    -- wtxid IS NULL, raw_tx IS NULL — the action is unsigned
  INSERT INTO inputs (action_id, output_id, vin, nsequence, description)
    ON CONFLICT (output_id) DO NOTHING RETURNING output_id
  -- verify we locked enough inputs to fund the transaction
  -- if insufficient: ROLLBACK (nothing persisted, nothing to clean up)
COMMIT
```

**Database state after Phase 1:**
- `actions`: one new row, `wtxid IS NULL` (unsigned), no `raw_tx`
- `inputs`: one row per consumed output, each locking a UTXO via UNIQUE(output_id)
- `outputs`: **untouched** — change outputs exist only in memory
- `spendable`: **untouched** — locked outputs are still in spendable but excluded by the NOT EXISTS anti-join on inputs

**Contention window:** only the duration of Phase 1 (a few INSERTs). A concurrent `createAction` trying to lock the same output will block briefly here, then see the conflict and move on to other UTXOs.

#### Phase 2: Sign (atomic, milliseconds for the commit — signing work happens in memory)

UTXO selection, key derivation, template evaluation, ECDSA signing — all happen in memory between Phase 1 and the Phase 2 commit. If signing fails, the action stays unsigned (inputs remain locked, reaper will clean up).

If `signAndProcess: false`, this phase is deferred — see **Deferred Signing — signAction** below.

```
-- signing happens in memory (key derivation, ECDSA, script templates)
BEGIN
  UPDATE actions SET wtxid = ?, raw_tx = ? WHERE id = ?
  -- send path also writes the output rows with promoted = false here
  INSERT INTO outputs (action_id, satoshis, vout, locking_script,
                       output_type, derivation_prefix, derivation_suffix,
                       sender_identity_key, promoted = false)
  -- broadcasts row appears here too (intent != 'none'), pre-stamped for
  -- the daemon push-discovery loop
  INSERT INTO broadcasts (action_id)
COMMIT
```

**Database state after Phase 2 (send path):**
- `actions`: `wtxid` set, `raw_tx` set — the action is signed and ready for broadcast
- `outputs`: rows for every output with `promoted = false` — the immutable record exists but the outputs are **not** in the canonical UTXO set yet
- `spendable`: untouched — no UTXO claims until Phase 4
- `broadcasts`: one row, `broadcast_at IS NULL` (the daemon will stamp it before POSTing to ARC)

**Internal path (`broadcast_intent = 'none'`)** does not produce a Phase 3. Phases 1, 2, and 4 commit synchronously inside `create_action` (see **internalizeAction** and the equivalent porcelain paths below). Internal outputs are written with `promoted = true` and `spendable` rows inserted in the same transaction. No broadcasts row is ever created.

#### Phase 3: Broadcast (managed by Engine::Broadcast)

Phase 3 applies to the send path only (`broadcast_intent IN ('delayed', 'inline')`). Internal-path actions skip it entirely.

The broadcasts row was created during Phase 2 commit. Phase 3 is the network call that drives it through ARC's lifecycle.

```ruby
# inline path: the wallet POSTs to ARC synchronously
Engine::Broadcast#submit(action_id:)
# delayed path: the daemon's push-discovery loop finds the row
#   (broadcast_at IS NULL) and calls Engine::Broadcast#submit
```

`Engine::Broadcast#submit`:
1. Stamps `broadcast_at = now()` and commits (`Store#mark_broadcast_attempted`) — the row leaves the push-discovery set and joins the poll set. **State flag:** `broadcast_at` is a state marker — NULL means the row is queued for submission; non-NULL means it has been submitted and is awaiting outcome. The `where(broadcast_at: nil)` predicate in `Store#mark_broadcast_attempted` prevents racing re-stamps within a single in-flight attempt; `Store#clear_broadcast_attempted` reverts the stamp on a 503 response so the row re-enters the queued state for clean retry. After a 503 + retry, `broadcast_at` reflects the retry timestamp rather than the first attempt.
2. POSTs to ARC (network call — outside any DB transaction)
3. On accepted ARC response: persists the status fields and triggers Phase 4 (`Store#promote_action_outputs`)
4. On terminal rejection: `Store#fail_broadcast_action` deletes the action, its broadcasts row, and its (unpromoted) output rows in one transaction
5. On 503 backpressure: `Store#clear_broadcast_attempted` reverts `broadcast_at` to NULL (guarded against the concurrent-SSE-event race by a `tx_status IS NULL` predicate); the daemon's `pending_submissions` discovery picks the row back up next cycle

If the process crashes between steps 1 and 2: the row sits with `broadcast_at IS NOT NULL AND tx_status IS NULL`. The daemon's poll loop finds it via `Store#pending_polls` and calls `Engine::Broadcast#poll_status` (`GET /tx/{txid}`) to resolve the outcome.

If the process crashes between steps 2 and 3: same recovery — the poll loop converges the row to its terminal state and triggers Phase 4 or `fail_broadcast_action` accordingly.

`Engine::Broadcast#poll_status` shares the Phase 4 trigger and the terminal-rejection trigger with `submit` — both call sites invoke `Store#promote_action_outputs` (idempotent via the `promoted` flag) or `Store#fail_broadcast_action`. The post-broadcast lifecycle is symmetric across the two entry points.

#### Phase 4: Promote (atomic, milliseconds — triggered by broadcast acceptance on the send path, synchronous on the internal path)

On the **send path**, Phase 4 fires from `Engine::Broadcast#submit` or `#poll_status` when ARC returns an accepted status (`SEEN_ON_NETWORK`, `ACCEPTED_BY_NETWORK`, `MINED`, `IMMUTABLE`). The output rows already exist from Phase 2 — the work is to flip them into the canonical UTXO set:

```
BEGIN
  -- Flip the membership marker on every output of this action.
  -- Idempotent: a second invocation finds no promoted = false rows.
  UPDATE outputs SET promoted = true WHERE action_id = ? AND promoted = false
  -- Wallet-owned outputs join the UTXO set.
  INSERT INTO spendable (output_id, action_id)
    SELECT id, action_id FROM outputs
     WHERE action_id = ?
       AND output_type IS DISTINCT FROM 'outbound'
       AND id NOT IN (SELECT output_id FROM spendable)
  -- If ARC returned MINED + merklePath:
  INSERT INTO blocks (height, merkle_root, block_hash)
    VALUES (?, ?, ?) ON CONFLICT (height) DO NOTHING
  INSERT INTO tx_proofs (wtxid, block_id, block_index, merkle_path, raw_tx)
    ON CONFLICT (wtxid) DO UPDATE SET ...
  UPDATE actions SET tx_proof_id = ? WHERE id = ?
COMMIT
```

On the **internal path** (`broadcast_intent = 'none'`), Phase 4 is committed inside the same transaction as Phase 1+2 by `Store#promote_action`. Output rows are written directly with `promoted = true` and spendable rows are inserted alongside them. No broadcast acceptance trigger is involved.

**Database state after Phase 4 (send path):**
- `outputs`: rows already existed from Phase 2; `promoted` flipped `false → true`.
- `spendable`: new rows for wallet-owned outputs. Outbound outputs never get a spendable row (trigger enforced).
- `tx_proofs`: proof created if ARC returned MINED (proof arrives for free).
- `actions`: `tx_proof_id` set if proof arrived with broadcast response.

**Database state after Phase 4 (internal path):**
- `outputs`: new rows for all transaction outputs, written with `promoted = true`.
- `spendable`: new rows for wallet-owned outputs.
- No broadcasts row, no proof from this path (incoming actions carry their proof; wbikd / send_payment have no on-chain proof requirement at this stage).

The new wallet-owned outputs are live in the UTXO set. They're immediately available for the next `createAction`.

#### Broadcast Failure

If ARC returns a terminal rejection (`REJECTED`, `DOUBLE_SPEND_ATTEMPTED`, `MALFORMED`), `Store#fail_broadcast_action` deletes the action, its broadcasts row, and its unpromoted output rows in a single transaction. CASCADE on inputs frees the locked UTXOs. `MINED_IN_STALE_BLOCK` is **not** terminal — it emits `task.failed reason=stale_beef` and is re-discovered on the next scheduler tick (see `docs/wallet-events.md`).

```
BEGIN
  -- Send-path outputs are promoted = false at this point, so they
  -- have no spendable rows. Clear the dependents, then the rows.
  DELETE FROM output_baskets WHERE action_id = ?
  DELETE FROM output_details WHERE action_id = ?
  DELETE FROM output_tags    WHERE output_id IN (
    SELECT id FROM outputs WHERE action_id = ?
  )
  DELETE FROM outputs        WHERE action_id = ?
  DELETE FROM broadcasts     WHERE action_id = ?
  DELETE FROM actions        WHERE id = ?
    -- ON DELETE CASCADE removes inputs, freeing the locked UTXOs
COMMIT
```

Under #189 the FK on `outputs.action_id` is RESTRICT, so the explicit deletes above are required — there is no automatic CASCADE on outputs. The deletes are safe because send-path outputs reachable by `fail_broadcast_action` are by construction `promoted = false`, never claimed by another input.

#### Reaper: TTL Cleanup

Two classes of stale actions:

**Never signed** (`wtxid IS NULL` — Phase 1 happened, signing never did):
```sql
-- No outputs exist yet (send path defers writes to sign time;
-- internal path commits in one transaction so wtxid is never NULL).
-- CASCADE on inputs.action_id frees the locked UTXOs.
DELETE FROM actions a
WHERE a.wtxid IS NULL
  AND a.created_at < (now() - interval '?');
```

**Never sent** (`wtxid IS NOT NULL`, send path, no broadcasts row):
```sql
-- Action was signed and outputs were persisted (promoted = false)
-- but a broadcasts row was never created — sign_action committed
-- but the broadcast intent never reached Phase 3. RESTRICT FK on
-- outputs.action_id means the dependents must go first.
DELETE FROM output_baskets WHERE action_id IN (...stale ids...);
DELETE FROM output_details WHERE action_id IN (...stale ids...);
DELETE FROM output_tags    WHERE output_id IN (
  SELECT id FROM outputs WHERE action_id IN (...stale ids...)
);
DELETE FROM outputs        WHERE action_id IN (...stale ids...);
DELETE FROM actions a
WHERE a.wtxid IS NOT NULL
  AND a.broadcast_intent != 'none'
  AND a.created_at < (now() - interval '?')
  AND NOT EXISTS (SELECT 1 FROM broadcasts b WHERE b.action_id = a.id);
```

**Sent but unresolved** (broadcast row exists, outputs not yet promoted — needs ARC poll):
```sql
SELECT a.id, a.wtxid, b.tx_status, b.broadcast_at
FROM actions a
JOIN broadcasts b ON b.action_id = a.id
WHERE NOT EXISTS (
  SELECT 1 FROM outputs o WHERE o.action_id = a.id AND o.promoted = true
)
  AND b.broadcast_at < (now() - interval '?');
-- The daemon's poll-discovery loop already handles this via
-- Store#pending_polls; the reaper query is the manual-investigation
-- entry point for rows that have lingered beyond the poll TTL.
```

Internal-path actions (`broadcast_intent = 'none'`) are not visible to the reaper — they commit atomically with their outputs and never enter a "stuck between phases" state.

#### Proof Arrival (async, via ARC callback or polling)

```
BEGIN
  INSERT INTO blocks (height, merkle_root, block_hash)
    VALUES (?, ?, ?) ON CONFLICT (height) DO NOTHING
  INSERT INTO tx_proofs (wtxid, block_id, block_index, merkle_path, raw_tx)
    ON CONFLICT (wtxid) DO UPDATE SET ...
  UPDATE actions SET tx_proof_id = ? WHERE wtxid = ?
  UPDATE broadcasts SET tx_status = 'MINED', block_hash = ?, block_height = ? WHERE action_id = ?
COMMIT
```

The action's derived status transitions to `completed` (tx_proof_id is now set). Can arrive via:
- The broadcast response itself (ARC returns MINED immediately for fast blocks)
- ARC SSE events (`/events` endpoint — push-based)
- Polling ARC `GET /tx/{txid}`
- Daemon fetch cycle (Action adopts Fetchable — structural queries find actions needing proofs)

#### abortAction (before broadcast)

```
BEGIN
  -- Abort applies to actions that have not yet been broadcast.
  -- It is rejected if a broadcasts row exists.
  -- Under #189 the outputs.action_id FK is RESTRICT, so any deferred
  -- output rows (promoted = false) must be cleared before the action.
  DELETE FROM output_baskets WHERE action_id = ?
  DELETE FROM output_details WHERE action_id = ?
  DELETE FROM output_tags    WHERE output_id IN (
    SELECT id FROM outputs WHERE action_id = ?
  )
  DELETE FROM outputs        WHERE action_id = ?
  DELETE FROM actions        WHERE id = ?
    -- CASCADE deletes inputs, freeing locked UTXOs
COMMIT
```

After a broadcasts row exists, `abortAction` is a no-op — the network may have the transaction. The terminal-rejection path (`Store#fail_broadcast_action`) handles cleanup when ARC definitively rejects.

#### Deferred Signing — signAction

**When:** `createAction` is called with `signAndProcess: false`, or when any input declares `unlocking_script_length` without providing an `unlocking_script`. The wallet can't fully sign the transaction — the caller needs to provide unlocking scripts for some inputs.

**What's deferred:** Only signing and broadcasting. The deferral is about **inputs**, not outputs. The outputs are fully known at `createAction` time — they don't change between `createAction` and `signAction`.

The output rows are written to the immutable log at `createAction` time so the caller can see them via `list_outputs(include_*)`, but they are written with `promoted = false`. They do **not** join the canonical UTXO set until the eventual `signAction` is followed by an accepted broadcast (Phase 4 on the send path). No `spendable` rows exist for a deferred action until that point.

**Deferred createAction** runs Phase 1 and a partial Phase 2 (`stage_action`):

```
BEGIN
  -- Phase 1: Lock (same as synchronous)
  INSERT INTO actions (broadcast_intent, nlocktime, description, ...)
    -- wtxid IS NULL initially
  INSERT INTO inputs (action_id, output_id, vin, nsequence, description)
    ON CONFLICT (output_id) DO NOTHING RETURNING output_id

  -- Build the unsigned transaction in memory.
  -- Stage Phase 2 (no signing yet): persist the unsigned raw_tx, its
  -- hash as the placeholder wtxid, and the output rows with
  -- promoted = false. No broadcasts row — the broadcast intent only
  -- materialises at signAction time.
  UPDATE actions SET wtxid = ?, raw_tx = unsigned_tx WHERE id = ?
  INSERT INTO outputs (action_id, satoshis, vout, locking_script,
                       output_type, derivation_prefix, derivation_suffix,
                       sender_identity_key, promoted = false)
  INSERT INTO output_baskets (output_id, basket_id, action_id)
  INSERT INTO output_details (output_id, action_id, change, description, ...)
COMMIT
```

Returns `{ signable_transaction: { tx: unsigned_raw_tx, reference: action.reference } }`.

**Database state after deferred createAction:**
- `actions`: `wtxid` set (placeholder hash of unsigned bytes), `raw_tx` set
- `inputs`: locked, same as synchronous Phase 1
- `outputs`: rows exist with `promoted = false` — the immutable record is in place but the outputs are **not** in the canonical UTXO set
- `spendable`: **untouched** — UTXO claims wait until broadcast acceptance (Phase 4)
- `broadcasts`: **untouched** — the broadcast row only exists from `signAction` onwards

**signAction** completes the deferred transaction:

```
-- In memory: deserialize the unsigned raw_tx, apply caller unlocking
-- scripts, sign remaining P2PKH inputs with derived keys
BEGIN
  UPDATE actions SET wtxid = signed_wtxid, raw_tx = signed_tx WHERE id = ?
  INSERT INTO broadcasts (action_id)  -- send path only (intent != 'none')
COMMIT
-- Phase 3 (broadcast) and Phase 4 (promote on acceptance) — same as
-- the synchronous send path.
```

`signAction` only touches the action row and creates the broadcasts row. The output rows persisted by `stage_action` are not rewritten; their `promoted` flag remains `false` until Phase 4 flips it after the broadcast is accepted.

**Cleanup for abandoned deferred actions:**

If `signAction` is never called, the action sits with locked inputs and unpromoted output rows for a transaction that will never reach the network. `abortAction` is the supported cleanup path — under #189 the outputs.action_id FK is RESTRICT, so abort must clear the output rows before the action row:

```sql
BEGIN
  -- No spendable rows to clear (promoted = false means none were
  -- created). Just the output rows and their lightweight dependents.
  DELETE FROM output_baskets WHERE action_id = ?
  DELETE FROM output_details WHERE action_id = ?
  DELETE FROM output_tags    WHERE output_id IN (
    SELECT id FROM outputs WHERE action_id = ?
  )
  DELETE FROM outputs        WHERE action_id = ?
  -- Release locked UTXOs and remove the action.
  DELETE FROM actions        WHERE id = ?
    -- CASCADE deletes inputs, freeing locked UTXOs
COMMIT
```

The reaper handles the same shape for actions abandoned past their TTL (see **Reaper: TTL Cleanup** above). Either way, no spendable rows existed so nothing has to be removed from the UTXO set — the cleanup is purely about the immutable log and the locked inputs.

**Broadcast failure on the send path:** if ARC returns a terminal rejection after `signAction`, `Store#fail_broadcast_action` runs the same shape of cleanup as `abortAction` plus the broadcasts row. Under the restored 4-phase design, descendants of a failed transaction cannot exist — outputs only join the UTXO set after broadcast acceptance, so no child action could have consumed them. The batch-aware cascade for the future chained-send subsystem is covered by #192.

#### internalizeAction (incoming) — internal path

```
BEGIN
  INSERT INTO blocks (height, merkle_root, block_hash)
    VALUES (?, ?, ?) ON CONFLICT (height) DO NOTHING
  INSERT INTO tx_proofs (wtxid, block_id, ...) ON CONFLICT DO UPDATE ...
  INSERT INTO actions (tx_proof_id, wtxid, broadcast_intent: 'none', ...)
  -- Internal path: outputs written directly with promoted = true,
  -- spendable rows inserted in the same transaction. No Phase 3.
  INSERT INTO outputs (action_id, satoshis, vout, locking_script,
                       output_type, derivation_prefix, derivation_suffix,
                       sender_identity_key, promoted = true)
  INSERT INTO spendable (output_id, action_id)
  INSERT INTO output_baskets (output_id, basket_id, action_id)
  INSERT INTO output_details (output_id, action_id, ...)
COMMIT
```

Incoming actions arrive with BEEF — the proof is already available. The action is born with `tx_proof_id` set (derived status: `completed`) or with `broadcast_intent = 'none'` and no proof (derived status: `internal`) depending on the source. Outputs go directly into the immutable log and the UTXO set in one atomic transaction. No broadcasts row, no Phase 3, no broadcast acceptance trigger.

The internal path also serves `import_utxo` (imported root-key UTXO), wbikd address management (slot locks), and `send_payment` (porcelain that returns BEEF for out-of-band delivery). All four callers commit Phases 1, 2, and 4 in a single transaction.

#### relinquishOutput

```
BEGIN
  DELETE FROM spendable WHERE output_id = ?;
  DELETE FROM output_baskets WHERE output_id = ?;
COMMIT
```

The output row stays in the log. The wallet forgets about it — no spendable entry, no basket.

#### Summary: What Each Table Experiences

| Table | INSERT | UPDATE | DELETE | Character |
|-------|--------|--------|--------|-----------|
| **blocks** | proof arrival / internalize / chain tracker | never | never | Append-only — known block headers |
| **actions** | createAction | wtxid (sign), tx_proof_id (proof) | abort, fail_broadcast, reaper | Mutable — the lifecycle entity |
| **inputs** | Phase 1 (lock) | never | CASCADE from action delete | Born and dies with its action |
| **broadcasts** | Phase 2 (send path: alongside sign) | `broadcast_at`, ARC response updates | abort never reaches here; fail_broadcast / CASCADE from action | Broadcast lifecycle |
| **outputs** | Phase 2 (send path, `promoted = false`) / Phase 4 internalize (`promoted = true`) | `promoted` flag (single-shot false → true at send-path Phase 4) | abort / fail_broadcast / reaper (cleanup paths only — never during normal lifecycle) | Append-only log with one carve-out: the `promoted` membership flag |
| **spendable** | Phase 4 (both paths) | never | spend / relinquish / reaper / fail_broadcast | The wallet — INSERT/DELETE only |
| **output_baskets** | Phase 2 (send path) / Phase 4 (internal path) | basket move | relinquish / reaper / abort / fail_broadcast | Mutable membership |
| **output_details** | Phase 2 (send path) / Phase 4 (internal path) | never | reaper / abort / fail_broadcast | Immutable metadata (until reaped) |
| **tx_proofs** | proof arrival / internalize | upsert on re-proof | never | Append-mostly |

---

## 5. Baskets

Output grouping with replenishment policy. Baskets are entities, not just string labels.

| col | type | attributes |
| --- | --- | --- |
| id | bigint | GENERATED ALWAYS AS IDENTITY PRIMARY KEY |
| name | text | NOT NULL UNIQUE |
| target_count | integer | |
| target_value | integer | |
| created_at | timestamptz | NOT NULL DEFAULT now() |
| updated_at | timestamptz | NOT NULL DEFAULT now() |

**Constraints:**
- `UNIQUE (name)` — plain unique (no soft delete)
- `CHECK length(name) BETWEEN 1 AND 300`
- `CHECK name != 'default'` — the default basket is implicit (no row needed)
- `CHECK target_count IS NULL OR target_count >= 0`
- `CHECK target_value IS NULL OR target_value >= 0`

```ruby
class Wallet::Basket < Sequel::Model
  one_to_many :output_baskets
  many_to_many :outputs, join_table: :output_baskets
end
```

---

## 6. Outputs

The append-only log. A permanent record of every output the wallet has ever participated in — both wallet-owned outputs (with derivation data) and outbound payments (with `output_type = 'outbound'`).

The table is immutable in every sense the schema cares about: **no per-row DELETE or UPDATE happens during normal lifecycle**. The only mutation allowed on an existing row is the single-shot `promoted` flag flip (false → true) at send-path Phase 4 — structurally analogous to `actions.tx_proof_id` flipping from NULL to set on proof arrival. Cleanup paths (`abortAction`, `fail_broadcast_action`, reaper) do delete output rows, but they only ever reach rows that never made it into the canonical UTXO set (`promoted = false`). Once an output has been promoted, it stays in the log; lifecycle exit at scale is partition drop, not per-row DELETE.

Derivation data (spending authority) lives here because it's a fact about the output, recorded when the key is derived. This is separate from spendability — an output can have derivation data without being in the UTXO set.

The UTXO set (what's spendable now) is the `spendable` table. Queries enter through `spendable` and PK-join back here for data — the outputs table is never full-scanned.

At scale, partition by id range. Old partitions where all outputs have been spent (no remaining `spendable` rows) can be detached and archived.

| col | type | attributes |
| --- | --- | --- |
| id | bigint | GENERATED ALWAYS AS IDENTITY PRIMARY KEY |
| action_id | bigint | NOT NULL REFERENCES actions (id) ON DELETE RESTRICT |
| satoshis | bigint | NOT NULL |
| created_at | timestamptz | NOT NULL DEFAULT now() |
| locking_script | bytea | NOT NULL |
| vout | integer | NOT NULL |
| output_type | output_type | |
| derivation_prefix | text | |
| derivation_suffix | text | |
| sender_identity_key | text | |
| promoted | bool | NOT NULL DEFAULT true |

**Constraints:**
- `UNIQUE (action_id, vout)` — an output is uniquely identified by its position in the action that created it
- `CHECK satoshis >= 0`
- `CHECK vout >= 0`
- `CHECK length(locking_script) >= 1`
- Typed outputs (root, outbound) must NOT have derivation fields:
  - `CHECK output_type IS NULL OR derivation_prefix IS NULL`
  - `CHECK output_type IS NULL OR derivation_suffix IS NULL`
  - `CHECK output_type IS NULL OR sender_identity_key IS NULL`
- Derived outputs (NULL type) must have ALL derivation fields:
  - `CHECK output_type IS NOT NULL OR derivation_prefix IS NOT NULL`
  - `CHECK output_type IS NOT NULL OR derivation_suffix IS NOT NULL`
  - `CHECK output_type IS NOT NULL OR sender_identity_key IS NOT NULL`

**`promoted` column:** Membership marker for the canonical UTXO set. Written `false` at sign time on the send path; flipped to `true` exactly once at Phase 4 when broadcast acceptance fires. Internal-path inserts (`broadcast_intent = 'none'`) write `promoted = true` directly. The column defaults `true` so any backfill of pre-existing rows lands in the post-promotion state. The send-path Phase 4 update is idempotent — a re-poll of an already-promoted broadcast finds no `promoted = false` rows and is a no-op.

**Cascade:** `action_id ON DELETE RESTRICT` (under #189). Outputs cannot be orphaned by an action delete — the delete is rejected unless the dependent output rows are removed first. The cleanup paths (`abort_action`, `fail_broadcast_action`, reaper) handle this explicitly. Under the restored 4-phase design these paths only ever encounter `promoted = false` rows (the send path never DELETEs a row that has joined the UTXO set), so the delete is safe.

**Note:** No `updated_at` — the row is immutable apart from the `promoted` flip. No `basket_id` — basket membership is in `output_baskets`. No `wtxid` — derived via `output.action.wtxid` (always resolvable under the RESTRICT FK, since the parent action cannot be deleted while output rows remain). Column order optimized for alignment: 8-byte columns first, then variable-width, with 4-byte `vout` tucked after `locking_script` to reduce padding.

```ruby
class Wallet::Output < Sequel::Model
  many_to_one :action
  one_to_one  :spendable_entry, class: :Spendable
  one_to_one  :detail,  class: :OutputDetail
  one_to_one  :input          # the input row claiming this output, if any
  one_to_one  :output_basket  # current basket membership, if any
  many_to_many :tags, join_table: :output_tags

  dataset_module do
    # The UTXO set: outputs in the spendable table and not claimed by any input
    def spendable
      where(
        Sequel.exists(Spendable.where(Sequel[:spendable][:output_id] => Sequel[:outputs][:id]).select(1))
      ).exclude(
        Sequel.exists(Input.where(Sequel[:inputs][:output_id] => Sequel[:outputs][:id]).select(1))
      )
    end

    def in_basket(name)
      where(
        Sequel.exists(
          OutputBasket.join(:baskets, id: :basket_id)
            .where(Sequel[:output_baskets][:output_id] => Sequel[:outputs][:id])
            .where(Sequel[:baskets][:name] => name)
            .select(1)
        )
      )
    end

    def min_satoshis(value)
      where { satoshis >= value }
    end
  end

  def outpoint
    "#{action.wtxid}.#{vout}"
  end

  def basket
    output_basket&.basket
  end

  def spendable?
    spendable_entry && input.nil?
  end
end
```

---

## 7. Spendable

The wallet. Pure set membership — each row says "this output is available to spend." The presence of a row IS the spendable state. No data columns beyond the keys. DELETE = spent or relinquished. ~28 bytes per row. At a typical UTXO pool the entire table fits in PostgreSQL's buffer cache permanently.

The hot-path UTXO selection query scans this table (in memory), then PK-joins to `outputs` for satoshis, derivation data, and locking script.

| col | type | attributes |
| --- | --- | --- |
| id | bigint | GENERATED ALWAYS AS IDENTITY PRIMARY KEY |
| output_id | bigint | NOT NULL REFERENCES outputs (id) UNIQUE |
| action_id | bigint | NOT NULL REFERENCES actions (id) ON DELETE CASCADE |

**Indexes:**
- The UNIQUE on `output_id` serves as the index (and enforces one spendable entry per output)

**Cascade:** `action_id ON DELETE CASCADE` — deleting an action automatically removes its spendable entries. Denormalized (derivable via `output_id -> outputs.action_id`) but justified: 8 bytes per row, set once at creation, enables single-statement reaper cleanup.

**Trigger:** `prevent_outbound_spendable` — BEFORE INSERT trigger rejects any row referencing an output with `output_type = 'outbound'`. The database itself prevents invalid state — outbound outputs (payments to others) can never appear in the UTXO set.

**Note:** No timestamps — INSERT at output promotion, DELETE at spend/relinquish. The churn pattern is INSERT-heavy (~8 change outputs created per ~2 inputs consumed). Dead tuples from DELETEs are minimal and vacuum is trivial on a table this small.

```ruby
class Wallet::Spendable < Sequel::Model
  many_to_one :output
  many_to_one :action
end
```

---

## 8. Output Details

Display and application metadata. Never queried in the UTXO selection hot path. One-to-one with outputs.

| col | type | attributes |
| --- | --- | --- |
| id | bigint | GENERATED ALWAYS AS IDENTITY PRIMARY KEY |
| output_id | bigint | NOT NULL REFERENCES outputs (id) UNIQUE |
| action_id | bigint | NOT NULL REFERENCES actions (id) ON DELETE CASCADE |
| change | bool | NOT NULL DEFAULT false |
| type | text | |
| purpose | text | |
| provided_by | text | |
| description | text | |
| custom_instructions | text | |
| script_length | integer | |
| script_offset | integer | |

**Cascade:** `action_id ON DELETE CASCADE` — deleting an action automatically removes its output details.

**`change` flag:** Cosmetic. Tells the UI "this output was change from a transaction you sent." Never indexed, never queried in the hot path. UTXO selection picks by satoshis and basket, never by change flag. Change outputs are structurally identical to derived outputs — `output_type` NULL with derivation fields.

**Note:** No timestamps — written at output creation, immutable.

```ruby
class Wallet::OutputDetail < Sequel::Model
  many_to_one :output
  many_to_one :action
end
```

---

## 9. Output Baskets

Basket membership for outputs. An output belongs to at most one basket at a time. Moving an output between baskets = UPDATE `basket_id`. Relinquishing = DELETE the row. The outputs table is never touched.

| col | type | attributes |
| --- | --- | --- |
| id | bigint | GENERATED ALWAYS AS IDENTITY PRIMARY KEY |
| output_id | bigint | NOT NULL REFERENCES outputs (id) UNIQUE |
| action_id | bigint | NOT NULL REFERENCES actions (id) ON DELETE CASCADE |
| basket_id | bigint | NOT NULL REFERENCES baskets (id) |
| created_at | timestamptz | NOT NULL DEFAULT now() |
| updated_at | timestamptz | NOT NULL DEFAULT now() |

**Constraints:**
- `UNIQUE (output_id)` — an output can be in at most one basket

**Cascade:** `action_id ON DELETE CASCADE` — deleting an action automatically removes its basket memberships.

**Indexes:**
- `idx_output_baskets_basket_satoshis` on `(basket_id)` — basket filter in UTXO selection

```ruby
class Wallet::OutputBasket < Sequel::Model
  many_to_one :output
  many_to_one :basket
  many_to_one :action
end
```

---

## 10. Inputs

The consumption relationship. The lock mechanism. Each row says "this output is being used as input N of this action." The UNIQUE constraint on `output_id` enforces single-spend. `ON DELETE CASCADE` from actions means aborting an action automatically releases all its claimed outputs.

| col | type | attributes |
| --- | --- | --- |
| id | bigint | GENERATED ALWAYS AS IDENTITY PRIMARY KEY |
| action_id | bigint | NOT NULL REFERENCES actions (id) ON DELETE CASCADE |
| output_id | bigint | NOT NULL REFERENCES outputs (id) |
| vin | integer | NOT NULL |
| nsequence | bigint | NOT NULL DEFAULT 4294967295 |
| description | text | |
| created_at | timestamptz | NOT NULL DEFAULT now() |
| updated_at | timestamptz | NOT NULL DEFAULT now() |

**Constraints:**
- `UNIQUE (output_id)` — an output can only be claimed once (the structural lock)
- `UNIQUE (action_id, vin)` — input indexes are unique within an action
- `CHECK vin >= 0`
- `CHECK nsequence BETWEEN 0 AND 4294967295`

**Indexes:**
- The UNIQUE constraints serve as indexes for both the anti-join (spendable query) and the FK lookups

```ruby
class Wallet::Input < Sequel::Model
  many_to_one :action
  many_to_one :output
end
```

---

## 11. Labels

Label definitions for categorizing actions. Normalized — the label string is stored once, then referenced via a join table.

| col | type | attributes |
| --- | --- | --- |
| id | bigint | GENERATED ALWAYS AS IDENTITY PRIMARY KEY |
| label | text | NOT NULL UNIQUE |
| created_at | timestamptz | NOT NULL DEFAULT now() |
| updated_at | timestamptz | NOT NULL DEFAULT now() |

**Constraints:**
- `UNIQUE (label)` — plain unique (no soft delete)
- `CHECK length(label) BETWEEN 1 AND 300`

```ruby
class Wallet::Label < Sequel::Model
  many_to_many :actions, join_table: :action_labels
end
```

---

## 12. Action Labels

Join table: actions to labels (many-to-many).

| col | type | attributes |
| --- | --- | --- |
| id | bigint | GENERATED ALWAYS AS IDENTITY PRIMARY KEY |
| action_id | bigint | NOT NULL REFERENCES actions (id) ON DELETE CASCADE |
| label_id | bigint | NOT NULL REFERENCES labels (id) |
| created_at | timestamptz | NOT NULL DEFAULT now() |
| updated_at | timestamptz | NOT NULL DEFAULT now() |

**Constraints:**
- `UNIQUE (action_id, label_id)`

**Indexes:**
- `idx_action_labels_label_id` on `(label_id)` — reverse lookup

```ruby
class Wallet::ActionLabel < Sequel::Model
  many_to_one :action
  many_to_one :label
end
```

---

## 13. Tags

Tag definitions for categorizing outputs. Same normalization pattern as labels.

| col | type | attributes |
| --- | --- | --- |
| id | bigint | GENERATED ALWAYS AS IDENTITY PRIMARY KEY |
| tag | text | NOT NULL UNIQUE |
| created_at | timestamptz | NOT NULL DEFAULT now() |
| updated_at | timestamptz | NOT NULL DEFAULT now() |

**Constraints:**
- `UNIQUE (tag)` — plain unique (no soft delete)
- `CHECK length(tag) BETWEEN 1 AND 300`

```ruby
class Wallet::Tag < Sequel::Model
  many_to_many :outputs, join_table: :output_tags
end
```

---

## 14. Output Tags

Join table: outputs to tags (many-to-many).

| col | type | attributes |
| --- | --- | --- |
| id | bigint | GENERATED ALWAYS AS IDENTITY PRIMARY KEY |
| output_id | bigint | NOT NULL REFERENCES outputs (id) |
| tag_id | bigint | NOT NULL REFERENCES tags (id) |
| created_at | timestamptz | NOT NULL DEFAULT now() |
| updated_at | timestamptz | NOT NULL DEFAULT now() |

**Constraints:**
- `UNIQUE (output_id, tag_id)`

**Indexes:**
- `idx_output_tags_tag_id` on `(tag_id)` — reverse lookup

```ruby
class Wallet::OutputTag < Sequel::Model
  many_to_one :output
  many_to_one :tag
end
```

---

## 15. Certificates

Identity certificate headers (BRC-52). Per-field encryption keys live in the fields table.

| col | type | attributes |
| --- | --- | --- |
| id | bigint | GENERATED ALWAYS AS IDENTITY PRIMARY KEY |
| type | text | NOT NULL |
| subject | text | |
| serial_number | text | NOT NULL |
| certifier | text | NOT NULL |
| verifier | text | |
| revocation_outpoint | text | |
| signature | text | |
| created_at | timestamptz | NOT NULL DEFAULT now() |
| updated_at | timestamptz | NOT NULL DEFAULT now() |

**Constraints:**
- `UNIQUE (type, serial_number, certifier)`

**Indexes:**
- `idx_certificates_certifier` on `(certifier)`
- `idx_certificates_subject` on `(subject)`

```ruby
class Wallet::Certificate < Sequel::Model
  one_to_many :fields, class: :CertificateField
end
```

---

## 16. Certificate Fields

Per-field storage for certificates. Each field has its own `master_key` for field-level encryption, enabling selective revelation (BRC-52).

| col | type | attributes |
| --- | --- | --- |
| id | bigint | GENERATED ALWAYS AS IDENTITY PRIMARY KEY |
| certificate_id | bigint | NOT NULL REFERENCES certificates (id) ON DELETE CASCADE |
| name | text | NOT NULL |
| value | text | |
| master_key | text | |
| created_at | timestamptz | NOT NULL DEFAULT now() |
| updated_at | timestamptz | NOT NULL DEFAULT now() |

**Constraints:**
- `UNIQUE (certificate_id, name)`

```ruby
class Wallet::CertificateField < Sequel::Model
  many_to_one :certificate
end
```

---

## 17. Settings

Key-value wallet configuration.

| col | type | attributes |
| --- | --- | --- |
| id | bigint | GENERATED ALWAYS AS IDENTITY PRIMARY KEY |
| key | text | NOT NULL UNIQUE |
| value | text | |
| created_at | timestamptz | NOT NULL DEFAULT now() |
| updated_at | timestamptz | NOT NULL DEFAULT now() |

```ruby
class Wallet::Setting < Sequel::Model
  unrestrict_primary_key # allow upsert by key

  def self.get(key)
    first(key: key)&.value
  end

  def self.set(key, value)
    update_or_create({ key: key }, value: value)
  end
end
```

---

## 18. SSE Cursors

Arcade SSE listener resume points. One row per Arcade callbackToken; the row records the high-water `Last-Event-ID` the wallet has successfully pushed onto the in-proc status bus. On reconnect, the listener loads the cursor for its token and reconnects with the `Last-Event-ID` header so Arcade replays events strictly after the cursor — the wallet doesn't redeliver events it has already handed off.

| col | type | attributes |
| --- | --- | --- |
| token | text | PRIMARY KEY |
| last_event_id | bigint | NOT NULL |
| updated_at | timestamptz | NOT NULL |

**No FK on `token`:** the token is an external identifier, not a row in any other wallet table. In practice it is wallet-derived (HMAC-from-WIF via `BSV::Wallet::CallbackToken#derive`) and supplied to Arcade for callback scoping — the wallet owns it, Arcade just relays callbacks tagged with it.

**`last_event_id`:** Arcade emits SSE `id:` fields as nanosecond timestamps (~19 digits — see Arcade PR #50). `bigint` accommodates the full range.

**Upsert semantics:** writes go through `INSERT ... ON CONFLICT (token) DO UPDATE`. Concurrent listeners booting for the same token (defensive — the daemon should run one) race cleanly; last write wins, no PK violation. The cursor records what has been *bus-pushed*, not necessarily what has been applied — replay-on-reconnect is the safety net for application failures downstream.

```ruby
class Wallet::SseCursor < Sequel::Model
  unrestrict_primary_key # token is the PK
end
```

---

## Key Queries

**Spendable outputs in a basket** — the hot path for `createAction`'s funding loop (the `select_inputs` primitive). Enters through `spendable` (the wallet, in memory), PK-joins to `outputs` (the log) for data:

```sql
SELECT o.id, o.satoshis, o.vout, o.action_id, o.locking_script,
       o.derivation_prefix, o.derivation_suffix, o.sender_identity_key
FROM spendable s
INNER JOIN outputs o ON o.id = s.output_id
INNER JOIN output_baskets ob ON ob.output_id = o.id
WHERE ob.basket_id = ?
  AND NOT EXISTS (SELECT 1 FROM inputs i WHERE i.output_id = o.id)
ORDER BY o.satoshis DESC;
```

**Lock outputs** — claim outputs for a new action (atomic, conflict-safe):

```sql
INSERT INTO inputs (action_id, output_id, vin, description)
VALUES (?, ?, 0, ?), (?, ?, 1, ?), (?, ?, 2, ?)
ON CONFLICT (output_id) DO NOTHING
RETURNING output_id;
```

**Abort action** — cascade deletes inputs, releasing all claimed outputs:

```sql
DELETE FROM actions WHERE id = ?;
```

**Stale action recovery** — find send-path actions stuck between Phase 2 and Phase 3 (signed, inputs locked, no broadcasts row created), excluding internal-path actions:

```sql
-- RESTRICT FK on outputs.action_id means dependents must be cleared
-- before the action delete. The send-path rows reachable here have
-- promoted = false (Phase 4 never fired).
DELETE FROM actions a
WHERE a.wtxid IS NOT NULL
  AND a.broadcast_intent != 'none'
  AND a.created_at < (now() - interval '5 minutes')
  AND NOT EXISTS (SELECT 1 FROM broadcasts b WHERE b.action_id = a.id);
```

**List actions by labels** — BRC-100 `listActions` with label filter:

```sql
SELECT DISTINCT a.*
FROM actions a
INNER JOIN action_labels al ON al.action_id = a.id
INNER JOIN labels l ON l.id = al.label_id
WHERE l.label = ANY(?)
ORDER BY a.created_at DESC
LIMIT ? OFFSET ?;
```

**List outputs by basket and tags** — BRC-100 `listOutputs` with basket and tag filter:

```sql
SELECT DISTINCT o.*
FROM outputs o
INNER JOIN output_baskets ob ON ob.output_id = o.id
INNER JOIN baskets b ON b.id = ob.basket_id
INNER JOIN output_tags ot ON ot.output_id = o.id
INNER JOIN tags t ON t.id = ot.tag_id
WHERE b.name = ?
  AND t.tag = ANY(?)
ORDER BY o.created_at DESC
LIMIT ? OFFSET ?;
```

---

## Resolved Design Questions

- **`change` column placement:** On `output_details` (cosmetic display flag). Change outputs are structurally identical to derived outputs — `output_type` NULL with derivation fields. The `change` flag never participates in UTXO selection or constraints.
- **Soft delete:** Removed from baskets, labels, tags, certificates, action_labels, output_tags. Plain UNIQUE constraints replaced partial indexes. Hard delete for cleanup.
- **`relinquishOutput`:** DELETE the `spendable` row (remove from UTXO set). DELETE the `output_baskets` row (remove from basket). The output row stays in the log.
- **Default basket:** No basket assignment = default basket (implicit). `listOutputs(basket: 'default')` queries spendable outputs with no `output_baskets` row. `CHECK name != 'default'` prevents explicit creation of a 'default' basket entity.
- **Derivation data placement:** On `outputs`, not `spendable`. Derivation data is a fact about the output (recorded when the key is derived), not a statement of spendability. This preserves the state transition model: output rows record spending authority, spendable rows declare availability. Two facts, two moments in time.
- **`actions.satoshis`:** Dropped. Derivable from `SUM(outputs.satoshis)`. No BRC-100 method returns it at the action level.
- **`actions.reference`:** UUID type (was text). NOT NULL with `gen_random_uuid()` default.
- **Two lifecycles, one schema:** The `broadcast_intent` enum encodes which path an action follows. `delayed`/`inline` run the 4-phase send path with post-broadcast promotion; `none` runs Phases 1, 2, and 4 synchronously inside `create_action`. Both end with output rows present and (for wallet-owned outputs) spendable rows inserted — the routing fact is when Phase 4 commits, and the structural marker is the `promoted` flag on outputs.
- **`outputs.promoted` carve-out:** The outputs table is append-only with one deliberate exception: the `promoted` flag flips from `false` to `true` exactly once on the send path at Phase 4. Structurally analogous to `actions.tx_proof_id` flipping from NULL to set on proof arrival.
- **`outputs.action_id` is NOT NULL RESTRICT:** Under #189. Output rows cannot be orphaned. Cleanup paths must clear output rows before the action delete; this is safe because cleanup only ever encounters `promoted = false` rows that never joined the UTXO set.

---

## BRC-100 Transaction Operations Reference

**Creation:** `createAction` creates an Action (a Bitcoin transaction + metadata). Requires at least one input or output. Inputs require `inputBEEF` for SPV context. Outputs without `basket` are untracked. Can return a `signableTransaction` reference for deferred signing.

**Signing:** `signAction` completes a deferred transaction. The caller provides unlocking scripts for inputs they control; the wallet signs remaining P2PKH inputs with derived keys. Output rows were already written during `createAction` (`promoted = false`); `signAction` updates the action row (wtxid, signed raw_tx) and creates the broadcasts row. Phase 4 fires later on broadcast acceptance. See **Deferred Signing — signAction** in the lifecycle section.

**Aborting:** `abortAction` cancels an in-progress action that has not yet been broadcast. Clears dependent rows under the RESTRICT FK, then deletes the action; CASCADE on inputs frees the locked UTXOs.

**Internalization:** `internalizeAction` accepts incoming BEEF, verifies proofs, creates output rows (`promoted = true`) and spendable rows for outputs the wallet controls — all in one transaction. This is an internal-path action (`broadcast_intent = 'none'`).

**Listing:** `listActions` queries by labels (the response includes a `:status` symbol drawn from the derived-status table above; `:internal` replaces the previous `:nosend` label). `listOutputs` queries by basket/tags. Both are read-only with pagination.

**Relinquishment:** `relinquishOutput` releases an output from wallet tracking, even if unspent. Removes the spendable row and the basket membership; the output row stays in the log.

**Tags vs Labels:** Labels categorize actions (used with `listActions`). Tags categorize outputs (used with `listOutputs`). Both are purely organizational.

**Chained-send / batching:** The BRC-100 `noSend` / `sendWith` / `noSendChange` / `knownTxids` primitives are not implemented in this base wallet. They are deferred to issue #192 as a separate subsystem. See `reference/send_or_nosend.md` for the historical research notes.
