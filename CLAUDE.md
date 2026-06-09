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

## Database & Wallet Configuration

This is a **Postgres-based** wallet. SQLite exists as a convenience for fast logic-only specs that don't depend on DB invariants — it is not the production target.

The schema chooses Postgres-native features deliberately: `bytea` for everything hash-shaped, native `uuid` for `actions.reference`, ENUM types (`broadcast_intent`), CHECK constraints, RESTRICT FK semantics. See `reference/schema-intent.md`.

### Configuration model — no mystery

There are two audiences for wallet configuration, with different env-var conventions. Don't mix them up.

#### End-user mode (someone who installed the gem)

A single wallet, a single database. The end user sets one variable:

- **`DATABASE_URL`** — full Postgres URL (e.g. `postgres://user:pass@host:5432/my_wallet`), or any Sequel-compatible URL. The end user doesn't care about per-wallet derivation; they have one wallet.
- If `DATABASE_URL` is unset, `CLI.boot` falls back to SQLite at `~/.bsv-wallet/<name>.db` (or `default.db` for unnamed).

This is what README, install docs, and end-user-facing copy should foreground. End users **don't need to know about** `BSV_WALLET_POSTGRES` or `BSV_WALLET_WIF_<NAME>` — those are dev/test scaffolding.

#### Dev/test mode (this repo — what we use)

Multiple named wallets sharing one Postgres server. Resolution goes through **`BSV::Wallet::Fixtures`** — a registry block that maps each name to a WIF + database_url. The gem ships a default `config/fixtures.rb` that reads shell ENV vars and is auto-loaded when no user override exists, so the existing shell-env-driven convention (`~/.zshenv` locally, GitHub secrets in CI) still "just works".

Standard registered wallets:

- `alice`, `bob`, `carol` — integration specs
- `sdk` — e2e harness funder
- `w1`..`w5` — e2e wallet fleet (WIFs derived at runtime from `:sdk`)
- `test` — unit-spec DB (no WIF; specs generate their own keys)

ENV vars consumed by the default fixtures file:

- **`BSV_WALLET_POSTGRES`** — base URL (e.g. `postgres://postgres:postgres@localhost:5433/`). Per-wallet DB derives as `<base>/bsv_wallet_<name>`.
- **`BSV_WALLET_WIF_<NAME>`** — WIF per named wallet (e.g. `BSV_WALLET_WIF_ALICE`).
- **`DATABASE_URL_<NAME>`** (rare override) — pin a specific wallet to a non-standard URL.

`BSV_WALLET_POSTGRES` unset → unit specs fall back to in-memory SQLite (the SQLite-augmentation path). CLI tools that need a real wallet require it set.

Override the gem default by writing `~/.bsv-wallet/fixtures.rb` (or setting `BSV_WALLET_FIXTURES=<path>`). The user file fully replaces — register every wallet you want available. The e2e harness registers `w1`..`w5` at runtime via the same `Fixtures.configure` block.

### Conventions

- When the user says "the database" or "the wallet" without qualifying, assume Postgres in dev/test mode.
- Unit spec helper branches on `BSV_WALLET_POSTGRES`: unset → in-memory SQLite, set → `<base>/bsv_wallet_test`. The helper **ignores `DATABASE_URL`** — keeps an operator's working end-user `DATABASE_URL` from silently hijacking the spec run. Both backends run in CI (matrix job).
- Integration specs require **both** `BSV_WALLET_POSTGRES` and `BSV_WALLET_WIF_ALICE/BOB/CAROL` (each WIF funded with ≥ 1m sats on chain).
- E2E specs use the `sdk` wallet (`BSV_WALLET_WIF_SDK` + `<base>/bsv_wallet_sdk`) plus the `w1`..`w5` derived fleet for the multi-wallet harness.
- Postgres-specific behavior (CHECK violations, ENUM rejections, RESTRICT FK semantics, the `prevent_outbound_spendable` trigger) MUST have a spec that runs against Postgres — SQLite carries those via translation and won't surface a regression.
- New DB-touching test helpers must read the configured DB URL, never hardcode `sqlite://`.

## Running Specs

Specs must run from the gem directory, not the repo root.

```bash
# Wallet unit specs (Postgres — primary target)
cd gem/bsv-wallet && BSV_WALLET_POSTGRES=postgres://postgres:postgres@localhost:5433/ bundle exec rspec spec/bsv spec/bin

# Wallet unit specs against SQLite (augmentation — proves SQLite still works)
cd gem/bsv-wallet && bundle exec rspec spec/bsv spec/bin

# Wallet integration specs (require BSV_WALLET_POSTGRES + BSV_WALLET_WIF_ALICE/BOB/CAROL, each WIF funded with >= 1m sats)
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
