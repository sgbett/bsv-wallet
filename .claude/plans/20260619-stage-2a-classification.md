# Stage 2a — Classification deliverable: worked example

> Sister plan to `20260617-manageable-machined.md`. Deliverable for #397.
> Code is *sketch* — not committed source. Stage 2 implements; this proves
> the primitive surface holds end-to-end on three representative shapes.

## A — `createAction` (write-build, the main pressure test)

### BRC100 interface layer

```ruby
# lib/bsv/wallet/brc100.rb  (Stage 3 sibling; composition over engine)
module BSV
  module Wallet
    class BRC100
      def create_action(description:, input_beef: nil, inputs: nil, outputs: nil,
                        lock_time: nil, version: nil, labels: nil,
                        sign_and_process: true, accept_delayed_broadcast: true,
                        trust_self: nil, return_txid_only: false,
                        no_send: false, change_count: nil,
                        randomize_outputs: true, originator: nil)
        # BRC-100 spec-shape validation — does the input meet the BRC-100
        # contract? Distinct from operation invariants (key_deriver presence,
        # parameter-combination semantics) which live on the primitive per
        # ADR-026 decision 6. BRC100 owns spec-shape; Engine owns invariants.
        validate_description!(description)
        validate_create_action_params!(inputs: inputs, outputs: outputs)
        validate_output_ownership!(outputs)

        result = @engine.build_action(
          description: description, input_beef: input_beef,
          inputs: inputs, outputs: outputs,
          lock_time: lock_time, version: version, labels: labels,
          sign_and_process: sign_and_process,
          accept_delayed_broadcast: accept_delayed_broadcast,
          trust_self: trust_self, no_send: no_send,
          change_count: change_count, randomize_outputs: randomize_outputs
        )
        # `originator` stays here — recorded for audit at the interface,
        # not forwarded into engine.

        # Translate Engine's wallet-vocab return to BRC-100 spec shape
        # (ADR-026 decision 5). +:txid+ here is the BRC-100 spec key name;
        # the value carried is a wtxid (wire-order binary) until JSON
        # serialisation dtxid-converts at the wire boundary.
        if result[:signable_transaction]
          return {
            signable_transaction: {
              tx: result[:signable_transaction][:atomic_beef],
              reference: result[:signable_transaction][:reference]
            }
          }
        end
        # +return_txid_only+ nilifies the +tx+ key (BRC-100 keeps the key
        # present); engine's atomic_beef is computed regardless because the
        # SPV honesty check runs on it (#296 Phase B).
        return { txid: result[:wtxid], tx: nil } if return_txid_only && !no_send
        spec = { txid: result[:wtxid], tx: result[:atomic_beef] }
        spec[:no_send_change] = result[:no_send_change] if no_send
        if result[:send_with_results]
          # Per-item translation: engine returns wallet vocab (+wtxid:+),
          # BRC-100 ships spec-shape (+txid:+) for each companion's outcome.
          spec[:send_with_results] = result[:send_with_results].map { |r|
            { txid: r[:wtxid], status: r[:status] }
          }
        end
        spec
      end
    end
  end
end
```

### Engine machinery layer

```ruby
# lib/bsv/wallet/engine.rb  (Stage 2 — the orchestrator primitive)
class Engine
  def build_action(description:, input_beef: nil, inputs: nil, outputs: nil,
                   lock_time: nil, version: nil, labels: nil,
                   sign_and_process: true, accept_delayed_broadcast: true,
                   trust_self: nil, no_send: false, change_count: nil,
                   randomize_outputs: true, send_with: nil)
    # Param-combination preconditions (was Action.create lines 38–53)
    if no_send && deferred?(sign_and_process, inputs)
      raise UnsupportedActionError,
            'createAction(no_send: true) combined with deferred signing is not ' \
            'implemented in the base wallet; tracked in #192.'
    end
    require_key_deriver! unless deferred?(sign_and_process, inputs) || skip_change?(inputs)

    intent = map_broadcast_intent(no_send, accept_delayed_broadcast)

    # Pre-flight policy guards (was reach-back #3 + #4 first call).
    # Limp check always; headroom check skipped on deferred (no funds locked
    # yet — headroom is meaningless until signAction commits the spend).
    output_total      = (outputs || []).sum { |o| o[:satoshis] || 0 }
    pre_lock_balance  = @utxo_pool.balance
    pre_lock_count    = change_count || @utxo_pool.change_output_count
    @policy.guard_balance!(balance: pre_lock_balance, spending: 0)            # limp
    unless deferred?(sign_and_process, inputs)
      @policy.guard_balance!(balance: pre_lock_balance, spending: output_total) # headroom
    end

    # Row creation + delegation to slim Action for lifecycle work
    action_row = @store.create_action(action: {
      description: description, broadcast_intent: intent, input_beef: input_beef
    }, inputs: [])
    Action.attach_labels(engine: self, action_id: action_row[:id], labels: labels)
    action = Action.new(engine: self, row: action_row)

    if deferred?(sign_and_process, inputs)
      # Returns wallet vocab: +{ signable_transaction: { atomic_beef:, reference: } }+.
      # BRC100 translates the inner +:atomic_beef+ to BRC-100's +:tx+ key.
      return action.build_deferred!(inputs: inputs, outputs: outputs, ...)
    end

    # Signing branch dispatch — slim Action owns the row-level mutations
    if skip_change?(inputs)
      built = action.build_with_caller_inputs!(inputs: inputs, outputs: outputs, ...)
    else
      built = @funding_strategy.fund(action_id: action_row[:id], outputs: outputs,
                                     caller_inputs: inputs, change_count: pre_lock_count, ...)
      # Post-loop policy guard (reach-back #4 second call)
      @policy.guard_balance!(balance: pre_lock_balance,
                             spending: output_total + built[:actual_fee])
    end

    if no_send
      action.complete_internal!(built: built, outputs: outputs)
    else
      action.sign_and_save!(built: built, outputs: outputs)
    end

    atomic_beef = @hydrator.build_atomic_beef(built[:raw_tx], action_row[:id])
    @hydrator.validate_for_handoff!(atomic_beef, built[:wtxid])

    if no_send
      return { wtxid: built[:wtxid], atomic_beef: atomic_beef,
               no_send_change: action.query_change_outpoints }
    end

    dispatch_broadcast(action_row[:id], atomic_beef, intent: intent)   # private; absorbs #5 + worker.process

    # Wallet-vocab return shape per ADR-026 decision 5; BRC100 translates
    # to spec shape ({ txid:, tx: }) at the interface layer.
    { wtxid: built[:wtxid], atomic_beef: atomic_beef }
  end

  private

  # Returns the broadcast_intent symbol. The Store maps to/from the
  # +broadcast_intent+ ENUM string on persistence; in-process, the engine
  # threads the symbol so callers (e.g. +dispatch_broadcast+) compare on
  # symbols rather than re-fetching the string from the DB.
  def map_broadcast_intent(no_send, accept_delayed_broadcast)
    return :none    if no_send
    return :delayed if accept_delayed_broadcast
    :inline
  end

  def dispatch_broadcast(action_id, atomic_beef, intent:)
    publish_beef_hint(action_id, atomic_beef)          # internal; was reach-back #5
    @broadcast_worker.process(action_id) if intent == :inline
    # :delayed → daemon picks up from broadcasts row; :none → no-op.
  end
end

class Engine::Policy
  def initialize(threshold:, bypass:)
    @threshold = threshold; @bypass = bypass
  end

  def guard_balance!(balance:, spending:)
    return if @bypass
    projected = balance - spending
    return unless projected < @threshold
    raise LimpModeError.new(balance: projected, threshold: @threshold)
  end
end
```

### What moved

| From | To |
|---|---|
| `engine.send(:require_key_deriver!)` (Action) | `require_key_deriver!` inside `build_action` |
| `engine.send(:determine_broadcast, ...)` (Action) | `map_broadcast_intent` private inside Engine |
| `engine.send(:enforce_limp_mode!)` (Action) | `@policy.guard_balance!` (rolled in — limp is balance vs zero spend) |
| `engine.send(:enforce_headroom_against!, ...)` (Action ×2) | `@policy.guard_balance!` ×2 |
| `engine.send(:publish_beef_hint, ...)` (Action) | `dispatch_broadcast` (Engine private) |
| `engine.broadcast_worker.process(id) if broadcast == :inline` (Action) | `dispatch_broadcast` |
| `Action.create` (484 LOC orchestrator) | `Engine#build_action` (orchestrator) + `Action#build_with_caller_inputs!` / `Action#build_deferred!` / `Action#complete_internal!` / `Action#sign_and_save!` (row-level) |

## B — `internalizeAction` (write-import, the second shape)

### BRC100 interface layer

```ruby
module BSV
  module Wallet
    class BRC100
      def internalize_action(tx:, outputs:, description:, labels: nil,
                             trust_self: nil, known_txids: nil,
                             seek_permission: true, originator: nil)
        # Spec-shape validation (BRC100-owned per ADR-026 decision 6).
        validate_description!(description)
        known_txids&.each { |w| BSV::Primitives::Hex.validate_wtxid!(w, name: 'known_txids entry') }

        @engine.import_beef(
          tx: tx, outputs: outputs, description: description, labels: labels,
          trust_self: trust_self, known_txids: known_txids,
          seek_permission: seek_permission
        )
      end
    end
  end
end
```

### Engine machinery layer

```ruby
class Engine
  def import_beef(tx:, outputs:, description:, labels:, trust_self:,
                  known_txids:, seek_permission:)
    @beef_importer.import(
      tx: tx, outputs: outputs, description: description, labels: labels,
      trust_self: trust_self, known_txids: known_txids,
      seek_permission: seek_permission
    )
  end
end
```

### What moved

The current code already routes through `@beef_importer`. The Stage 2/3 change is just **hiding the collaborator** behind a wrapper. BRC100 stops knowing `@beef_importer` exists. Two lines of plumbing whose load-bearing job is decision 2.

The wrapper is the canonical thin-wrapper example: indivisible domain op, 1:1 with the BRC100 method, exists solely to enforce the interface/machinery boundary. (Same shape as the 24 read-side wrappers in the classification table.)

## C — `noSend` composability (the #192 pressure test)

> Sections C examples call `engine.build_action` directly (not BRC100),
> so they use the wallet-vocab return shape (`wtxid:` / `atomic_beef:`).
> The BRC100 layer translates to `{ txid:, tx: }` per ADR-026 decision 5.

### Stage 1 batch member (today, single-tx noSend)

```ruby
# Same engine.build_action, no_send: true
result = engine.build_action(
  description: "first batch member", outputs: [...],
  no_send: true, accept_delayed_broadcast: false
)
# => { wtxid:, atomic_beef:, no_send_change: [outpoint, ...] }
```

### Stage 2 batch member (chained — depends on stage-1 outpoints)

```ruby
result2 = engine.build_action(
  description: "second batch member",
  inputs: [
    { outpoint: result[:no_send_change][0], ... }
  ],
  outputs: [...],
  no_send: true
)
# => { wtxid:, atomic_beef:, no_send_change: [...] }
```

### Flush (the future #192 surface)

```ruby
# Either: a final createAction with send_with:
flush = engine.build_action(
  description: "final + flush batch",
  outputs: [...],
  no_send: false,
  send_with: [result[:wtxid], result2[:wtxid]]
)
# => { wtxid:, atomic_beef:, send_with_results: [{ wtxid:, status: }, ...] }

# Or: a sign_action with send_with: (for the deferred-signing flow):
engine.sign_action(reference: ..., spends: ..., send_with: [parked_wtxids])
```

### What the example proves

- `build_action` survives `no_send: true` returning a parked action with `no_send_change` outpoints (Stage 1).
- Subsequent `build_action` calls accept those outpoints as `inputs:` — the spendable / UTXO selection layer's job to honour parked-output visibility, but the primitive signature accommodates it (Stage 2).
- The flush is `send_with:` as a kwarg on the existing `build_action` (or `sign_action`) primitive — no new primitive at this scope; #192 designs the batch entity + parked-output storage + flush semantics on top.
- No `Engine::Batch` shown — that's #192's surface, not 2a's. The point is the primitives accommodate it.

## Surface validation summary

| Pressure | Result |
|---|---|
| BRC100 routes through engine primitives only (decision 2) | ✓ Both A and B above; no `engine.collaborator.<m>` |
| Engine owns the workflow (decision 1) | ✓ `build_action` sequences Policy / FundingStrategy / TxBuilder / Hydrator / dispatch internally |
| Slim Action does row mutations only | ✓ `Action#build_deferred!`, `#build_with_caller_inputs!`, `#complete_internal!`, `#sign_and_save!`, `#query_change_outpoints` — all row-scoped |
| Per-domain-operation granularity holds | ✓ `build_action` / `import_beef` are verbs at the natural domain level |
| #192 composes | ✓ C above — `no_send` / `send_with` accommodated without new primitives at this scope |
| #223 routes | ✓ A and B are JSON-friendly given the wrapper's binary↔base64 seam |

## Open during Stage 2 implementation

- Action's exact instance-method names (`build_with_caller_inputs!`, `build_deferred!`, `complete_internal!`, `sign_and_save!`) are sketched here for shape — Stage 2 may refine.
- `Engine::Policy`'s constructor and where it gets `threshold` / `bypass` from (probably the central config + an Engine init param).
- `signAction` shares the broadcast tail: `Action#sign!` reaches `determine_broadcast` (`engine/action.rb:413`) the same way `create` does. It rehomes to `map_broadcast_intent` / `dispatch_broadcast` identically, so it is not worked separately here — but Stage 2 must rehome this call-site too. The five #370 reach-backs span **six call-sites** (`determine_broadcast` and `enforce_headroom_against!` each appear twice); the worked example above covers the `create` path's call-sites, and this one closes the set.
