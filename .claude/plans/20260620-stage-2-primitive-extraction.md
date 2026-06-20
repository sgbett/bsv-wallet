# Stage 2 — Primitive Extraction (#402, PR 1: Write-Side)

Plan companion to HLR #402. Covers the substantive write-side PR: `Engine::Policy`, two internal helpers, four thick primitives, Action reshape, and BRC100's four write-method bodies thinned. Read-side (24 thin wrappers) is PR 2, covered separately at the bottom.

The 28 + 2 surface and granularity rules come from ADR-026 and the worked-example sketch at [`.claude/plans/20260619-stage-2a-classification.md`](20260619-stage-2a-classification.md). This file specifies implementation order, per-primitive signatures, Action's new shape, and spec migration.

## Naming convention (Stage 2 only — reverted in Stage 3)

BRC100 is a mixin into Engine at Stage 2 (HLR #402 decision 3). Bare invocation from BRC100 method bodies resolves via Ruby MRO — and 26 of the 28 primitive names collide with BRC-100 spec method names (`sign_action`, `encrypt`, `decrypt`, `create_hmac`, all of certificates, all of read-side outputs/actions/auth/static). Only `build_action` and `import_beef` are clash-free (BRC100 names them `create_action` and `internalize_action`).

**Convention:** uniform `do_` prefix on all 28 Engine primitives.

```ruby
# Engine
def do_build_action(...); end
def do_sign_action(reference:, spends:, ...); end
def do_abort_action(reference:); end
def do_import_beef(...); end
def do_encrypt(...); end
# ... all 24 read-side similarly

# BRC100 (mixin — bare invocation, self IS engine)
def create_action(...)
  validate_...
  do_build_action(...)
end

def sign_action(spends:, reference:, ...)
  validate_reference!(reference)
  do_sign_action(reference: reference, spends: spends, ...)
end
```

**Stage 3 sweep (committed — see [docs reference below](#stage-3-rename-commitment)):**
- `do_<name>` everywhere → `@engine.<name>`
- Drop the `do_` prefix on Engine methods, leaving `Engine#sign_action`, `Engine#encrypt`, etc. at their spec-aligned names.
- The mixin-vs-composition switch makes the prefix unnecessary because BRC100 is no longer in Engine's MRO; the two `sign_action` methods live on distinct classes.

The Stage 2 prefix is scaffolding for the mixin constraint, not a long-term name. Stage 3's HLR MUST land the rename — leaving `do_` prefixed primitives in place would be a regression against ADR-026 and the destination state.

<a name="stage-3-rename-commitment"></a>**Where this commitment lives:**
- This plan (above).
- HLR #402 to be amended: explicit "Stage 3 reverts the `do_` prefix" line under decision 3.
- ADR-026 to be amended: short note in decision 5 (or a new corollary) recording the Stage 2 prefix as scaffolding and the Stage 3 revert as a precondition for composition.

## Commit sequence (PR 1)

Six commits. Suite stays green at every commit — verify with the full unit run (Postgres + SQLite) before each. Order is dependency-driven, not aesthetic.

### Commit 1 — `Engine::Policy` (additive, semantics unchanged)

**New file:** `gem/bsv-wallet/lib/bsv/wallet/engine/policy.rb`

```ruby
class Engine
  class Policy
    def initialize(threshold:)
      @threshold = threshold
    end

    # Raise +LimpModeError+ when +balance - spending < threshold+, unless
    # +bypass:+ is true. Stateless — callers own the bypass switch.
    def guard_balance!(balance:, spending: 0, bypass: false)
      return if bypass

      projected = balance - spending
      return unless projected < @threshold

      raise BSV::Wallet::LimpModeError.new(balance: projected, threshold: @threshold)
    end
  end
end
```

**`engine.rb` changes:**
- New autoload entry for `Policy`.
- In `Engine#initialize`: `@policy = Engine::Policy.new(threshold: @limp_threshold)` after the threshold guard.
- `Engine#limp_mode?` and `#headroom` keep their current bodies (they read `@utxo_pool.balance` / `@limp_threshold` directly — no behaviour benefit to routing them through Policy yet).
- `Engine#enforce_limp_mode!` becomes `@policy.guard_balance!(balance: @utxo_pool.balance, bypass: @bypass_limp_mode)`.
- `Engine#enforce_headroom_against!(balance, spending)` becomes `@policy.guard_balance!(balance:, spending:, bypass: @bypass_limp_mode)`.
- `Engine#enforce_headroom!(spending)` keeps its current shape (calls `enforce_headroom_against!`).

**Why `bypass:` is a method param, not Policy state.** The temporary-bypass block at `engine.rb:273/285` and `:646/657` mutates `@bypass_limp_mode` in-place. Policy is constructed once at `Engine.new` and stays stateless; the bypass flag stays on Engine and flows in at call time. Smaller change, no observable semantic difference.

**New spec:** `spec/bsv/wallet/engine/policy_spec.rb` — exercises `guard_balance!` under all combinations of `balance` / `spending` / `bypass` / `threshold`.

**Acceptance gate (commit 1):** Full unit suite green against both Postgres and SQLite; Rubocop green.

### Commit 2 — `Engine#map_broadcast_intent` + `Engine#dispatch_broadcast` (additive)

**`engine.rb` private additions:**

```ruby
private

def map_broadcast_intent(no_send, accept_delayed_broadcast)
  # Body identical to current +determine_broadcast+. Rename for clarity:
  # this is a pure mapper, not a side-effectful "determine".
  return :none if no_send
  accept_delayed_broadcast ? :delayed : :inline
end

def dispatch_broadcast(action_id, atomic_beef, intent:)
  publish_beef_hint(action_id, atomic_beef) if atomic_beef
  @broadcast_worker.process(action_id) if intent == :inline
end
```

**Old methods stay alive** until commit 6:
- `Engine#determine_broadcast` — Action still calls it via `engine.send(:determine_broadcast, ...)`.
- `Engine#publish_beef_hint` — Action still calls it via `engine.send(:publish_beef_hint, ...)`.

**Acceptance gate (commit 2):** Suite green. No callers of the new methods yet — pure surface addition.

### Commit 3 — Add 4 write-side primitives as delegators

The primitives appear on Engine's public surface (under the `do_` prefix; see [naming convention](#naming-convention-stage-2-only--reverted-in-stage-3)); their bodies are pass-throughs initially. Inversion happens in commit 5.

**`Engine#do_build_action(**kwargs)`**

```ruby
def do_build_action(**kwargs)
  # Initial: delegate to Action.create. Commit 5 inverts — the
  # orchestrator body moves up here and Action.create slims to a
  # row-creation helper.
  Engine::Action.create(engine: self, **kwargs)
end
```

Accepted kwargs (mirrors `Action.create` exactly): `description:, input_beef: nil, inputs: nil, outputs: nil, lock_time: nil, version: nil, labels: nil, sign_and_process: true, accept_delayed_broadcast: true, trust_self: nil, return_txid_only: false, no_send: false, change_count: nil, randomize_outputs: true`.

`originator:` is NOT propagated — ADR-026 decision 7.

**`Engine#do_sign_action(reference:, spends:, accept_delayed_broadcast: true, return_txid_only: false, no_send: false)`**

```ruby
def do_sign_action(reference:, spends:, accept_delayed_broadcast: true,
                   return_txid_only: false, no_send: false)
  action = Engine::Action.find(engine: self, reference: reference)
  raise BSV::Wallet::InvalidParameterError, 'reference' unless action

  action.sign!(spends: spends, no_send: no_send,
               accept_delayed_broadcast: accept_delayed_broadcast,
               return_txid_only: return_txid_only)
end
```

**`Engine#do_abort_action(reference:)`**

```ruby
def do_abort_action(reference:)
  action = Engine::Action.find(engine: self, reference: reference)
  raise BSV::Wallet::InvalidParameterError, 'reference' unless action

  action.abort!
end
```

**`Engine#do_import_beef(tx:, outputs:, description:, labels: nil, trust_self: nil, known_txids: nil, seek_permission: true)`**

```ruby
def do_import_beef(tx:, outputs:, description:, labels: nil,
                   trust_self: nil, known_txids: nil, seek_permission: true)
  @beef_importer.import(
    tx: tx, outputs: outputs, description: description,
    labels: labels, trust_self: trust_self, known_txids: known_txids,
    seek_permission: seek_permission
  )
end
```

Note: `originator:` does not appear in `do_import_beef`'s signature; if BRC100's `internalize_action` accepts it for spec compliance, BRC100 swallows it.

**Acceptance gate (commit 3):** Suite green. BRC100 still calls `Engine::Action.create/find` directly; the new primitives are unused on the hot path but visible on the surface.

### Commit 4 — Thin BRC100's 4 write methods

Each becomes the uniform "validate spec-shape → call primitive → hash-wrap" body. Spec-shape validation stays at BRC100 per ADR-026 decision 6.

**`BRC100#create_action`** (replaces current body):

```ruby
def create_action(description:, input_beef: nil, inputs: nil, outputs: nil,
                  lock_time: nil, version: nil, labels: nil,
                  sign_and_process: true, accept_delayed_broadcast: true,
                  trust_self: nil, return_txid_only: false,
                  no_send: false, change_count: nil,
                  randomize_outputs: true, originator: nil)
  validate_description!(description)
  validate_create_action_params!(inputs: inputs, outputs: outputs)
  validate_output_ownership!(outputs)

  do_build_action(  # bare; mixin's self is engine
    description: description, input_beef: input_beef,
    inputs: inputs, outputs: outputs,
    lock_time: lock_time, version: version, labels: labels,
    sign_and_process: sign_and_process,
    accept_delayed_broadcast: accept_delayed_broadcast,
    trust_self: trust_self, return_txid_only: return_txid_only,
    no_send: no_send, change_count: change_count,
    randomize_outputs: randomize_outputs
  )
end
```

Return-shape note: at this commit `do_build_action` still returns the BRC100-shaped hash because it delegates to `Action.create`. The hash-wrap inversion (Engine returns raw, BRC100 wraps) happens in commit 5 alongside the orchestrator move. This is the transient state the 6-commit version accepts; reviewers should see commits 4 and 5 as a logical pair.

**`BRC100#sign_action`:**

```ruby
def sign_action(spends:, reference:, accept_delayed_broadcast: true,
                return_txid_only: false, no_send: false, originator: nil)
  validate_reference!(reference)
  do_sign_action(
    reference: reference, spends: spends,
    accept_delayed_broadcast: accept_delayed_broadcast,
    return_txid_only: return_txid_only, no_send: no_send
  )
end
```

**`BRC100#abort_action`:**

```ruby
def abort_action(reference:, originator: nil)
  validate_reference!(reference)
  do_abort_action(reference: reference)
end
```

**`BRC100#internalize_action`:**

```ruby
def internalize_action(tx:, outputs:, description:, labels: nil,
                       trust_self: nil, known_txids: nil,
                       seek_permission: true, originator: nil)
  validate_description!(description)
  known_txids&.each { |w| BSV::Primitives::Hex.validate_wtxid!(w, name: 'known_txids entry') }

  do_import_beef(  # bare; mixin's self is engine
    tx: tx, outputs: outputs, description: description,
    labels: labels, trust_self: trust_self, known_txids: known_txids,
    seek_permission: seek_permission
  )
end
```

**Acceptance gate (commit 4):** Full unit + integration suite green. BRC100 now goes through Engine's primitives end-to-end. Action's reach-backs are unchanged (still inside `Action.create`'s body).

### Commit 5 — Action reshape (the substantive interlock)

Lifts the orchestrator body of `Action.create` (lines 38–246) up into `Engine#do_build_action`. `Action.create` shrinks to a row-creation helper. Action grows instance methods for each row-level lifecycle step. All `engine.send(:_)` calls disappear.

**New `Engine#do_build_action` body** (replaces commit 3's delegator):

```ruby
def do_build_action(description:, input_beef: nil, inputs: nil, outputs: nil,
                    lock_time: nil, version: nil, labels: nil,
                    sign_and_process: true, accept_delayed_broadcast: true,
                    trust_self: nil, return_txid_only: false,
                    no_send: false, change_count: nil,
                    randomize_outputs: true)
  caller_supplied_inputs = !inputs.nil?
  deferred = !sign_and_process ||
             inputs&.any? { |i| i[:unlocking_script_length] && !i[:unlocking_script] }

  if !caller_supplied_inputs && !sign_and_process
    raise BSV::Wallet::InvalidParameterError.new(
      'sign_and_process', 'true when inputs is nil (wallet-selected inputs sign immediately)'
    )
  end

  if no_send && deferred
    raise BSV::Wallet::UnsupportedActionError,
          'createAction(no_send: true) combined with deferred signing is not implemented; #192.'
  end

  skip_change = caller_supplied_inputs && inputs.empty?
  require_key_deriver! unless deferred || skip_change

  intent = map_broadcast_intent(no_send, accept_delayed_broadcast)
  @policy.guard_balance!(balance: @utxo_pool.balance, bypass: @bypass_limp_mode)

  output_total = outputs&.sum { |o| o[:satoshis] || 0 } || 0
  pre_lock_balance = @utxo_pool.balance
  pre_lock_change_count = change_count || @utxo_pool.change_output_count
  unless deferred
    @policy.guard_balance!(balance: pre_lock_balance, spending: output_total,
                           bypass: @bypass_limp_mode)
  end

  action = Engine::Action.create(engine: self, description: description,
                                 intent: intent, input_beef: input_beef,
                                 labels: labels)

  if deferred
    return action.build_deferred!(
      inputs: inputs, outputs: outputs, lock_time: lock_time,
      version: version, randomize: randomize_outputs, intent: intent
    )
  end

  built = if skip_change
            action.build_with_caller_inputs!(
              inputs: inputs, outputs: outputs, lock_time: lock_time,
              version: version, randomize: randomize_outputs
            )
          else
            begin
              built = action.build_via_funding!(
                outputs: outputs, caller_inputs: caller_supplied_inputs ? inputs : nil,
                lock_time: lock_time, version: version,
                randomize: randomize_outputs, change_count: pre_lock_change_count
              )
              actual_fee = built[:total_input_satoshis] -
                           output_total - built[:change_outputs].sum { |c| c[:satoshis] }
              @policy.guard_balance!(balance: pre_lock_balance,
                                     spending: output_total + actual_fee,
                                     bypass: @bypass_limp_mode)
              built
            rescue BSV::Wallet::InsufficientFundsError
              action.abort!
              raise
            end
          end

  if no_send
    action.complete_internal!(built: built, outputs: outputs)
  else
    action.sign_and_save!(built: built, outputs: outputs)
  end

  atomic_beef = @hydrator.build_atomic_beef(built[:raw_tx], action.id)
  @hydrator.validate_for_handoff!(atomic_beef, built[:wtxid])

  if no_send
    return { wtxid: built[:wtxid], atomic_beef: atomic_beef,
             change_outpoints: action.query_change_outpoints }
  end

  dispatch_broadcast(action.id, atomic_beef, intent: intent)

  { wtxid: built[:wtxid], atomic_beef: atomic_beef }
end
```

Return shape is wallet vocab (`wtxid:` binary, `atomic_beef:`, `change_outpoints:`, `signable:` for deferred). BRC100 hash-wraps to BRC-100 vocab (`txid:`, `tx:`, `no_send_change:`, `signable_transaction:`).

**`Engine::Action.create` slims to row helper:**

```ruby
def self.create(engine:, description:, intent:, input_beef: nil, labels: nil)
  result = engine.store.create_action(
    action: { description: description, broadcast_intent: intent, input_beef: input_beef },
    inputs: []
  )
  attach_labels(engine: engine, action_id: result[:id], labels: labels)
  new(engine: engine, row: result)
end
```

**New Action instance methods:**

| Method | Responsibility | Returns |
|---|---|---|
| `#build_deferred!(inputs:, outputs:, lock_time:, version:, randomize:, intent:)` | Lock caller inputs, build unsigned tx, stage, return BRC-100-ish signable handle | `{ signable: { atomic_beef:, reference: } }` |
| `#build_with_caller_inputs!(inputs:, outputs:, lock_time:, version:, randomize:)` | Lock caller inputs, build signed tx (no funding loop, no change). Returns built hash | `{ wtxid:, raw_tx:, vout_mapping:, change_outputs: [] }` |
| `#build_via_funding!(outputs:, caller_inputs:, lock_time:, version:, randomize:, change_count:)` | Run FundingStrategy; returns funding hash | `{ wtxid:, raw_tx:, vout_mapping:, change_outputs:, total_input_satoshis: }` |
| `#sign_and_save!(built:, outputs:)` | `store.sign_action` + `store.save_proof` | `nil` |
| `#complete_internal!(built:, outputs:)` | Atomic `store.complete_internal_action` (sign + Phase-4 promote) | `nil` |

Plus existing `#sign!`, `#abort!`, `#query_change_outpoints` (sign! body changes too — see below).

**`Engine#do_sign_action` body** (replaces commit 3's delegator):

```ruby
def do_sign_action(reference:, spends:, accept_delayed_broadcast: true,
                   return_txid_only: false, no_send: false)
  action = Engine::Action.find(engine: self, reference: reference)
  raise BSV::Wallet::InvalidParameterError, 'reference' unless action

  if no_send && action.row[:broadcast_intent] != 'none'
    raise BSV::Wallet::UnsupportedActionError,
          'signAction(no_send: true) requires create_action(no_send: true); #192.'
  end

  signed = action.apply_caller_spends!(spends: spends)
  atomic_beef = @hydrator.build_atomic_beef(signed[:raw_tx], action.id)
  @hydrator.validate_for_handoff!(atomic_beef, signed[:wtxid])

  intent = map_broadcast_intent(no_send, accept_delayed_broadcast)
  dispatch_broadcast(action.id, atomic_beef, intent: intent) unless no_send

  { wtxid: signed[:wtxid], atomic_beef: atomic_beef }
end
```

Action's `#sign!` splits: `#apply_caller_spends!` does the deserialise + apply + sign + persist + save_proof; Engine handles BEEF assembly + dispatch. The old `#sign!` is gone.

**Removals in this commit:**
- `Action.create`'s monolithic body (lines 38–246).
- `Action#sign!` (becomes `#apply_caller_spends!` with narrower responsibility).
- All `engine.send(:_)` calls inside Action.

**Acceptance gate (commit 5):** Full unit + integration suite green. AC#9 (Action LOC 200–300) achieved. AC#6/#7/#8 (zero `engine.send`, no direct `broadcast_worker.process`, `.create` returns instance) satisfied.

### Commit 6 — Cleanup

- Delete `Engine#enforce_limp_mode!`, `Engine#enforce_headroom!`, `Engine#enforce_headroom_against!` (now Policy-only callers, which are inside `Engine#build_action`).
- Delete `Engine#determine_broadcast` (superseded by `map_broadcast_intent`).
- Fold `Engine#publish_beef_hint` body into `dispatch_broadcast` as inline; delete the standalone method.
- Audit specs for `engine.send(:_)` calls — any test still poking the old internals is testing implementation detail and should rewrite against the public primitive.
- Update `reference/principle-of-state.md` collaborator list to reflect Policy.

**Acceptance gate (commit 6):** Full suite + integration green; Rubocop green; grep for `engine.send(:` returns zero hits in `lib/` and only test-shaped hits (if any) in `spec/`.

## Spec migration

| Spec file | Change |
|---|---|
| `spec/bsv/wallet/engine/policy_spec.rb` | NEW (commit 1) — guard_balance! truth table |
| `spec/bsv/wallet/engine/action_spec.rb` | Rewrite (commit 5). Orchestration tests move to engine_spec; remaining tests cover row-level instance methods + helpers (build_input_specs etc.) |
| `spec/bsv/wallet/engine_spec.rb` | Grow (commit 5). New describe blocks for `do_build_action`, `do_sign_action`, `do_abort_action`, `do_import_beef` as primitives — orchestration semantics tested at Engine layer |
| `spec/bsv/wallet/brc100_spec.rb` | Unchanged in body. MRO + ownership assertions still hold (BRC100 still owns the 28). The `get_network` smoke still passes |
| `spec/integration/*` | Should pass unchanged — behaviour-preserving end-to-end is the gate |

## Decisions deferred to implementation

These are the small judgement calls the plan can't pre-decide; flag at implementation time:

1. **Engine#`reject_action`** — currently in `engine.rb:145` as an operator-facing wrapper. Not part of the 28 primitives (action_id is wallet-local, not a BRC-100 reference). Keep as-is, or migrate to `Engine#do_reject` private + bin/-only public wrapper — Stage 2 nit, not a blocker.
2. **`require_key_deriver!` placement** — currently on Engine, called by 6+ methods (line 185, 319, 374, 422, 507, 564, 605, 685). Stays on Engine; not a Policy concern. Internal `private` method.
3. **Whether `do_` primitives are private or public on Engine** — they need to be reachable from BRC100's mixin (which is in Engine's MRO, so private works), but bin/ tools and integration tests will want them accessible. Default to public; revisit if surface noise becomes a problem.

## PR 2 — Read-side (24 thin wrappers)

Mechanical sweep. One commit. Per the classification table: 6 crypto + 3 pubkey + 6 cert + 3 action-read + 2 auth + 4 static = 24.

All 24 use the same `do_` prefix established for PR 1.

For each method:

```ruby
# Engine
def do_encrypt(plaintext:, protocol_id:, key_id:, counterparty: 'self', privileged: false)
  require_key_deriver!
  @key_deriver.encrypt(plaintext: plaintext, protocol_id: protocol_id,
                       key_id: key_id, counterparty: counterparty, privileged: privileged)
end

# BRC100
def encrypt(plaintext:, protocol_id:, key_id:, ..., originator: nil)
  ciphertext = do_encrypt(plaintext: plaintext, protocol_id: protocol_id,
                          key_id: key_id, counterparty: counterparty, privileged: privileged)
  { ciphertext: ciphertext }
end
```

Tests: `engine_spec.rb` grows 24 new describe blocks asserting each primitive's signature + delegation. BRC100 specs unchanged (still assert the 28 spec names live on BRC100, MRO unaltered).

Acceptance: AC#1–4 of HLR #402 (the structural ACs) green; full suite green; Rubocop green.

## Open follow-ups (not in either PR)

- Stage 3 (mixin → composition over Engine primitives) — separate HLR.
- Sub-namespace grouping (`engine.crypto.encrypt`) — ADR-026 alternative D, deferred.
- `#192` chained-send restoration — consumes Stage 2's surface.
- `#385` Transmission domain — consumes Stage 2's surface.
