# Schema Intent

What the wallet's database is trying to express. Derived from the two
clean-room design sessions (`20260501_wallet-schema-clean-room-design`
and `20260503_bootstrap-schema-constraints-cli`). The intent below is
what the design says the schema should be — the live migrations may or
may not match.

---

## Cross-cutting principles

These ran through every table-level decision. They are the architectural
stance the design takes, not implementation tactics.

**1. Outputs are the ledger entries; transactions are events.** The wallet
is "an accounting ledger for a single participant" with cryptographic
settlement receipts. From the transcripts: "Outputs are the ledger
entries. Transactions are events." A Bitcoin transaction is bytes on the
wire; what the wallet records is an *Action* — the spec's word, used in
every BRC-100 method. The table is named accordingly.

**2. State is derived from structure, not stored as flags.** The TS SDK
suffered from `state`, `spendable`, `isDeleted`, `spentBy`, `noSend`
flags that could disagree with each other. The intent is: "you *cannot*
have inconsistent state because the state is derived, not stored." An
output's spendability is the presence of a row in `spendable`. A
broadcast's progress is the presence of a row in `broadcasts`. An
action's status is computed from `wtxid`, `tx_proof_id`, `broadcast`,
and the existence of outputs/broadcast rows. There is no status column.

**3. Binary all the way through.** PostgreSQL `bytea` for everything
hash-shaped: `wtxid`, `merkle_path`, `block_hash`, `merkle_root`, `raw_tx`,
`locking_script`. Ruby's binary-encoded strings carry raw bytes natively;
hex encode/decode only happens at the consumer boundary. "Killed the
TypeScript pattern at the source."

**4. The outputs table is the log; the spendable table is the wallet.**
The big realisation of the design sessions. The `outputs` table is
INSERT-only, ever-growing, accessed by primary key — never scanned. The
`spendable` table is small (proportional to current UTXO count), gets
INSERTs and DELETEs, lives in buffer cache, and is the entry point for
every hot-path query. Two different access patterns; two different tables.

**5. Immutability where possible, locality of mutation where not.** The
big growing tables (`outputs`, `tx_proofs`) are INSERT-only — zero dead
tuples, zero vacuum pressure on the hottest tables. Mutation is
concentrated in small tables (`spendable`, `inputs`, `output_baskets`,
`broadcasts`) where the churn is naturally bounded and vacuum is cheap.

**6. Structural relationships replace flags.** A claim on an output is
the existence of an `inputs` row (with `UNIQUE (output_id)` — the
structural lock). Basket assignment is the existence of an
`output_baskets` row. The "default" basket is the *absence* of a row,
not a row with a special name. Hence the CHECK that forbids creating a
basket literally named `'default'`. This pattern recurs: presence of a
row = explicit state, absence = the natural/default state.

**7. No user table; the wallet is an engine.** The TS SDK's `user_id`
columns are an artefact of its multi-tenant `StorageServer` model. The
intent here is the opposite: "We are staking a claim for the high-throughput
server wallet." Authentication is BRC-100's `isAuthenticated` /
`waitForAuthentication` interface — a layer *above* the wallet engine,
not embedded in its schema. Multi-tenant hosting is a deployment
concern that would belong in a different service.

**8. Two fast DB transactions, one network call between them.** The
synchronous wallet's lifecycle never holds a database transaction open
across a network call. The design splits createAction into:

   1. **Lock** — create the action (unsigned, inputs locked) in a single
      atomic commit. Milliseconds.
   2. **Sign** — derive keys, evaluate templates, ECDSA sign in memory;
      commit `wtxid` + `raw_tx` to the action. Independently deferrable
      (the `signableTransaction` flow).
   3. **Broadcast** — network call outside any DB transaction.
   4. **Promote** — on success, write outputs/spendable/baskets in a
      single atomic commit. On failure, delete the action and let CASCADE
      free its inputs.

**9. The database is the last line of defence, not the first.** "Every
rule that we are baking into the code we should be backing with database
constraints." Code-level validation gives clean errors; database CHECKs,
FKs, UNIQUEs, and triggers make bad data structurally impossible.

**10. Hard delete, not soft delete.** The original `deleted_at` columns
were a TS-SDK artefact of its cross-wallet *synchronisation* model. With
no sync, soft delete adds complexity without value. Drop the column,
DELETE the row.

**11. American English in identifiers** (overriding the global British
preference) to align with BRC-100's spec names.

---

## The `broadcast_intent` enum and the two lifecycles

The `broadcast_intent` enum (`'delayed'`, `'inline'`, `'none'`) on `actions`
encodes one structural fact: *should the daemon ever try to push this
action to the network?* `'delayed'` and `'inline'` say yes (with two
execution models for who does the pushing); `'none'` says no.

HLR #183 made this distinction load-bearing. Before #183, `'none'` was
conflated with BRC-100's `noSend` chained-send primitive — the wallet
treated "user asked us not to broadcast yet" and "this action is
permanently not destined for the network" as the same code path. They are
two different concerns. The chained-send concept is deferred to issue #192
(see `reference/send_or_nosend.md`); the `'none'` enum value is preserved
for the wallet's **internal path**:

- `internalize_action` accepts incoming BEEF that's already on-chain.
- `import_utxo` imports a root-key UTXO that's already on-chain.
- `generate_receive_address` / `internalize_wbikd_utxo` manage wbikd
  address slots (control plane, not network).
- `send_payment` returns an Atomic BEEF for out-of-band delivery to a
  recipient — the wallet author signs and persists the action, but the
  recipient (not the wallet) is responsible for broadcast.

All four callers commit Phases 1, 2, and 4 in a single atomic transaction
inside `create_action`. There is no Phase 3 because the wallet is never
going to call ARC for these actions. Output rows are written with
`promoted = true` directly; spendable rows are inserted alongside. No
broadcasts row is ever created. The derived status for these actions is
`:internal`.

This is structurally different from a send-path action that has been
**signed but not yet broadcast-accepted**. That state — `wtxid IS NOT
NULL`, `broadcast IN ('delayed', 'inline')`, outputs present but
`promoted = false`, broadcasts row exists with `tx_status IS NULL` — is
the daemon's working set, the rows the push-discovery loop and poll
loop drive through ARC. The `promoted` flag on outputs is the
single-shot membership marker that separates "in the log, not in the
UTXO set" from "in the log and in the UTXO set."

Two enum values, two lifecycles. The split is intentional and surfaces
in every query that touches actions: `Store#pending_pushes`,
`Store#pending_polls`, `Store#pending_proofs`, the reaper, the
derived-status table. Each of those filters on `broadcast != 'none'`
because internal-path actions live outside the network lifecycle.

## Per table

Each section describes the current synchronous send-path / internal-path
implementation per HLR #183 / PR #197. Where the original transcript
intent was implemented and then stripped to be re-implemented in a
future deferred-async subsystem, the section notes the supersession and
the deferred piece is captured under **Deferred to future subsystems**
below. Per-table integrity reflects what the live schema enforces plus
what the design says it should enforce (gaps tracked at the end).

### 1. actions

**Represents:** A BRC-100 Action — the wallet's record of a Bitcoin
transaction it created or received. *Not* a transaction in the database
sense ("BEGIN/COMMIT/ROLLBACK") — that ambiguity was the reason the table
isn't called `transactions`.

**Directly stores:** A nullable `wtxid` (set when the transaction is
signed), a `reference` UUID (lookup key during deferred signing — should
be UUIDv7 for B-tree friendliness; tracked in #198), a `description`
(5–50 chars per BRC-100's `DescriptionString5to50Characters`), the
`broadcast_intent` enum, the `raw_tx`, an optional `input_beef`, and the
FK `tx_proof_id`. `version` and `nlocktime` are **not** stored — they are
the leading / trailing four bytes of `raw_tx`, derived at the interface
(#351).

**Can be derived:** The action's *status* in BRC-100 terms (unsigned,
unprocessed, sending, unproven, completed, internal, failed) is computed
from structure. The `promoted` flag on outputs (see §3) distinguishes
"signed, in flight" from "broadcast accepted":

| Structural state | Derived status |
|------------------|----------------|
| `wtxid IS NULL` | unsigned |
| `wtxid IS NOT NULL`, `tx_proof_id IS NOT NULL` | completed |
| `wtxid IS NOT NULL`, `broadcast = 'none'`, no proof | internal |
| `wtxid IS NOT NULL`, send path, at least one promoted output, no proof | unproven |
| `wtxid IS NOT NULL`, send path, broadcast `tx_status = 'REJECTED'` | failed |
| `wtxid IS NOT NULL`, send path, broadcasts row exists, no promoted outputs | sending |
| `wtxid IS NOT NULL`, send path, no broadcasts row | unprocessed |

(`:internal` replaces the earlier `:nosend` label; HLR #183 renamed it
to disambiguate from BRC-100's chained-send concept, which is deferred
to #192.)

The `satoshis` total is derivable from `SUM(outputs.satoshis)` for the
action — explicitly dropped from the table during the constraints
session.

**State and transitions:** The action is the only "lifecycle" entity in
the schema. It transitions through the four phases on the **send path**
(unsigned → signed-and-staged → sent → promoted/proven) or commits
Phases 1+2+4 in a single atomic transaction on the **internal path**.
Each transition is a row UPDATE on this table (mutable by design — it
owns the lifecycle).

**Cleanup:** `abortAction` (pre-broadcast) and `fail_broadcast_action`
(terminal ARC rejection) both delete the action. Under #189
`outputs.action_id` is ON DELETE RESTRICT, so dependent output rows are
cleared explicitly first; CASCADE on `inputs.action_id` then frees the
locked UTXOs. The reaper handles the same shapes for stale TTL.

**Integrity:**
- `description` NOT NULL, length 5–50 — BRC-100 mandate.
- `wtxid` length must be exactly 32 bytes when present.
- `(wtxid IS NULL) = (raw_tx IS NULL)` — wtxid and raw_tx are written
  together at signing; one without the other is nonsensical.
- `broadcast` enum constrained to `delayed | inline | none` (Postgres
  ENUM type; CHECK constraint on SQLite).
- `reference` is `uuid` not `text` — "16 bytes fixed storage instead of
  37 bytes variable, native comparison operators, and the database
  rejects malformed values" — defaulted via `gen_random_uuid()` and
  NOT NULL with a UNIQUE index. UUIDv7 to avoid B-tree page splits is
  tracked in #198.

### 2. broadcasts

**Represents:** Evidence that a send-path action has been submitted to
ARC, plus the captured response lifecycle (ARC's `RECEIVED →
SEEN_ON_NETWORK → MINED → IMMUTABLE` enum, plus error/double-spend
terminal states). Internal-path actions (`broadcast = 'none'`) never
produce a broadcasts row.

**Directly stores:** `action_id` (UNIQUE — one broadcast attempt per
action), `broadcast_at` (NULL = push-discovery candidate; NOT NULL =
poll-discovery candidate), `tx_status` (the ARC string enum),
`arc_status` (numeric), `block_hash`, `block_height`, `merkle_path`,
`extra_info`, `competing_txs` (string array).

**Why it's its own table, not columns on actions:** A single broadcast
row binds together "intent to broadcast" + "result from ARC" + "merkle
path when mined." The row's *existence* derives the action's "sending"
status; its `tx_status` field derives "rejected/competing/proven."
Crucially, the table can be updated independently of `actions`.

**State transitions:** Row inserted at the Phase 2 commit alongside
sign, with `broadcast_at IS NULL`. The push-discovery loop stamps
`broadcast_at` immediately before POSTing to ARC, moving the row from
the push set to the poll set. ARC response fields are written by
`Engine::Broadcast#submit` (inline) or `#poll_status` (delayed). When
ARC reports MINED with a `merklePath`, that data feeds straight into
`tx_proofs` and `actions.tx_proof_id` gets linked, with Phase 4 firing
in the same transaction.

**Integrity:**
- `action_id` NOT NULL UNIQUE — at most one broadcast row per action.
- `block_hash` must be exactly 32 bytes when present.
- `block_height` must be `>= 0` when present.

Gaps tracked in #198: `tx_status` enum CHECK; constraint forbidding a
broadcasts row when `actions.broadcast = 'none'`; merkle_path/block_height
parity; `callback_token` column for SSE/webhook matching (the
event-handling machinery itself is in the deferred subsystem).

### 3. outputs (the log)

**Represents:** Every output the wallet has ever participated in,
whether ours to spend or someone else's payment. The append-only log.
"Outputs are *the most important thing* to a wallet."

**Directly stores:** `action_id` (ON DELETE RESTRICT per #189),
`satoshis`, `vout`, `locking_script`, `created_at`, `output_type`
(enum, NULL = derived output, `'root'` = root-key UTXO, `'outbound'` =
payment to someone else), `derivation_prefix`, `derivation_suffix`,
`sender_identity_key`, `promoted` (NOT NULL DEFAULT true).

A note on column placement: derivation data lives on `outputs`, not on
`spendable`. The May 3 transcript explored moving derivation to
spendable to handle outbound outputs; #65 reverted that and #66
introduced `output_type = 'outbound'` here on `outputs` to mark
payment outputs structurally. Outbound rows never get a spendable row
(enforced by a BEFORE-INSERT trigger on `spendable`).

**Change-row provenance.** Change outputs reach this table by the same
route as caller outputs: `Store#sign_action(change_outputs:)` writes
them at Phase 2 in a single atomic commit. Their derivation fields
(`derivation_prefix`, `derivation_suffix`, `sender_identity_key = self`)
are produced by the `generate_change` primitive on `Engine::Action`,
invoked from `Engine::Action.create`'s funding loop, which derives BRC-42
self-keys, templates change outputs onto the tx, distributes the surplus,
and returns the surviving change rows for the Store to persist. The primitive runs regardless of where the inputs came
from — wallet-selected (via `select_inputs` + the funding-loop top-up
path) or caller-supplied. Structurally a change row is just another
derived output (`output_type IS NULL` + all three derivation fields);
the `output_details.change` boolean is cosmetic UI metadata only (per
#66 / cross-cutting principle 6). The send-path / internal-path split
governs *when Phase 4 commits* — it does not change how or when change
rows enter `outputs`.

**Can be derived:**
- The outpoint string is `"#{action.wtxid_hex}.#{vout}"` — never stored.
- Whether an output is currently spendable: presence of a `spendable`
  row.
- Whether an output is the wallet's: `output_type IS DISTINCT FROM
  'outbound'`.
- Whether the action is incoming or outgoing: derived as
  `broadcast_intent != 'none'` (the wallet authors broadcastable actions),
  not from a stored column or anything on the output itself.

**State and transitions:** Rows are append-only with one deliberate
exception — the `promoted` flag flips false → true exactly once on the
send path at Phase 4 (structurally analogous to `actions.tx_proof_id`
flipping). Cleanup paths (`abort`, `fail_broadcast_action`, reaper)
do delete output rows, but they only ever reach rows that never made
it into the canonical UTXO set (`promoted = false`). At scale, lifecycle
exit is partition drop, not per-row DELETE.

- **Send path** writes outputs at Phase 2 with `promoted = false`.
  They become canonical UTXO set members at Phase 4 when broadcast
  acceptance flips the flag and inserts the spendable rows.
- **Internal path** (`broadcast = 'none'`) writes outputs with
  `promoted = true` and inserts spendable rows in the same Phase 1+2+4
  atomic transaction. The column default of `true` is calibrated for
  the internal path; any backfill of pre-existing rows lands in the
  post-promotion state.

**Integrity:**
- `(action_id, vout)` UNIQUE — an output is uniquely identified by its
  position in the action that created it.
- `satoshis >= 0`, `vout >= 0`.
- `locking_script` NOT NULL, length ≥ 1 — even an unspendable
  OP_RETURN-only output is 1 byte (`0x6a`).
- Cross-column constraints on derivation (per #65 / #66):
  - Typed outputs (root, outbound) must NOT have derivation fields.
  - Derived outputs (NULL type) must have all three derivation fields.
- `action_id` ON DELETE RESTRICT — outputs cannot be orphaned by an
  action delete. Cleanup paths clear dependents first; this is safe
  because cleanup only ever encounters `promoted = false` rows.

**The "log" property at scale:** the table is designed to grow forever
with bounded mutation (the single `promoted` flip plus cleanup-only
deletes). The hot path enters through `spendable` (small, in-memory)
and joins to outputs by PK only — the table is never full-scanned.

### 4. spendable (the wallet)

**Represents:** The set of outputs the wallet can currently spend.
Pure set membership — the presence of a row IS the spendable state.
Started as `output_controls`; the rename came when the design realised
"`output_controls` is the wallet! `outputs` is the log file!"

**Directly stores:** `output_id` (UNIQUE FK), `action_id` (denormalised;
ON DELETE CASCADE). No data columns. ~28 bytes per row; the entire
UTXO set lives comfortably in PostgreSQL's buffer cache.

A note on column placement: the May 3 transcript briefly moved
`output_type` and the three derivation columns onto spendable to give
outbound outputs a natural "not here" home. #65 reverted that move and
#66 introduced `output_type = 'outbound'` on `outputs`. Spendable is
pure set membership again — the trigger does the rejection work that
the column would have done structurally.

**State transitions:**
- INSERT at Phase 4 (both paths) for wallet-owned outputs only.
- DELETE on spend (after the spending action's broadcast succeeds), on
  relinquishOutput, or via CASCADE if the parent action is deleted.

**Integrity:**
- `output_id` NOT NULL UNIQUE — an output is in the UTXO set at most
  once.
- `action_id` NOT NULL with `ON DELETE CASCADE` — aborts free the lock
  in one statement.
- BEFORE-INSERT trigger `prevent_outbound_spendable` — rejects a
  spendable row referencing an output with `output_type = 'outbound'`.
  The database itself prevents the invalid state.

### 5. inputs (the lock mechanism)

**Represents:** The consumption relationship between an output and the
action that's spending it. The structural lock: "INSERT a row to lock;
DELETE to release. That IS the lock. The spending transaction
relationship IS the locking mechanism."

**Directly stores:** `action_id` (CASCADE), `output_id`, `vin`,
`nsequence`, `description` (per-input BRC-100 metadata).

**Can be derived:** The "previously called `spent_transaction_id`" link
on outputs is reconstructed by joining through `inputs`. Spendability
includes `NOT EXISTS (SELECT 1 FROM inputs WHERE output_id = ?)`.

**State transitions:**
- INSERT on Phase 1 (lock); the INSERT itself *is* the lock attempt.
- DELETE on action abort (via `ON DELETE CASCADE`).
- Permanent once the parent action proves.

**Integrity:**
- `UNIQUE (output_id)` — at most one input per output. This is the
  structural lock.
- `UNIQUE (action_id, vin)` — vin index is unique within an action.
  This composite gives free index coverage of `action_id` alone.
- `vin >= 0`, `nsequence BETWEEN 0 AND 4294967295` (default
  `4_294_967_295` = `0xFFFFFFFF` = final).

**Concurrency model:** Phase 1 uses `INSERT ... ON CONFLICT (output_id)
DO NOTHING RETURNING output_id` — "skips conflicting rows silently;
RETURNING gives you back which ones succeeded." Two concurrent
createActions that picked the same UTXO get serialised by Postgres and
one of them gets nothing back for that row.

### 6. tx_proofs (settlement evidence)

**Represents:** Merkle inclusion proof for a Bitcoin transaction. The
table is named for what it *is*, not for what it contains incidentally —
the `raw_tx` lives here for BEEF construction convenience, but the
entity is the proof.

**Directly stores:** `wtxid` (UNIQUE), `block_id` FK (per #79 — block
context lives in `blocks`, not inline), `block_index`, `merkle_path`,
`raw_tx`. The transcripts originally placed `block_hash`,
`block_height`, `merkle_root` directly on tx_proofs; #79 normalised
them into `blocks` because block-level data was being repeated across
every proof from the same block, and the chain tracker needs a single
source-of-truth for "what is the merkle root at height N?".

**Lifecycle:**
- Row is created when raw_tx is first stored (during sign for actions
  we author, or during BEEF processing for ancestors).
- `block_id` and `merkle_path` land later when ARC reports MINED or a
  TSC proof is fetched.

**Integrity:**
- `wtxid` NOT NULL UNIQUE, exactly 32 bytes.
- `raw_tx` NOT NULL, minimum 20 bytes (the structural floor for a
  1-output transaction with a 1-byte locking script).

Gap tracked in #198: `merkle_path IS NULL OR block_id IS NOT NULL` —
"either we have no merkle path, OR we have the block context." The
asymmetric direction is intentional: we may legitimately know the
block before the merkle path arrives.

### 7. baskets

**Represents:** A named group of outputs with optional replenishment
policy (`target_count`, `target_value`).

**Directly stores:** `name`, `target_count`, `target_value`.

**Integrity:**
- `UNIQUE (name)` — global namespace (we ripped out the `user_id`
  composite when the user table was removed).
- `length(name) BETWEEN 1 AND 300` — BRC-100's
  `BasketStringUnder300Characters`.
- `name != 'default'` — "the default should just be" the absence of an
  `output_baskets` row; creating a literal `'default'` basket would
  create ambiguity, so the database forbids it.
- `target_count >= 0`, `target_value >= 0`.
- No `deleted_at` — hard delete only.

### 8. output_baskets

**Represents:** Membership of an output in a basket. Absence of a row
means default basket.

**Directly stores:** `output_id` (UNIQUE — one basket at a time),
`basket_id`, `action_id` (denormalised CASCADE), `created_at`,
`updated_at`.

**State transitions:** INSERT for explicit assignment; UPDATE
`basket_id` to move; DELETE to relinquish or revert to default.
"Moving to a named basket = INSERT into output_baskets. Moving back to
default = DELETE from output_baskets." (The engine treats
`basket: 'default'` as a no-op rather than inserting a row.)

**Integrity:** `output_id` NOT NULL UNIQUE; `action_id` NOT NULL CASCADE.

### 9. output_details

**Represents:** Display- and application-level metadata for an output —
descriptions, custom instructions, script offset/length, the BRC-100
"providedBy"/"purpose" hints, plus a `change` boolean retained as
cosmetic UI metadata. The structural marker for "not ours" is
`output_type = 'outbound'` on `outputs` (per #66); the `change`
boolean is purely for display ("this output was change from a
transaction you sent") and never participates in selection or
constraints.

**Directly stores:** `output_id` (UNIQUE FK), `description`,
`custom_instructions`, `purpose`, `provided_by`, `type`,
`script_length`, `script_offset`, `change`, `action_id` (denormalised
CASCADE).

**Lifecycle:** Optional one-to-one with outputs; never participates in
the hot path; never queried against.

### 10. labels, action_labels

**Represents:** Action-level labels (BRC-100's "transaction-level labels
categorize entire transactions").

**Integrity:**
- `labels.label` UNIQUE, length 1–300 (BRC-100's
  `LabelStringUnder300Characters`).
- `action_labels` UNIQUE `(action_id, label_id)`; `action_id` ON DELETE
  CASCADE (the constraint session caught this: "deleting an action
  with labels would currently fail").
- No `deleted_at` on either table.

### 11. tags, output_tags

**Represents:** Output-level tags (per-output classification).

**Integrity:**
- `tags.tag` UNIQUE, length 1–300 (BRC-100's
  `OutputTagStringUnder300Characters`).
- `output_tags` UNIQUE `(output_id, tag_id)`.
- No `deleted_at`.

### 12. certificates, certificate_fields

**Represents:** BRC-52/BRC-65 identity certificates with per-field
encryption for selective revelation.

**Directly stores (certificates):** `type`, `subject`, `serial_number`,
`certifier`, `verifier`, `revocation_outpoint`, `signature`.

**Directly stores (fields):** `certificate_id` (CASCADE), `name`,
`value`, `master_key` (per-field encryption key).

**Integrity:**
- `certificates` UNIQUE `(type, serial_number, certifier)`.
- `certificate_fields` UNIQUE `(certificate_id, name)`.
- No `deleted_at` on either table.

### 13. settings

**Represents:** Key-value wallet config (identity key persistence,
external service config).

**Integrity:** `key` UNIQUE.

### 14. blocks (live-schema addition per #79)

**Represents:** A known block. One row per height; `merkle_root` and
`block_hash` are facts about the block, not about individual proofs.

The original transcripts stored these inline on `tx_proofs`. #79
factored them out — denormalised data was being repeated across every
proof from the same block, and the chain tracker needs a single
source-of-truth for "what is the merkle root at height N?". Populated
write-through: chain tracker checks here first, fetches from the
network on miss.

**Integrity:** `height` UNIQUE; `merkle_root` exactly 32 bytes;
`block_hash` exactly 32 bytes when present.

### 15. tx_reqs (superseded by #90 — removed)

The May 1 transcript designed `tx_reqs` as a first-class
proof-harvesting queue with status enum, attempts counter, and
history. Migration 004 dropped the table; PR #90 replaced the job-queue
model with entity-driven structural queries (`Action` adopts
`Fetchable`; push-discovery and poll-discovery loops query `actions` /
`broadcasts` directly). No work-queue table required. Retained here
only as a pointer for anyone reading the transcripts and wondering
where the table went.

---

## Deferred to future subsystems

PR #197 deliberately reduced the wallet's implementation surface to
the synchronous send path and the internal path. Several pieces of the
original transcript intent were implemented at various points, then
stripped or never landed, and are queued for re-design as dedicated
subsystems. They are real design intent — captured here so they aren't
mistaken for current schema and so the eventual subsystem HLRs have a
starting reference back into the transcripts.

### Chained-send / batching (HLR #192)

BRC-100's `noSend`, `sendWith`, `noSendChange`, and `knownTxids`
primitives let a caller assemble a batch of related transactions and
broadcast them together, with the wallet permitted to spend
not-yet-broadcast change between siblings. The May 1 transcript
discussed this extensively and an initial implementation existed
pre-#197; that surface was removed and the design space queued in
#192 with a phased acceptance ladder.

The `broadcast = 'none'` enum value was originally conflated with
noSend; HLR #183 disentangled them — `'none'` is now the wallet's
**internal path** only. The chained-send subsystem will likely
introduce its own broadcast semantics (a new enum value or a sibling
table) rather than overloading `'none'` again.

### Asynchronous response handling (SSE, webhooks)

The transcripts described an ARC SSE listener thread holding a
persistent `GET /events?callbackToken=...` connection, plus an
`X-CallbackUrl` webhook receiver. Both would push status updates into
the broadcasts row asynchronously instead of inline POST + sync
response.

What's in current scope: inline POST via `Engine::Broadcast#submit`
plus the daemon's poll loop (`Engine::Broadcast#poll_status`) calling
`GET /tx/{txid}`. The push/poll split is already the right shape for
adopting SSE later — push-discovery becomes "submit + register
callback"; poll-discovery becomes the fallback for rows that have
slipped past the SSE stream's `Last-Event-ID` replay window.

What's queued: the SSE listener (persistent connection, reconnection
with replay) and the webhook receiver. The `broadcasts.callback_token`
column required to match incoming events back to broadcasts rows is
the additive piece tracked in #198, but the consuming machinery is
part of this subsystem.

### nonfinal transactions

The May 1 transcript briefly modelled `nonfinal` — transactions with
non-final `nLockTime` or `nSequence` that can't be mined yet. The
state was identified as "irreducibly stored" (structurally identical
to other states but carrying different intent) and would need an
explicit marker. Never implemented; queued.

### Full ARC tx_status lifecycle

The current implementation handles enough of ARC's status enum to
drive the send-path lifecycle through to MINED / REJECTED, plus the
non-terminal `MINED_IN_STALE_BLOCK` re-discovery. The broader enum
(`UNKNOWN`, `RECEIVED`, `SENT_TO_NETWORK`, `ACCEPTED_BY_NETWORK`,
`SEEN_ON_NETWORK`, `MINED`, `IMMUTABLE`, `DOUBLE_SPEND_ATTEMPTED`,
`REJECTED`) carries information the deferred-async subsystem will need
to consume — particularly to distinguish "in flight" sub-states for
user-facing status reporting. The enum CHECK constraint is tracked in
#198.

### Multi-tenant scoping

The wallet is deliberately single-tenant (cross-cutting principle 7).
The transcripts and the May 3 bin-CLI session explored hosting
multiple wallets in one process; the chosen pattern is separate
databases per wallet, with the multi-wallet-per-database scenario
explicitly out of scope. A `scope` column on `settings` (and
elsewhere) would only be needed if that decision were reversed.

---

## Gaps

Where the database does not yet enforce the design's intent — or where
the intent was explicitly superseded by a later design decision.

Status legend: **Resolved** (implemented or design changed to match
live schema), **Moot** (the underlying premise no longer applies),
**Open** (gap stands, not yet tracked), **Tracked** (open, captured in
an HLR or PR).

**1. No CHECK enforcing the spendable/outputs derivation invariant.**
The design intent said derivation data lives on `spendable` and external
payment outputs simply do not get a spendable row. The live migrations
keep derivation on `outputs` with the `output_type` enum and a
`prevent_outbound_spendable` trigger.

> *Resolved — superseded by #65.* The May 3 "move to spendable" decision
> was explicitly reverted. Derivation stays on `outputs`, `spendable`
> returns to pure `{id, output_id, action_id}` set membership. Schema
> intent now aligns with the live schema.

**2. `output_type` enum values diverge from the design's vocabulary.**
Transcripts settled on `('root', 'change')` with NULL = derived. The
live enum is `('root', 'outbound')`.

> *Resolved — superseded by #66.* `'outbound'` was the deliberate later
> choice; it marks payment outputs (someone else's) so the trigger can
> reject spendable rows for them. The transcript's `'change'` value was
> superseded — change outputs are structurally identical to derived
> outputs (NULL type + derivation fields).

**3. `output_details.change` was meant to be dropped.** With
`output_type` carrying the structural marker, the boolean is redundant.

> *Resolved — superseded by #66.* Retained as cosmetic UI metadata
> only; no longer carries structural meaning. `outbound` is the
> structural distinction; `change` is just for display.

**4. No `CHECK (broadcasts.tx_status IN (...))`** to constrain ARC
status strings to the known enum (`UNKNOWN`, `RECEIVED`,
`SENT_TO_NETWORK`, `ACCEPTED_BY_NETWORK`, `SEEN_ON_NETWORK`, `MINED`,
`IMMUTABLE`, `DOUBLE_SPEND_ATTEMPTED`, `REJECTED`). Any string can be
written.

> *Tracked — #198 item 4.*

**5. No CHECK on `broadcasts.merkle_path`/`block_height` parity.** A
MINED broadcast should have both; a RECEIVED broadcast neither.

> *Open — not in #198.* Distinct from the tx_proofs parity constraint;
> applies to ARC snapshot data on the broadcasts row.

**6. No CHECK enforcing that `tx_proof_id` on actions implies the
linked tx_proof actually has a merkle_path.** A partially-populated
tx_proof (raw_tx but no merkle path) linked from an action would
mislead the derived status.

> *Tracked indirectly — #198 item 3* adds `tx_proofs.(merkle_path IS
> NULL OR block_id IS NOT NULL)`. The action-side rule (tx_proof_id ⇒
> merkle_path) is a separate cross-table invariant not covered there.

**7. No constraint on `actions.broadcast = 'none'` excluding a
broadcasts row.** A `'none'` action is internal-path — by definition
should never have a broadcasts row.

> *Tracked — #198 item 5.* Made load-bearing by #197's send/internal
> path split (HLR #183).

**8. `outputs.action_id` was made nullable + ON DELETE SET NULL in
migration 002.** The "outputs are immutable" intent would require
NOT NULL with no SET NULL behaviour.

> *Resolved — #197 (commit `7f6004e`, closes #189).* Column flipped to
> NOT NULL with ON DELETE RESTRICT. "Outputs are immutable" is
> structurally true; no orphan rows possible.

**9. No CHECK enforcing the `(wtxid IS NULL) = (raw_tx IS NULL)` parity
on `tx_proofs`.**

> *Moot.* Both columns are NOT NULL on `tx_proofs`; the parity rule has
> no nullable side to enforce against.

**10. `tx_reqs.status` enum is enforced by CHECK in the live schema but
the table itself was dropped in migration 004.**

> *Resolved — superseded by #90.* The harvester queue is replaced by
> entity-driven structural queries (`Pushable` / `Fetchable` mixins).
> `Action` adopts `Fetchable`; no work-queue table required. The
> transcript's `tx_reqs` design was superseded.

**11. No length constraint on `actions.raw_tx`.** `tx_proofs.raw_tx`
has a 20-byte minimum; `actions.raw_tx` has none beyond NOT NULL via
the parity rule.

> *Open — not in #198.* Same 20-byte floor would apply.

**12. `certificates` is missing constraints on field formats.** Several
columns (`type`, `subject`, `certifier`, `verifier`, `signature`) are
text without length/format validation.

> *Open — not in #198.*

**13. `output_details` permits orphaned rows pre-promotion.** The
`action_id` denormalised CASCADE prevents long-term orphans but doesn't
constrain row ordering relative to outputs/spendable/baskets.

> *Open — low-impact.* Largely mitigated by the all-or-nothing
> Phase-4 transaction in the live code.

**14. Settings has no scoping.** A single global namespace.

> *By design.* Multi-wallet-per-process is handled by separate
> databases (per the bin-CLI convention in the May 3 transcript); a
> `scope` column would only be needed for in-process multi-tenancy,
> which is explicitly outside the wallet's remit (principle 7).

**15. No CHECK on `broadcasts.tx_status` and `arc_status` agreement.**
The numeric `arc_status` should correspond to the string `tx_status`.

> *Open — low value.* Would couple the schema to ARC's internal mapping
> table; the practical benefit is minor.

**16. `broadcasts.callback_token` column missing.** ARC's SSE
(`/events?callbackToken=...`) and `X-CallbackToken` header need a
column for the listener to match incoming events back to broadcasts
rows.

> *Tracked — #198 item 1.* Flagged in the May 1 transcript but never
> landed.

**17. `actions.reference` uses UUIDv4, not UUIDv7.** The unique-indexed
column is currently `gen_random_uuid()`, causing B-tree page splits.

> *Tracked — #198 item 2.* The May 3 transcript explicitly raised this:
> UUIDv7 is time-ordered so inserts always append.

The recurring theme: the wallet has gone a long way to make state
*structurally* impossible to corrupt, but several cross-column
invariants — particularly across `actions ↔ broadcasts ↔ tx_proofs` —
remain code-enforced rather than database-enforced. The four-phase
commit model is robust against process crashes between phases, but it
relies on the code always taking the right phase boundaries; a stray
direct INSERT could leave the wallet in a state the derived-status
table cannot interpret.
