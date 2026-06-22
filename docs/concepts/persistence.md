# Persistence

The wallet keeps all of its state in a relational database, accessed through [Sequel](https://sequel.jeremyevans.net/). Two things make the persistence layer distinctive: structural state is the **single source of truth** — what the principle of state names as canonical — and the schema pushes a surprising amount of the wallet's safety down into database constraints and triggers rather than trusting application code alone.

This page is the narrative shape of the data model. For the table-by-table reference, see [Schema](../reference/schema.md). For the principle, see [Principle of state](../reference/principle-of-state.md). When this page and the reference disagree, the reference wins.

## Postgres-primary, SQLite-augmentation

This is a **Postgres-based** wallet. The schema chooses Postgres-native features deliberately: `bytea` for everything hash-shaped, native `uuid` for `actions.reference`, ENUM types (`broadcast_intent`, ARC `tx_status`), CHECK constraints, RESTRICT FK semantics, BEFORE-INSERT and BEFORE-DELETE triggers. The rationale for the per-primitive choice is in [ADR-009](../../.architecture/decisions/adrs/20260505_ADR-009-postgres-native-primitives.md).

SQLite is **a convenience for fast logic-only specs that do not depend on DB invariants** — not the production target. The migrations are written once, with guards that emit Postgres-native DDL or a SQLite equivalent from the same source:

| Concept | PostgreSQL | SQLite |
|---------|------------|--------|
| Binary columns | `bytea` | `blob` |
| Timestamps | `timestamptz` | `datetime` |
| Enumerations | `CREATE TYPE … AS ENUM` | `CHECK (col IN (…))` |
| Primary keys | `BIGINT … IDENTITY` | `INTEGER PRIMARY KEY AUTOINCREMENT` |
| Arrays | `text[]` | `text` |

The two backends are tested for the same behaviour — a constraint that exists on one has an equivalent on the other — but the augmentation is one-way. New Postgres-specific behaviour (CHECK violations, ENUM rejections, RESTRICT FK semantics, triggers) **must** be tested against Postgres directly; SQLite translation carries the rules but does not reliably surface a regression in its constraint vocabulary. When the user says "the database" or "the wallet" without qualifying, the answer is Postgres.

`Store.connect(url)` is the factory that picks the backend from the URL scheme — `postgres://` (or `postgresql://`) yields `Store::Postgres`, anything else yields `Store::SQLite`:

```ruby
store = BSV::Wallet::Store.connect("postgres://user:pw@localhost/bsv_wallet_alice")
store = BSV::Wallet::Store.connect("sqlite:///home/me/.bsv-wallet/alice.db")
store.migrate!
```

## The model boundary

The `Store` is implemented with Sequel models (`Action`, `Output`, `Broadcast`, `Promotion`, `Transmission`, …), but — as covered in [Architecture](architecture.md) — **no Sequel object leaves the `Store`.** Every public method returns plain hashes and arrays. The models exist to express associations and a little derived logic (most importantly `Action#derived_status`); they are an internal implementation detail of the persistence layer, not part of its contract.

Models are autoloaded and `Sequel::Model.require_valid_table = false` defers schema introspection until first query, so the model classes can be defined before `migrate!` has created their tables.

## The core data model

Twenty-one tables, but the lifecycle turns on a handful of them:

```
   blocks ──< tx_proofs ──< actions >── broadcasts
                              │  │            │
                  outputs >───┘  └─< inputs   │
                    │                          │
                    │           promotions ────┤
                    │                          │
        ┌───────────┼───────────┬──────────────┘
     spendable  output_details  output_baskets  output_tags

   transmissions >── transmission_txids
   sse_cursors
```

- **`actions`** — the transaction lifecycle row. Holds `wtxid`, `raw_tx`, `broadcast_intent`, a UUIDv7 `reference`, and little else. Crucially it has **no status column** (see [Action lifecycle](action-lifecycle.md)).
- **`outputs`** — the wallet's log of every output it has created or received, carrying BRC-42 derivation metadata. Append-only **with one named deviation** — see below.
- **`inputs`** — the structural lock and spend record: one row per output an action consumes.
- **`spendable`** — the UTXO set. An output is spendable iff it has a row here and no row in `inputs`.
- **`broadcasts`** — the ARC lifecycle: `broadcast_at`, `tx_status`, `arc_status`, retry count, `provider`, and proof fields.
- **`promotions`** — the structural authorisation that an action's outputs are canonical. A promotions row is what turns a freshly-broadcast action from `:sending` into `:unproven`; see below.
- **`tx_proofs`** / **`blocks`** — merkle inclusion proofs and the chain tracker's local header view.
- **`transmissions`** / **`transmission_txids`** — wallet-to-peer BEEF delivery state; the two-phase write on ACK is what makes per-peer trim knowable. See [Transmission](transmission.md).
- **`sse_cursors`** — last-event-id for the Arcade SSE push pipeline, keyed on `callback_token`.

The remainder are organisational or metadata: `baskets` / `output_baskets` (grouping), `labels` / `action_labels` and `tags` / `output_tags` (classification), `output_details` (display metadata), `certificates` / `certificate_fields` (BRC-52), and `settings` (key-value configuration). The canonical table-by-table reference is in [Schema](../reference/schema.md).

## The promotions table: structural authorisation

A promotions row is the database's record of "this action's outputs are canonical." It exists for an action exactly when the broadcast was **accepted** (any non-rejected ARC status) or when the action is internal (`broadcast_intent = 'none'`, with no broadcast at all to accept). `Action#derived_status` reads the existence of this row, not a column on `outputs`, to decide `:unproven`.

Storing this as a row rather than a flag is the structural-state convention applied one level up: a promotion is a *fact* about an action, gated by FK to the broadcast that authorised it (`promotions_broadcast_status_fkey`), so a flip to REJECTED has to delete the promotions row before it can take effect. The constraints (`promo_path`, `auth_not_rejected`) make the gating impossible to bypass at the application layer. This is the composite-FK gate pattern described in [Architecture: Designed for scale](architecture.md#designed-for-scale).

Outputs themselves no longer carry a `promoted` boolean. The earlier design (one flag per output, flipped at Phase 4) was replaced because a per-output flag duplicated what is fundamentally per-action state — every output of an accepted action is canonical, every output of a rejected one is not. The promotions row says it once, on the action. ADR-023 records the move.

## Outputs are append-only, with a named deviation

The `outputs` table is **append-only** for all routine state changes: an output written at Phase 2 is never updated in place to mark it spendable, and never deleted after promotion. Promotion is now represented by the existence of a `promotions` row (per the previous section), not by mutating the output. This is the principle-of-state shape applied to the highest-volume table in the schema.

The deviation: outputs **can** be deleted, in a bounded set of failure paths. `reject_action`, `abort_action`, and the reaper delete unpromoted outputs as part of unwinding an action that never reached canonical state. The mechanism is forced by the schema's `outputs.action_id` FK being `ON DELETE RESTRICT`: cleaning up the action requires its dependents to go first. The principle-of-state document calls this the **failure-bounded delete** deviation and frames it as a *vacuum win* — without it, every failed/aborted action would leak its outputs forever, growing the table without bound.

ADR-011 (post-broadcast promotion) recorded the original promoted-UPDATE flag deviation; ADR-023 (promotion-as-a-row) superseded that flag deviation, restoring outputs to pure-append for routine state. ADR-011 (failure-bounded delete) still stands: the delete-on-failure path is the one carved-out exception, named and justified rather than treated as drift. The full framing is in [Principle of state — A note on scale](../reference/principle-of-state.md#a-note-on-scale).

The takeaway in narrative form: "outputs are immutable, append-only" is the *first-order* statement, true for everything except the abort/reap/reject path; saying it without that caveat misses why the schema needs RESTRICT FK semantics on `outputs.action_id` and why those teardown methods exist at all.

## Invariants enforced in the schema

The schema is where the wallet's most important rules are made unbreakable. These are the same invariants the application enforces, restated as constraints so that no code path can violate them.

**Single-spend.** `inputs.output_id` is `UNIQUE`. Two actions cannot claim the same output; the second insert simply fails. The lock is the row.

**Immutable outputs (with the named deviation).** `outputs.action_id` is `NOT NULL` with an `ON DELETE RESTRICT` foreign key. An output cannot be orphaned or silently deleted at the schema level; cleaning it up requires the dependent action to be removed first, which forces the failure-bounded delete path described above.

**Outbound outputs are never spendable.** A `BEFORE INSERT` trigger (`prevent_outbound_spendable`) forbids a `spendable` row for any output typed `outbound`. The pool *cannot* be handed an output that was paid away.

**Received history is never deleted.** A `BEFORE DELETE` trigger (`prevent_internal_action_delete`) blocks deleting an internal action (`broadcast_intent = 'none'`) that has a `promotions` row. A `CHECK` can't express this — checks don't fire on `DELETE` — so a trigger is the only mechanism. The promotions-row test is what distinguishes a canonical internal action (deletion forbidden) from an ephemeral zero-output WBIKD lock (deletable).

**Intent integrity.** `broadcasts` has a composite foreign key to `actions(id, broadcast_intent)` with `ON UPDATE RESTRICT`, plus a `CHECK (intent != 'none')`. A broadcast row's intent is locked to its parent action's intent, and an internal action can never acquire one. The composite-FK gate.

**Promotion gating.** `promotions` has the composite foreign key `promotions_action_intent_fkey` to `actions(id, broadcast_intent)` plus `promotions_broadcast_status_fkey` to `broadcasts(action_id, authorising_status)`. The CHECKs `promo_path` and `auth_not_rejected` forbid a broadcast-intent action from carrying a promotion that does not trace to an accepted broadcast row. A `REJECTED` broadcast cannot be the authoriser. The composite-FK gate, again.

**Transmission grain.** `transmissions` has `UNIQUE(action_id, counterparty)`, so a retransmission to the same peer updates in place. The BRC-43 canonical hex CHECK on `counterparty` (`\A0[23][0-9a-f]{64}\z`) matches the engine-side validation exactly, so a malformed pubkey fails the same way at both layers.

**Value sanity.** Length and range checks abound (migration 003): hashes are exactly 32 bytes, satoshis and heights are non-negative, descriptions are 5–50 characters, a merkle path may not exist without block context, and so on.

## Byte order in storage

As described in [Transactions & BEEF](transactions-and-beef.md), the canonical stored form is **wire order** (raw SHA-256d output): `wtxid`, `merkle_root`, and block hashes are stored as raw bytes in `bytea`/`blob` columns. Display-order (reversed hex — what the wallet calls `dtxid`) appears only at the edges. The `display_txid` model concern provides the reversal for presentation. Keeping one representation in storage means uniqueness, joins, and comparisons never have to worry about which way round a hash is.

## Backend-specific handling

A few semantics genuinely differ between the two databases, and the concrete `Store` subclasses absorb them:

- **`Store::SQLite`** enables WAL journal mode (database-wide) and the `foreign_keys` PRAGMA on *every* pooled connection (it is per-connection, not global). Because SQLite's `INSERT … ON CONFLICT DO NOTHING` always returns the last rowid even when nothing was inserted, `try_lock_input` re-queries to confirm it actually won the lock.
- **`Store::Postgres`** loads the `pg_enum`, `pg_array`, and `pg_json` extensions and requires the `pg` gem (with a helpful error if it is missing). Postgres returns `nil` from a `DO NOTHING` conflict, so a truthy result is an unambiguous "this insert won".

The `UTXOPool#select` path's lock semantics depend on getting this right, which is why it lives in the backend subclass rather than the shared base.

## Migrations and schema evolution

The schema ships as **three ordered migrations**. The split is functional, not historical — pre-release the project adopted an "amend in place" policy (#353), so migrations express the canonical end-state structure rather than recording every step that got there:

| # | Migration | What it establishes |
|---|-----------|---------------------|
| 001 | `create_schema` | Every table in its end-state shape, the ARC `tx_status` enum, the `broadcast_intent` and `output_type` enums, and the intent / promotion gating CHECKs that are inseparable from the CREATE TABLE statements. Includes `sse_cursors`, `promotions`, `transmissions`, `transmission_txids` and the `broadcasts.provider` column inline rather than as later additions. |
| 002 | `action_id_cascade` | Adds denormalised `action_id` FK columns on the leaf tables with `ON DELETE CASCADE`, so an aborted action's rows are reclaimed cleanly without an application-side delete sweep. |
| 003 | `schema_constraints` | All length, range, and parity checks; the BRC-43 hex CHECK on `transmissions.counterparty`; the two triggers (`prevent_outbound_spendable`, `prevent_internal_action_delete`). |

`migrate!` runs them idempotently at boot, so a fresh database and an existing one converge on the same shape. Once the gem ships post-release, the policy flips: schema changes will land as additive, ordered migrations again.

## Settings and housekeeping

`settings` is a small key-value table for wallet configuration that needs to persist. `reap_stale_actions(threshold:)` is the housekeeping operation that clears abandoned, unpromoted actions and releases their locked inputs; in production it is driven by the daemon's reaper fibre.

## Related

- [Principle of state](../reference/principle-of-state.md) — the canonical principle this whole page operationalises, and the "A note on scale" section that frames the outputs-immutability deviation.
- [Schema](../reference/schema.md) — table-by-table reference; the normative source for column types, constraints, indexes, and migration content.
- [Action lifecycle](action-lifecycle.md) — how phases map onto table writes.
- [Transmission](transmission.md) — the `transmissions` and `transmission_txids` tables.
- [Events](events.md) — the broadcast-status event stream that drives the canonical-promotion transaction in `record_broadcast_result`.
