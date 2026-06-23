# Quickstart

From nothing to a first on-chain payment. This is the happy path;
environmental detail lives in
[Installation & Configuration](installation.md).

## Prerequisites

- Ruby >= 3.3
- A funded WIF private key (mainnet or testnet)
- Docker (optional — only if you want Postgres instead of SQLite)

## 1. Choose a backend

=== "SQLite (default, zero-config)"

    Nothing to do. With `DATABASE_URL` unset, the wallet creates
    `~/.bsv-wallet/<name>.db` automatically.

=== "Postgres"

    ```sh
    docker compose up -d        # Postgres on localhost:5433
    ```

    Add `pg` to your Gemfile (the gem ships only `sqlite3`), then either
    set `DATABASE_URL` or set the `BSV_WALLET_POSTGRES` base URL — see
    [Installation & Configuration](installation.md).

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

ctx = BSV::Wallet::CLI.boot(wallet_name: 'alice')   # migrates the DB, builds the Engine
puts ctx[:key_deriver].root_private_key.public_key.address
```

The root address is the only funding entry point — everything else flows
from there.

## 4. Ingest the funds

```ruby
engine = ctx[:engine]
engine.import_wallet   # scans the root address, imports each UTXO
```

`import_wallet` defaults to `no_send: false` — the import self-payment is
queued for `walletd` to broadcast. Pass `no_send: true` if you want to
build locally without publishing (rare; tests only).

## 5. Send a payment

```ruby
result = engine.send_payment(
  recipient: '02a1b2…',   # 66-char compressed pubkey hex
  satoshis:  5_000
)

# result => {
#   txid:                <32-byte binary>,   # wire-order wtxid — convert via to_dtxid for display
#   beef:                <binary>,           # atomic BEEF
#   sender_identity_key: "<66-char hex>",    # compressed pubkey, hex per identity carve-out
#   outputs: [{ vout: 0, satoshis: 5_000, derivation_prefix: "...", derivation_suffix: "1" }]
# }
```

`no_send` defaults to `false` (broadcast — the BRC-100 `createAction`
default). Pass `no_send: true` to build the BEEF envelope without
publishing — the shape callers reach for when handing the action off to a
counterparty peer-to-peer.

The `txid:` key is the subject `wtxid` (wire-order binary, 32 bytes), the
BRC-100 spec boundary name. Convert to a display-order hex string with
the `BSV::Wallet::Txid` refinement:

```ruby
using BSV::Wallet::Txid
result[:txid].to_dtxid   # => 64-char display-order hex
```

See the [wtxid / dtxid convention in Transactions & BEEF](../concepts/transactions-and-beef.md#byte-order-wire-vs-display).

## 6. Run the daemon

A queued broadcast is *queued*, not pushed — nothing lands on chain until
`walletd` is running:

```sh
bin/walletd alice mainnet
```

## 7. Peer-to-peer delivery

For sending a payment directly to a counterparty (BRC-29 over HTTP),
compose the porcelain pipe on the sender side:

```sh
bin/create alice <bob_identity_key> 500 --no-send \
  | bin/transmit alice --to <bob_identity_key> --endpoint https://peer.example/internalize
```

On the recipient side, `bin/receive` reads the JSON envelope on stdin and
internalises the outputs.

!!! warning "Gotchas to know about"
    - **Limp mode** blocks all outbound spend below 50,000 sats. Set
      `LIMP_THRESHOLD` (or `c.limp_threshold` in `~/.bsv-wallet/config.rb`)
      to lift the floor.
    - **`no_send` defaults to `false`** (broadcast). Pass `no_send: true`
      to build a BEEF envelope without publishing — the shape `bin/create`
      uses for the peer pipe.
    - **One wallet per process** — never boot two in the same process.
      Each `bin/` script is its own OS process for this reason.
