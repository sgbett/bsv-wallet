# Plan: Encapsulate input selection and change generation (#199)

## Context

`Engine#create_action` has two structurally separate paths:

1. **Caller-supplied inputs** (`engine.rb:103–192`, `build_transaction` at `engine.rb:1717`) — does **no** fee computation, **no** balance check, **no** change generation. Surplus silently goes to miners; deficit silently produces an ARC-rejected broadcast.

2. **Auto-funded inputs** (`auto_fund_action` at `engine.rb:1746`) — UTXO selection, BRC-42 change derivation, SDK fee computation, change persistence. Re-implements the entire create_action body.

The HLR (#199) fixes the silent fund-loss bug on the caller-inputs path by treating **input selection** and **change generation** as two independent encapsulated primitives, composed inside a single `create_action` flow. `auto_fund_action` disappears.

The bug is demonstrable today: `spec/bsv/wallet/engine/porcelain_spec.rb:207` ("caller-provided inputs still work unchanged") locks a 100,000-sat UTXO for a 4,000-sat output. The 96,000-sat surplus is signed away as miner fee. That spec encodes the bug; updating it is part of this work.

## Approach

Two primitives, one composition. No mode switch.

**Primitive 1 — `select_inputs(target_satoshis, exclude:)`** → returns UTXO candidates whose `sum(satoshis) >= target_satoshis`. Pure pool selection. No fee estimation, no margin. The `exclude` param supports top-up calls (don't re-select what's already locked). Invoked when the caller passes `inputs: nil`. Bypassed entirely when the caller supplies their own inputs.

**Primitive 2 — `generate_change(action_id, caller_outputs, ...)`** → loads resolved inputs from Store, builds the full transaction (caller outputs + change), runs SDK fee + Benford change distribution, shuffles, signs. Returns either `{ wtxid, raw_tx, vout_mapping, change_specs }` on success OR a `shortfall:` integer on insufficient input satoshis. Applies **universally** — invoked regardless of input source.

**Composition inside `create_action`** — fee is **not** estimated upfront; the loop converges:

```
1. validate
2. determine broadcast intent + enforce limp mode pre-flight
3. resolve initial inputs:
     if caller supplied inputs: use them directly
     else: select_inputs(target: sum(outputs)) → input specs
4. Phase 1: lock initial inputs (Store#create_action — same as today)
5. attach labels
6. branch on deferred?
     if deferred: build_transaction (no fee, no change) + stage_action
     else:        funding loop:
         loop:
           result = generate_change(action_id, outputs)
           break if result.success
           raise InsufficientFundsError if caller_supplied_inputs (can't top up)
           more = select_inputs(target: result.shortfall, exclude: locked)
           Store#lock_inputs(action_id:, inputs: more)  # append to inputs table
         sign_action(outputs:, change_outputs:)
7. atomic BEEF
8. branch on broadcast intent: internal / inline / delayed
```

In practice the loop terminates in one pass: the first `select_inputs(sum(outputs))` returns enough satoshis to cover outputs, and the fee is small relative to that, so a single top-up of a few hundred sats covers it. Pathological cases (dust-only pool, fees > sum(outputs)) might need two passes; the loop bounds itself by the pool's spendable set.

The auto-fund / caller-inputs distinction collapses to one decision: "did the caller supply inputs?" That decision picks the source of UTXOs for Phase 1 and gates the top-up branch. Everything else is shared.

## Design decisions

### Where the primitives live

Methods on `Engine` (private, like `build_funded_transaction` today). Not separate classes. The HLR's "callable, replaceable, testable in isolation" criterion is met by giving them clean signatures with collaborators (`@utxo_pool`, `@store`, `@key_deriver`) passed via ivars. Promoting to PORO classes is a future refactor if a second strategy lands.

### Change count when caller supplies inputs

Use `@utxo_pool.change_output_count` regardless of input source. The change-output count is a function of wallet topology (`balance / MIN_UTXO_SATS`, current spendable count, `MAX_CHANGE_PER_TX`) — independent of which inputs feed the transaction. Caller-inputs path gets the same UTXO-pool grooming as auto-fund.

### Insufficient funds detection

Two distinct cases now:

- **Auto-fund**: the funding loop drives top-ups until inputs cover outputs + fee. If `select_inputs(shortfall, exclude: locked)` cannot return enough (pool depleted), `PoolDepletedError` bubbles → engine wraps as `InsufficientFundsError`.
- **Caller-inputs**: the caller's set is fixed. First `generate_change` call reports a shortfall → engine immediately raises `InsufficientFundsError`. No top-up, no second attempt.

Either way, no tx hits the wire. Phase 1 locks for caller-inputs failures are cleaned up by the reaper via CASCADE (same as any other Phase 2 failure).

### How `generate_change` reports shortfall

Today's `build_funded_transaction` calls `tx.fee(fee_model, change_distribution: :random)` and relies on the SDK to fail or succeed. For the top-up loop, the engine needs a precise shortfall figure. Two options:

(i) Let the SDK raise, catch the exception, and compute `(sum(outputs) + tx.size_with_templates / 1000 * 100) - sum(inputs)` to get the shortfall.

(ii) Pre-compute fee from `tx` with templates attached (SDK exposes size methods), compare to surplus, and return shortfall directly without raising.

(ii) is cleaner — `generate_change` becomes a function over a known transaction shape, returns success or `{ shortfall: N }`. Look at the SDK's `Transaction#fee` to confirm we can ask "what fee would this be?" without mutating the tx. If we can't, fall back to (i).

### Headroom enforcement

`enforce_headroom!` currently runs upfront in `auto_fund_action` with an estimated `output_total + fee_margin`. Without an upfront fee estimate, we have two options:

- **Pre-flight check on `sum(outputs)`** — catches obviously oversized spends before any locking, but doesn't account for fee. Pessimistic by ~1k sats.
- **Final check on `sum(outputs) + actual_fee`** — exact, after the funding loop converges. The lock is in place before this fires, so a limp-mode failure leaves a Phase 1 to clean up.

**Recommendation: both.** Cheap pre-flight on `sum(outputs)` to fail fast on obvious cases; exact check after the loop converges to catch the marginal "fee pushes us over" case. The Phase 1 cleanup on the exact-check path is fine — same shape as a deficit cleanup.

### Deferred signing + change

Today's deferred path (`sign_and_process: false` or any `unlocking_script_length` placeholder) goes through `build_transaction` with `sign: false`, then `stage_action`. The HLR says "Current `sign_and_process: false` semantics preserved."

Two clean options:

(a) **Skip change generation on the deferred path.** Today's behaviour preserved exactly. The caller takes responsibility for adding change before deferring, or accepts the surplus-to-miner outcome on this narrow path. The bug fix lands on the synchronous path; deferred-with-change becomes a follow-up.

(b) **Run change generation, then sign-by-template.** Change outputs are added before the external signer commits to sighashes. Fee uses the deferred input's `unlocking_script_length` as the size hint. More work and more risk.

**Recommendation: (a) for this HLR.** The fund-loss bug is on the synchronous path (the one used in production today and in the spec at line 207). Deferred-with-change is a separate concern worth its own design pass.

### `inputs: []` (explicit empty inputs)

Today this signs a 0-input transaction (used for OP_RETURN-only actions per the spec at line 231). Preserve: when the caller passes an empty array, skip both input selection AND change generation. The composition step "did the caller supply inputs?" should treat `[]` as "yes, an empty set" — not "no, please select for me."

### `auto_fund_action` removal

Method goes away in this PR. Callers from inside the engine — none; only `create_action` itself routes through it. The `find_or_create_wbikd_slot` flow at `engine.rb:1389` invokes `create_action(inputs:...)` indirectly with `outputs: [...]` and no `inputs:` key, so it goes through the unified flow.

### Schema-intent.md / docs

`docs/reference/schema-intent.md` is freshly untracked. It currently describes the Phase 2 split between auto-fund and caller-inputs in passing (e.g. "**Send path** writes outputs at Phase 2 with `promoted = false`"). It does **not** describe the change-generation primitive or the unified flow. Add a short section under the `outputs` table description noting that change rows are written by the change-generation primitive at Phase 2b regardless of input source.

`docs/reference/schema.md` and `docs/design.md` mention `auto_fund_action` and the two-path model — update to describe the unified Phase 2 composition. Drop references to the removed method.

## Files to modify

| File | Change |
|------|--------|
| `gem/bsv-wallet/lib/bsv/wallet/engine.rb` | Rewrite `create_action` to compose primitives via the funding loop; introduce `select_inputs`; reshape `build_funded_transaction` → `generate_change` (returns success or shortfall, no upfront fee estimate); delete `auto_fund_action`; split `enforce_headroom!` into pre-flight + exact final check |
| `gem/bsv-wallet/lib/bsv/wallet/interface/store.rb` | Add `lock_inputs(action_id:, inputs:)` abstract method |
| `gem/bsv-wallet/lib/bsv/wallet/store.rb` | Implement `lock_inputs` (extract from existing Phase 1 input-insert logic in `create_action`) |
| `gem/bsv-wallet/spec/bsv/wallet/engine/porcelain_spec.rb` | Update "caller-provided inputs still work unchanged" (line 207) — now expects a change output; add new specs for surplus-with-change and deficit-raises |
| `gem/bsv-wallet/spec/bsv/wallet/engine_spec.rb` | Audit `build_transaction` unit tests — that method may stay (deferred path) or merge into the new flow |
| `docs/reference/schema-intent.md` | Note unified Phase 2 in §3 (outputs) and §4 (spendable) |
| `docs/reference/schema.md` | Drop the auto-fund/caller-inputs split language; describe unified Phase 2 |
| `docs/design.md` | Same — update Phase 2 narrative |

One Store change needed: a `Store#lock_inputs(action_id:, inputs:)` operation to append additional input rows to an existing action mid-flow (for the top-up branch). This is the same `INSERT ... ON CONFLICT (output_id) DO NOTHING RETURNING output_id` shape Phase 1 uses today, just without the surrounding `actions` INSERT. `Store#sign_action` already takes `change_outputs:` (added in #61); the caller-inputs path just starts passing it.

## Implementation steps

1. **Add `Store#lock_inputs(action_id:, inputs:)`** — extract the Phase 1 input-insert from today's `Store#create_action`. Same `INSERT ... ON CONFLICT` shape. Both the initial Phase 1 (via `create_action`) and the top-up branch end up sharing this primitive.

2. **Extract `select_inputs(target_satoshis, exclude: [])`** as a private method on Engine. Pure pool selection — no headroom, no fee estimate, no margin. Returns input specs ready for `Store#lock_inputs`. Unit-testable against an in-memory pool.

3. **Reshape `build_funded_transaction` → `generate_change`** so it (a) works with any input source, (b) returns `{ shortfall: N }` instead of raising when inputs don't cover outputs + fee. Investigate the SDK's `Transaction#fee` to find a non-mutating size/fee query; if unavailable, catch the SDK's raise and compute shortfall from the failed state.

4. **Rewrite `create_action`** as the composition described above. Drop `auto_fund_action`. The current `auto_fund` branch at `engine.rb:85–101` disappears. Headroom check splits into a cheap pre-flight on `sum(outputs)` and an exact post-loop check on `sum(outputs) + fee`.

5. **Update porcelain_spec.rb backward-compat test** to assert change is generated. Add specs:
   - caller inputs with surplus → change output present, fees correct
   - caller inputs with deficit → `InsufficientFundsError` raised, no broadcasts row
   - caller inputs with empty array → preserves OP_RETURN-only behaviour
   - auto-fund happy path with one top-up iteration → finishes with correct fee and change
   - auto-fund where initial selection misses fee by < 1k sats → top-up locks one more UTXO
   - auto-fund specs unchanged (regression check on behaviour)

6. **Update docs/reference/schema-intent.md, docs/reference/schema.md, docs/design.md** to describe the unified Phase 2 composition and the funding loop.

7. **Run the full suite**: `bundle exec rspec spec/bsv spec/bin` + integration if the wallet env vars are set.

8. **RuboCop pass** — `auto_fund_action` was on the long-method exception list; removal lets us drop the exception.

## Out of scope (per HLR)

- Input selection strategy improvements (split-eagerness, Benford, coin-control, pinned inputs).
- Deferred signing combined with change generation — preserve today's deferred semantics; deferred path does not generate change.
- Chained-send / `sendWith` / `noSendChange` — tracked in #192.
- Caller-controllable change addressing.

## Open questions for review

1. **Empty-inputs semantics**: confirm `inputs: []` should mean "use no inputs" rather than "let the wallet select." Today the spec at line 231 relies on the former.

2. **Deferred + change**: confirm option (a) above — defer becomes "no change generation, current semantics preserved." Or do we want to deliver (b) in this HLR?

3. **`InsufficientFundsError` vs `LimpModeError`**: today both can fire on the auto-fund path. With caller inputs, `LimpModeError` is the pre-flight headroom check (would breach the limp threshold even with infinite fee margin); `InsufficientFundsError` is the SDK-level fail-to-fund (input sats < output sats + actual fee). Are both ergonomic from the caller's perspective, or should one be the canonical "not enough money" surface?
