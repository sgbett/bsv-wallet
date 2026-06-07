# BSV Wallet — Project Instructions

## Language Convention: American English

**Override global preference:** This project uses **American English** throughout — code, comments, documentation, and commit messages.

The BRC-100 specification defines method names using American English (`internalizeAction`, `randomizeOutputs`). Using British English for Ruby method names (`internalise_action`, `randomise_outputs`) while the spec uses American creates confusion about which convention applies where. Consistency wins: American English everywhere.

Examples: behavior, color, organization, optimize, summarize, favor, center, internalize, randomize.

## Transaction ID Convention: wtxid / dtxid

Two representations, one simple rule:

- **Binary** (Ruby internals, database, wire format): `wtxid` — wire-order, raw SHA256d, 32 bytes
- **String** (JSON, logs, CLI, external APIs): `dtxid` — display-order hex, 64 characters

No exceptions. If it's binary, it's `wtxid`. If it's a string, it's `dtxid`.

### Naming

| Name | Format | When |
|------|--------|------|
| `wtxid` | 32-byte binary, wire order | Method params, variables, hash keys, database columns |
| `dtxid` | 64-char hex string, display order | ARC API calls, JSON responses, logs, CLI output |
| `txid` | Varies | BRC-100 spec names only (`known_txids:`, return key `:txid`) — boundary comment required |

### BRC-100 spec names

Where a specification requires `txid` (e.g., `known_txids:` parameter, `:txid` return key), keep the spec name. Add a boundary comment. The value is a wire-order wtxid — the key name is the spec's label, not a byte-order indicator.

### SDK API names

Third-party conventions stay as-is: `PathElement#txid` (boolean flag), `txOrId` (TSC field). These are not our naming to change.

### Source

`Transaction#wtxid` returns wire order (SDK v0.17.0+). `Transaction#txid` returns display order — a convenience method, never used in the data path. The `DisplayTxid` module provides `dtxid` on Sequel models.

## Database: Postgres is Primary

This is a **Postgres-based** wallet. SQLite exists as a convenience for fast logic-only specs that don't depend on DB invariants — it is not the production target.

The schema chooses Postgres-native features deliberately: `bytea` for everything hash-shaped, native `uuid` for `actions.reference`, ENUM types (`broadcast_intent`), CHECK constraints, RESTRICT FK semantics. See `reference/schema-intent.md`.

**Conventions:**

- When the user says "the database" or "the wallet" without qualifying, assume Postgres.
- The local `.env` (loaded by `BSV::Wallet::CLI.boot` via `dotenv/load`) provides per-wallet Postgres URLs (`DATABASE_URL_ALICE`, etc.) — anything that shells out to `bin/` inherits these. Tests must not override them with sqlite paths.
- Unit specs branch on `BSV_WALLET_POSTGRES`: unset → in-memory SQLite, set (e.g. `postgres://postgres:postgres@localhost:5433/`) → Postgres at `<base>/bsv_wallet_test`. The spec helper derives the test DB from the base and **ignores `DATABASE_URL`** — keeps an operator's working DATABASE_URL from silently hijacking the spec run. Both run in CI (matrix job).
- Integration specs run against Postgres locally (via `.env`) and Postgres in CI. New DB-touching test helpers must read the configured DB URL, never hardcode `sqlite://`.
- Postgres-specific behaviour (CHECK violations, ENUM rejections, RESTRICT FK semantics, the `prevent_outbound_spendable` trigger) MUST have a spec that runs against Postgres — SQLite carries those via translation and won't surface a regression.

## Running Specs

Specs must run from the gem directory, not the repo root.

```bash
# Wallet unit specs (Postgres — primary target)
cd gem/bsv-wallet && BSV_WALLET_POSTGRES=postgres://postgres:postgres@localhost:5433/ bundle exec rspec spec/bsv spec/bin

# Wallet unit specs against SQLite (augmentation — proves SQLite still works)
cd gem/bsv-wallet && bundle exec rspec spec/bsv spec/bin

# Wallet integration specs (require BSV_WALLET_WIF_ALICE/BOB/CAROL + each funded with >= 1m sats)
cd gem/bsv-wallet && bundle exec rspec spec/integration

# All wallet specs (unit + integration)
cd gem/bsv-wallet && bundle exec rspec

# RuboCop
cd gem/bsv-wallet && bundle exec rubocop
```

## Architecture Framework

The `.architecture/` directory contains the AI Software Architect framework:

- **`members.yml`** — architecture team roster (10 specialists)
- **`principles.md`** — architectural principles governing design decisions
- **`decisions/adrs/`** — Architectural Decision Records
- **`reviews/`** — architecture reviews and system analyses
- **`config.yml`** — framework configuration

Commands: `architecture-status`, `create-adr`, `specialist-review`, `architecture-review`, `list-members`
