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

## Running Specs

Each gem has its own Gemfile, spec_helper, and `.rspec` — specs must run from the gem's directory, not the repo root.

```bash
# Wallet unit specs (fast, no infra)
cd gem/bsv-wallet && bundle exec rspec spec/bsv spec/bin

# Wallet integration specs (require BSV_WALLET_WIF_ALICE/BOB + Alice funded with >= 1m sats)
cd gem/bsv-wallet && bundle exec rspec spec/integration

# All wallet specs (unit + integration)
cd gem/bsv-wallet && bundle exec rspec

# Postgres specs
cd gem/bsv-wallet-postgres && bundle exec rspec

# RuboCop (wallet gem only in CI)
cd gem/bsv-wallet && bundle exec rubocop
```

Running `bundle exec rspec gem/bsv-wallet-postgres/spec/` from the repo root will fail — the postgres spec_helper won't load, so model constants are uninitialized.

## Architecture Framework

The `.architecture/` directory contains the AI Software Architect framework:

- **`members.yml`** — architecture team roster (10 specialists)
- **`principles.md`** — architectural principles governing design decisions
- **`decisions/adrs/`** — Architectural Decision Records
- **`reviews/`** — architecture reviews and system analyses
- **`config.yml`** — framework configuration

Commands: `architecture-status`, `create-adr`, `specialist-review`, `architecture-review`, `list-members`
