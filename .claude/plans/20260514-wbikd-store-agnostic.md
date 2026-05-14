# WBIKD Store-Agnostic Redesign — On-Chain Derivation + OP_RETURN Recovery

## Context

The current WBIKD implementation (#102) derives addresses from `encode_int64(action.id)` and `encode_int64(output.id)` — database integer primary keys. This couples recovery to the PostgreSQL schema's sequential integer PKs. Issue #108 redesigns derivation to use on-chain data (slot txid + vout) and adds OP_RETURN recovery markers, matching the draft BRC at `reference/brc-draft-wbikd.md`.

No backward compatibility needed — clean replacement.

---

## What Changes

| Aspect | Old (#102) | New (#108) |
|--------|-----------|------------|
| derivation_prefix | `encode_int64(locking_action.id)` | slot output's display-order txid (64-char hex) |
| derivation_suffix | `encode_int64(slot_output.id)` | slot output's vout as string (always `"0"`) |
| Recovery | enumerate `action_id × output_id` with identity key | scan OP_RETURNs by `HMAC-SHA256(privkey, sats)`, extract sibling txid+vout |
| Store dependency | sequential integer PKs required | none — derivation from on-chain data |

---

## Phase 1: Add OP_RETURN to slot creation

**File:** `gem/bsv-wallet/lib/bsv/wallet/engine.rb` — `find_or_create_wbikd_slot`

The slot creation `create_action` call gets a second output — an OP_RETURN containing the recovery marker:

```ruby
def find_or_create_wbikd_slot
  result = @store.query_outputs(basket: 'p wbikd', limit: 1)
  if result[:total].positive?
    slot = result[:outputs].first
    # Look up source txid for on-chain derivation
    action = @store.find_action(id: slot[:action_id])
    dtxid = action[:wtxid].reverse.unpack1('H*')
    return { slot: slot, dtxid: dtxid, vout: slot[:vout] }
  end

  # Compute recovery marker: HMAC-SHA256(identity_private_key, satoshi_amount)
  slot_sats = rand(100..1000)
  marker = compute_wbikd_marker(slot_sats)
  op_return_script = BSV::Script::Script.op_return(marker).to_binary

  # Create slot via broadcast self-payment with OP_RETURN recovery marker
  prefix = SecureRandom.uuid  # TODO: random_derivation (#107)
  suffix = '1'
  derived_pub = @key_deriver.derive_public_key(
    protocol_id: [2, prefix], key_id: suffix, counterparty: 'self'
  )
  script = BSV::Script::Script.p2pkh_lock(
    BSV::Primitives::Digest.hash160(derived_pub)
  ).to_binary

  create_result = create_action(
    description: 'wbikd slot creation',
    accept_delayed_broadcast: false,
    outputs: [
      { satoshis: slot_sats, locking_script: script,
        basket: 'p wbikd',
        derivation_prefix: prefix, derivation_suffix: suffix,
        sender_identity_key: @key_deriver.identity_key },
      { satoshis: 0, locking_script: op_return_script }
    ],
    randomize_outputs: false
  )

  # txid from create_action is wire-order wtxid
  dtxid = create_result[:txid].reverse.unpack1('H*')

  # Re-query for the slot output
  result = @store.query_outputs(basket: 'p wbikd', limit: 1)
  { slot: result[:outputs].first, dtxid: dtxid, vout: 0 }
end

def compute_wbikd_marker(satoshis)
  key_bytes = @key_deriver.raw_private_key_bytes
  BSV::Primitives::Digest.hmac_sha256(key_bytes, satoshis.to_s)
end
```

**Key points:**
- `randomize_outputs: false` guarantees slot P2PKH at vout 0, OP_RETURN at vout 1, change at vout 2+
- Derivation suffix is always `"0"` (the slot vout)
- The return shape changes: now returns `{ slot:, dtxid:, vout: }` instead of just the slot hash
- Existing slot lookup also fetches the source txid via `find_action`

**KeyDeriver needs `raw_private_key_bytes`:** A new accessor on KeyDeriver that returns the 32-byte identity private key scalar. Check if `PrivateKey` already exposes this (e.g., `to_hex` → pack, or a `bytes` method).

---

## Phase 2: Update `generate_receive_address` derivation

**File:** `gem/bsv-wallet/lib/bsv/wallet/engine.rb`

```ruby
def generate_receive_address
  require_key_deriver!

  slot_info = find_or_create_wbikd_slot
  slot = slot_info[:slot]

  # Lock the slot
  locking_action = @store.create_action(
    action: { description: 'wbikd address lock', broadcast: :none, nlocktime: 0, outgoing: true },
    inputs: [{ output_id: slot[:id], vin: 0 }]
  )
  return generate_receive_address unless locking_action

  wtxid, raw_tx, = build_transaction(locking_action[:id], [{ output_id: slot[:id] }], [], nil, nil, false)
  @store.sign_action(action_id: locking_action[:id], wtxid: wtxid, raw_tx: raw_tx)
  @proof_store.save_proof(wtxid: wtxid, proof: { raw_tx: raw_tx })
  attach_labels(locking_action[:id], ['wbikd'])

  # Derive from on-chain data: slot txid + vout
  derivation_prefix = slot_info[:dtxid]
  derivation_suffix = slot_info[:vout].to_s
  derived_pub = @key_deriver.derive_public_key(
    protocol_id: [2, derivation_prefix], key_id: derivation_suffix, counterparty: 'self'
  )
  address = BSV::Primitives::PublicKey.from_bytes(derived_pub).address(network: @network_name)

  { address: address, derivation_prefix: derivation_prefix, derivation_suffix: derivation_suffix }
end
```

**What changed:** `encode_int64(action_id/slot_id)` → `slot_info[:dtxid]` / `slot_info[:vout].to_s`

---

## Phase 3: Update `list_receive_addresses`

**File:** `gem/bsv-wallet/lib/bsv/wallet/engine.rb`

The list method needs to look up each slot output's source txid and vout:

```ruby
def list_receive_addresses
  require_key_deriver!

  result = list_actions(labels: ['wbikd'], include_inputs: true, limit: 10_000)
  result[:actions].filter_map do |action|
    next unless action[:status] == :nosend

    input = action[:inputs]&.first
    next unless input

    # Look up slot output's source txid + vout for on-chain derivation
    slot_output = @store.find_output(id: input[:output_id])
    next unless slot_output

    source_action = @store.find_action(id: slot_output[:action_id])
    next unless source_action&.dig(:wtxid)

    derivation_prefix = source_action[:wtxid].reverse.unpack1('H*')
    derivation_suffix = slot_output[:vout].to_s

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

**Store dependency:** Needs `find_output(id:)` — check if this exists, or use `query_outputs` with ID filter. Also needs `find_action(id:)` which already exists.

---

## Phase 4: Remove `encode_int64`

Delete the `encode_int64` helper — no longer used. The derivation params are now plain strings (64-char hex txid, decimal vout string).

---

## Phase 5: Add `raw_private_key_bytes` to KeyDeriver

**File:** `gem/bsv-wallet/lib/bsv/wallet/key_deriver.rb`

```ruby
def raw_private_key_bytes
  @private_key.to_hex.then { |h| [h].pack('H*') }
end
```

Or check if `PrivateKey` already has a `bytes` / `to_binary` method.

---

## Phase 6: Update specs

**File:** `gem/bsv-wallet/spec/bsv/wallet/engine/wbikd_spec.rb`

Key changes:
- `prefund_wbikd_slots` needs to create outputs with known wtxid on the source action (so dtxid is deterministic in tests)
- Derivation param assertions: no longer base64 format, now 64-char hex (prefix) and decimal string (suffix)
- Determinism test: re-derive from txid + vout matches returned address
- New test: OP_RETURN marker present on slot creation (if testable without broadcast)
- New test: `compute_wbikd_marker` produces expected HMAC

---

## Phase 7: Recovery method (optional — may defer)

`Engine#recover_wbikd_addresses` — the full recovery scan. Enumerate sat range, compute HMACs, scan OP_RETURNs. This is the "cold recovery" path. It could be deferred to a separate issue since it requires blockchain OP_RETURN scanning infrastructure that may not exist yet in the Services layer.

---

## Files Modified

| File | Change |
|---|---|
| `gem/bsv-wallet/lib/bsv/wallet/engine.rb` | Update `find_or_create_wbikd_slot` (OP_RETURN + return shape), `generate_receive_address` (on-chain derivation), `list_receive_addresses` (source txid lookup), add `compute_wbikd_marker`, remove `encode_int64` |
| `gem/bsv-wallet/lib/bsv/wallet/key_deriver.rb` | Add `raw_private_key_bytes` accessor |
| `gem/bsv-wallet/spec/bsv/wallet/engine/wbikd_spec.rb` | Update all derivation assertions + add OP_RETURN/HMAC tests |
| `reference/brc-draft-wbikd.md` | Update to reflect final implementation |

---

## Open Questions

1. **`find_output(id:)`** — does the Store interface have this? If not, need to add it or use an alternative lookup.
2. **PrivateKey bytes access** — verify `PrivateKey#to_hex` exists and is the scalar (not WIF). May need `bn.to_s(16)` or similar.
3. **Recovery method scope** — implement in this PR or defer? The draft BRC describes it but it needs OP_RETURN scanning via Services.

---

## Verification

```bash
cd gem/bsv-wallet && bundle exec rspec
cd gem/bsv-wallet-postgres && bundle exec rspec
cd gem/bsv-wallet && bundle exec rubocop
```
