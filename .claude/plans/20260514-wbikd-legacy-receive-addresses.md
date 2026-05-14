# WBIKD — Legacy Receive Addresses via Wallet Basket Identity Key Derivation

## Context

BRC-29 payments require both parties to have BRC-100 wallets. Legacy senders (exchanges, non-BRC-100 wallets, scripts) need a plain P2PKH address string. WBIKD generates and tracks receive addresses using the wallet's existing action/basket/input machinery — no new tables, no separate watchlist. The database IS the watchlist.

---

## How It Works

1. **Basket `p wbikd`** holds pre-funded UTXOs as "address slots"
2. **Generate address:** lock a slot with a no-send zero-output action, derive BRC-42 address from `encode_int64(action.id)` + `encode_int64(output.id)`
3. **Monitor:** daemon scans outstanding addresses for UTXOs, internalizes funds (tagging with `wbikd`), aborts the lock to recycle the slot
4. **Sweep:** future intermittent scan of all `wbikd`-tagged outputs re-derives addresses and checks for additional payments

---

## Key Design Decisions

### Derivation params are base64-encoded integer IDs, NOT UUIDs

```ruby
derivation_prefix = [action.id].pack('q>').then { |b| [b].pack('m0') }
derivation_suffix = [output.id].pack('q>').then { |b| [b].pack('m0') }
```

**Why integers, not UUIDs:** Recoverability. If the wallet database is lost but the identity key is retained, funds can be recovered by enumerating all `(action_id, output_id)` combinations, deriving the BRC-42 key for each, and checking the resulting address for UTXOs. With UUIDs (128-bit random), enumeration is impossible. With sequential integer IDs, the search space is bounded: `max(action_id) × max(output_id)`. This is security as an economic function — if the lost funds are large enough, the enumeration cost is justified.

The database column type for derivation_prefix/suffix is `text` — these fields accept any string. The reference wallets use base64-encoded 8 random bytes (12-char strings). Our WBIKD encoding produces the same format (base64 of 8 bytes).

### Slot creation MUST broadcast

```ruby
create_action(description: 'wbikd slot creation', outputs: [...], randomize_outputs: false)
# No no_send: true — this broadcasts
```

**Why broadcast:** Auto-fund selects UTXOs and creates change outputs. Without broadcast, those funding UTXOs stay locked indefinitely and change never becomes spendable. The wallet's effective balance shrinks each time an address is generated. Broadcasting releases the change immediately. The random satoshi amount (100-1000) also provides privacy — slots are indistinguishable from normal wallet activity on-chain.

### Locking action is a hypothesis; internalized output is evidence

The locking action says "someone might pay to this address." It exists solely to:
- Lock the slot (prevent reuse via UNIQUE constraint on `inputs.output_id`)
- Provide the action.id for deterministic derivation
- Be discoverable via the `wbikd` label for scanning

When funds arrive, `internalize_wbikd_utxo` crystallizes the derivation params onto the internalized output row (permanent, immutable). The locking action is then aborted — the hypothesis is discarded once evidence exists. The slot returns to `p wbikd` for reuse.

### Tag internalized outputs for sweep scanning

Internalized outputs are tagged `wbikd`. This enables future sweep tools to:
1. `list_outputs(tags: ['wbikd'])` — find every address ever used
2. Re-derive each address from the stored `derivation_prefix`/`derivation_suffix`
3. Check for additional payments (someone re-sending to a previously used address)

The tag survives output spending (output rows are immutable), so the sweep can always find historical addresses even after the locking action is long gone and the funds have been spent.

---

## Phase 1: `Engine#generate_receive_address`

**File:** `gem/bsv-wallet/lib/bsv/wallet/engine.rb`

```ruby
def generate_receive_address
  require_key_deriver!

  slot = find_or_create_wbikd_slot

  # Lock the slot with a no-send zero-output action.
  # Uses @store.create_action directly — internal operation,
  # should not enforce limp mode.
  locking_action = @store.create_action(
    action: { description: 'wbikd address lock', broadcast: :none, nlocktime: 0, outgoing: true },
    inputs: [{ output_id: slot[:id], vin: 0 }]
  )
  wtxid, raw_tx, = build_transaction(locking_action[:id], [{ output_id: slot[:id] }], [], nil, nil, false)
  @store.sign_action(action_id: locking_action[:id], wtxid: wtxid, raw_tx: raw_tx)
  @proof_store.save_proof(wtxid: wtxid, proof: { raw_tx: raw_tx })
  attach_labels(locking_action[:id], ['wbikd'])

  # Derive address from deterministic integer-based params
  derivation_prefix = encode_int64(locking_action[:id])
  derivation_suffix = encode_int64(slot[:id])
  derived_pub = @key_deriver.derive_public_key(
    protocol_id: [2, derivation_prefix], key_id: derivation_suffix, counterparty: 'self'
  )
  address = BSV::Primitives::PublicKey.from_bytes(derived_pub).address(network: @network_name)

  { address: address, derivation_prefix: derivation_prefix, derivation_suffix: derivation_suffix }
end
```

**Private helpers:**

```ruby
def find_or_create_wbikd_slot
  result = @store.query_outputs(basket: 'p wbikd', limit: 1)
  return result[:outputs].first if result[:total].positive?

  # Broadcast self-payment — releases change back to wallet
  prefix = SecureRandom.uuid  # TODO: replace with random_derivation (#107)
  suffix = '1'
  # ... derive key, build script, create_action with broadcast ...
end

def encode_int64(int)
  [int].pack('q>').then { |b| [b].pack('m0') }
end
```

---

## Phase 2: `Engine#list_receive_addresses`

Uses `list_actions(labels: ['wbikd'], include_inputs: true)` — no new store methods. Re-derives addresses from `encode_int64(action[:id])` and `encode_int64(input[:output_id])`.

---

## Phase 3: Daemon integration

Add `pending_scans: nil` to `Daemon.initialize` (backward-compatible). Calls `@pending_scans.call` each cycle if set.

---

## Phase 4: `Engine#scan_receive_addresses`

Scans outstanding addresses via `:get_utxos`. For each found UTXO, calls `internalize_wbikd_utxo`.

---

## Phase 5: Fund internalization + slot recycling

`internalize_wbikd_utxo`:
1. Fetch raw tx, verify P2PKH output matches derived address
2. Create incoming action, promote with derivation params + `tags: ['wbikd']`
3. Fetch and link merkle proof if mined
4. Abort the locking action → slot recycled to `p wbikd`

---

## Related Issues

- **#107** — Replace `SecureRandom.uuid` with `random_derivation` helper across all derivation sites

---

## Files Modified

| File | Change |
|---|---|
| `gem/bsv-wallet/lib/bsv/wallet/engine.rb` | Add `generate_receive_address`, `list_receive_addresses`, `scan_receive_addresses` (public); `find_or_create_wbikd_slot`, `internalize_wbikd_utxo`, `fetch_and_link_proof`, `encode_int64` (private); refactor proof fetching out of `import_utxo` |
| `gem/bsv-wallet/lib/bsv/wallet/daemon.rb` | Add `pending_scans:` parameter and `run_scans` call |
| `gem/bsv-wallet/spec/bsv/wallet/engine/wbikd_spec.rb` | WBIKD specs |
| `gem/bsv-wallet/spec/bsv/wallet/daemon_spec.rb` | Scan cycle specs |

---

## Verification

```bash
cd gem/bsv-wallet && bundle exec rspec
cd gem/bsv-wallet-postgres && bundle exec rspec
cd gem/bsv-wallet && bundle exec rubocop
```
