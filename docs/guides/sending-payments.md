# Sending Payments

Task recipes for the wallet porcelain. Each call returns a hash; per-keyword
detail and the lower-level BRC-100 methods are in the
[API reference](../reference/api/index.md).

!!! warning "`no_send` defaults to `false`"
    Every method here broadcasts by default (matching BRC-100). Pass
    `no_send: true` to build and sign without publishing, returning a BEEF
    envelope for peer-to-peer handoff. See [Safety Rules](safety-rules.md).

## Send a payment

```ruby
engine.send_payment(
  recipient: '02a1b2...',   # 66-char compressed pubkey hex (02/03 prefix)
  satoshis:  5_000
)
# => {
#      txid:                "<32-byte binary wtxid>",
#      beef:                "<Atomic BEEF binary>",
#      sender_identity_key: "<66-char hex>",
#      outputs: [
#        { vout: 0, satoshis: 5_000,
#          derivation_prefix: "<...>", derivation_suffix: "1" }
#      ]
#    }
```

The `txid:` key is the subject's wire-order wtxid (32-byte binary). The name
follows the BRC-100 boundary convention — keep it as-is when threading the
value through spec-shaped calls. For logging or display, convert to hex via
the `BSV::Wallet::Txid` refinement: `using BSV::Wallet::Txid;
result[:txid].to_dtxid`.

`send_payment` generates BRC-42 derivation parameters, derives a P2PKH locking
script for the recipient, and delegates to `build_action`, whose funding loop
handles UTXO selection, fees, and change (see
[Broadcast Lifecycle](broadcast-lifecycle.md)). With `no_send: true` the
returned BEEF is for peer-to-peer handoff — see
[Deliver to a peer](#deliver-to-a-peer) below.

## Bootstrap: getting the wallet funded

A new wallet owns nothing on chain. Funding is a two-step bootstrap:

1. Send satoshis to the wallet's **root-key P2PKH address**:

   ```ruby
   ctx[:key_deriver].root_private_key.public_key.address
   ```

2. Scan that address and ingest its UTXOs:

   ```ruby
   engine.import_wallet
   # => { imported: <count>, utxos: [...] }
   ```

`import_wallet` queries the network for the root address's UTXOs and calls
`import_utxo` for each. `import_utxo` verifies the on-chain output is P2PKH to
the root key before importing, then runs a small self-payment to bring the
funds under BRC-42-derived management — so the wallet's spendable balance is
the gross UTXO value minus that fee. Imports are idempotent: a duplicate
`wtxid` is skipped.

## Receive addresses (WBIKD)

```ruby
engine.generate_receive_address
# => { address:, derivation_prefix:, derivation_suffix: }

engine.list_receive_addresses   # outstanding (pending) addresses
engine.scan_receive_addresses   # scan + import any funds received
```

Each receive address derives deterministically from on-chain data (a slot's
source txid and vout), which is what makes database-loss recovery possible.

## Consolidation and sweeping

A single transaction cannot consume an unbounded number of inputs, so reducing
a fragmented UTXO set is iterative:

```ruby
engine.consolidate_step(target_inputs: 20)
# picks the smallest N outputs plus the largest as a fee anchor,
# self-pays with a single change output

engine.sweep(recipient: '02a1b2...')        # one consolidation pass to a recipient
engine.sweep_to_root(target_inputs: 20)     # loop consolidate_step, then sweep to root (recipient defaults to self — the wallet's own identity)
engine.estimate_sweep_fee(input_count:, recipient_script:) # fee preview
```

## Headroom and rejection

```ruby
engine.headroom                      # spendable balance minus the limp threshold
engine.reject_action(action_id:)     # operator-driven failure + cascade unwind
```

`headroom` reflects the limp-mode guard; `reject_action` is the manual entry
point to the rejection cascade described in
[Broadcast Lifecycle](broadcast-lifecycle.md).

## Deliver to a peer

Broadcasting ships a transaction to the miner network for consensus.
*Transmit* is the complementary path: it ships a signed action's Atomic BEEF
to a **named peer** for SPV — the BEEF-handoff destination for a
`no_send: true` action.

```ruby
engine.transmission.transmit(
  counterparty:        '02a1b2...',           # peer identity pubkey, lowercase BRC-43 hex
  action_id:           42,
  outputs:             [{ vout:, satoshis:, derivation_prefix:, derivation_suffix: }],
  sender_identity_key: ctx[:identity_key],
  endpoint:            'https://peer.example/ingest'  # optional; nil = you deliver it
)
# => { transmission_id:, beef:, sent_wtxids:, outputs:, sender_identity_key:, delivery: }
```

With an `endpoint`, the wallet POSTs the per-peer-trimmed BEEF over HTTPS and
records the ACK on success; with `endpoint: nil` it returns the envelope and
you take responsibility for delivery. The `counterparty` must be a canonical
BRC-43 compressed pubkey (lowercase, `02`/`03` prefix) — `self`/`anyone`
sentinels and mixed-case hex are rejected at the engine boundary. The HTTPS
endpoint passes an SSRF policy gate; see
[Safety Rules](safety-rules.md#transmission-security-envelope) and
[Operating the Daemon](operating-the-daemon.md). The `bin/transmit` script
wraps this for the command line.
