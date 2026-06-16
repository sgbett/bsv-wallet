# Consolidate migrations 004–014 into 001–003 — Plan

**Issue:** #353
**Branch:** `refactor/353-consolidate-migrations`
**Date:** 2026-06-16

## Context

The schema is defined by 14 Sequel migrations under `gem/bsv-wallet/db/migrations/`.
Migrations 004–014 are almost entirely *post-design corrections* — create-then-undo
churn discovered in live testing, Copilot reviews, and ADR work — not foundational
schema. The wallet is pre-release (README: migrations are *amended in place*, the model
is wipe-and-re-migrate, there is no deployed data). The principle-of-state docs make the
schema **structure** canonical; migration **history** is an implementation detail that
lives in git, the issues, and the ADRs — not in the migration files. So the issues that
drove 004–014 should have edited 001/003 directly.

Goal: express the *final* schema in three clean migrations with zero create-then-undo,
delete 004–014, and (per decision) also fix the same churn anti-pattern found **inside**
001↔003. The end-state schema must be byte-identical to today's.

**Decisions taken (planning):**
- **Full de-churn** — also fix internal 001↔003 churn, not just 004–014.
- **Fold the two genuinely-new tables** (`promotions` #012, `sse_cursors` #010) into the
  three base migrations. Result is truly three migrations.

## Target three-way split

A clean conceptual split, matching how 001/003 already mostly work:

- **001 — structure.** Every table in final shape: columns, types, enums, indexes,
  inline UNIQUE constraints, and FKs that exist at creation time. The two new tables.
- **002 — denormalised cascade FKs.** The `action_id` denormalisation (derivable, but
  justified for single-statement cascade cleanup).
- **003 — validation.** All CHECK constraints, `NOT NULL` settings, and triggers.

## What changes vs today's final schema: nothing

This is a pure reorganisation. The same tables, columns, enums, constraints, triggers,
names, and semantics — reached in 3 steps instead of 14. Correctness = schema-dump
equivalence (see Verification).

## 001 — rewrite (structure, final shape)

Fold in, relative to current 001:
- **Drop `tx_reqs` entirely** (004) — never create it.
- **`actions`**: remove `outgoing` (013), `version`/`nlocktime` (014), and `satoshis`
  (currently created here, dropped in 003). On Postgres define `reference` as `:uuid`
  directly with `default uuidv7()` (remove the text→uuid conversion now in 003); SQLite
  stays `:text`. (`reference` NOT NULL stays in 003.)
- **`outputs`**: define `action_id` FK as `null: false, on_delete: :restrict` directly
  (removes the 002 SET NULL → 006 RESTRICT flip). Add the `output_type` column here
  (move from 003) and create the `output_type` enum here. Never create `promoted`
  (005 add / 012 drop — gone).
- **`broadcasts`**: add `retry_count` (007) and `provider` (009) columns; add a named
  `unique %i[action_id tx_status]` (`broadcasts_action_id_tx_status_key`) — required as
  the FK target for `promotions`.
- **`tx_status` enum**: insert `SEEN_MULTIPLE_NODES` after `SEEN_ON_NETWORK` in the
  `arc_tx_statuses` array (011 folded; preserves declared order the enum-order spec checks).
- **`action_labels`**: define `action_id` FK with `on_delete: :cascade` directly
  (removes the 003 FK flip).
- **Soft-delete removal**: drop `deleted_at` from `baskets`, `labels`, `tags`,
  `output_tags`, `certificates`, `action_labels`; replace each partial unique index
  (`baskets_name_index`, `labels_label_index`, `tags_tag_index`) with the corresponding
  named full UNIQUE constraint (`baskets_name_unique`, `labels_label_unique`,
  `tags_tag_unique`) inline (these currently land in 003).
- **New `sse_cursors`** (010): `token` PK, `last_event_id` bigint NOT NULL,
  `updated_at` (timestamptz/datetime, `now()` default).
- **New `promotions`** (012), created *after* `actions` and `broadcasts`: `action_id`
  bigint PK → `actions(id)` ON DELETE CASCADE; `intent` (broadcast_intent) NOT NULL;
  `authorising_status` (tx_status) nullable; composite FKs
  `(action_id, intent)→actions(id, broadcast_intent)` and
  `(action_id, authorising_status)→broadcasts(action_id, tx_status)` ON UPDATE CASCADE.
  Its two CHECKs (`promo_path`, `auth_not_rejected`) go in 003.

`down`: reverse — drop `promotions` before its FK targets; drop the `output_type`,
`broadcast_intent`, `tx_status` enums (output_type now born here).

## 002 — rewrite (denormalised cascade FKs)

- **Keep**: add `action_id` (+ FK→`actions` ON DELETE CASCADE) to `spendable`,
  `output_baskets`, `output_details` (names `*_action_id_fkey` preserved).
- **Remove**: all `outputs.action_id` manipulation (now final in 001).
- **Add** (folded from 012): second FK on `spendable.action_id` →
  `promotions(action_id)` ON DELETE CASCADE (`spendable_promotion_fkey`). `promotions`
  exists from 001, so the target is available.

## 003 — rewrite (validation only)

- **Keep**: all CHECK constraints; `set_column_not_null` for `tx_proofs.raw_tx`,
  `actions.description`, `actions.reference`, `outputs.locking_script`, and
  `spendable/output_details/output_baskets.action_id`; the `output_type` CHECKs
  (`typed_no_*`, `derived_needs_*`, SQLite `output_type_values`); the
  `prevent_outbound_spendable` trigger.
- **Add** `prevent_internal_action_delete` trigger — **final (012) form** that checks for
  a `promotions` row (not `outputs.promoted`). Postgres function + trigger; SQLite trigger.
  The 008 intermediate form never exists.
- **Add** `promotions` CHECKs `promo_path` and `auth_not_rejected`.
- **Update** SQLite `tx_status_values` CHECK to include `SEEN_MULTIPLE_NODES`.
- **Remove** all churn now handled in 001: `drop_column :satoshis`; the six `deleted_at`
  drops + index→constraint recreations; the `reference` text→uuid conversion; the
  `action_labels` FK flip; the `output_type` column add (CHECKs stay). Remove
  `nlocktime_range` (013 — referenced the now-gone `outgoing`) and all `tx_reqs` CHECKs.

## Delete

`004_*` through `014_*` — 11 files.

## Spec / comment updates

- **`spec/bsv/wallet/store/migration_spec.rb`** — the one real code constraint:
  - Rewrite the `broadcasts.provider (migration 009)` round-trip test (lines ~214–239).
    `target: 8` no longer exists; retarget to a **full down/up cycle**: migrate full →
    assert `provider` present → `Sequel::Migrator.run(rt, path, target: 0)` → assert tables
    gone → migrate full → assert `provider` present. Keep the SQLite dedicated-connection
    logic (the comment at 218–224 still applies — table rebuilds in 002/003 remain).
    Drop "(migration 009)" from the describe label.
  - Update the enum-order comment (72–74) referencing the #011 `ALTER TYPE` — the value is
    now declared inline; the assertion is unchanged.
  - Add `promotions` and `sse_cursors` to `expected_tables` (now 19) and fix the
    "17 tables" label.
- **Comment-only** (non-breaking): `lib/bsv/wallet/store/models/promotion.rb:11`
  ("(migration 012)" → 001); `spec/integration/walletd_broadcaster_provider_spec.rb:16`
  ("migration 009" → 001). `lib/bsv/wallet/engine/broadcast.rb:275` ("migration 003")
  stays correct — `wtxid_raw_tx_parity` remains in 003.
- **Grep to confirm clean** before finishing: no remaining references to a migration
  number, and no app/spec use of `promoted`, `tx_reqs`, `actions.outgoing`,
  `actions.satoshis`, `actions.nlocktime`, `actions.version`, or `deleted_at`.
- **`reference/schema.md` / `reference/schema-intent.md`**: key off issue numbers, not
  migration numbers — expected no change; grep `migration` to confirm.

## Critical correctness risk: constraint names

Postgres auto-names constraints; the consolidated migrations must reproduce the **same
names** wherever code, down-blocks, or pg_dump would surface them (e.g.
`broadcasts_action_id_tx_status_key`, `spendable_promotion_fkey`, `*_action_id_fkey`,
`baskets_name_unique`, `labels_label_unique`, `tags_tag_unique`, the `outputs_action_id_fkey`
RESTRICT FK). Use explicit `name:` on `unique`/constraint declarations in `create_table`
where the originals were named. The schema-dump diff is the guard.

## Verification

1. **Schema-dump diff (gold standard — proves equivalence).** Before the change (current
   HEAD), migrate a fresh Postgres DB and capture `pg_dump --schema-only --no-owner
   --no-privileges` as a baseline. After consolidation, migrate a fresh DB and dump again;
   the two must be **identical**. Repeat for SQLite (`.schema` of a freshly-migrated
   `sqlite::memory:`). This catches constraint-name drift, column order, defaults, and FK
   semantics that example specs can miss.
2. **Unit suite, Postgres (primary):**
   `cd gem/bsv-wallet && BSV_WALLET_POSTGRES=postgres://postgres:postgres@localhost:5433/ bundle exec rspec spec/bsv spec/bin`
   — `migration_spec.rb` is the key gate (exact enum values/order, value-restriction
   CHECKs, structural constraints, triggers, blob columns, defaults).
3. **Unit suite, SQLite (augmentation):** `cd gem/bsv-wallet && bundle exec rspec spec/bsv spec/bin`
   — proves the SQLite path and the table-rebuild `alter_table`s in 002/003 still work.
4. **Integration suite** (needs `BSV_WALLET_POSTGRES` + funded `ALICE/BOB/CAROL` WIFs):
   `cd gem/bsv-wallet && bundle exec rspec spec/integration`.
5. **RuboCop:** `cd gem/bsv-wallet && bundle exec rubocop`.

## Notes

- **Down blocks retained** (reverse of the new `up`); the round-trip test exercises them.
  They could be dropped given the wipe-and-re-migrate model, but default is to keep.
- **No ADR.** The end-state schema is unchanged; this is migration hygiene under the
  README's existing "amend in place, pre-release" policy, not a new architectural
  decision.
- **One cohesive PR/commit:** `refactor(schema): consolidate migrations 004–014 into 001–003`,
  body noting the end-state is unchanged and verified by schema-dump diff.
