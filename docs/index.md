# BSV Wallet

A [BRC-100](https://github.com/bsv-blockchain/BRCs/blob/master/wallet/0100.md) single-key wallet engine and daemon for Ruby. Transaction management, key derivation, encryption, certificates, identity verification — all 28 spec methods surfaced, with porcelain on top for payments, sweeps and peer delivery.

## What this is not

A server-side library. No GUI, no seed-phrase recovery flow, no browser extension, no mobile SDK. The wallet is a long-lived process holding a single WIF, designed to be embedded in a Ruby application or run as a daemon (`bin/walletd`).

## At a glance

| Area | Capability |
|---|---|
| Spec | All 28 BRC-100 methods surfaced via `engine.brc100` (4 stubs/unsupported — see capability matrix) |
| Key derivation | BRC-42/43 (ECDH + invoice-number), not plain BIP-32 |
| Certificates | BRC-52 selective disclosure, BRC-69 Schnorr key-linkage |
| Tx interchange | BRC-95 atomic BEEF; BRC-29 envelope for peer delivery |
| Backends | Postgres-primary, SQLite-augmentation (one schema, two adapters) |
| Network | ARC broadcast, callback or polling; daemon-side `bin/walletd` |
| Safety | Limp mode below 50,000 sats spendable; hard floor 10,000 |
| Fee model | 100 sat/KB default, configurable |
| Network default | mainnet (`BSV_WALLET_NETWORK=testnet` to switch) |
| Constraints | One wallet per OS process; Ruby >= 3.3; `pg` in your Gemfile for Postgres |

## Where next

- **New here** — [Getting Started](getting-started/installation.md): install the gem and run the quickstart.
- **Doing something specific** — [Guides](guides/sending-payments.md): payments, broadcast lifecycle, operating the daemon, safety rules.
- **Understanding how it works** — [Concepts](concepts/architecture.md): architecture, action lifecycle, transactions and BEEF, transmission, persistence, events.
- **Canonical rules** — [Reference](reference/principle-of-state.md): principles, schema, state machines, external specs.

See [About these docs](about-these-docs.md) for the four-layer structure and link policy.
