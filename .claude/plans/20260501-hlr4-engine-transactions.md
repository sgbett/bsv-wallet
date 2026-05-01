# Plan: HLR #4 — BRC-100 Engine: Transaction Operations

## Context

Layers 1 and 2 are complete (models, Store, UTXOPool, BroadcastQueue, ProofStore). The Engine is Layer 3 — pure orchestration. It receives components at construction time, validates BRC-100 parameters, calls components in the right order, and returns spec-conformant responses.

This HLR covers the 7 transaction methods (codes 1-7). The remaining 21 methods (HLR #5) are mostly SDK delegation and simpler.

**Source issue:** sgbett/bsv-wallet#4

**Key constraint:** Layer 3 contains NO SQL, NO ARC calls, NO thread management. It speaks only to Layer 2a interfaces.

---

## Engine file: `gem/bsv-wallet/lib/bsv/wallet/engine.rb`

Lives in the **core** gem, not the postgres gem. The engine depends only on the abstract interfaces — it doesn't know about Sequel, PostgreSQL, or ARC.

### Constructor

```ruby
class Engine
  include BSV::Wallet::Interface::BRC100

  def initialize(store:, utxo_pool:, broadcast_queue:, proof_store:,
                 key_deriver: nil, network: :mainnet)
    @store = store
    @utxo_pool = utxo_pool
    @broadcast_queue = broadcast_queue
    @proof_store = proof_store
    @key_deriver = key_deriver  # SDK key derivation (HLR #5)
    @network = network
  end
end
```

`key_deriver` is nil for now — HLR #5 adds it. The engine can be partially functional (transaction ops work, crypto methods raise NotImplementedError).

### Parameter Validation

Private method `validate_description!(desc)` — checks 5-50 chars per BRC-100.

Private method `validate_create_action_params!(...)` — at least one input or output, descriptions on all inputs/outputs.

BRC-100 error codes via `InvalidParameterError`.

---

## Method-by-method

### create_action

The most complex method. Four phases, multiple code paths.

**Code paths:**
1. **Standard (sign_and_process: true, no_send: false)** — full Phase 1→2→3→4
2. **Deferred signing (sign_and_process: false or unlocking_script_length present)** — Phase 1 only, return signable_transaction
3. **No-send (no_send: true)** — Phase 1→2, no broadcast, promote immediately with no_send_change
4. **Send-with (send_with: [...])** — submit previously no-send'd actions for broadcast

```ruby
def create_action(description:, input_beef: nil, inputs: nil, outputs: nil,
                  lock_time: nil, version: nil, labels: nil,
                  sign_and_process: true, accept_delayed_broadcast: true,
                  trust_self: nil, known_txids: nil, return_txid_only: false,
                  no_send: false, no_send_change: nil, send_with: nil,
                  randomize_outputs: true, originator: nil)

  validate_description!(description)
  validate_create_action_params!(inputs: inputs, outputs: outputs)

  # Determine broadcast intent
  broadcast = if no_send then :none
              elsif accept_delayed_broadcast then :delayed
              else :inline
              end

  # Phase 1: UTXO selection + lock
  input_specs = resolve_inputs(inputs, input_beef, no_send_change)
  action_result = @store.create_action(
    action: { description: description, broadcast: broadcast,
              nlocktime: lock_time || 0, version: version,
              input_beef: input_beef, satoshis: calculate_satoshis(outputs) },
    inputs: input_specs
  )
  raise BSV::Wallet::InsufficientFundsError if action_result.nil?

  # Attach labels
  if labels&.any?
    label_ids = @store.find_or_create_labels(names: labels)
    @store.label_action(action_id: action_result[:id], label_ids: label_ids)
  end

  # Check if deferred signing needed
  deferred = !sign_and_process || inputs&.any? { |i| i[:unlocking_script_length] && !i[:unlocking_script] }

  if deferred
    return { signable_transaction: { tx: nil, reference: action_result[:reference] } }
  end

  # Phase 2: Sign
  # Transaction construction would use the SDK here
  # For now: the caller provides complete inputs with unlocking scripts
  txid, raw_tx = build_and_sign_transaction(action_result, inputs, outputs, lock_time, version, randomize_outputs)
  @store.sign_action(action_id: action_result[:id], txid: txid, raw_tx: raw_tx)

  # Phase 3: Broadcast (unless no_send)
  if no_send
    # Promote immediately for no-send — outputs are known
    @store.promote_action(action_id: action_result[:id], outputs: outputs || [])
    change_outpoints = extract_change_outpoints(action_result[:id])
    return { txid: txid, tx: raw_tx, no_send_change: change_outpoints }
  end

  broadcast_result = @broadcast_queue.submit(
    action_id: action_result[:id],
    raw_tx: raw_tx,
    immediate: broadcast == :inline
  )

  # Phase 4: Promote (if broadcast accepted inline)
  if broadcast == :inline && accepted?(broadcast_result)
    @store.promote_action(action_id: action_result[:id], outputs: outputs || [])
    handle_proof_from_broadcast(action_result[:id], broadcast_result)
  end

  # Handle send_with batch
  send_with_results = nil
  if send_with&.any?
    send_with_results = send_with.map do |sw_txid|
      sw_action = @store.find_action(txid: sw_txid)
      next unless sw_action
      br = @broadcast_queue.submit(action_id: sw_action[:id], raw_tx: sw_action[:raw_tx], immediate: true)
      { txid: sw_txid, status: br[:tx_status]&.downcase&.to_sym || :sending }
    end.compact
  end

  result = { txid: txid, tx: return_txid_only ? nil : raw_tx }
  result[:send_with_results] = send_with_results if send_with_results
  result
end
```

The `build_and_sign_transaction` method is a placeholder — full transaction construction requires SDK integration (key derivation, script templates, ECDSA signing). For HLR #4, we implement the orchestration and test the flow using pre-built transaction data. The SDK integration comes with HLR #5.

### sign_action

```ruby
def sign_action(spends:, reference:, accept_delayed_broadcast: true,
                return_txid_only: false, no_send: false, send_with: nil, originator: nil)
  action = @store.find_action(reference: reference)
  raise BSV::Wallet::InvalidParameterError.new('reference') unless action

  # Apply unlocking scripts (SDK would build the final tx here)
  txid, raw_tx = apply_spends_and_sign(action, spends)
  @store.sign_action(action_id: action[:id], txid: txid, raw_tx: raw_tx)

  broadcast = if no_send then :none
              elsif accept_delayed_broadcast then :delayed
              else :inline
              end

  unless broadcast == :none
    broadcast_result = @broadcast_queue.submit(
      action_id: action[:id], raw_tx: raw_tx,
      immediate: broadcast == :inline
    )

    if broadcast == :inline && accepted?(broadcast_result)
      @store.promote_action(action_id: action[:id], outputs: []) # outputs were set during create
      handle_proof_from_broadcast(action[:id], broadcast_result)
    end
  end

  { txid: txid, tx: return_txid_only ? nil : raw_tx }
end
```

### abort_action

```ruby
def abort_action(reference:, originator: nil)
  action = @store.find_action(reference: reference)
  raise BSV::Wallet::InvalidParameterError.new('reference') unless action

  @store.abort_action(action_id: action[:id])
  @utxo_pool.release(outputs: []) # no-op for tier 1
  { aborted: true }
end
```

### list_actions

```ruby
def list_actions(labels:, label_query_mode: :any, include_labels: false,
                 include_inputs: false, include_input_source_locking_scripts: false,
                 include_input_unlocking_scripts: false, include_outputs: false,
                 include_output_locking_scripts: false, limit: 10, offset: 0,
                 seek_permission: true, originator: nil)
  result = @store.query_actions(
    labels: labels, label_query_mode: label_query_mode,
    limit: limit, offset: offset,
    include_labels: include_labels, include_inputs: include_inputs,
    include_input_locking_scripts: include_input_locking_scripts,
    include_outputs: include_outputs,
    include_output_locking_scripts: include_output_locking_scripts
  )
  { total_actions: result[:total], actions: result[:actions] }
end
```

### internalize_action

```ruby
def internalize_action(tx:, outputs:, description:, labels: nil,
                       seek_permission: true, originator: nil)
  validate_description!(description)

  # TODO: Validate BEEF data (BRC-67 SPV) via SDK
  # TODO: Extract proof from BEEF

  # Create action (incoming, no broadcast)
  action_result = @store.create_action(
    action: { description: description, broadcast: :none, outgoing: false }
  )

  # Attach labels
  if labels&.any?
    label_ids = @store.find_or_create_labels(names: labels)
    @store.label_action(action_id: action_result[:id], label_ids: label_ids)
  end

  # Process outputs by protocol
  output_specs = outputs.map do |out|
    spec = { satoshis: 0, vout: out[:output_index] }

    case out[:protocol]
    when :wallet_payment, 'wallet payment'
      rem = out[:payment_remittance]
      spec.merge!(
        derivation_prefix: rem[:derivation_prefix],
        derivation_suffix: rem[:derivation_suffix],
        sender_identity_key: rem[:sender_identity_key]
      )
    when :basket_insertion, 'basket insertion'
      rem = out[:insertion_remittance]
      spec.merge!(
        basket: rem[:basket],
        custom_instructions: rem[:custom_instructions],
        tags: rem[:tags]
      )
    end
    spec
  end

  @store.promote_action(action_id: action_result[:id], outputs: output_specs)

  { accepted: true }
end
```

### list_outputs

```ruby
def list_outputs(basket:, tags: nil, tag_query_mode: :any, include: nil,
                 include_custom_instructions: false, include_tags: false,
                 include_labels: false, limit: 10, offset: 0,
                 seek_permission: true, originator: nil)
  result = @store.query_outputs(
    basket: basket, tags: tags, tag_query_mode: tag_query_mode,
    limit: limit, offset: offset,
    include_locking_scripts: include == :locking_scripts,
    include_custom_instructions: include_custom_instructions,
    include_tags: include_tags, include_labels: include_labels
  )
  { total_outputs: result[:total], outputs: result[:outputs] }
end
```

### relinquish_output

```ruby
def relinquish_output(basket:, output:, originator: nil)
  # output is an outpoint string or output_id — resolve to output_id
  # For now, treat as output_id
  @store.relinquish_output(output_id: output)
  { relinquished: true }
end
```

---

## Private helpers

- `validate_description!(desc)` — 5-50 chars
- `validate_create_action_params!` — at least one input or output
- `accepted?(broadcast_result)` — checks tx_status is in accepted set
- `handle_proof_from_broadcast(action_id, result)` — if broadcast returned proof data, save proof and link
- `build_and_sign_transaction(...)` — placeholder for SDK integration
- `apply_spends_and_sign(...)` — placeholder for SDK integration
- `extract_change_outpoints(action_id)` — query change outputs for no_send_change

---

## Files to Create

```
gem/bsv-wallet/
  lib/bsv/wallet/engine.rb         ← NEW
  spec/bsv/wallet/engine_spec.rb   ← NEW
```

Update `gem/bsv-wallet/lib/bsv/wallet.rb` to add autoload for Engine.

---

## Testing approach

Engine specs use **real PostgreSQL** — the engine orchestrates concrete components. We construct a real Store, UTXOPool, BroadcastQueue (with mocked arc_client), and ProofStore, then test the full flow.

- Pre-fund the wallet with outputs via Store#promote_action
- Test each method end-to-end
- Mock `build_and_sign_transaction` since SDK transaction construction isn't available yet — inject pre-built txid/raw_tx

**Spec structure:**
- Engine construction (accepts components)
- create_action: standard flow, deferred signing, no-send, send-with, validation errors
- sign_action: complete deferred flow
- abort_action: releases locked outputs
- list_actions: label filtering, pagination
- internalize_action: creates completed action with outputs
- list_outputs: basket/tag filtering
- relinquish_output: removes from tracking

---

## Verification

1. `cd gem/bsv-wallet && bundle exec rspec` — core gem specs pass
2. Engine creates action + locks inputs + promotes on broadcast acceptance
3. Deferred signing: create_action returns reference, sign_action completes it
4. No-send: returns no_send_change outpoints
5. Abort: action deleted, locked outputs released
6. list_actions/list_outputs: correct filtering and pagination
7. internalize_action: creates completed action with outputs
8. Validation: short description raises InvalidParameterError
