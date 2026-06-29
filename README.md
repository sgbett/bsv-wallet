# BSV Wallet

[![CI](https://github.com/sgbett/bsv-wallet/actions/workflows/main.yml/badge.svg)](https://github.com/sgbett/bsv-wallet/actions/workflows/main.yml)
[![Ruby](https://img.shields.io/badge/ruby-%3E%3D%203.3-red)](https://rubygems.org/gems/bsv-wallet)

A single-user, high-throughput BSV wallet built on the [BSV Ruby SDK](https://github.com/sgbett/bsv-ruby-sdk), implementing the [BRC-100](https://github.com/bsv-blockchain/BRCs/blob/master/wallet/0100.md) interface: UTXO lifecycle, transaction construction, broadcasting, and proof management.

## Table of Contents

1. [Acknowledgements](#acknowledgements)
2. [Objective](#objective)
3. [Getting Started](#getting-started)
4. [Features](#features)
5. [Documentation](#documentation)
6. [Contribution Guidelines](#contribution-guidelines)
7. [Support & Contacts](#support--contacts)
8. [Licence](#licence)

## Acknowledgements

This gem owes a debt to the BSV Association's development team, whose work on the [TypeScript SDK](https://github.com/bsv-blockchain/ts-stack/tree/main/packages/sdk) and wallet-toolbox packages inspired our approach. An earlier Ruby port proved the idea was viable; this gem is a clean-room rebuild that carried those lessons forward.

## Objective

Run the BRC-100 surface at the throughput BSV is built for, with as little between Ruby and the database as possible.

The design choices follow from that: no heavy dependencies, a light Ruby-native stack, and a clean division of labour — **the wallet validates, the database enforces**. State is derived, never stored; invalid state is structurally impossible. The reasoning is recorded in the [architecture decision records](.architecture/decisions/adrs/) and the [architecture concepts page](docs/concepts/architecture.md).

### Architecture

Four-layer SOA — each layer has a single responsibility:

```
┌─────────────────────────────────────────────────────────┐
│  Layer 4: Consumer / Presentation                       │
│  (your application — hex conversion, API formatting)    │
├─────────────────────────────────────────────────────────┤
│  Layer 3: Business Process (BRC-100)                    │
│  Engine — orchestration; 28 BRC-100 methods via brc100  │
├─────────────────────────────────────────────────────────┤
│  Layer 2: Services                                      │
│  Store, UTXOPool, Broadcaster, Services                 │
├─────────────────────────────────────────────────────────┤
│  Layer 1: Operational Systems                           │
│  PostgreSQL, ARC, workers, callback endpoints           │
└─────────────────────────────────────────────────────────┘
```

The Engine contains no SQL, no ARC calls, no thread management. It receives Layer 2 components at construction and orchestrates them. Swap implementations by passing different objects — same interface, different backend. For the engineering decomposition behind this customer-facing shape (the contract/concrete collaborator split, the runtime fibres, the structural-state principle), see [docs/concepts/architecture.md](docs/concepts/architecture.md).

### Configuration

End-user configuration lives in the `BSV::Wallet.configure do |c| ... end` block. The canonical reference is the gem's [`config/config.example.rb`](gem/bsv-wallet/config/config.example.rb) template — when installed as a gem, find it under `<gem_dir>/config/config.example.rb` (run `bundle info bsv-wallet` or `gem which bsv-wallet` to locate). Copy it to `~/.bsv-wallet/config.rb` (or set `BSV_WALLET_CONFIG=<path>`) and override the knobs you care about. Every setting also defaults from a shell ENV var (`DATABASE_URL`, `WIF`, `LIMP_THRESHOLD`, `BSV_WALLET_HINTS_SOCKET`, etc.), so the wallet works out of the box from your shell env — the config file is only needed when you want to pin values explicitly or override the defaults.

### Database Backends

The wallet is built for **PostgreSQL** — set `DATABASE_URL` to a `postgres://` URL (or `c.database_url` in your config file; requires the `pg` gem). **SQLite** is a zero-setup fallback for development and fast logic-only tests, and is the default when no `DATABASE_URL` is set. Both run through Sequel.

A `docker-compose.yml` is provided for local PostgreSQL development:

```bash
docker compose up -d postgres
```

It runs `postgres:18` on port `5433` (to avoid clashing with a host install on `5432`) with user/password `postgres`/`postgres`. Data is bind-mounted to `./tmp/postgres-data` (gitignored) — wipe it with `rm -rf tmp/postgres-data` to start fresh.

On first init it creates a handful of empty databases (one for the test suite, a couple for hand-driven CLI sessions); the wallet boots and migrates each per-process.

#### Pre-production migration model

The wallet is pre-production — there is no installed user base whose data must survive a schema change. Schema work edits the migrations under `gem/bsv-wallet/db/migrations/` directly — existing migrations are amended, not only appended — so there is no expectation of forward-migrating a diff. The trade-off is intentional: a clean, re-runnable schema while it is still being shaped.

What this means in practice: **after pulling a branch that touches the schema, wipe and re-migrate** rather than expecting Sequel to migrate the diff forward.

```bash
# Postgres
docker compose down
rm -rf tmp/postgres-data
docker compose up -d postgres

# SQLite
rm -f ~/.bsv-wallet/*.db tmp/*.db   # or whichever DATABASE_URL paths you've used
```

If `bundle exec rspec` starts failing with constraint/column errors after a `git pull`, this is almost always the cause. The wipe will become a non-issue once the wallet has actual deployments — at that point the project will switch to forward-only migrations.

#### Rebuilding dev wallets after a convention flip

A wider change — a derivation-convention flip, a CHECK-literal change, anything that leaves existing on-chain UTXOs unspendable under the new code — needs the funded dev fleet (`alice`/`bob`/`carol`/`sdk`/`w1`..`w5`) rebuilt before merge. The rake tasks below cover the destructive steps; schema lifecycle and on-chain funding are deliberately separate tasks (no bundled "rebuild + fund" path — see #493).

```bash
cd gem/bsv-wallet

# 1. Reset every wallet's database to clean-schema state. Per wallet:
#    sweep current spendable UTXOs back to that wallet's own root,
#    DROP DATABASE, CREATE, migrate. Aborts on sweep failure — the
#    operator should investigate before blowing away DB state.
bundle exec rake fixtures:rebuild_all FORCE=1

# 2. Fund each non-:sdk wallet explicitly. Default 1_000_000 sats from
#    :sdk. Override per call as needed.
bundle exec rake fixtures:fund[alice]
bundle exec rake fixtures:fund[bob,500000]
bundle exec rake fixtures:fund[carol]

# 3. Mechanical merge-gate. Verify each wallet has clean schema state
#    AND a non-zero root balance on chain. Exits non-zero on any
#    failing wallet.
bundle exec rake fixtures:verify
```

For single-wallet operations, the same tasks accept a name:

```bash
bundle exec rake fixtures:rebuild[alice]   # sweep + drop + create + migrate
bundle exec rake fixtures:fund[alice]      # send sats from :sdk
```

`fixtures:rebuild` and `fixtures:fund` are deliberately split — `rebuild` is on-chain-neutral except for the wallet's own sweep-to-root, and `fund` is the only task that moves sats from `:sdk`. There is no bundled "rebuild and fund" path.

After `fixtures:rebuild[sdk]`, sdk's database is empty but the on-chain root P2PKH UTXOs are preserved. Restore sdk's view of those funds via `bin/wallet`:

```bash
bin/wallet --wallet=sdk import   # rescan chain for root UTXOs and internalise
```

The same `import` command also works for `alice`/`bob`/`carol` if you want to pick up their pre-existing on-chain root funding alongside (or instead of) a fresh `fixtures:fund` top-up.

`fixtures:rebuild_all` does **not** abort the fleet on a per-wallet failure — the loop catches the exception, logs which wallet failed, and continues. The task exits non-zero at the end if any wallet failed, listing them in the summary line; the operator triages from there rather than re-running the bulk variant.

Wall time is chain-tip bound (~5-15 minutes for the full fleet). Requires `BSV_WALLET_POSTGRES` + `BSV_WALLET_WIF_<NAME>` in ENV, with `:sdk` carrying ≥ N·1m sats for the N target wallets. Drop+recreate over `DELETE FROM` because the per-wallet `outputs.spendable_recoverable` CHECK embeds the WIF-derived root P2PKH script; a fresh `CREATE DATABASE` rebakes the CHECK against the current WIF.

## Getting Started

### Requirements

- Ruby >= 3.3
- [bsv-sdk](https://github.com/sgbett/bsv-ruby-sdk) gem
- PostgreSQL (the production target — requires the `pg` gem; SQLite is the zero-setup development fallback)

### Installation

Add to your Gemfile:

```ruby
gem 'bsv-wallet'
gem 'pg'  # only if using PostgreSQL
```

### Basic Usage

```ruby
require 'bsv-wallet'

# Connect — SQLite by default, or pass a postgres:// URL for PostgreSQL
store = BSV::Wallet::Store.connect('sqlite://wallet.db')
store.migrate!

# Key derivation from your WIF (the wallet reads it from the environment)
wif = ENV.fetch('WIF')
key_deriver = BSV::Wallet::KeyDeriver.new(
  private_key: BSV::Primitives::PrivateKey.from_wif(wif)
)

# A broadcast provider (GorillaPool / Arcade) drives broadcast + status;
# Services routes chain queries, ChainTracker verifies incoming proofs.
provider = BSV::Network::Providers::GorillaPool.default(testnet: false)
services = BSV::Network::Services.new(providers: [provider])

# Compose the wallet
engine = BSV::Wallet::Engine.new(
  store:         store,
  utxo_pool:     BSV::Wallet::Store::UTXOPool.new(store: store),
  broadcaster:   BSV::Network::Broadcaster.new(providers: [provider], store: store),
  services:      services,
  key_deriver:   key_deriver,
  chain_tracker: BSV::Network::ChainTracker.new(store: store, services: services),
  network:       :mainnet
)

# Create a transaction (BRC-100 createAction)
result = engine.create_action(
  description: 'payment to merchant',
  outputs: [
    { satoshis: 5000, locking_script: recipient_script, basket: 'payments' }
  ],
  labels: ['merchant']
)

# result[:txid]  — 32-byte wire-order wtxid
# result[:tx]    — Atomic BEEF binary (BRC-95)
```

## Features

- **BRC-100 Interface** — All 28 wallet methods: transaction creation, signing, internalization, listing, key management, cryptography, certificates, authentication, and network queries.
- **Action Lifecycle** — Phase-based state machine: create (lock inputs) → sign (attach wtxid) → broadcast → promote (write outputs). Status derived from structure, never stored.
- **SPV Validation** — Structural BEEF verification via the SDK's `Transaction::Tx#verify`, with optional merkle-root checking through the chain tracker.
- **Proof Management** — Merkle proof storage from BEEF ancestry and ARC callbacks, automatic linking to actions.
- **Broadcast Lifecycle** — Immediate and delayed broadcast via ARC, webhook callback handling, stale broadcast polling.
- **UTXO Management** — Basket-based output organization, tag filtering, coin selection, structural locking (INSERT ON CONFLICT) for concurrency safety.
- **Deferred Signing** — Create transactions with placeholder inputs, apply caller-provided unlocking scripts later via `sign_action`.
- **trustSelf Optimization** — Replace known ancestors with TXID-only BEEF entries when the wallet already holds their proofs.

## Documentation

Full documentation is available at **[sgbett.github.io/bsv-wallet](https://sgbett.github.io/bsv-wallet/)**, layered as Getting Started → Guides → Concepts → Reference. The first three are narrative (read in order from the top, or jump to the layer that answers the question in hand); Reference is canonical (cited from the other layers, not restated).

- [Getting Started — Quickstart](docs/getting-started/quickstart.md) — install, configure, send your first transaction
- [Concepts — Architecture](docs/concepts/architecture.md) — the system as a narrative: layers, components, the principles they encode
- [API Reference](https://sgbett.github.io/bsv-wallet/reference/api/) — auto-generated from YARD annotations
- [Architecture Decision Records](.architecture/decisions/adrs/) — the foundational design decisions and their rationale
- [BRC-100 Specification](https://github.com/bsv-blockchain/BRCs/blob/master/wallet/0100.md) — the external contract this wallet implements

**Protocol reference:**

The [BSV Protocol Documentation](https://hub.bsvblockchain.org/bitcoin-protocol-documentation) on the BSV Hub is the canonical protocol reference. The project includes an [MCP](https://modelcontextprotocol.io/) configuration (`.mcp.json`) that connects [Claude Code](https://docs.anthropic.com/en/docs/claude-code) to the hub's search endpoint for AI-assisted development.

## Contribution Guidelines

Contributions are welcome — bug reports, feature requests, and pull requests.

1. **Fork & Clone** — Fork this repository and clone it locally.
2. **Set Up** — Run `bundle install` in `gem/bsv-wallet` to install dependencies. For PostgreSQL testing, start the provided container with `docker compose up -d postgres` and set `DATABASE_URL` (see [Database Backends](#database-backends)).
3. **Branch** — Create a new branch for your changes.
4. **Test** — Ensure all specs pass with `cd gem/bsv-wallet && bundle exec rspec spec/bsv spec/bin`, and lint passes with `bundle exec rubocop`.
5. **Commit** — Follow [Conventional Commits](https://www.conventionalcommits.org/) for commit messages.
6. **Pull Request** — Open a pull request against `master`.

## Support & Contacts

Maintainer: Simon Bettison

For questions, bug reports, or feature requests, please [open an issue](https://github.com/sgbett/bsv-wallet/issues) on GitHub.

## Licence

[Open BSV Licence Version 5](LICENSE)

Thank you for being a part of the BSV Blockchain Libraries Project. Let's build the future of BSV Blockchain together!
