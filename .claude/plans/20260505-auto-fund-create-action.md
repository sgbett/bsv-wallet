# Plan: Auto-fund createAction with Split Eagerness (#61)

## Context

`createAction` requires callers to manually select UTXOs, compute fees, and build change outputs. HLR #61 adds auto-funding: when `inputs: nil`, the wallet handles everything. The key architectural decision: input locking (reversible via CASCADE) is split from change output creation (permanent — outputs table is immutable). Inputs lock early; change outputs write atomically with signing.

## Files to Modify

| File | Changes |
|------|---------|
| `gem/bsv-wallet/lib/bsv/wallet/interface/store.rb:37` | Add `change_outputs:` param to `sign_action`; add `query_change_output_vouts` |
| `gem/bsv-wallet-postgres/lib/bsv/wallet/postgres/store.rb:55` | Implement `change_outputs:` in `sign_action`; add `query_change_output_vouts` |
| `gem/bsv-wallet/lib/bsv/wallet/engine.rb` | Add `auto_fund_action`, `build_funded_transaction`; modify `create_action`; implement `query_change_outpoints` |
| `gem/bsv-wallet/spec/bsv/wallet/engine_spec.rb` | Auto-fund specs |

## Implementation Steps

### Step 1: Store interface — `sign_action` + `query_change_output_vouts`

**`interface/store.rb:37`** — add optional `change_outputs: []` to `sign_action` signature. Add new abstract method:

```ruby
def sign_action(action_id:, wtxid:, raw_tx:, change_outputs: [])
def query_change_output_vouts(action_id:)
```

### Step 2: Postgres store — `sign_action` writes change outputs

**`postgres/store.rb:55`** — within the existing `@db.transaction` block, after UPDATE actions + INSERT tx_proofs, loop over `change_outputs`:

```ruby
change_outputs.each do |chg|
  output = Output.create(
    action_id: action_id, satoshis: chg[:satoshis],
    vout: chg[:vout], locking_script: chg[:locking_script]
  )
  Spendable.create(
    output_id: output.id, action_id: action_id,
    derivation_prefix: chg[:derivation_prefix],
    derivation_suffix: chg[:derivation_suffix],
    sender_identity_key: chg[:sender_identity_key]
  )
  OutputDetail.create(output_id: output.id, action_id: action_id, change: true)
end
```

Default `change_outputs: []` means all existing callers are unchanged.

### Step 3: Postgres store — `query_change_output_vouts`

```ruby
def query_change_output_vouts(action_id:)
  Output.where(action_id: action_id)
        .where(OutputDetail.dataset
          .where(Sequel[:output_details][:output_id] => Sequel[:outputs][:id])
          .where(change: true).select(1).exists)
        .select_map(:vout)
end
```

### Step 4: Engine — `auto_fund_action` private method

Orchestrates the auto-fund flow. Called from `create_action` when `inputs.nil? && outputs&.any?`.

```ruby
def auto_fund_action(description:, outputs:, lock_time:, version:,
                     broadcast:, labels:, randomize_outputs:,
                     no_send:, send_with:, return_txid_only:)
```

**Flow:**

1. **Estimate needed satoshis** — `output_total + fee_margin`
   ```ruby
   output_total = outputs.sum { |o| o[:satoshis] || 0 }
   estimated_size = 10 + 148 + (outputs.length + 1) * 34  # 1 input + outputs + change
   fee_margin = (estimated_size / 1000.0 * 100).ceil
   ```

2. **Select UTXOs** — `@utxo_pool.select(satoshis: output_total + fee_margin)`

3. **Phase 1: Lock** — build input_specs from candidates, `@store.create_action`

4. **Build funded transaction** — `build_funded_transaction(...)` (Step 5)

5. **Phase 2b: Atomic sign + change** — `@store.sign_action(..., change_outputs: change_outputs)`

6. **Phases 3-4** — build BEEF, handle no_send/broadcast/promote (reuse existing logic). `promote_with_outputs` receives caller `outputs` only (change already written).

7. **Return** — same hash shape as existing `create_action`

### Step 5: Engine — `build_funded_transaction` private method

This is separate from `build_transaction` to avoid touching the existing tested path.

```ruby
def build_funded_transaction(action_id:, caller_outputs:,
                             lock_time:, version:, randomize:)
```

**Returns:** `[wtxid, raw_tx, vout_mapping, change_outputs]`

**Sequence:**

**A. Resolve inputs + derive signing keys:**
```ruby
resolved_inputs = @store.resolve_inputs_for_signing(action_id: action_id)
tx_inputs, signing_keys = build_inputs(resolved_inputs, nil)
# nil caller_inputs → all inputs fall through to P2PKH path in build_inputs
```

**B. Derive change output key (BRC-42 self-payment):**
```ruby
change_prefix = SecureRandom.uuid
change_suffix = '1'
change_pub = @key_deriver.derive_public_key(
  protocol_id: [2, change_prefix], key_id: change_suffix, counterparty: 'self'
)
change_script = BSV::Script::Script.p2pkh_lock(
  BSV::Primitives::Digest.hash160(change_pub)
)
```

**C. Build all outputs (caller + change), shuffle together:**
```ruby
caller_tx_outputs = caller_outputs.map { |out|
  BSV::Transaction::TransactionOutput.new(
    satoshis: out[:satoshis] || 0,
    locking_script: resolve_locking_script(out[:locking_script])
  )
}
change_tx_output = BSV::Transaction::TransactionOutput.new(
  satoshis: 0, locking_script: change_script, change: true
)

all_outputs = caller_tx_outputs + [change_tx_output]
if randomize && all_outputs.length > 1
  all_outputs.shuffle!
end
```

**D. Assemble transaction:**
```ruby
tx = BSV::Transaction::Transaction.new(version: version || 1, lock_time: lock_time || 0)
tx_inputs.each { |inp| tx.add_input(inp) }
all_outputs.each { |out| tx.add_output(out) }
```

**E. Attach P2PKH templates for fee estimation:**
```ruby
signing_keys.each do |idx, key|
  tx.inputs[idx].unlocking_script_template = BSV::Transaction::P2PKH.new(key)
end
```

Templates are required by `estimated_size` (called within `tx.fee`). Must be set BEFORE fee computation, BEFORE signing.

**F. Compute fee + distribute change:**
```ruby
fee_model = BSV::Transaction::FeeModels::SatoshisPerKilobyte.new(value: 100)
tx.fee(fee_model, change_distribution: :random)
```

SDK behavior: computes fee from `estimated_size`, calculates `available = input_sats - non_change_sats - fee_sats`. If `available <= 0`, calls `@outputs.reject!(&:change)` — **mutates** `tx.outputs`, removing change. Otherwise distributes via Benford.

**G. Detect change survival, compute final vout positions:**
```ruby
change_survived = tx.outputs.include?(change_tx_output)

# Rebuild vout_mapping from actual tx.outputs (positions may have shifted)
vout_mapping = {}
caller_tx_outputs.each_with_index do |co, orig_idx|
  vout_mapping[orig_idx] = tx.outputs.index(co)
end
```

Uses Ruby object identity — `caller_tx_outputs` contains the same objects as `tx.outputs`. If change was removed, positions shift; `index` finds the correct position.

**H. Sign (AFTER fee — sighash commits to final output values):**
```ruby
signing_keys.each { |idx, key| tx.sign(idx, key) }
```

**I. Build change_outputs spec for store:**
```ruby
change_output_specs = []
if change_survived
  change_output_specs << {
    satoshis: change_tx_output.satoshis,
    vout: tx.outputs.index(change_tx_output),
    locking_script: change_script.to_binary,
    derivation_prefix: change_prefix,
    derivation_suffix: change_suffix,
    sender_identity_key: @key_deriver.identity_key
  }
end
```

**J. Return:**
```ruby
[tx.wtxid, tx.to_binary, vout_mapping, change_output_specs]
```

### Step 6: Engine — `create_action` modification

At the top of `create_action`, after validation (line 47), before Phase 1 (line 51):

```ruby
if inputs.nil? && outputs&.any?
  require_key_deriver!
  return auto_fund_action(
    description: description, outputs: outputs,
    lock_time: lock_time, version: version,
    broadcast: broadcast, labels: labels,
    randomize_outputs: randomize_outputs,
    no_send: no_send, send_with: send_with,
    return_txid_only: return_txid_only
  )
end
```

Existing code from Phase 1 onward is completely untouched.

Validate: auto-fund + deferred signing is rejected:
```ruby
if inputs.nil? && !sign_and_process
  raise BSV::Wallet::InvalidParameterError.new(
    'sign_and_process', 'true when inputs is nil (auto-funded actions sign immediately)'
  )
end
```

### Step 7: Engine — `query_change_outpoints` implementation

Replace stub at line 743:

```ruby
def query_change_outpoints(action_id)
  action = @store.find_action(id: action_id)
  return [] unless action&.dig(:wtxid)

  dtxid = action[:wtxid].reverse.unpack1('H*')
  vouts = @store.query_change_output_vouts(action_id: action_id)
  vouts.map { |vout| "#{dtxid}.#{vout}" }
end
```

### Step 8: Tests

- **Auto-fund happy path**: fund wallet via internalize, call `create_action(outputs: [...])` with no inputs, verify signed tx, verify change output spendable
- **Dust change removal**: outputs consume nearly all input satoshis, verify no change output written
- **Insufficient funds**: pool has less than needed, verify PoolDepletedError
- **no_send + change**: auto-funded no_send, verify `no_send_change` contains change outpoints
- **Backward compatibility**: existing tests with `inputs: [...]` still pass
- **inputs: nil + sign_and_process: false**: verify InvalidParameterError

## Edge Cases

- **Dust**: SDK removes change output, `change_output_specs` is empty, sign_action writes zero change rows
- **Fee re-estimation**: greedy largest-first selection typically overshoots; SDK computes exact fee from actual transaction. If exact fee > estimate, change just shrinks. If even after removing change inputs < outputs, validate and raise InsufficientFundsError
- **Concurrent callers**: both select same UTXOs from pool → first locks via INSERT ON CONFLICT, second gets rollback → InsufficientFundsError (existing behavior)
- **Signing failure**: change_outputs never reach the DB — sign_action transaction isn't called. Action + inputs cleaned up by reaper CASCADE. Zero orphan outputs.

## Key Ordering Constraint

Within `build_funded_transaction`, the order is critical:

1. Build inputs + outputs → 2. Attach P2PKH templates → 3. `tx.fee` (needs templates for `estimated_size`) → 4. `tx.sign` (needs final output values for sighash)

Templates before fee. Fee before sign. Sign after outputs are final.
