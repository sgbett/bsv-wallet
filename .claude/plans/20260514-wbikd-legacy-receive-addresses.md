# WBIKD — Legacy Receive Addresses via Wallet Basket Identity Key Derivation

## Context

BRC-29 payments require both parties to have BRC-100 wallets. Legacy senders (exchanges, non-BRC-100 wallets, scripts) need a plain P2PKH address string. WBIKD generates and tracks receive addresses using the wallet's existing action/basket/input machinery — no new tables, no separate watchlist. The database IS the watchlist.

---

## How It Works

1. **Basket `p wbikd`** holds pre-funded UTXOs as "address slots"
2. **Generate address:** lock a slot with a no-send zero-output action, derive BRC-42 address from action.reference + output.id
3. **Monitor:** daemon scans outstanding addresses for UTXOs, internalizes funds, aborts the lock to recycle the slot

---

## Phase 1: `Engine#generate_receive_address`

**File:** `gem/bsv-wallet/lib/bsv/wallet/engine.rb`

```ruby
def generate_receive_address
  require_key_deriver!

  slot = find_or_create_wbikd_slot

  # Lock the slot with a no-send zero-output action
  locking_action = @store.create_action(
    action: { description: 'wbikd address lock', broadcast: :none, outgoing: true },
    inputs: [{ output_id: slot[:id], vin: 0 }]
  )
  wtxid, raw_tx, _ = build_transaction(locking_action[:id], [{ output_id: slot[:id] }], [], nil, nil, false)
  @store.sign_action(action_id: locking_action[:id], wtxid: wtxid, raw_tx: raw_tx)
  @proof_store.save_proof(wtxid: wtxid, proof: { raw_tx: raw_tx })
  attach_labels(locking_action[:id], ['wbikd'])

  # Derive address from deterministic params
  derivation_prefix = locking_action[:reference].to_s
  derivation_suffix = slot[:id].to_s
  derived_pub = @key_deriver.derive_public_key(
    protocol_id: [2, derivation_prefix], key_id: derivation_suffix, counterparty: 'self'
  )
  address = BSV::Primitives::PublicKey.from_bytes(derived_pub).address(network: @network_name)

  { address: address, derivation_prefix: derivation_prefix, derivation_suffix: derivation_suffix }
end
```

**Private helper — slot creation:**

```ruby
def find_or_create_wbikd_slot
  result = @store.query_outputs(basket: 'p wbikd', limit: 1)
  return result[:outputs].first if result[:total_outputs] > 0

  # Create a slot via self-payment (broadcast, random sats for privacy)
  prefix = SecureRandom.uuid
  suffix = '1'
  derived_pub = @key_deriver.derive_public_key(
    protocol_id: [2, prefix], key_id: suffix, counterparty: 'self'
  )
  script = BSV::Script::Script.p2pkh_lock(
    BSV::Primitives::Digest.hash160(derived_pub)
  ).to_binary

  slot_sats = rand(100..1000)  # Random amount — indistinguishable from normal activity
  create_action(
    description: 'wbikd slot creation',
    outputs: [{
      satoshis: slot_sats, locking_script: script,
      basket: 'p wbikd',
      derivation_prefix: prefix, derivation_suffix: suffix,
      sender_identity_key: @key_deriver.identity_key
    }],
    randomize_outputs: false
  )

  # Re-query for the newly created slot
  result = @store.query_outputs(basket: 'p wbikd', limit: 1)
  result[:outputs].first
end
```

**Why broadcast the slot creation:** The slot is a real on-chain self-payment with random satoshis — indistinguishable from normal wallet activity. Privacy by default.

**Why the locking action bypasses public `create_action`:** It calls `@store.create_action` + `build_transaction` directly because it's an internal operation (doesn't spend wallet funds, shouldn't enforce limp mode). The slot creation goes through public `create_action` (auto-funded, does enforce limp mode).

---

## Phase 2: `Engine#list_receive_addresses`

**File:** `gem/bsv-wallet/lib/bsv/wallet/engine.rb`

```ruby
def list_receive_addresses
  require_key_deriver!

  result = list_actions(labels: ['wbikd'], include_inputs: true)
  result[:actions].filter_map do |action|
    next unless action[:status] == :nosend

    input = action[:inputs]&.first
    next unless input

    derivation_prefix = action[:reference].to_s
    derivation_suffix = input[:output_id].to_s
    derived_pub = @key_deriver.derive_public_key(
      protocol_id: [2, derivation_prefix], key_id: derivation_suffix, counterparty: 'self'
    )
    address = BSV::Primitives::PublicKey.from_bytes(derived_pub).address(network: @network_name)

    { address: address, derivation_prefix: derivation_prefix,
      derivation_suffix: derivation_suffix,
      action_reference: action[:reference], created_at: action[:created_at] }
  end
end
```

Uses `list_actions(labels: ['wbikd'], include_inputs: true)` — no new store methods needed. The `wbikd` label is attached during `generate_receive_address`.

---

## Phase 3: Daemon integration

**File:** `gem/bsv-wallet/lib/bsv/wallet/daemon.rb`

Add optional `pending_scans:` parameter (backward-compatible):

```ruby
def initialize(services:, pending_pushes: -> { [] }, stale_fetches: -> { [] },
               pending_proofs: -> { [] }, pending_scans: nil, interval: 30)
  @pending_scans = pending_scans
end
```

Add `run_scans` to the polling cycle:

```ruby
def run_cycle
  push_pending
  fetch_stale
  fetch_proofs
  run_scans if @pending_scans
end

def run_scans
  @pending_scans.call
rescue StandardError => e
  BSV.logger&.error { "[Daemon] scan error: #{e.class}: #{e.message}" }
end
```

The callable is wired at boot time:

```ruby
# In CLI.boot or application setup:
pending_scans = -> { engine.scan_receive_addresses }
```

---

## Phase 4: `Engine#scan_receive_addresses`

**File:** `gem/bsv-wallet/lib/bsv/wallet/engine.rb`

```ruby
def scan_receive_addresses
  return { scanned: 0, found: 0 } unless @key_deriver && @network_provider

  addresses = list_receive_addresses
  return { scanned: 0, found: 0 } if addresses.empty?

  found_count = 0
  addresses.each do |addr_info|
    result = @network_provider.call(:get_utxos, addr_info[:address])
    next unless result.respond_to?(:http_success?) && result.http_success?

    utxos = result.data
    next if utxos.nil? || utxos.empty?

    utxos.each do |utxo|
      internalize_wbikd_utxo(
        dtxid: utxo['tx_hash'], vout: utxo['tx_pos'],
        derivation_prefix: addr_info[:derivation_prefix],
        derivation_suffix: addr_info[:derivation_suffix],
        action_reference: addr_info[:action_reference]
      )
      found_count += 1
    rescue StandardError => e
      BSV.logger&.error { "[Engine] wbikd scan: #{e.message}" }
    end
  end

  { scanned: addresses.length, found: found_count }
end
```

---

## Phase 5: Fund internalization + slot recycling

**File:** `gem/bsv-wallet/lib/bsv/wallet/engine.rb`

Private method modeled on `import_utxo` (engine.rb:342):

```ruby
def internalize_wbikd_utxo(dtxid:, vout:, derivation_prefix:, derivation_suffix:, action_reference:)
  # 1. Fetch raw tx from network
  result = @network_provider.call(:get_tx, txid: dtxid)
  return unless result.respond_to?(:http_success?) && result.http_success?

  raw_tx = parse_raw_tx(result.data)
  tx = BSV::Transaction::Transaction.from_binary(raw_tx)
  output = tx.outputs[vout]
  return unless output

  # 2. Verify output matches our derived address
  derived_pub = @key_deriver.derive_public_key(
    protocol_id: [2, derivation_prefix], key_id: derivation_suffix, counterparty: 'self'
  )
  expected_hash = BSV::Primitives::Digest.hash160(derived_pub)
  return unless output.locking_script.p2pkh? &&
                output.locking_script.chunks[2].data == expected_hash

  # 3. Create incoming action (same pattern as import_utxo)
  wtxid = tx.wtxid
  import_action = @store.create_action(
    action: { description: 'wbikd received funds', broadcast: :none, outgoing: false }
  )
  @store.sign_action(action_id: import_action[:id], wtxid: wtxid, raw_tx: raw_tx)
  @proof_store.save_proof(wtxid: wtxid, proof: { raw_tx: raw_tx })

  # 4. Promote with BRC-42 derivation params (output is immediately spendable)
  @store.promote_action(
    action_id: import_action[:id],
    outputs: [{
      satoshis: output.satoshis, vout: vout,
      locking_script: output.locking_script.to_binary,
      derivation_prefix: derivation_prefix,
      derivation_suffix: derivation_suffix,
      sender_identity_key: @key_deriver.identity_key
    }]
  )

  # 5. Fetch and link merkle proof if mined
  fetch_and_link_proof(import_action[:id], wtxid, dtxid)

  # 6. Abort the locking action — CASCADE releases slot back to p wbikd basket
  abort_action(reference: action_reference)
end
```

**No self-payment step needed** (unlike `import_utxo`): the internalized output already has BRC-42 derivation params, so the wallet can spend it directly with `derive_signing_key`. Root-key UTXOs need a self-payment because they lack derivation — WBIKD outputs don't.

**Slot recycling:** `abort_action` CASCADE-deletes the locking action's input row → slot output becomes spendable again → back in basket `p wbikd` → available for next `generate_receive_address`.

---

## Refactor: Extract `fetch_and_link_proof`

**File:** `gem/bsv-wallet/lib/bsv/wallet/engine.rb`

Extract the merkle proof fetching from `import_utxo` (lines ~370-390) into a reusable private method, shared by both `import_utxo` and `internalize_wbikd_utxo`:

```ruby
def fetch_and_link_proof(action_id, wtxid, dtxid)
  # Try get_tx_details for proof data
  detail_result = @network_provider.call(:get_tx_details, txid: dtxid)
  if detail_result.respond_to?(:http_success?) && detail_result.http_success?
    # ... extract height, block_hash, merkle_path
    # ... save proof and link to action
  end
end
```

---

## Files Modified

| File | Change |
|---|---|
| `gem/bsv-wallet/lib/bsv/wallet/engine.rb` | Add `generate_receive_address`, `list_receive_addresses`, `scan_receive_addresses` (public); `find_or_create_wbikd_slot`, `internalize_wbikd_utxo`, `fetch_and_link_proof` (private); refactor proof fetching out of `import_utxo` |
| `gem/bsv-wallet/lib/bsv/wallet/daemon.rb` | Add `pending_scans:` parameter and `run_scans` call |
| `gem/bsv-wallet/spec/bsv/wallet/engine_spec.rb` | WBIKD specs |
| `gem/bsv-wallet/spec/bsv/wallet/daemon_spec.rb` | Scan cycle specs |

---

## Testing Strategy

1. **generate_receive_address** — returns valid P2PKH address + derivation params; creates slot when none available; reuses existing unlocked slot; deterministic re-derivation from same params
2. **list_receive_addresses** — empty when no addresses; lists outstanding; absent after abort
3. **scan_receive_addresses** — no-op without key_deriver/network; no-op with no outstanding addresses; happy path with mock UTXO response
4. **internalize_wbikd_utxo** — creates incoming action with correct derivation params; output is spendable; slot recycled after abort; proof linked if mined
5. **daemon** — backward-compatible without pending_scans; scan callable invoked each cycle; error handling

---

## Verification

```bash
cd gem/bsv-wallet && bundle exec rspec
cd gem/bsv-wallet-postgres && bundle exec rspec
cd gem/bsv-wallet && bundle exec rubocop
```
