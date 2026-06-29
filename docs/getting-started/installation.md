---
title: Installation
parent: Getting Started
nav_order: 1
---

# Installation & Configuration

Everything environmental that the [Quickstart](quickstart.md) glosses over:
dependencies, backend selection, configuration, and the bundled executables.

## Install

```ruby
gem 'bsv-wallet'
```

Requires Ruby >= 3.3.

## Runtime dependencies

| Gem | Role |
|---|---|
| `bsv-sdk` (~> 0.24) | Cryptography, transaction building, BEEF, network providers |
| `sequel` (~> 5.0) | ORM and migration runner — the Store layer |
| `sqlite3` | Default embedded backend |
| `async` | The reactor that hosts the daemon's fibers |
| `async-http` (~> 0.95) | HTTPS client for peer delivery (`bin/transmit`) |
| `omq` | In-process message queue for daemon IPC |
| `logger` | `BSV.logger` |

{: .warning }
> **Postgres needs `pg` in your own bundle**
>
> `pg` is **not** a dependency of this gem — only `sqlite3` ships. When you
> point the wallet at a Postgres URL, `Store::Postgres` requires `pg` lazily
> and raises a friendly `LoadError` if it is missing. Add `gem 'pg'` to your
> Gemfile to use Postgres.

## Backend selection

`BSV::Wallet::Store.connect(url)` picks the adapter from the URL scheme:

- `postgres://` or `postgresql://` → Postgres
- anything else → SQLite

`store.migrate!` runs the bundled migrations before the models bind. With
`DATABASE_URL` unset, the wallet falls back to SQLite at
`~/.bsv-wallet/<name>.db` (or `~/.bsv-wallet/default.db` for the unnamed
wallet).

Postgres is the production target — `bytea`, native `uuid`, ENUM types,
CHECK constraints and `RESTRICT` foreign keys all flow through the schema
unchanged. SQLite is a convenience for fast logic-only specs that don't
depend on those primitives. Choose Postgres for any workload you'd put on a
real machine.

## Configuration

`CLI.boot` has two modes, distinguished by whether you pass a wallet name:

- **End-user mode** (`boot(wallet_name: nil)`) — a single wallet whose
  settings come from `BSV::Wallet.config`: a `configure` block in
  `~/.bsv-wallet/config.rb` if present, otherwise ENV defaults read at
  startup (`WIF`, `DATABASE_URL`, `BSV_WALLET_NETWORK`, `LIMP_THRESHOLD`,
  …).
- **Dev/test mode** (`boot(wallet_name: 'alice')`) — named-wallet fixtures
  resolved through `BSV::Wallet::Fixtures`: a `configure` block in
  `~/.bsv-wallet/fixtures.rb`, falling back to the gem default which reads
  `BSV_WALLET_WIF_<NAME>` / `DATABASE_URL_<NAME>` / `BSV_WALLET_POSTGRES`
  from the shell. This lets one environment host several named wallets.

Two conveniences apply to backend selection in both modes:

- **`BSV_WALLET_POSTGRES`** — a base URL such as
  `postgres://postgres:postgres@localhost:5433/`. Each named wallet then
  maps to its own database `bsv_wallet_<name>`, so one variable configures
  every wallet without per-wallet `DATABASE_URL` entries.
- **SQLite fallback** — when no Postgres URL applies, the wallet uses
  `~/.bsv-wallet/<name>.db` (or `default.db` for the unnamed wallet).

### Tuning knobs

`BSV::Wallet.config` reads these ENV vars at startup (override them
programmatically in a `configure` block):

| Variable | Default | Effect |
|---|---|---|
| `LIMP_THRESHOLD` | `50000` | Spending floor — see safety-rules guide |
| `BSV_WALLET_NETWORK` | `mainnet` | `mainnet` / `testnet` |
| `BSV_WALLET_FEE_RATE_SATS_PER_KB` | `100` | Fee rate (default 0.1 sat/byte) |
| `BSV_WALLET_DAEMON_SEQUEL_CONNECTIONS` | `16` | Daemon DB pool size |
| `BSV_WALLET_TX_CACHE_SIZE` | `20000` | Hydrated-tx cache size |
| `BSV_WALLET_REAP_THRESHOLD_S` | `3600` | Stale-action reap age |
| `BSV_WALLET_HINTS_SOCKET` | unset | Optional cross-process EF hint socket |

## Executables

- **`walletd`** — the only packaged executable: the background daemon.
  `bin/walletd [wallet_name] [network]`.
- **Development scripts** (in `bin/`, not packaged): `balance`, `create`,
  `create_action`, `derive`, `import`, `import_root_utxo`, `internalize`,
  `list_outputs`, `lock`, `receive`, `reject`, `select_utxos`, `sweep`,
  `consolidate`, `transmit`. Each boots an Engine via `CLI.boot` and
  exercises one operation.

The composable porcelain for a peer-to-peer payment is the
`bin/create | bin/transmit` pipe on the sender side (signs, builds the
trimmed BEEF, delivers over HTTP) and `bin/receive` on the recipient side
(reads the JSON envelope on stdin and internalises the outputs).
