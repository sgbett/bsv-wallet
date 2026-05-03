# Schema Integrity Constraints — Working Document

## General Principles

1. **The database is the last line of defense.** Every invariant enforced in code must be backed by a database constraint. Code can be bypassed, refactored, or have bugs. The schema cannot be bypassed.
2. **NOT NULL is the default stance.** A column should be nullable only with an explicit reason. "We might not have this value yet" is a valid reason; "we didn't think about it" is not.
3. **CHECK constraints encode cross-column invariants.** If column B is meaningless without column A, express that relationship as a CHECK constraint.
4. **Binary fields have known sizes.** A wtxid is always 32 bytes. A block hash is always 32 bytes. Encode these as CHECK constraints.
5. **Range constraints prevent nonsense.** Satoshis cannot be negative. Vout cannot be negative. Block height cannot be negative.
6. **Constraints should not break the action lifecycle.** The four-phase lifecycle (lock → sign → broadcast → promote) means some columns start NULL and are filled later. Constraints must accommodate this progression.

---

## Legend

- ✅ — constraints are adequate, nothing to do
- ❌ — needs work, see Needed column

---

## Table-by-Table Audit

### 1. tx_proofs

| Column | Type | Status | Needed |
|--------|------|--------|--------|
| id | bigint PK | ✅ | |
| wtxid | bytea NOT NULL UNIQUE | ❌ | CHECK `length(wtxid) = 32` |
| height | integer, nullable | ❌ | CHECK `merkle_path IS NULL OR height IS NOT NULL` |
| block_index | integer, nullable | ✅ | |
| merkle_path | bytea, nullable | ✅ | |
| raw_tx | bytea, nullable | ❌ | NOT NULL, CHECK `length(raw_tx) >= 189` |
| block_hash | bytea, nullable | ❌ | CHECK `block_hash IS NULL OR length(block_hash) = 32` |
| merkle_root | bytea, nullable | ❌ | CHECK `merkle_root IS NULL OR length(merkle_root) = 32` |
| created_at | timestamptz NOT NULL | ✅ | |
| updated_at | timestamptz NOT NULL | ✅ | |

**merkle_path → height:** A merkle path without a block height is structurally nonsensical. The CHECK enforces: if you have a proof, you must know what block it's in. The reverse is allowed — ARC can report a block height (MINED status) before the merkle path is available.

**raw_tx NOT NULL, >= 189 bytes:** Every tx_proof must have the raw transaction. The `"\x00".b` placeholder in engine code is dead code — remove it. 189 bytes is the minimum 1-in/1-out P2PKH transaction: 25-byte locking script + 68-byte minimum DER signature + 33-byte compressed pubkey + 36-byte outpoint + 27-byte overhead.

---

### 2. actions

| Column | Type | Status | Needed |
|--------|------|--------|--------|
| id | bigint PK | ✅ | |
| tx_proof_id | bigint FK, nullable | ✅ | |
| wtxid | bytea, nullable, UNIQUE WHERE NOT NULL | ❌ | CHECK `wtxid IS NULL OR length(wtxid) = 32` |
| reference | text UNIQUE DEFAULT gen_random_uuid() | ❌ | ALTER type to uuid, NOT NULL, change default to UUIDv7 |
| outgoing | boolean NOT NULL | ✅ | |
| satoshis | bigint, nullable | ❌ | DROP COLUMN |
| description | text, nullable | ❌ | NOT NULL, CHECK `length(description) BETWEEN 5 AND 50` |
| version | integer, nullable | ✅ | |
| nlocktime | bigint NOT NULL DEFAULT 0 | ❌ | CHECK `nlocktime >= 0` |
| broadcast | broadcast_intent NOT NULL | ✅ | |
| raw_tx | bytea, nullable | ❌ | CHECK `(wtxid IS NULL) = (raw_tx IS NULL)` |
| input_beef | bytea, nullable | ✅ | |
| created_at | timestamptz NOT NULL | ✅ | |
| updated_at | timestamptz NOT NULL | ✅ | |

| Index | Status | Needed |
|-------|--------|--------|
| UNIQUE on wtxid (partial, WHERE NOT NULL) | ✅ | |
| UNIQUE on reference | ✅ | serves as B-tree index for lookups |
| INDEX on broadcast | ✅ | |

**satoshis DROP:** Derivable from `SUM(outputs.satoshis)`. Not returned by any BRC-100 method at the action level. No query depends on it.

**wtxid/raw_tx parity:** `sign_action` always sets both together. An action is either unsigned (both NULL) or signed (both set).

**description NOT NULL:** The engine already validates 5-50 chars. The database should enforce it too.

**reference UUIDv7:** Currently `gen_random_uuid()` which produces UUIDv4 (random). Random UUIDs fragment B-tree indexes — each insert lands at a random leaf page, causing splits and poor cache locality. UUIDv7 is time-ordered, so inserts always append to the right edge of the tree. The reference field is used for deferred signing lookups (`find_action(reference:)`) before a wtxid exists. PostgreSQL 17+ has `uuidv7()` via pgcrypto; for earlier versions, generate application-side.

---

### 3. broadcasts

| Column | Type | Status | Needed |
|--------|------|--------|--------|
| id | bigint PK | ✅ | |
| action_id | bigint NOT NULL UNIQUE FK | ✅ | |
| broadcast_at | timestamptz, nullable | ✅ | |
| tx_status | text, nullable | ✅ | |
| arc_status | integer, nullable | ✅ | |
| block_hash | bytea, nullable | ❌ | CHECK `block_hash IS NULL OR length(block_hash) = 32` |
| block_height | integer, nullable | ❌ | CHECK `block_height IS NULL OR block_height >= 0` |
| merkle_path | bytea, nullable | ✅ | |
| extra_info | text, nullable | ✅ | |
| competing_txs | text[], nullable | ✅ | |
| created_at | timestamptz NOT NULL | ✅ | |
| updated_at | timestamptz NOT NULL | ✅ | |

---

### 4. baskets

| Column | Type | Status | Needed |
|--------|------|--------|--------|
| id | bigint PK | ✅ | |
| name | text NOT NULL, partial UNIQUE | ❌ | CHECK `length(name) BETWEEN 1 AND 300`, CHECK `name != 'default'`, convert to plain UNIQUE |
| target_count | integer, nullable | ❌ | CHECK `target_count IS NULL OR target_count >= 0` |
| target_value | integer, nullable | ❌ | CHECK `target_value IS NULL OR target_value >= 0` |
| created_at | timestamptz NOT NULL | ✅ | |
| updated_at | timestamptz NOT NULL | ✅ | |
| deleted_at | timestamptz, nullable | ❌ | DROP COLUMN |

---

### 5. outputs

| Column | Type | Status | Needed |
|--------|------|--------|--------|
| id | bigint PK | ✅ | |
| action_id | bigint FK, nullable (SET NULL) | ✅ | |
| satoshis | bigint NOT NULL | ❌ | CHECK `satoshis >= 0` |
| created_at | timestamptz NOT NULL | ✅ | |
| locking_script | bytea, nullable | ❌ | NOT NULL, CHECK `length(locking_script) >= 1` |
| vout | integer NOT NULL | ❌ | CHECK `vout >= 0` |
| output_type | (does not exist) | ❌ | ADD enum column `output_type` (values: `'root'`, `'change'`), nullable, DEFAULT NULL |
| sender_identity_key | text, nullable | ❌ | CHECK: see cross-column constraints below |
| derivation_prefix | text, nullable | ❌ | CHECK: see cross-column constraints below |
| derivation_suffix | text, nullable | ❌ | CHECK: see cross-column constraints below |

**locking_script NOT NULL:** Every output has a locking script. The engine always provides one. No valid state exists without one.

**output_type enum:** NULL = normal derived output. `'root'` = funded directly to identity key (import_utxo, legacy P2PKH). `'change'` = wallet's own change output. Replaces the `change` boolean on `output_details`.

**Cross-column constraints:**
```sql
-- Derived outputs (output_type IS NULL) must provide all derivation fields
CHECK (output_type IS NOT NULL OR derivation_prefix IS NOT NULL)
CHECK (output_type IS NOT NULL OR derivation_suffix IS NOT NULL)
CHECK (output_type IS NOT NULL OR sender_identity_key IS NOT NULL)

-- Root/change outputs must NOT have derivation fields
CHECK (output_type IS NULL OR derivation_prefix IS NULL)
CHECK (output_type IS NULL OR derivation_suffix IS NULL)
CHECK (output_type IS NULL OR sender_identity_key IS NULL)
```

To omit derivation data you must explicitly declare the output as `'root'` or `'change'`. To provide derivation data you must leave `output_type` NULL. No other combination is valid.

---

### 6. spendable

| Column | Type | Status | Needed |
|--------|------|--------|--------|
| id | bigint PK | ✅ | |
| output_id | bigint NOT NULL UNIQUE FK | ✅ | |
| action_id | bigint FK CASCADE, nullable | ❌ | NOT NULL |

---

### 7. output_details

| Column | Type | Status | Needed |
|--------|------|--------|--------|
| id | bigint PK | ✅ | |
| output_id | bigint NOT NULL UNIQUE FK | ✅ | |
| action_id | bigint FK CASCADE, nullable | ❌ | NOT NULL |
| change | boolean NOT NULL | ❌ | DROP COLUMN — replaced by `outputs.output_type = 'change'` |
| type | text, nullable | ✅ | |
| purpose | text, nullable | ✅ | |
| provided_by | text, nullable | ✅ | |
| description | text, nullable | ✅ | |
| custom_instructions | text, nullable | ✅ | |
| script_length | integer, nullable | ✅ | |
| script_offset | integer, nullable | ✅ | |

---

### 8. output_baskets

| Column | Type | Status | Needed |
|--------|------|--------|--------|
| id | bigint PK | ✅ | |
| output_id | bigint NOT NULL UNIQUE FK | ✅ | |
| basket_id | bigint NOT NULL FK | ✅ | |
| action_id | bigint FK CASCADE, nullable | ❌ | NOT NULL |
| created_at | timestamptz NOT NULL | ✅ | |
| updated_at | timestamptz NOT NULL | ✅ | |

---

### 9. inputs

| Column | Type | Status | Needed |
|--------|------|--------|--------|
| id | bigint PK | ✅ | |
| action_id | bigint NOT NULL FK CASCADE | ✅ | |
| output_id | bigint NOT NULL FK | ✅ | |
| vin | integer NOT NULL | ❌ | CHECK `vin >= 0` |
| nsequence | bigint NOT NULL DEFAULT 4294967295 | ❌ | CHECK `nsequence BETWEEN 0 AND 4294967295` |
| description | text, nullable | ✅ | |
| created_at | timestamptz NOT NULL | ✅ | |
| updated_at | timestamptz NOT NULL | ✅ | |

---

### 10. labels

| Column | Type | Status | Needed |
|--------|------|--------|--------|
| id | bigint PK | ✅ | |
| label | text NOT NULL, partial UNIQUE | ❌ | CHECK `length(label) BETWEEN 1 AND 300`, convert to plain UNIQUE |
| created_at | timestamptz NOT NULL | ✅ | |
| updated_at | timestamptz NOT NULL | ✅ | |
| deleted_at | timestamptz, nullable | ❌ | DROP COLUMN |

---

### 11. action_labels

| Column | Type | Status | Needed |
|--------|------|--------|--------|
| id | bigint PK | ✅ | |
| action_id | bigint NOT NULL FK | ❌ | ADD `ON DELETE CASCADE` |
| label_id | bigint NOT NULL FK | ✅ | |
| created_at | timestamptz NOT NULL | ✅ | |
| updated_at | timestamptz NOT NULL | ✅ | |
| deleted_at | timestamptz, nullable | ❌ | DROP COLUMN |

**CASCADE:** Deleting an action should cascade to its label associations. Currently the FK has no ON DELETE — deleting an action with labels fails.

---

### 12. tags

| Column | Type | Status | Needed |
|--------|------|--------|--------|
| id | bigint PK | ✅ | |
| tag | text NOT NULL, partial UNIQUE | ❌ | CHECK `length(tag) BETWEEN 1 AND 300`, convert to plain UNIQUE |
| created_at | timestamptz NOT NULL | ✅ | |
| updated_at | timestamptz NOT NULL | ✅ | |
| deleted_at | timestamptz, nullable | ❌ | DROP COLUMN |

---

### 13. output_tags

| Column | Type | Status | Needed |
|--------|------|--------|--------|
| id | bigint PK | ✅ | |
| output_id | bigint NOT NULL FK | ✅ | |
| tag_id | bigint NOT NULL FK | ✅ | |
| created_at | timestamptz NOT NULL | ✅ | |
| updated_at | timestamptz NOT NULL | ✅ | |
| deleted_at | timestamptz, nullable | ❌ | DROP COLUMN |

---

### 14. certificates

| Column | Type | Status | Needed |
|--------|------|--------|--------|
| id | bigint PK | ✅ | |
| type | text NOT NULL | ✅ | |
| subject | text, nullable | ✅ | |
| serial_number | text NOT NULL | ✅ | |
| certifier | text NOT NULL | ✅ | |
| verifier | text, nullable | ✅ | |
| revocation_outpoint | text, nullable | ✅ | |
| signature | text, nullable | ✅ | |
| created_at | timestamptz NOT NULL | ✅ | |
| updated_at | timestamptz NOT NULL | ✅ | |
| deleted_at | timestamptz, nullable | ❌ | DROP COLUMN |

---

### 15. certificate_fields

| Column | Type | Status | Needed |
|--------|------|--------|--------|
| id | bigint PK | ✅ | |
| certificate_id | bigint NOT NULL FK CASCADE | ✅ | |
| name | text NOT NULL | ✅ | |
| value | text, nullable | ✅ | |
| master_key | text, nullable | ✅ | |
| created_at | timestamptz NOT NULL | ✅ | |
| updated_at | timestamptz NOT NULL | ✅ | |

---

### 16. tx_reqs

| Column | Type | Status | Needed |
|--------|------|--------|--------|
| id | bigint PK | ✅ | |
| tx_proof_id | bigint FK, nullable | ✅ | |
| wtxid | bytea NOT NULL UNIQUE | ❌ | CHECK `length(wtxid) = 32` |
| status | text NOT NULL DEFAULT 'unmined' | ❌ | CHECK `status IN ('unmined', 'completed', 'failed')` |
| attempts | integer NOT NULL DEFAULT 0 | ❌ | CHECK `attempts >= 0` |
| notified | boolean NOT NULL | ✅ | |
| history | text, nullable | ✅ | |
| notify | text, nullable | ✅ | |
| batch | text, nullable | ✅ | |
| raw_tx | bytea, nullable | ✅ | |
| input_beef | bytea, nullable | ✅ | |
| created_at | timestamptz NOT NULL | ✅ | |
| updated_at | timestamptz NOT NULL | ✅ | |

---

### 17. settings

| Column | Type | Status | Needed |
|--------|------|--------|--------|
| id | bigint PK | ✅ | |
| key | text NOT NULL UNIQUE | ✅ | |
| value | text, nullable | ✅ | |
| created_at | timestamptz NOT NULL | ✅ | |
| updated_at | timestamptz NOT NULL | ✅ | |

---

## Resolved Questions

1. **actions.satoshis → DROP COLUMN.** Derivable via `SUM(outputs.satoshis)` for the action_id. Not returned by any BRC-100 method at the action level. Denormalized with no query justification — remove it entirely.

2. **Minimum raw_tx length: 189 bytes.** The smallest valid Bitcoin transaction is a single-input, single-output P2PKH: 25-byte P2PKH script + 68-byte minimum DER signature + 33-byte compressed pubkey + 36-byte outpoint + 27-byte overhead = 189 bytes. Anything smaller is not a real transaction.

3. **One migration (004).** All additive constraints, no shape changes. Database can be rebuilt — no production data to protect.

4. **No backfill needed.** Fresh database only. Migration 003's nullable action_id columns (spendable, output_details, output_baskets) will just be altered to NOT NULL directly.

5. **Remove `"\x00".b` raw_tx fallback.** Dead code — `import_utxo` always has raw_tx from WoC. Make raw_tx a required parameter (no default). The tx_proofs.raw_tx NOT NULL constraint will catch any future caller that tries to skip it.
