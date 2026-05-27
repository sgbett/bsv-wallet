# HLR #198 — Schema Constraint Gaps

**Branch:** `feat/198-schema-constraint-gaps`
**Strategy:** Single PR, commits per sub-task. Amend existing migrations 001/003 rather than stacking 007+ (pre-production schema, fresh installs only).

## Task order

| Order | Sub-issue | Migrations touched | Code ripple |
|---|---|---|---|
| A | #217 — rename `actions.broadcast` → `broadcast_intent` + `UNIQUE(id, broadcast_intent)` | 001, 003 | ~10 files (store, engine, interface, specs) |
| B | #218 — `broadcasts.callback_token text` | 001 | none (additive) |
| C | #219 — `tx_proofs` CHECK (`merkle_path IS NULL OR block_id IS NOT NULL`) | 001 | none (additive) |
| D | #220 — `broadcasts.tx_status` → ENUM, positioned after `arc_status` | 001 | broadcast lifecycle code (status values) |
| E | #221 — `broadcasts.intent` + composite FK + CHECK `intent != 'none'` | 001 | broadcast creation code (populate intent) |
| F | #222 — UUIDv7 for `actions.reference` (pg18 native, SQLite app-side) | 001, 003 | Action model `before_create` for SQLite |

## Notes

- Column ordering matters for D and E (user requested padding-efficient layout). Amending 001 directly avoids the drop+add reorder problem entirely.
- A must land first (FK target requires `UNIQUE(id, broadcast_intent)`).
- B, C, F orthogonal — can interleave anywhere.
- D and E share the broadcasts table layout; ordering of changes matters within migration 001.
- Each task: amend migration + update code + update `reference/schema.md` + run both backends.

## Verification gate per task

- `bundle exec rspec spec/bsv spec/bin` (SQLite)
- `DATABASE_URL=postgres://postgres:postgres@localhost:5433/bsv_wallet_test bundle exec rspec spec/bsv spec/bin` (pg18)
- After E lands, drop the wallet container + wipe `tmp/postgres-data` once to verify a clean run on a fresh DB

## Out of scope

- New 007+ migration files (deliberate — pre-production)
- Production data migration concerns (none exist)
- Daemon-side SSE callback consumer (gap 1 just lands the column; consumer is downstream work)
