# Wallet Storage Schema — Clean-Room Design

## Design Principles

1. **Outputs are the primary entity.** The outputs table is the wallet's ledger — the source of truth for "what does this wallet own?" Actions are the events that create and consume outputs.
2. **State is derived, not stored.** An output's spendability is structural: no `spendable` boolean, no `state` enum. Spendable = has a row in `spendable` AND no input row claims it. Spent = an input row exists. Relinquished = no `spendable` row and no input row. Action status is derived from structural state + the `broadcast` intent flag — no status column.
3. **The inputs table is the lock mechanism.** Claiming an output for a transaction = INSERT into inputs. Releasing it = DELETE (via cascade). The UNIQUE constraint on `output_id` enforces single-spend atomically.
4. **Outputs are immutable (append-only).** The `outputs` table is the log — a permanent record of every output the wallet has ever participated in, including derivation data, locking script, and output type. It is never UPDATE'd or DELETE'd. All mutable state lives in relationship tables: basket membership in `output_baskets`, spending claims in `inputs`, tags in `output_tags`. The `spendable` table is the wallet — a minimal set of output_ids representing the current UTXO set. Outputs is the log; spendable is the wallet.
5. **The spendable table is the UTXO set.** A row in `spendable` means "this output can be spent." Pure set membership: `{id, output_id, action_id}` — no data columns. The presence of a row IS the spendable state. DELETE = spent or relinquished. The hot-path query scans this tiny table, then PK-joins to outputs for data.
6. **Display metadata is vertically partitioned.** Application metadata lives in `output_details` (including the cosmetic `change` flag). Basket membership lives in `output_baskets`.
7. **BRC-100 drives the vocabulary.** Transactions are called "actions" (BRC-100 term). The 28 wallet methods define what the storage must serve.
8. **Proofs are settlement receipts.** A merkle proof proves an action's transaction is in a block. `action.tx_proof_id IS NOT NULL` means settled.
9. **No user table.** The wallet is an engine, not a user-facing service. Identity and authentication are layers above. The wallet knows who it is because it was constructed with a key — that's a runtime parameter, not a database row. Multi-tenant hosting (many users, one database) is a separate concern that can be added via a user-centric schema above the core wallet tables.
10. **Binary data is bytea.** Transaction IDs, block hashes, merkle paths, raw transactions, and locking scripts are stored as `bytea`. Sequel models return binary strings (Ruby `Encoding::BINARY`). The entire internal stack — database, models, wallet code, SDK primitives — works with binary. Hex conversion is a presentation concern at the BRC-100 API boundary, not a storage or model concern. No relationships JOIN on txid — all FKs use surrogate bigint PKs.
11. **The database is the last line of defense.** Every invariant enforced in code must be backed by a database constraint. Code can be bypassed, refactored, or have bugs. The schema cannot be bypassed. NOT NULL is the default stance; a column should be nullable only with an explicit reason. CHECK constraints encode cross-column invariants, binary field sizes, and range validity.

## Enums

```sql
CREATE TYPE broadcast_intent AS ENUM ('delayed', 'inline', 'none');
CREATE TYPE output_type AS ENUM ('root', 'outbound');
```

**broadcast_intent:** Immutable, set at action creation. Controls when/whether the transaction is broadcast to the network.

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

## 1. Tx Proofs

Merkle inclusion proof — evidence that a transaction is in a block. Independent of whether a wallet action references it (ancestor proofs exist for BEEF construction).

| col | type | attributes |
| --- | --- | --- |
| id | bigint | GENERATED ALWAYS AS IDENTITY PRIMARY KEY |
| wtxid | bytea | NOT NULL UNIQUE |
| height | integer | |
| block_index | integer | |
| merkle_path | bytea | |
| raw_tx | bytea | NOT NULL |
| block_hash | bytea | |
| merkle_root | bytea | |
| created_at | timestamptz | NOT NULL DEFAULT now() |
| updated_at | timestamptz | NOT NULL DEFAULT now() |

**Constraints:**
- `CHECK length(wtxid) = 32` — wtxid is always 32 bytes
- `CHECK length(raw_tx) >= 20` — minimum valid transaction size (version + input_count + output_count + amount + script_len + OP_1 + locktime)
- `CHECK merkle_path IS NULL OR height IS NOT NULL` — a proof without a block height is nonsensical
- `CHECK block_hash IS NULL OR length(block_hash) = 32`
- `CHECK merkle_root IS NULL OR length(merkle_root) = 32`

```ruby
class Wallet::TxProof < Sequel::Model
end
```

---

## 2. Actions

A BRC-100 Action — a Bitcoin transaction throughout its lifecycle from conception to settlement. The wallet's audit log of "what happened and why."

| col | type | attributes |
| --- | --- | --- |
| id | bigint | GENERATED ALWAYS AS IDENTITY PRIMARY KEY |
| tx_proof_id | bigint | REFERENCES tx_proofs (id) |
| wtxid | bytea | UNIQUE WHERE NOT NULL |
| reference | uuid | NOT NULL UNIQUE DEFAULT gen_random_uuid() |
| outgoing | bool | NOT NULL DEFAULT true |
| description | text | NOT NULL |
| version | integer | |
| nlocktime | bigint | NOT NULL DEFAULT 0 |
| broadcast | broadcast_intent | NOT NULL DEFAULT 'delayed' |
| raw_tx | bytea | |
| input_beef | bytea | |
| created_at | timestamptz | NOT NULL DEFAULT now() |
| updated_at | timestamptz | NOT NULL DEFAULT now() |

**Constraints:**
- `CHECK wtxid IS NULL OR length(wtxid) = 32`
- `CHECK length(description) BETWEEN 5 AND 50`
- `CHECK nlocktime >= 0`
- `CHECK (wtxid IS NULL) = (raw_tx IS NULL)` — an action is either unsigned (both NULL) or signed (both set)

**Indexes:**
- `idx_actions_broadcast` on `(broadcast)` — worker queries scan for actions pending broadcast

**No status column.** Status is derived from structural state:

| Structural state | Derived status |
|---|---|
| `wtxid IS NULL` | unsigned — waiting for signAction |
| `wtxid IS NOT NULL`, no broadcast row, no outputs | unprocessed — broadcast pending |
| `wtxid IS NOT NULL`, broadcast row exists, no outputs | sending — broadcast in progress |
| `broadcast = 'none'`, no `tx_proof_id` | nosend |
| outputs exist, `tx_proof_id IS NULL` | unproven — waiting for proof |
| `tx_proof_id IS NOT NULL` | completed |
| broadcast row has `tx_status = 'REJECTED'` | failed — network rejected |

```ruby
class Wallet::Action < Sequel::Model
  many_to_one :tx_proof
  one_to_one  :broadcast_entry, class: :BroadcastQueue
  one_to_many :outputs
  one_to_many :inputs
  many_to_many :labels, join_table: :action_labels

  def derived_status
    return :unsigned    if wtxid.nil?
    return :completed   if tx_proof_id
    return :nosend      if broadcast == 'none'
    return :unproven    if outputs.any?
    return :failed      if broadcast_entry&.tx_status == 'REJECTED'
    return :sending     if broadcast_entry
    :unprocessed
  end
end
```

## 3. Broadcasts

Evidence that a broadcast has been initiated. One row per action. The broadcast record and the network call are tightly coupled — the `BroadcastQueue` model owns both the row and the POST to ARC. The action doesn't know or care about broadcast mechanics.

When ARC reports MINED with a `merklePath`, the broadcast handler creates a `tx_proof` and links it to the action — the proof arrives for free via the broadcast response.

| col | type | attributes |
| --- | --- | --- |
| id | bigint | GENERATED ALWAYS AS IDENTITY PRIMARY KEY |
| action_id | bigint | NOT NULL REFERENCES actions (id) UNIQUE |
| broadcast_at | timestamptz | |
| tx_status | text | |
| arc_status | integer | |
| block_hash | bytea | |
| block_height | integer | |
| merkle_path | bytea | |
| extra_info | text | |
| competing_txs | text[] | |
| created_at | timestamptz | NOT NULL DEFAULT now() |
| updated_at | timestamptz | NOT NULL DEFAULT now() |

**Constraints:**
- `UNIQUE (action_id)` — one broadcast record per action
- `CHECK block_hash IS NULL OR length(block_hash) = 32`
- `CHECK block_height IS NULL OR block_height >= 0`

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
  INSERT INTO actions (broadcast, nlocktime, description, ...)
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

If `signAndProcess: false`, this phase is deferred — see **Deferred Signing — signAction** below. The deferred path runs the full pipeline (including output promotion) but skips signing and broadcasting.

```
-- signing happens in memory (key derivation, ECDSA, script templates)
BEGIN
  UPDATE actions SET wtxid = ?, raw_tx = ? WHERE id = ?
COMMIT
```

**Database state after Phase 2:**
- `actions`: `wtxid` set, `raw_tx` set — the action is signed and ready for broadcast
- Everything else unchanged

#### Phase 3: Broadcast (managed by BroadcastQueue)

The action calls `broadcast` which creates a `broadcasts` row and conditionally posts to ARC:

```ruby
broadcast_entry = BroadcastQueue.create(action_id: id)
broadcast_entry.post! if broadcast == 'inline'
# If broadcast == 'delayed', the BroadcastQueueWorker picks it up
# If broadcast == 'none', no broadcast row is created at all
```

The `BroadcastQueue#post!` method:
1. Sets `broadcast_at` and saves (the intent is recorded)
2. POSTs to ARC (network call — outside any DB transaction)
3. Updates the row with ARC's response (tx_status, block_hash, etc.)
4. On acceptance: writes outputs to the immutable log (Phase 4)

If the process crashes between steps 1 and 3: the broadcast row has `broadcast_at` set but no `tx_status`. The worker can retry or investigate via ARC's `GET /tx/{txid}`.

If the process crashes between steps 3 and 4: the broadcast row has the ARC response. The worker can complete Phase 4 (write outputs) based on the stored response.

#### Phase 4: Promote (atomic, milliseconds — triggered by broadcast acceptance)

```
BEGIN
  INSERT INTO outputs (action_id, satoshis, vout, locking_script,
                       output_type, derivation_prefix, derivation_suffix, sender_identity_key)
  INSERT INTO spendable (output_id, action_id)   -- wallet-owned outputs only
  INSERT INTO output_baskets (output_id, basket_id, action_id)
  INSERT INTO output_details (output_id, action_id, change, description, ...)
  -- If ARC returned MINED + merklePath:
  INSERT INTO tx_proofs (wtxid, height, block_index, merkle_path, block_hash, merkle_root, raw_tx)
    ON CONFLICT (wtxid) DO UPDATE SET ...
  UPDATE actions SET tx_proof_id = ? WHERE id = ?
COMMIT
```

**Database state after Phase 4:**
- `outputs`: new rows for all transaction outputs (immutable from this point). Wallet-owned outputs have derivation fields; outbound outputs have `output_type = 'outbound'`.
- `spendable`: new rows for wallet-owned outputs only. Outbound outputs never get a spendable row (trigger enforced).
- `tx_proofs`: proof created if ARC returned MINED (proof arrives for free!)
- `actions`: `tx_proof_id` set if proof arrived with broadcast response

The new wallet-owned outputs are now live in the UTXO set. They're immediately available for the next `createAction`.

#### Broadcast Failure

If ARC rejects the transaction, the broadcast row records the rejection (tx_status = 'REJECTED', competing_txs, extra_info). The action and its inputs remain — the wallet operator can investigate and decide whether to abort or retry.

For automatic cleanup:
```
BEGIN
  DELETE FROM actions WHERE id = ?
    -- ON DELETE CASCADE removes inputs, freeing the locked UTXOs
COMMIT
```

#### Reaper: TTL Cleanup

Two classes of stale actions:

**Never signed** (deferred actions that were abandoned — have outputs but no wtxid):
```sql
-- Clean up output relationships first
DELETE FROM spendable WHERE output_id IN (
  SELECT o.id FROM outputs o JOIN actions a ON o.action_id = a.id
  WHERE a.wtxid IS NULL AND a.created_at < (now() - interval '?')
);
DELETE FROM output_baskets WHERE output_id IN (
  SELECT o.id FROM outputs o JOIN actions a ON o.action_id = a.id
  WHERE a.wtxid IS NULL AND a.created_at < (now() - interval '?')
);
DELETE FROM output_details WHERE output_id IN (
  SELECT o.id FROM outputs o JOIN actions a ON o.action_id = a.id
  WHERE a.wtxid IS NULL AND a.created_at < (now() - interval '?')
);
-- Then delete the action (CASCADE to inputs, freeing locked UTXOs)
DELETE FROM actions a
WHERE a.wtxid IS NULL
  AND a.created_at < (now() - interval '?');
```

**Never sent** (signed but never broadcast — no outputs because promotion was post-broadcast):
```sql
DELETE FROM actions a
WHERE a.wtxid IS NOT NULL
  AND a.broadcast != 'none'
  AND NOT EXISTS (SELECT 1 FROM broadcasts b WHERE b.action_id = a.id)
  AND a.created_at < (now() - interval '?')
  AND NOT EXISTS (SELECT 1 FROM outputs o WHERE o.action_id = a.id);
```

**Sent but unresolved** (broadcast row exists, no outputs — needs investigation):
```sql
SELECT a.id, a.wtxid, b.tx_status, b.broadcast_at
FROM actions a
JOIN broadcasts b ON b.action_id = a.id
WHERE NOT EXISTS (SELECT 1 FROM outputs o WHERE o.action_id = a.id)
  AND b.broadcast_at < (now() - interval '?');
-- Worker investigates: GET /tx/{txid} from ARC, then promote or abort
```

#### Proof Arrival (async, via ARC callback or polling)

```
BEGIN
  INSERT INTO tx_proofs (wtxid, height, block_index, merkle_path, block_hash, merkle_root, raw_tx)
    ON CONFLICT (wtxid) DO UPDATE SET ...
  UPDATE actions SET tx_proof_id = ? WHERE wtxid = ?
  UPDATE broadcasts SET tx_status = 'MINED', block_hash = ?, block_height = ? WHERE action_id = ?
COMMIT
```

The action's derived status transitions to `completed` (tx_proof_id is now set). Can arrive via:
- The broadcast response itself (ARC returns MINED immediately for fast blocks)
- ARC SSE events (`/events` endpoint — push-based)
- Polling ARC `GET /tx/{txid}`
- `tx_reqs` worker

#### abortAction (before broadcast)

```
BEGIN
  DELETE FROM actions WHERE id = ? AND wtxid IS NULL
    -- CASCADE deletes inputs, freeing locked UTXOs
    -- only works on unsigned actions (wtxid IS NULL)
COMMIT
```

After broadcast, abort is meaningless — the network has the transaction.

#### Deferred Signing — signAction

**When:** `createAction` is called with `signAndProcess: false`, or when any input declares `unlocking_script_length` without providing an `unlocking_script`. The wallet can't fully sign the transaction — the caller needs to provide unlocking scripts for some inputs.

**What's deferred:** Only signing and broadcasting. The deferral is about **inputs**, not outputs. The outputs are fully known at `createAction` time — they don't change between `createAction` and `signAction`.

**Deferred createAction** runs the full pipeline except signing and broadcasting:

```
BEGIN
  -- Phase 1: Lock (same as synchronous)
  INSERT INTO actions (broadcast, nlocktime, description, ...)
    -- wtxid IS NULL
  INSERT INTO inputs (action_id, output_id, vin, nsequence, description)
    ON CONFLICT (output_id) DO NOTHING RETURNING output_id

  -- Build unsigned transaction in memory
  -- (resolve inputs, assemble outputs, determine vout ordering — no signing)
  UPDATE actions SET raw_tx = unsigned_tx WHERE id = ?

  -- Promote outputs (not deferred — outputs are known now)
  INSERT INTO outputs (action_id, satoshis, vout, locking_script,
                       output_type, derivation_prefix, derivation_suffix, sender_identity_key)
  INSERT INTO spendable (output_id, action_id)
  INSERT INTO output_baskets (output_id, basket_id, action_id)
  INSERT INTO output_details (output_id, action_id, change, description, ...)
COMMIT
```

Returns `{ signable_transaction: { tx: unsigned_raw_tx, reference: action.reference } }`.

**Database state after deferred createAction:**
- `actions`: `wtxid IS NULL`, `raw_tx` has unsigned transaction bytes
- `inputs`: locked, same as synchronous Phase 1
- `outputs`: written — the wallet's outputs are in the immutable log
- `spendable`: written — outputs are immediately available for BEEF chaining (another `createAction` can spend them before the parent is signed and broadcast)

**signAction** completes the deferred transaction:

```
-- In memory: deserialize unsigned raw_tx, apply caller unlocking scripts,
-- sign remaining P2PKH inputs with derived keys
BEGIN
  UPDATE actions SET wtxid = ?, raw_tx = signed_tx WHERE id = ?
COMMIT
-- Broadcast (Phase 3 — same as synchronous path)
```

The outputs, spendable entries, baskets, and details are already written — signAction only touches the action row.

**Cleanup for abandoned deferred actions:**

If `signAction` is never called, the action sits unsigned with locked inputs and spendable outputs backed by a transaction that will never be broadcast. The reaper cleans up:

```sql
BEGIN
  -- Remove phantom outputs from the UTXO set
  DELETE FROM spendable
    WHERE output_id IN (SELECT id FROM outputs WHERE action_id = ?);
  DELETE FROM output_baskets
    WHERE output_id IN (SELECT id FROM outputs WHERE action_id = ?);
  DELETE FROM output_details
    WHERE output_id IN (SELECT id FROM outputs WHERE action_id = ?);
  -- Release locked UTXOs and remove the action
  DELETE FROM actions WHERE id = ?;
    -- CASCADE deletes inputs, freeing locked UTXOs
COMMIT
```

Output rows remain in the immutable log — orphaned but harmless. They have no spendable entry (removed), no basket, and their parent action is gone. They are invisible to the wallet and will be archived with cold partitions.

**BEEF chain failure cascade:** if a parent action fails broadcast, ARC rejects all descendant transactions. Each failed action is cleaned up independently — delete its spendable entries (removing its outputs from the UTXO set) and delete the action (cascade-deleting its inputs, freeing the locked UTXOs). No tree-walking required.

**Note:** `abortAction` (above) only works for unsigned actions that have not yet written outputs — it relies on a clean CASCADE. For deferred actions that have written outputs, use the reaper cleanup path which explicitly removes the output relationships first.

#### internalizeAction (incoming)

```
BEGIN
  INSERT INTO tx_proofs (wtxid, height, ...) ON CONFLICT DO UPDATE ...
  INSERT INTO actions (tx_proof_id, wtxid, outgoing: false, broadcast: 'none', ...)
  INSERT INTO outputs (action_id, satoshis, vout, locking_script,
                       output_type, derivation_prefix, derivation_suffix, sender_identity_key)
  INSERT INTO spendable (output_id, action_id)
  INSERT INTO output_baskets (output_id, basket_id, action_id)
  INSERT INTO output_details (output_id, action_id, ...)
COMMIT
```

Incoming actions arrive with BEEF — the proof is already available. The action is born with `tx_proof_id` set (derived status: completed). Outputs go directly into the immutable log and the UTXO set in one atomic transaction. No broadcast needed.

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
| **actions** | createAction | wtxid (sign), tx_proof_id (proof) | abort, reaper | Mutable — the lifecycle entity |
| **inputs** | Phase 1 (lock) | never | CASCADE from action delete | Born and dies with its action |
| **broadcasts** | Phase 3 (broadcast) | ARC response updates | CASCADE from action delete | Broadcast lifecycle |
| **outputs** | Phase 4 / deferred Phase 1 / internalize | **never** | **never** | **Immutable log** |
| **spendable** | Phase 4 / deferred Phase 1 / internalize | never | spend / relinquish / reaper | The wallet — INSERT/DELETE only |
| **output_baskets** | Phase 4 / deferred Phase 1 / internalize | basket move | relinquish / reaper | Mutable membership |
| **output_details** | Phase 4 / deferred Phase 1 / internalize | never | reaper | Immutable metadata (until reaped) |
| **tx_proofs** | proof arrival / internalize | upsert on re-proof | never | Append-mostly |

---

## 4. Baskets

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

## 5. Outputs

The immutable log. A permanent, append-only record of every output the wallet has ever participated in — both wallet-owned outputs (with derivation data) and outbound payments (with `output_type = 'outbound'`). **Immutable** — never UPDATE'd, never DELETE'd. Provenance survives in history until cold partitions are archived.

Derivation data (spending authority) lives here because it's a fact about the output, recorded when the key is derived. This is separate from spendability — an output can have derivation data without being in the UTXO set.

The UTXO set (what's spendable now) is the `spendable` table. Queries enter through `spendable` and PK-join back here for data — the outputs table is never full-scanned.

At scale, partition by id range. Old partitions where all outputs have been spent (no remaining `spendable` rows) can be detached and archived.

| col | type | attributes |
| --- | --- | --- |
| id | bigint | GENERATED ALWAYS AS IDENTITY PRIMARY KEY |
| action_id | bigint | NOT NULL REFERENCES actions (id) |
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

**Note:** No `updated_at` — immutable rows have no updates. No `basket_id` — basket membership is in `output_baskets`. No `wtxid` — derived via `output.action.wtxid`. Column order optimized for alignment: 8-byte columns first, then variable-width, with 4-byte `vout` tucked after `locking_script` to reduce padding.

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

## 6. Spendable

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

## 7. Output Details

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

## 8. Output Baskets

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

## 9. Inputs

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

## 10. Labels

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

## 11. Action Labels

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

## 12. Tags

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

## 13. Output Tags

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

## 14. Certificates

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

## 15. Certificate Fields

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

## 16. Tx Reqs

Proof request lifecycle. Tracks "I need a proof for this txid" — a work queue for the proof-harvesting worker.

| col | type | attributes |
| --- | --- | --- |
| id | bigint | GENERATED ALWAYS AS IDENTITY PRIMARY KEY |
| tx_proof_id | bigint | REFERENCES tx_proofs (id) |
| wtxid | bytea | NOT NULL UNIQUE |
| status | text | NOT NULL DEFAULT 'unmined' |
| attempts | integer | NOT NULL DEFAULT 0 |
| notified | bool | NOT NULL DEFAULT false |
| history | text | |
| notify | text | |
| batch | text | |
| raw_tx | bytea | |
| input_beef | bytea | |
| created_at | timestamptz | NOT NULL DEFAULT now() |
| updated_at | timestamptz | NOT NULL DEFAULT now() |

**Constraints:**
- `CHECK length(wtxid) = 32`
- `CHECK status IN ('unmined', 'completed', 'failed')`
- `CHECK attempts >= 0`

**Indexes:**
- `idx_tx_reqs_status` on `(status)` — worker polling

```ruby
class Wallet::TxReq < Sequel::Model
  many_to_one :tx_proof
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

## Key Queries

**Spendable outputs in a basket** — the hot path for `createAction` auto-funding. Enters through `spendable` (the wallet, in memory), PK-joins to `outputs` (the log) for data:

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

**Stale action recovery** — find prepared actions (signed, inputs locked, no outputs yet) older than threshold, excluding nosend:

```sql
DELETE FROM actions a
WHERE a.wtxid IS NOT NULL
  AND a.broadcast != 'none'
  AND a.created_at < (now() - interval '5 minutes')
  AND NOT EXISTS (SELECT 1 FROM outputs o WHERE o.action_id = a.id);
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
- **Soft delete:** Removed from baskets, labels, tags, certificates, action_labels, output_tags. Plain UNIQUE constraints replaced partial indexes. Hard delete for cleanup. Outputs are never deleted (immutable log).
- **`relinquishOutput`:** DELETE the `spendable` row (remove from UTXO set). DELETE the `output_baskets` row (remove from basket). The output row stays in the log forever.
- **Default basket:** No basket assignment = default basket (implicit). `listOutputs(basket: 'default')` queries spendable outputs with no `output_baskets` row. `CHECK name != 'default'` prevents explicit creation of a 'default' basket entity.
- **Derivation data placement:** On `outputs`, not `spendable`. Derivation data is a fact about the output (recorded when the key is derived), not a statement of spendability. This preserves the state transition model: output rows record spending authority, spendable rows declare availability. Two facts, two moments in time.
- **`actions.satoshis`:** Dropped. Derivable from `SUM(outputs.satoshis)`. No BRC-100 method returns it at the action level.
- **`actions.reference`:** UUID type (was text). NOT NULL with `gen_random_uuid()` default.

---

## BRC-100 Transaction Operations Reference

**Creation:** `createAction` creates an Action (a Bitcoin transaction + metadata). Requires at least one input or output. Inputs require `inputBEEF` for SPV context. Outputs without `basket` are untracked. Can return a `signableTransaction` reference for deferred signing.

**Signing:** `signAction` completes a deferred transaction. The caller provides unlocking scripts for inputs they control; the wallet signs remaining P2PKH inputs with derived keys. Outputs were already written during `createAction` — `signAction` only updates the action row (wtxid, signed raw_tx) and triggers broadcast. See **Deferred Signing — signAction** in the lifecycle section.

**Aborting:** `abortAction` cancels an in-progress action. Cascade-deletes inputs, releasing claimed outputs.

**Internalization:** `internalizeAction` accepts incoming BEEF, verifies proofs, creates output rows for outputs the wallet controls.

**Listing:** `listActions` queries by labels. `listOutputs` queries by basket/tags. Both are read-only with pagination.

**Relinquishment:** `relinquishOutput` releases an output from wallet tracking, even if unspent.

**Tags vs Labels:** Labels categorize actions (used with `listActions`). Tags categorize outputs (used with `listOutputs`). Both are purely organizational.
