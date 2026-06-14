# ADR-013: Auto-funding createAction — calling convention, input selection, schema, and change

## Status

Accepted.

**Decided:** 2026-05-27 (PR #210, `12a2b66` — `create_action` rewritten as composition of `select_inputs` + `generate_change`, `auto_fund_action` removed; HLR #61).

## Context

`create_action` is the wallet's transaction-building entry point. As a raw BRC-100 primitive it expects the caller to have already selected UTXOs, computed the fee, built the change output, and balanced inputs against outputs — pushing funding arithmetic into every caller (`bin/send` did its own coin selection). The caller knows what it wants to pay; it should not have to know which coins to spend, what the fee will be, or how much change to return.

Funding a transaction is several coupled jobs decided together: a *calling convention* that distinguishes "fund this for me" from "I am supplying the inputs", an *input-selection* step that covers the outputs plus the (not-yet-known) fee, the *schema phasing* that decides when inputs and change rows are written, and a *change-derivation* step that emits BRC-42 change for the surplus. The fee depends on the final size, which depends on the inputs and change outputs, which depend on the fee — a small fixpoint. The wallet must converge it without leaking an intermediate, unbalanced, or under-funded transaction into the database.

The funding work also straddles the schema's immutability asymmetry (ADR-004, ADR-011): `inputs` rows are cheap and reversible (a `DELETE FROM actions` cascades to them, releasing the locked UTXOs), whereas `outputs` rows are part of the append-only log and effectively permanent once written. Inputs may therefore be claimed speculatively and early; change outputs must not exist unless a valid signed transaction references them.

## Decision Drivers

* The caller declares payment intent; the wallet resolves inputs, fee, and change — parity with what a BRC-100 wallet is expected to do.
* The BRC-100 `create_action` signature must be preserved — auto-funding is additive behaviour when `inputs` is omitted, not a new method.
* Fee and change arithmetic is stateless transaction maths — it belongs in the SDK, not the wallet (ADR-018).
* No intermediate or under-funded transaction may ever be persisted (ADR-003): the funding fixpoint converges in memory, and the result lands in atomic writes.
* Locked inputs must be reversible; change outputs, on the immutable log, must not be written speculatively (ADR-004, ADR-011).

## Decision

`create_action` auto-funds inline: when the caller omits `inputs`, the wallet selects coins to cover the output total, drives a funding loop to convergence against the actual fee, derives BRC-42 change, signs, and persists — all within the single `create_action` call, then dispatches per the action's broadcast intent. Four distinct sub-decisions, **made together in PR #210**, give this its shape:

### (a) The `inputs` argument is tri-state — `nil` vs `[]` is load-bearing

The same parameter expresses three distinct caller intents; the discriminator is `!inputs.nil?` (`gem/bsv-wallet/lib/bsv/wallet/engine/action.rb:30`):

* **`nil`** — the wallet selects and funds (auto-fund path). `caller_supplied_inputs` is false; `select_inputs` covers `sum(outputs)` and the funding loop tops up for the fee.
* **`[]`** (explicit empty array) — explicitly no wallet inputs (e.g. an OP_RETURN-only transaction). `caller_supplied_inputs` is true and `skip_change` is set (`action.rb:57`); the wallet neither selects coins nor generates change.
* **`[…]`** (non-empty) — caller-supplied inputs, used verbatim. The wallet does not extend the set; a fee shortfall raises rather than topping up.

The distinction between `nil` and `[]` is the convention, not incidental: `caller_supplied_inputs = !inputs.nil?` (`action.rb:30`) and `skip_change = caller_supplied_inputs && inputs.empty?` (`action.rb:57`).

### (b) Input selection — the wallet covers `sum(outputs)`, then converges the fee

When `inputs` is `nil` and there are outputs to fund, the initial selection targets the output total via `select_inputs(target_satoshis: output_total)` (`action.rb:84-85`). The fee fixpoint is then converged by `run_funding_loop` (`action.rb:847`), which calls `generate_change` and reports a `shortfall` (`required_fee − surplus`) when the locked inputs do not cover the fee with change at zero. On a shortfall the wallet selects more coins, **excluding those already locked** (`select_inputs(target_satoshis: result[:shortfall], exclude: locked_output_ids)`, `action.rb:870`), locks them, and re-evaluates. With caller-supplied inputs a shortfall raises `InsufficientFundsError` immediately (`action.rb:867`), since the caller's set is fixed. The loop is bounded by the spendable-pool size and converges in one or two iterations in practice.

### (c) Schema implementation — inputs locked early and reversibly; change written atomically at the appropriate phase

Input selection and change creation have different atomicity requirements and are written in different phases:

* *Phase 1 — lock inputs (reversible).* Selected outputs are claimed by INSERT into `inputs` within `Store#create_action`'s transaction (`action.rb:90`); the `UNIQUE(output_id)` + `INSERT … ON CONFLICT (output_id) DO NOTHING` makes the claim the structural lock (ADR-004). If anything downstream fails, deleting the action cascades the locks away — nothing permanent has been written.
* *Phase 2 — build, fee, sign (in memory).* The funding loop converges; a signing failure here leaves zero artifacts.
* *Atomic commit.* `Store#sign_action` writes the signed `raw_tx`, the caller's pending outputs, and the change-output rows in one `db.transaction` (ADR-003). Change outputs are "born signed" — they exist only because a valid signed transaction references them. On the send path they are written `promoted: false` (`action.rb:422`) and join the spendable set at Phase-4 acceptance; on the internal path (`broadcast_intent = 'none'`) they promote synchronously (ADR-011).

A wallet-selected (`inputs: nil`) action cannot be deferred: `sign_and_process: false` with `inputs: nil` is rejected (`action.rb:39-43`), because the change template must be evaluated against the actual fee, which requires immediate signing.

### (d) Change derivation — BRC-42 keys, fee from the SDK, fan-out groomed by the pool

The wallet states intent; the SDK does the arithmetic. `generate_change` (`action.rb:940`) assembles the transaction with P2PKH unlocking-script templates so the SDK can estimate size, asks `BSV::Transaction::FeeModels::SatoshisPerKilobyte.new(value: 100)` for the required fee via `compute_fee` (`action.rb:995-996`), and distributes change across the change outputs via `tx.fee(fee_model, change_distribution: :random)` (`action.rb:1003`) — Benford, for privacy. `100 sats/kb` (0.1 sat/byte) is the default rate, reflecting BSV's low-fee design. The wallet computes neither the fee nor the per-output split itself.

The number of change outputs is a pool-grooming heuristic, capped per transaction. `UTXOPool#change_output_count` (`gem/bsv-wallet/lib/bsv/wallet/store/utxo_pool.rb:54-58`) returns `clamp(target − spendable_count, 1, MAX_CHANGE_PER_TX)` where `target = min(MAX_UTXO_COUNT, balance / MIN_UTXO_SATS)` (defaults `MAX_UTXO_COUNT = 500`, `MIN_UTXO_SATS = 1000`, `MAX_CHANGE_PER_TX = 8`, `utxo_pool.rb:9-11`). A thin or already-groomed pool yields one change output; a pool below target fans out up to eight, growing the spendable set organically through normal use without producing dust. The caller may override the heuristic with `change_count:` (`action.rb:74`) — e.g. for consolidation. This is present behaviour, not deferred.

**Deferred:** higher UTXOPool tiers — pre-split dedicated baskets (tier 2) and the pre-warmed in-memory `TxCache` (tier 3) — remain future work behind the same `UTXOPool` interface; tier 1 is a direct `find_spendable` query. Spending-pattern-aware UTXO sizing and background consolidation/dust-sweeping are likewise deferred.

## Alternatives Considered

### A. Keep `create_action` a raw primitive; fund in each caller
Every caller selects coins, computes the fee, and builds change itself.
**Pros:** `create_action` stays minimal; callers retain full control.
**Cons:** duplicates funding logic across callers and got it wrong in `bin/send`; not what a BRC-100 wallet is expected to do (the caller declares outputs, the wallet funds). **Rejected.**

### B. A separate `auto_fund_action` method beside `create_action`
Expose auto-funding as its own entry point.
**Pros:** keeps the primitive and the convenience visibly distinct.
**Cons:** two methods for one operation, and a second BRC-100-shaped surface to keep aligned. The tri-state `inputs` argument (a) already carries the distinction additively — `nil` selects the auto-fund path within the existing signature. **Rejected** (a standalone `auto_fund_action` was built and then removed in #210 in favour of composition).

### C. Compute the fee and distribute change in the wallet
Re-implement fee estimation and change distribution in Ruby rather than calling the SDK (rejects (d)'s delegation).
**Pros:** no SDK round-trip for the maths.
**Cons:** fee/change arithmetic is stateless transaction maths and belongs in the SDK (ADR-018); duplicating it in the wallet risks drift from the SDK's size model and Benford distribution. The wallet states intent (the transaction and the rate); the SDK computes. **Rejected.**

### D. Write change outputs eagerly (at lock time, alongside inputs)
Persist the change rows in Phase 1 with the inputs (rejects (c)'s split phasing).
**Pros:** one fewer deferred write.
**Cons:** `outputs` is the immutable log — an eagerly written change row orphans permanently if signing fails, leaving a non-output in the log. Inputs are reversible (CASCADE) and may be eager; change outputs must wait for a valid signed transaction to reference them. **Rejected.**

### E. Single change output always (the pre-#68 behaviour)
Emit exactly one change output per transaction (rejects (d)'s fan-out).
**Pros:** simplest possible change handling.
**Cons:** the spendable pool never grows beyond the funding-UTXO count, capping concurrency and forcing large single-input transactions. The grooming heuristic fans out up to eight when below target and collapses to one when at/above it — pool growth for free, dust avoided by the `min_utxo_sats` floor. **Rejected.**

## Consequences

### Positive

* Callers declare payment outputs and let the wallet resolve inputs, fee, and change — BRC-100 parity, no funding logic duplicated per caller.
* The BRC-100 signature is unchanged; auto-funding is purely additive behaviour of `inputs: nil` (a).
* Fee/change arithmetic stays in the SDK (ADR-018); the wallet supplies intent (d).
* No intermediate transaction is persisted: the fixpoint converges in memory (b), results land atomically (c, ADR-003).
* Locked inputs are reversible; change outputs are never speculative on the immutable log (c; ADR-004, ADR-011).
* The pool grooms itself toward a target size through ordinary use (d), lifting the concurrency ceiling without an explicit splitting step.

### Negative

* The funding loop locks UTXOs during construction, holding liquidity for the duration; on the synchronous path this is milliseconds, but auto-selected inputs cannot be deferred (`sign_and_process: false` with `inputs: nil` is rejected — the change template must be evaluated against the actual fee, which requires immediate signing).
* Convergence is iterative; pathological pools are bounded by the spendable count, with exhaustion surfacing as `InsufficientFundsError`.
* The wallet depends on the SDK's fee model and `tx.fee` change distribution behaving as specified — including the SDK silently dropping dust-level change (hence the surviving-change filter after distribution).

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

The decision pushes funding into the wallet where a BRC-100 wallet is expected to do it, while keeping the arithmetic in the SDK where statelessness says it belongs — the boundary is drawn on principle, not convenience. The tri-state `inputs` argument (a) is the right additive move: one signature, three intents, no second method to keep aligned (a standalone `auto_fund_action` was tried and removed). The split phasing (c) is the load-bearing insight — it falls straight out of the immutability asymmetry already decided in ADR-004/011, so this ADR applies an existing rule rather than inventing one. The change-output grooming heuristic (d) is modest (one clamped formula) and earns its keep by lifting the concurrency ceiling. The deferred tiers are genuinely deferred behind a stable interface, not vapour. **Approve.**

## Validation

* **(a)** `Engine#create_action` and `Action.create` accept `inputs:` and branch on `!inputs.nil?`; `nil` → `select_inputs`, `[]` → `skip_change`, `[…]` → verbatim (`action.rb:30,57,82-88`).
* **(b)** `run_funding_loop` selects with `exclude: locked_output_ids` on a shortfall (`action.rb:870`) and raises `InsufficientFundsError` (not a top-up) when inputs are caller-supplied and short (`action.rb:867`).
* **(c)** Phase-1 input locking is an INSERT into `inputs` via `Store#create_action` with `ON CONFLICT (output_id)`; change-output rows are written in `Store#sign_action`'s `db.transaction`, not at lock time; `inputs: nil` + `sign_and_process: false` is rejected (`action.rb:39-43`).
* **(d)** `generate_change` obtains the fee from `FeeModels::SatoshisPerKilobyte.new(value: 100)` via `compute_fee` and distributes change via `tx.fee(model, change_distribution: :random)` (`action.rb:995-1003`); `UTXOPool#change_output_count` returns a value in `[1, MAX_CHANGE_PER_TX]`, single output only at/above target (`utxo_pool.rb:54-58`).

## References

* ADR-003 — atomic transitions; no intermediate state persisted.
* ADR-004 — inputs-as-lock (`UNIQUE(output_id)` + `ON CONFLICT`); the reversible side of split phasing.
* ADR-011 — post-broadcast promotion; change written atomically within the phased lifecycle.
* ADR-018 — stateless SDK / stateful wallet; fee and change arithmetic is the SDK's job.
* HLR #61 (auto-fund: coin selection, fee, change; split-phasing rationale), #199 (encapsulate selection + change generation; caller-inputs fund-loss fix), #68 (UTXOPool sizing — change-output fan-out), #208 (`select_inputs` primitive with `exclude:`), #209 (`generate_change` with shortfall reporting), #210 (`create_action` as composition; `auto_fund_action` removed — the convergence point for (a)–(d)).
* `gem/bsv-wallet/lib/bsv/wallet/engine.rb`; `gem/bsv-wallet/lib/bsv/wallet/engine/action.rb`; `gem/bsv-wallet/lib/bsv/wallet/store/utxo_pool.rb`; `gem/bsv-wallet/lib/bsv/wallet/store.rb`.

## Unverified claims

None.
