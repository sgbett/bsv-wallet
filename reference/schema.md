# Wallet Storage Schema — Clean-Room Design

## Design Principles

1. **Outputs are the primary entity.** The outputs table is the wallet's ledger — the source of truth for "what does this wallet own?" Actions are the events that create and consume outputs.
2. **State is derived, not stored.** An output's spendability is structural: no `spendable` boolean, no `state` enum. Spendable = has a row in `spendable` AND no input row claims it. Spent = an input row exists. Relinquished = no `spendable` row and no input row. Action status is derived from structural state + the `broadcast_intent` flag — no status column.
3. **The inputs table is the lock mechanism.** Claiming an output for a transaction = INSERT into inputs. Releasing it = DELETE (via cascade). The UNIQUE constraint on `output_id` enforces single-spend atomically.
4. **Outputs are write-once during their canonical lifetime.** The `outputs` table is the log — a permanent record of every output the wallet has ever participated in, including derivation data, locking script, and output type. Once an output joins the canonical UTXO set (signalled by a `promotions` row gating its `spendable` membership), it is never UPDATE'd or DELETE'd. Cleanup paths (`abort_action`, `fail_broadcast_action`, `reject_action`, reaper) only ever delete *never-promoted* rows, and only as part of an atomic action tear-down. All mutable state lives in relationship tables: basket membership in `output_baskets`, spending claims in `inputs`, tags in `output_tags`. The `spendable` table is the wallet — a minimal set of output_ids representing the current UTXO set. Outputs is the log; spendable is the wallet.
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

**No status column.** Status is derived from structural state. The send path (`broadcast_intent IN ('delayed', 'inline')`) and the internal path (`broadcast_intent = 'none'`) share the table, and the derivation distinguishes them via the existence of a `promotions` row for the action (see **Promotions** below):

| Structural state | Derived status |
|---|---|
| `wtxid IS NULL` | unsigned — waiting for signAction |
| `wtxid IS NOT NULL`, `tx_proof_id IS NOT NULL` | completed |
| `wtxid IS NOT NULL`, `broadcast_intent = 'none'`, no `tx_proof_id` | internal — non-network action (incoming, wbikd, import, send_payment) |
| `wtxid IS NOT NULL`, send path, `EXISTS (promotions WHERE action_id = id)`, no `tx_proof_id` | unproven — waiting for proof |
| `wtxid IS NOT NULL`, send path, broadcast row has `tx_status = 'REJECTED'` | failed — network rejected |
| `wtxid IS NOT NULL`, send path, broadcast row exists, no promotions row | sending — broadcast in progress |
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
    # A promotions row is recorded only at Phase 4, when the broadcast
    # was accepted (#307 / ADR-023) — its existence is the :unproven gate.
    return :unproven   if Wallet::Promotion.where(action_id: id).any?
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
- `UNIQUE (action_id, tx_status)` — composite UNIQUE serving as the FK target for `promotions(action_id, authorising_status)`. Trivially satisfied (`action_id` is already unique), but the pair must be declared as a key for the dependent FK to resolve.
- `FOREIGN KEY (action_id, intent) REFERENCES actions (id, broadcast_intent) ON UPDATE RESTRICT` — composite FK ties the broadcast row to its parent action's intent atomically; `ON UPDATE RESTRICT` makes the immutability of `actions.broadcast_intent` an enforced schema invariant rather than a code-only convention
- `CHECK intent != 'none'` — actions with `broadcast_intent = 'none'` are internal-path and cannot have a broadcast row
- `CHECK block_hash IS NULL OR length(block_hash) = 32`
- `CHECK block_height IS NULL OR block_height >= 0`

**`intent` column:** Duplicates `actions.broadcast_intent` for the composite FK target. The pair `(intent != 'none', composite FK)` is the trigger-free equivalent of "an action with `broadcast_intent = 'none'` cannot have a broadcasts row" (#198/#221) — chosen over a trigger to avoid per-row procedural overhead at high throughput.

**`callback_token`:** Wallet-generated opaque string sent to ARC in the `X-CallbackToken` header at submission time. ARC's `/events` SSE endpoint echoes the token on each status event — the listener uses it to look up the originating broadcast row without round-tripping a txid lookup. Nullable: rows broadcast before the SSE listener landed have none.

**`tx_status`:** ARC's transaction lifecycle status. Postgres uses the `tx_status` ENUM (`CREATE TYPE` above) — the canonical vocabulary lives in ARC's `metamorph_api.proto`. SQLite gets an equivalent CHECK constraint with the same set. `IMMUTABLE` is appended for the wallet's terminal-status set (anticipates an ARC addition; referenced by `Broadcast::TERMINAL_STATUSES`). Column positioned after `arc_status` for efficient row padding in Postgres.

**Mutable-target consequence for promotions:** `promotions(action_id, authorising_status)` references `broadcasts(action_id, tx_status) ON UPDATE CASCADE`. As `tx_status` advances through the lifecycle (RECEIVED → SEEN_ON_NETWORK → MINED), the cascade keeps `promotions.authorising_status` synced — `broadcasts.tx_status` stays the single source of truth, with no duplicated "accepted" latch. A flip to `REJECTED` while a promotions row exists would cascade into `auth_not_rejected` and fail the CHECK; `Store#reject_action` therefore deletes the promotions row before the broadcasts row is removed (see **reject_action** below). See **Promotions** (§7) for the full FK gate.

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
  INSERT INTO actions (broadcast_intent, description, ...)
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
  -- send path writes the output rows here. No "promoted" flag — the row's
  -- canonical-UTXO membership is gated by the absence of a promotions row,
  -- not by a column on outputs.
  INSERT INTO outputs (action_id, satoshis, vout, locking_script,
                       output_type, derivation_prefix, derivation_suffix,
                       sender_identity_key)
  -- broadcasts row appears here too (intent != 'none'), pre-stamped for
  -- the daemon push-discovery loop
  INSERT INTO broadcasts (action_id)
COMMIT
```

**Database state after Phase 2 (send path):**
- `actions`: `wtxid` set, `raw_tx` set — the action is signed and ready for broadcast
- `outputs`: rows for every output — the immutable record exists, but no `promotions` row exists yet so the outputs are **not** in the canonical UTXO set
- `spendable`: untouched — the `spendable.action_id → promotions(action_id)` FK structurally prevents any spendable row from existing without authorisation (Phase 4)
- `broadcasts`: one row, `broadcast_at IS NULL` (the daemon will stamp it before POSTing to ARC)

**Internal path (`broadcast_intent = 'none'`)** does not produce a Phase 3. Phases 1, 2, and 4 commit synchronously inside `create_action` (see **internalizeAction** and the equivalent porcelain paths below). Internal outputs are written, a `promotions` row is inserted with `intent = 'none'` and `authorising_status = NULL` (the `promo_path` CHECK admits this combination), and `spendable` rows are inserted in the same transaction. No broadcasts row is ever created.

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
4. On terminal rejection: `Store#fail_broadcast_action` deletes the action, its broadcasts row, and its output rows in one transaction (no promotions row exists at this point — Phase 4 only fires on a non-rejected ACK)
5. On 503 backpressure: `Store#clear_broadcast_attempted` reverts `broadcast_at` to NULL (guarded against the concurrent-SSE-event race by a `tx_status IS NULL` predicate); the daemon's `pending_submissions` discovery picks the row back up next cycle

If the process crashes between steps 1 and 2: the row sits with `broadcast_at IS NOT NULL AND tx_status IS NULL`. The daemon's poll loop finds it via `Store#pending_polls` and calls `Engine::Broadcast#poll_status` (`GET /tx/{txid}`) to resolve the outcome.

If the process crashes between steps 2 and 3: same recovery — the poll loop converges the row to its terminal state and triggers Phase 4 or `fail_broadcast_action` accordingly.

`Engine::Broadcast#poll_status` shares the Phase 4 trigger and the terminal-rejection trigger with `submit` — both call sites invoke `Store#promote_action_outputs` (idempotent via the `promotions` row — a second invocation finds the row present and returns immediately) or `Store#fail_broadcast_action`. The post-broadcast lifecycle is symmetric across the two entry points.

#### Phase 4: Promote (atomic, milliseconds — triggered by broadcast acceptance on the send path, synchronous on the internal path)

On the **send path**, Phase 4 fires from `Engine::Broadcast#submit` or `#poll_status` when ARC returns an accepted status (`SEEN_ON_NETWORK`, `ACCEPTED_BY_NETWORK`, `MINED`, `IMMUTABLE`). The output rows already exist from Phase 2 — the work is to record the authorisation and bring the wallet-owned outputs into the canonical UTXO set:

```
BEGIN
  -- Record promote-authorisation as a row. The composite FK
  -- (action_id, authorising_status) → broadcasts (action_id, tx_status)
  -- requires that pair to currently exist in broadcasts; the auth_not_rejected
  -- CHECK forbids REJECTED / DOUBLE_SPEND_ATTEMPTED.
  INSERT INTO promotions (action_id, intent, authorising_status)
    VALUES (?, ?, ?)        -- intent = the action's broadcast_intent,
                            -- authorising_status = the current tx_status
    ON CONFLICT (action_id) DO NOTHING
  -- Wallet-owned outputs join the UTXO set. The spendable.action_id FK
  -- to promotions(action_id) means this insert only succeeds because the
  -- promotions row was just written.
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

On the **internal path** (`broadcast_intent = 'none'`), Phase 4 is committed inside the same transaction as Phase 1+2 by `Store#promote_action`. The promotions row is inserted with `intent = 'none'` and `authorising_status = NULL` (the `promo_path` CHECK admits the internal disjunction; the composite FK to `broadcasts` skips on NULL via MATCH SIMPLE). Spendable rows are inserted alongside. No broadcast acceptance trigger is involved.

**Database state after Phase 4 (send path):**
- `outputs`: unchanged from Phase 2 — same rows, untouched.
- `promotions`: one new row, `authorising_status = ` the broadcast's current tx_status. The row's existence IS the canonical-state fact (#307 / ADR-023).
- `spendable`: new rows for wallet-owned outputs. Outbound outputs never get a spendable row (`prevent_outbound_spendable` trigger).
- `tx_proofs`: proof created if ARC returned MINED (proof arrives for free).
- `actions`: `tx_proof_id` set if proof arrived with broadcast response.

**Database state after Phase 4 (internal path):**
- `outputs`: new rows for all transaction outputs.
- `promotions`: one new row, `intent = 'none'`, `authorising_status = NULL`.
- `spendable`: new rows for wallet-owned outputs.
- No broadcasts row, no proof from this path (incoming actions carry their proof; wbikd / send_payment have no on-chain proof requirement at this stage).

The new wallet-owned outputs are live in the UTXO set. They're immediately available for the next `createAction`.

#### Broadcast Failure

If ARC returns a terminal rejection (`REJECTED`, `DOUBLE_SPEND_ATTEMPTED`, `MALFORMED`), `Store#fail_broadcast_action` tears the action down in a single transaction. `MINED_IN_STALE_BLOCK` is **not** terminal — it emits `task.failed reason=stale_beef` and is re-discovered on the next scheduler tick (see `docs/wallet-events.md`).

```
BEGIN
  -- No promotions row was ever recorded for this action (Phase 4 only
  -- fires on a non-rejected ACK), so spendable is empty by construction.
  -- Outputs exist from Phase 2 but are not in the UTXO set — the
  -- spendable.action_id → promotions(action_id) FK structurally
  -- prevented any insert.
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

Under #189 the FK on `outputs.action_id` is RESTRICT, so the explicit deletes above are required — there is no automatic CASCADE on outputs. The deletes are safe because outputs reachable by `fail_broadcast_action` are by construction never-promoted (no promotions row was recorded), so the spendable membership gate (§7) ensures they were never in the UTXO set.

The companion path for an action that *was* promoted optimistically but later flipped to REJECTED — the speculative-promote rollback — is `Store#reject_action` (see **reject_action** below). `fail_broadcast_action` and `reject_action` cover disjoint pre- and post-promotion regimes.

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
-- Action was signed and outputs were persisted but a broadcasts row
-- was never created — sign_action committed but the broadcast intent
-- never reached Phase 3. No promotions row exists (Phase 4 requires
-- a broadcasts row to satisfy the composite FK target), so spendable
-- is empty by construction. RESTRICT FK on outputs.action_id means
-- the output dependents must be cleared explicitly before the action.
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

**Sent but unresolved** (broadcast row exists, no promotions row — needs ARC poll):
```sql
SELECT a.id, a.wtxid, b.tx_status, b.broadcast_at
FROM actions a
JOIN broadcasts b ON b.action_id = a.id
WHERE NOT EXISTS (
  SELECT 1 FROM promotions p WHERE p.action_id = a.id
)
  AND b.broadcast_at < (now() - interval '?');
-- The daemon's poll-discovery loop already handles this via
-- Store#pending_polls; the reaper query is the manual-investigation
-- entry point for rows that have lingered beyond the poll TTL.
```

Internal-path actions (`broadcast_intent = 'none'`) are not visible to the reaper — they commit atomically with their outputs and a promotions row in one transaction, and never enter a "stuck between phases" state. The `prevent_internal_action_delete` BEFORE DELETE trigger on `actions` makes this a schema-level fact: any DELETE against an action with `broadcast_intent = 'none'` AND an existing `promotions` row is refused (`check_violation` ERRCODE → `Sequel::CheckConstraintViolation`). Defence-in-depth mirroring `Store#reject_action`'s `CannotRejectInternalActionError`.

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
  -- It is a no-op if a broadcasts row exists.
  -- It is refused (raises CannotAbortPromotedActionError) if a
  -- promotions row exists — internal-path actions have no broadcasts
  -- row but ARE promoted at create_action time and may already own
  -- canonical UTXO history that downstream actions have spent.
  -- Under #189 the outputs.action_id FK is RESTRICT, so any deferred
  -- output rows must be cleared before the action.
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

After a broadcasts row exists, `abortAction` is a no-op — the network may have the transaction. The terminal-rejection path (`Store#fail_broadcast_action`) handles cleanup when ARC definitively rejects, and `Store#reject_action` (see below) handles the speculative-promote rollback when an optimistically-promoted action later flips to REJECTED.

#### reject_action — speculative-promote rollback

`Store#reject_action` unwinds an action whose Phase 4 already fired on an optimistic ARC ACK (any non-rejected status admits the promotion under `auth_not_rejected`) but whose `tx_status` subsequently flipped to a terminal-rejected value. The promotion is gone, but children may have spent its outputs in the meantime — the rollback walks the action graph forward and tears every descendant down first.

```ruby
do_reject(action_id, visited: Set)
  # idempotency guard: visited set protects against diamond DAGs
  # (a child spending two outputs of a common ancestor) — second visit
  # no-ops rather than raising
  return if visited.include?(action_id)

  # internal-path actions own canonical received UTXO history; rolling
  # them back would compound chain divergence rather than reflect it.
  raise CannotRejectInternalActionError if broadcast_intent == 'none'

  # ARC told us this tx is accepted (SEEN_ON_NETWORK / MINED / etc.);
  # deletion would compound a wallet-vs-chain divergence. Operator
  # investigation is the right response, not unwind.
  raise CannotRejectAcceptedActionError if broadcast.tx_status ∈ ACCEPTED

  # forward-walk: tear children down first so outputs.action_id RESTRICT
  # doesn't block this action's output deletes
  child_actions_of(action_id).each { |c| do_reject(c, visited) }

  # tear-down sequence: order matters
  DELETE spendable, output_tags, output_baskets, output_details, outputs
  DELETE action_labels
  DELETE promotions   -- BEFORE broadcasts: the composite FK
                      -- (action_id, authorising_status) → broadcasts blocks
                      -- the broadcasts delete otherwise
  DELETE broadcasts
  DELETE actions      -- CASCADE inputs, freeing locked UTXOs
```

The cascade structure earns its keep here: deleting `promotions` cascades any remaining `spendable` rows out automatically via the structural FK (§7). The explicit `DELETE FROM spendable` above is belt-and-braces, kept for clarity and to guarantee zero leftover rows in the same transaction.

Three reasons this is correct-by-construction:

1. **Idempotent re-entry.** Action graphs are DAGs (an input can only spend an existing output — true cycles are impossible), but diamonds occur naturally (a consolidation combining two outputs of a common ancestor). The visited set ensures the second arrival no-ops rather than raising and rolling back the whole cascade.
2. **Composite FK ordering.** The `promotions(action_id, authorising_status) → broadcasts(action_id, tx_status)` FK means the broadcasts row cannot be deleted while a promotions row references it. Delete the promotion first, then the broadcast.
3. **CASCADE + CHECK interaction.** Because the broadcasts FK is `ON UPDATE CASCADE`, an external `UPDATE broadcasts SET tx_status = 'REJECTED'` while a promotions row exists would cascade `authorising_status` to REJECTED and fail the `auth_not_rejected` CHECK. The call sequence — delete promotions first, then update or delete broadcasts — keeps this from firing in practice. If it ever did, the wallet would see a constraint violation rather than silent corruption.

#### Deferred Signing — signAction

**When:** `createAction` is called with `signAndProcess: false`, or when any input declares `unlocking_script_length` without providing an `unlocking_script`. The wallet can't fully sign the transaction — the caller needs to provide unlocking scripts for some inputs.

**What's deferred:** Only signing and broadcasting. The deferral is about **inputs**, not outputs. The outputs are fully known at `createAction` time — they don't change between `createAction` and `signAction`.

The output rows are written to the immutable log at `createAction` time so the caller can see them via `list_outputs(include_*)`. They do **not** join the canonical UTXO set until the eventual `signAction` is followed by an accepted broadcast (Phase 4 on the send path) — no `promotions` row exists yet, and the `spendable.action_id → promotions(action_id)` FK structurally prevents any `spendable` row from existing until then.

**Deferred createAction** runs Phase 1 and a partial Phase 2 (`stage_action`):

```
BEGIN
  -- Phase 1: Lock (same as synchronous)
  INSERT INTO actions (broadcast_intent, description, ...)
    -- wtxid IS NULL initially
  INSERT INTO inputs (action_id, output_id, vin, nsequence, description)
    ON CONFLICT (output_id) DO NOTHING RETURNING output_id

  -- Build the unsigned transaction in memory.
  -- Stage Phase 2 (no signing yet): persist the unsigned raw_tx, its
  -- hash as the placeholder wtxid, and the output rows. No promotions
  -- row, no broadcasts row — both materialise at signAction time (or
  -- on the eventual broadcast ACK in Phase 4 for promotions).
  UPDATE actions SET wtxid = ?, raw_tx = unsigned_tx WHERE id = ?
  INSERT INTO outputs (action_id, satoshis, vout, locking_script,
                       output_type, derivation_prefix, derivation_suffix,
                       sender_identity_key)
  INSERT INTO output_baskets (output_id, basket_id, action_id)
  INSERT INTO output_details (output_id, action_id, change, description, ...)
COMMIT
```

Returns `{ signable_transaction: { tx: unsigned_raw_tx, reference: action.reference } }`.

**Database state after deferred createAction:**
- `actions`: `wtxid` set (placeholder hash of unsigned bytes), `raw_tx` set
- `inputs`: locked, same as synchronous Phase 1
- `outputs`: rows exist — the immutable record is in place but the outputs are **not** in the canonical UTXO set
- `promotions`: **untouched** — no authorisation has been recorded
- `spendable`: **untouched** — the `spendable.action_id → promotions` FK gates UTXO membership; no row can exist until the promotions row exists at Phase 4
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

`signAction` only touches the action row and creates the broadcasts row. The output rows persisted by `stage_action` are not rewritten; the promotion happens at Phase 4 by inserting a `promotions` row after the broadcast is accepted.

**Cleanup for abandoned deferred actions:**

If `signAction` is never called, the action sits with locked inputs and output rows for a transaction that will never reach the network. No `promotions` row exists (Phase 4 never fired). `abortAction` is the supported cleanup path — under #189 the outputs.action_id FK is RESTRICT, so abort must clear the output rows before the action row:

```sql
BEGIN
  -- No spendable rows to clear: the spendable.action_id → promotions
  -- FK structurally prevented any insert (no promotions row exists).
  -- Just the output rows and their lightweight dependents.
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
  -- Internal path: outputs written, a promotions row inserted with
  -- intent='none' and authorising_status=NULL (the promo_path CHECK
  -- admits the internal disjunction), and spendable rows inserted in
  -- the same transaction. No Phase 3, no broadcasts row.
  INSERT INTO outputs (action_id, satoshis, vout, locking_script,
                       output_type, derivation_prefix, derivation_suffix,
                       sender_identity_key)
  INSERT INTO promotions (action_id, intent, authorising_status)
    VALUES (?, 'none', NULL)
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
| **actions** | createAction | wtxid (sign), tx_proof_id (proof) | abort, fail_broadcast, reject, reaper | Mutable — the lifecycle entity |
| **inputs** | Phase 1 (lock) | never | CASCADE from action delete | Born and dies with its action |
| **broadcasts** | Phase 2 (send path: alongside sign) | `broadcast_at`, ARC response updates | abort never reaches here; fail_broadcast / reject / CASCADE from action | Broadcast lifecycle |
| **outputs** | Phase 2 (send path) / Phase 4 (internal path, alongside promotions row) | never | abort / fail_broadcast / reject / reaper (cleanup paths only — never during normal lifecycle) | Append-only log; row-existence in `promotions` gates UTXO membership |
| **promotions** | Phase 4 (send path: on broadcast acceptance / internal path: in the create_action transaction) | `authorising_status` via ON UPDATE CASCADE from `broadcasts.tx_status` | reject (delete-before-broadcasts-delete ordering) / CASCADE from action | Existence-as-state authorisation gate |
| **spendable** | Phase 4 (both paths) | never | spend / relinquish / reaper / fail_broadcast / CASCADE from promotions delete | The wallet — INSERT/DELETE only |
| **output_baskets** | Phase 2 (send path) / Phase 4 (internal path) | basket move | relinquish / reaper / abort / fail_broadcast / reject | Mutable membership |
| **output_details** | Phase 2 (send path) / Phase 4 (internal path) | never | reaper / abort / fail_broadcast / reject | Immutable metadata (until reaped) |
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

**Write-once during canonical lifetime.** No per-row UPDATE happens, ever — the table has no mutable columns. Per-row DELETE happens *only* in cleanup paths (`abort_action`, `fail_broadcast_action`, `reject_action`, reaper) and *only* on rows whose parent action is being torn down in the same atomic transaction. Whether such a delete can reach a row is gated structurally: an output's parent action either has a `promotions` row (§7) — in which case it owns canonical UTXO membership and the cleanup paths refuse to touch it — or it doesn't, in which case the row never crossed the authorisation gate and tear-down is safe. Lifecycle exit at scale is partition drop, not per-row DELETE.

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

**Canonical-state marker:** there isn't a column for it. An output is "in the canonical UTXO set" iff its parent action has a row in `promotions` (§7) and the output has a row in `spendable` (§8). The promotions row's existence IS the canonical-state fact (#307 / ADR-023). This replaces the earlier `outputs.promoted` boolean — which was a per-row UPDATE deviation from append-only — with row-existence in a separate table, gating UTXO membership declaratively.

**Cascade:** `action_id ON DELETE RESTRICT` (under #189). Outputs cannot be orphaned by an action delete — the delete is rejected unless the dependent output rows are removed first. The cleanup paths (`abort_action`, `fail_broadcast_action`, `reject_action`, reaper) handle this explicitly. The combination of RESTRICT + the spendable→promotions gate makes the safety property mechanical: any output reached by a delete is by construction one whose action had no promotions row (or has just had it deleted as part of an in-flight `reject_action` cascade).

**Note:** No `updated_at` — outputs have no UPDATE path at all. No `basket_id` — basket membership is in `output_baskets`. No `wtxid` — derived via `output.action.wtxid` (always resolvable under the RESTRICT FK, since the parent action cannot be deleted while output rows remain). Column order optimized for alignment: 8-byte columns first, then variable-width, with 4-byte `vout` tucked after `locking_script` to reduce padding.

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

## 7. Promotions

Promote-authorisation as a row. The existence of a `promotions` row for an action IS the canonical-state fact: "this action's outputs are in the UTXO set." This replaces the earlier `outputs.promoted` boolean (#307 / ADR-023), which was a per-row UPDATE deviation from append-only outputs; with promotion modelled as row-existence, `outputs` returns to pure INSERT-only.

A single row per action — promotion was always a per-action fact, and the PK is `action_id` (a non-auto PK that is also an FK to `actions`). The gate is declarative: two CHECKs on the row itself, plus two composite FKs that tie it to its parent action's intent and (for the send path) to a non-rejected broadcast status. There is no trigger anywhere — the hot send path (Phase 4) carries only the INSERT + the FK lookups (#221, ADR-019).

| col | type | attributes |
| --- | --- | --- |
| action_id | bigint | PRIMARY KEY REFERENCES actions (id) ON DELETE CASCADE |
| intent | broadcast_intent | NOT NULL |
| authorising_status | tx_status | NULL |

**CHECKs:**
- `promo_path` — `(intent = 'none' AND authorising_status IS NULL) OR (intent <> 'none' AND authorising_status IS NOT NULL)`. Internal-path actions authorise themselves by being internal; send-path actions must name the broadcast status that authorised them. The disjunction is exhaustive.
- `auth_not_rejected` — `authorising_status IS NULL OR authorising_status NOT IN ('REJECTED', 'DOUBLE_SPEND_ATTEMPTED')`. The optimistic-promotion set: any non-rejected status, including interim states (`RECEIVED`, `SEEN_ON_NETWORK`). Promote on the first non-rejected ACK; `Store#reject_action` compensates on a later flip.

**Composite FKs:**
- `FOREIGN KEY (action_id, intent) REFERENCES actions (id, broadcast_intent)` — `intent` tracks the parent action's intent atomically (the same composite-FK pattern `broadcasts.intent` uses, ADR-019). Combined with the unique `(id, broadcast_intent)` index on `actions`, this enforces that the recorded `intent` matches what the action declared.
- `FOREIGN KEY (action_id, authorising_status) REFERENCES broadcasts (action_id, tx_status) ON UPDATE CASCADE` — a send-path promotion can only exist while a `broadcasts` row holds the status named in `authorising_status`. NULL on the internal path skips the FK match under MATCH SIMPLE — the broadcasts row doesn't exist for internal actions, and the NULL `authorising_status` makes this consistent.

**ON UPDATE CASCADE — single source of truth.** `broadcasts.tx_status` keeps advancing (`RECEIVED` → `SEEN_ON_NETWORK` → `MINED` → `IMMUTABLE`). Rather than duplicate "the status that authorised the promotion" as a frozen value on `promotions`, the FK references the live `broadcasts.tx_status` and CASCADEs updates. `tx_status` stays the canonical fact; `promotions.authorising_status` is a live projection of it. The consequence: a flip to `REJECTED` while a promotions row exists would cascade `authorising_status` to REJECTED and fail the `auth_not_rejected` CHECK. `Store#reject_action` therefore deletes the promotions row *before* the broadcasts row is deleted or updated to REJECTED. Correct-by-construction: violations fail loudly with a CHECK error rather than drifting.

**Cascade in:** `action_id ON DELETE CASCADE` from `actions`. Deleting an action removes its promotions row.

**Cascade out:** `spendable.action_id REFERENCES promotions(action_id) ON DELETE CASCADE` (§8) — the structural gate on UTXO membership. Deleting the promotions row cascades every `spendable` row for the action out in one statement.

**Defence-in-depth: `prevent_internal_action_delete` trigger.** A BEFORE DELETE trigger on `actions` refuses any DELETE whose target has `broadcast_intent = 'none'` AND an existing `promotions` row. This is canonical received UTXO history (incoming BEEF, imports, `wbikd`, `send_payment`) — code that would unwind it has gone wrong, and the schema must refuse the operation even if `Store#reject_action`'s `CannotRejectInternalActionError` is bypassed. Postgres raises with `check_violation` ERRCODE → `Sequel::CheckConstraintViolation`.

```ruby
class Wallet::Promotion < Sequel::Model
  unrestrict_primary_key  # action_id is set explicitly, not generated
  many_to_one :action
end
```

References: ADR-022 (state as a FK row — the general principle this realises), ADR-023 (promotion as a row — the specific application), #307 (the defect this closes), #221 (the composite-FK precedent), ADR-002 (why a hot-path trigger was the wrong backstop), ADR-003 (schema as canonical state — the principle the old app-only enforcement breached).

---

## 8. Spendable

The wallet. Pure set membership — each row says "this output is available to spend." The presence of a row IS the spendable state. No data columns beyond the keys. DELETE = spent or relinquished. ~28 bytes per row. At a typical UTXO pool the entire table fits in PostgreSQL's buffer cache permanently.

The hot-path UTXO selection query scans this table (in memory), then PK-joins to `outputs` for satoshis, derivation data, and locking script.

| col | type | attributes |
| --- | --- | --- |
| id | bigint | GENERATED ALWAYS AS IDENTITY PRIMARY KEY |
| output_id | bigint | NOT NULL REFERENCES outputs (id) UNIQUE |
| action_id | bigint | NOT NULL — two FKs (see Cascades below) |

**Indexes:**
- The UNIQUE on `output_id` serves as the index (and enforces one spendable entry per output)

**Cascades — two FKs on `action_id`:**

1. `action_id REFERENCES actions (id) ON DELETE CASCADE` — the denormalised-cascade pattern (#189-era). Deleting an action removes its spendable entries directly. Denormalised (derivable via `output_id → outputs.action_id`) but justified: 8 bytes per row, set once at creation, enables single-statement reaper cleanup.
2. `action_id REFERENCES promotions (action_id) ON DELETE CASCADE` — the structural authorisation gate (ADR-023). A `spendable` row cannot exist without a `promotions` row for the same `action_id`. UTXO-set membership is therefore structurally gated on authorisation: writing `spendable` requires the promotion to already exist, and dropping the promotion cascades the spendable rows out in one statement.

The two FKs are belt-and-braces. `Store#reject_action` exploits the second one — it deletes the promotions row first and the spendable rows fall out via cascade before the action delete fires. The first FK then handles any teardown path that goes straight at the action without touching promotions (e.g. abort, reaper).

**Trigger:** `prevent_outbound_spendable` — BEFORE INSERT trigger rejects any row referencing an output with `output_type = 'outbound'`. The database itself prevents invalid state — outbound outputs (payments to others) can never appear in the UTXO set.

**Note:** No timestamps — INSERT at output promotion, DELETE at spend/relinquish. The churn pattern is INSERT-heavy (~8 change outputs created per ~2 inputs consumed). Dead tuples from DELETEs are minimal and vacuum is trivial on a table this small.

```ruby
class Wallet::Spendable < Sequel::Model
  many_to_one :output
  many_to_one :action
end
```

---

## 9. Output Details

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

## 10. Output Baskets

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

## 11. Inputs

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

## 12. Labels

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

## 13. Action Labels

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

## 14. Tags

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

## 15. Output Tags

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

## 16. Certificates

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

## 17. Certificate Fields

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

## 18. Settings

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

## 19. SSE Cursors

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
-- no promotions row (Phase 4 never fired) and so cannot be in spendable.
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
- **Two lifecycles, one schema:** The `broadcast_intent` enum encodes which path an action follows. `delayed`/`inline` run the 4-phase send path with post-broadcast promotion; `none` runs Phases 1, 2, and 4 synchronously inside `create_action`. Both end with output rows present and (for wallet-owned outputs) spendable rows inserted — the routing fact is when Phase 4 commits, and the structural marker is the existence of a `promotions` row for the action (§7).
- **Promotion as a row (#307 / ADR-023):** Promote-authorisation lives in the `promotions` table — row existence IS the canonical-state fact. Replaces the earlier `outputs.promoted` boolean. Two upsides: `outputs` returns to pure INSERT-only (no HOT-tuple churn, no vacuum debt), and the authorisation invariant — *promoted ⟹ internal OR broadcast-accepted* — gets a declarative schema backstop via composite FKs and CHECKs, with **no trigger on the hot send path** (ADR-002, #221).
- **`outputs.action_id` is NOT NULL RESTRICT:** Under #189. Output rows cannot be orphaned. Cleanup paths must clear output rows before the action delete; this is safe because the `spendable → promotions` FK gate (§8) ensures cleanup only ever reaches rows whose action lacked a promotions row (or whose promotions row is being deleted in the same transaction).

---

## BRC-100 Transaction Operations Reference

**Creation:** `createAction` creates an Action (a Bitcoin transaction + metadata). Requires at least one input or output. Inputs require `inputBEEF` for SPV context. Outputs without `basket` are untracked. Can return a `signableTransaction` reference for deferred signing.

**Signing:** `signAction` completes a deferred transaction. The caller provides unlocking scripts for inputs they control; the wallet signs remaining P2PKH inputs with derived keys. Output rows were already written during `createAction` (no `promotions` row yet — the spendable→promotions FK keeps them out of the UTXO set); `signAction` updates the action row (wtxid, signed raw_tx) and creates the broadcasts row. Phase 4 fires later on broadcast acceptance, inserting the promotions row and the spendable rows. See **Deferred Signing — signAction** in the lifecycle section.

**Aborting:** `abortAction` cancels an in-progress action that has not yet been broadcast. Clears dependent rows under the RESTRICT FK, then deletes the action; CASCADE on inputs frees the locked UTXOs.

**Internalization:** `internalizeAction` accepts incoming BEEF, verifies proofs, creates output rows, inserts a `promotions` row (`intent='none'`, `authorising_status=NULL`), and inserts spendable rows for outputs the wallet controls — all in one transaction. This is an internal-path action (`broadcast_intent = 'none'`); the `prevent_internal_action_delete` trigger then protects the canonical UTXO history from later deletion (§7).

**Listing:** `listActions` queries by labels (the response includes a `:status` symbol drawn from the derived-status table above; `:internal` replaces the previous `:nosend` label). `listOutputs` queries by basket/tags. Both are read-only with pagination.

**Relinquishment:** `relinquishOutput` releases an output from wallet tracking, even if unspent. Removes the spendable row and the basket membership; the output row stays in the log.

**Tags vs Labels:** Labels categorize actions (used with `listActions`). Tags categorize outputs (used with `listOutputs`). Both are purely organizational.

**Chained-send / batching:** The BRC-100 `noSend` / `sendWith` / `noSendChange` / `knownTxids` primitives are not implemented in this base wallet. They are deferred to issue #192 as a separate subsystem. See `reference/send_or_nosend.md` for the historical research notes.
