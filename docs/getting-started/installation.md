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
| `bsv-sdk` (~> 0.26) | Cryptography, transaction building, BEEF, network providers |
| `sequel` (~> 5.0) | ORM and migration runner — the Store layer |
| `sqlite3` | Default embedded backend |
| `async` | The reactor that hosts the daemon's fibres |
| `async-http` (~> 0.95) | HTTP client for the daemon's Arcade status stream (`Network::SSEListener`) |
| `omq` | Message-queue sockets between the daemon's fibres, and the optional cross-process hints socket |
| `logger` | `BSV.logger` |

Peer delivery (`bin/transmit`) uses Ruby's standard `net/http`, not `async-http`.

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

`store.migrate!` runs the bundled migrations before the models bind. With no database URL configured (see [Configuration](#configuration)), the wallet falls back to SQLite at `~/.bsv-wallet/<name>.db` (or `~/.bsv-wallet/default.db` for the unnamed wallet).

Postgres is the production target — `bytea`, native `uuid`, ENUM types,
CHECK constraints and `RESTRICT` foreign keys all flow through the schema
unchanged. SQLite is a convenience for fast logic-only specs that don't
depend on those primitives. Choose Postgres for any workload you'd put on a
real machine.

## Configuration

`CLI.boot` has two modes, distinguished by whether you pass a wallet name:

- **End-user mode** (`boot(wallet_name: nil)`) — a single wallet whose settings come from `BSV::Wallet.config`: a `configure` block in `~/.bsv-wallet/config.rb` (or the file `BSV_WALLET_CONFIG` names) if present, otherwise ENV defaults read at startup (`WIF`, `DATABASE_URL`, `BSV_WALLET_NETWORK`, `LIMP_THRESHOLD`, …).
- **Dev/test mode** (`boot(wallet_name: 'alice')`) — named-wallet fixtures
  resolved through `BSV::Wallet::Fixtures`: a `configure` block in
  `~/.bsv-wallet/fixtures.rb`, falling back to the gem default which reads
  `BSV_WALLET_WIF_<NAME>` / `DATABASE_URL_<NAME>` / `BSV_WALLET_POSTGRES`
  from the shell. This lets one environment host several named wallets.

Two conveniences apply to backend selection:

- **`BSV_WALLET_POSTGRES`** (named wallets only) — a base URL such as `postgres://postgres:postgres@localhost:5433/`. Each named wallet then maps to its own database `bsv_wallet_<name>`, so one variable configures every named wallet without per-wallet `DATABASE_URL_<NAME>` entries (which, when set, take precedence). The unnamed wallet ignores it and reads `DATABASE_URL`.
- **SQLite fallback** (both modes) — when no database URL applies, the wallet uses `~/.bsv-wallet/<name>.db` (or `default.db` for the unnamed wallet).

### Tuning knobs

`BSV::Wallet.config` reads these ENV vars at startup; a `configure` block overrides them through the attribute named.

| Variable | `configure` attribute | Default | Effect |
|---|---|---|---|
| `LIMP_THRESHOLD` | `limp_threshold` | `50000` | Spending floor in sats (minimum 10,000) — see [Safety rules](../guides/safety-rules.md#limp-mode) |
| `BSV_WALLET_NETWORK` | `network` | `mainnet` | `mainnet` / `testnet` |
| `BSV_WALLET_TRUST_MODEL` | `trust_model` | `trusted_service` | Who answers merkle-root checks: `trusted_service` or `spv_headers` — see [SPV header verification](../reference/spv-header-verification.md) |
| `BSV_WALLET_FEE_RATE_SATS_PER_KB` | `fee_model` | `100` | Fee rate in sats/kB (0.1 sat/byte); the attribute takes a whole fee model |
| `BSV_WALLET_DAEMON_SEQUEL_CONNECTIONS` | `daemon_pool_size` | `16` | `walletd`'s Sequel connection pool size |
| `BSV_WALLET_TX_CACHE_SIZE` | `tx_cache_size` | `20000` | Capacity of the `HydratedTxCache`, in entries (`0` disables it) |
| `BSV_WALLET_REAP_THRESHOLD_S` | `reap_threshold` | `3600` | Age in seconds after which `walletd` reaps an abandoned action |
| `BSV_WALLET_HINTS_SOCKET` | `hints_socket` | unset (off) | OMQ endpoint, such as an `ipc://` socket path, that `walletd` binds to receive Atomic BEEF hints from other processes' Engines |

{: .warning }
> **The hints socket is a trust boundary**
>
> The hints socket is unauthenticated, and `walletd` deserialises every message it receives on it, so only trusted local processes may be able to reach it. Use an `ipc://` socket in a directory that only the wallet's user can access, never a shared directory or a network endpoint (#556).

## Executables

The gem's `bin/` directory holds three scripts, and all three ship in the gem. Only `walletd` is installed as an executable, so run `wallet` and `transmit` from a checkout or from the installed gem's directory.

- **`walletd`** — the background daemon: `bin/walletd [wallet_name] [network]`.
- **`wallet`** — the command-line wallet: `bin/wallet [global-flags] <command> [args]`, with the commands `balance`, `list`, `send`, `receive`, `import`, `reject`, `sweep` and `consolidate`. Global flags such as `--wallet=<name>` come before the command; `bin/wallet --help` and `bin/wallet <command> --help` list them.
- **`transmit`** — delivers an action's Atomic BEEF to a named peer over HTTP: `bin/transmit [wallet_name] --to <identity_key> --endpoint <url>`.

`wallet` and `transmit` boot an Engine through `CLI.boot`, one wallet per process; `walletd` boots a Store and a broadcaster but no Engine.

For a peer-to-peer payment, the sender pipes `bin/wallet send <identity_key> <sats>` into `bin/transmit`, which delivers the envelope over HTTP, and the recipient runs `bin/wallet receive`, which reads the same JSON envelope on stdin and internalises the outputs. The [Quickstart](quickstart.md) walks through the commands.
