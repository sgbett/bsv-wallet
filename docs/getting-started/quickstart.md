---
title: Quickstart
parent: Getting Started
nav_order: 2
---

# Quickstart

From nothing to a first on-chain payment. This is the happy path;
environmental detail lives in
[Installation & Configuration](installation.md).

## Prerequisites

- Ruby >= 3.3
- A funded WIF private key (mainnet or testnet)
- Docker (optional — only if you want Postgres instead of SQLite)

## 1. Choose a backend

### SQLite (default, zero-config)

Nothing to do. With no database URL configured, the wallet creates `~/.bsv-wallet/<name>.db` automatically (`default.db` for the unnamed wallet).

### Postgres

```sh
docker compose up -d        # Postgres on localhost:5433
```

Add `pg` to your Gemfile (the gem ships only `sqlite3`). Then point the wallet at the server: for a named wallet such as `alice`, set the `BSV_WALLET_POSTGRES` base URL (the wallet uses the database `bsv_wallet_alice`); for the unnamed wallet, set `DATABASE_URL`. See [Installation & Configuration](installation.md).

## 2. Set your key

```sh
export BSV_WALLET_WIF_ALICE=<your-wif-private-key>
# Or, for an unnamed wallet: export WIF=<wif> and omit wallet_name: in step 3.
```

Env-var resolution and named-wallet precedence are covered in
[Installation & Configuration](installation.md).

## 3. Fund the root address

A fresh wallet owns no UTXOs. Boot the wallet and print its **root-key
P2PKH address**, then send some satoshis to it from another wallet:

```ruby
require 'bsv-wallet'
require 'bsv/wallet/cli'   # CLI.boot is not loaded by require 'bsv-wallet'

ctx = BSV::Wallet::CLI.boot(wallet_name: 'alice')   # migrates the DB, builds the Engine
puts ctx[:key_deriver].root_private_key.public_key.address
```

The root address is the only funding entry point — everything else flows
from there.

## 4. Ingest the funds

```ruby
engine = ctx[:engine]
engine.import_wallet(broadcast_intent: :delayed)   # scans the root address, imports each UTXO
```

The broadcast intent is required; there is no default. `:delayed` queues
the import self-payment for `walletd` to broadcast, `:inline` submits it
now, and `:none` builds and signs it without publishing (rare; tests only).

## 5. Send a payment

```ruby
result = engine.send_payment(
  recipient:        '02a1b2…',   # 66-char compressed pubkey hex
  satoshis:         5_000,
  broadcast_intent: :delayed
)

# result => {
#   wtxid:               <32-byte binary>,   # wire order; convert via to_dtxid for display
#   atomic_beef:         <binary>,           # Atomic BEEF (BRC-95)
#   sender_identity_key: "<66-char hex>",    # compressed pubkey, hex per identity carve-out
#   outputs: [{ vout: 0, satoshis: 5_000, derivation_prefix: "...", derivation_suffix: "..." }]
# }
```

The broadcast intent is required; there is no default. `:delayed` queues
the payment for `walletd`, `:inline` submits it now, and `:none` builds and
signs it without publishing — the BEEF envelope callers reach for when
handing the action off to a counterparty peer-to-peer.

`wtxid:` is the subject transaction's ID in wire order (32 bytes of binary). Convert it to a display-order hex string with the `BSV::Wallet::Txid` refinement:

```ruby
using BSV::Wallet::Txid
result[:wtxid].to_dtxid   # => 64-char display-order hex
```

See the [wtxid / dtxid convention in Transactions & BEEF](../concepts/transactions-and-beef.md#byte-order-wire-vs-display).

## 6. Run the daemon

A queued broadcast is *queued*, not pushed — nothing lands on chain until
`walletd` is running:

```sh
bin/walletd alice mainnet
```

## 7. Peer-to-peer delivery

To send a payment directly to a counterparty (BRC-29 over HTTP), pipe `bin/wallet send` into `bin/transmit` on the sender side:

```sh
bin/wallet --wallet=alice send <bob_identity_key> 500 --broadcast=none \
  | bin/transmit alice --to <bob_identity_key> --endpoint https://peer.example/internalize
```

Given an identity key, `bin/wallet send` writes a JSON envelope (the BEEF, the transaction's dtxid, the sender's identity key and the BRC-29 derivation data) to stdout. `bin/transmit` records a transmission, delivers it to the peer's endpoint, and marks it acknowledged only when the peer's ACK names the right transaction. `bin/transmit` takes the wallet name as its first argument rather than `--wallet=`, and `--to` must be lowercase hex. With `--broadcast=none` the transaction goes only to the peer: the sender never broadcasts it, and `bin/wallet receive` doesn't either. Leave the flag off to broadcast it as well.

On the recipient side, `bin/wallet receive` reads the same envelope on stdin (or from `--file=<path>`) and internalises the outputs. This wallet has no HTTP endpoint for incoming transmissions yet (#544), so without a peer service you can hand the envelope over as a file:

```sh
bin/wallet --wallet=alice send <bob_identity_key> 500 > payment.json
bin/wallet --wallet=bob receive --file=payment.json
```

{: .warning }
> **Gotchas to know about**
>
> - **Limp mode** refuses any outbound spend that would leave the wallet's balance below 50,000 sats (importing and sweeping are exempt). Set `LIMP_THRESHOLD` (or `c.limp_threshold` in `~/.bsv-wallet/config.rb`) to move the threshold; it can't go below 10,000.
> - **The broadcast intent has no default.** Pass `broadcast_intent: :none` to build a BEEF envelope without publishing.
> - **One wallet per process** — never boot two in the same process.
>   Each `bin/` script is its own OS process for this reason.
