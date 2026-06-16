# Extract Engine::FundingStrategy (#323)

Phase 3 of the Engine decomposition (#291); the **first** extraction. ADR-024 records *why* the Engine is decomposed; this plan is the first concrete cut. Absorbs #213 (lock-retry). Behaviour-preserving except for that one deliberate change.

## Conceptual model (the load-bearing framing)

The decomposition does **not** fall along inputs/outputs. It falls along a *scratch vs commit* boundary, and within scratch, a *private vs shared* boundary. Three parts:

1. **Private scratch — the scribe (TxBuilder + change).** Building tx bytes from a fixed input set is pure: derive BRC-42 change keys, template, compute fee, distribute change, shuffle, sign. All in-process, free to discard and redo each fixpoint iteration. Change *minting* lives here because it is pure and local — which is why ChangeGenerator folds into TxBuilder (the next extraction) rather than standing alone.
2. **Shared scratch — the quartermaster (FundingStrategy, this PR).** Acquiring inputs is *also* provisional — an input lock is a **lease**, designed to be released or reaped, not a record. But the lease must be **externalised across the process boundary** (a row in `inputs`) so concurrent actions don't claim the same UTXO. That externalisation — visibility-while-held, not durability — is what brings contention, TOCTOU, and #213. The lock's weight was never the write; it's the *coordination*.
3. **Canonical commit — the Store (Phase 4 promotion).** The one genuinely never-unwrite act. It happens *after* convergence and belongs to neither collaborator (see ADR-023 / #307). Both the scribe and the quartermaster work entirely in scratch and hand a finished, still-provisional tx to the Store to commit.

This maps onto ADR-018: building (given inputs) is stateless; acquiring inputs is irreducibly stateful. We cut on the stateless/stateful axis, which is *orthogonal* to inputs/outputs — so Change (pure, folds into the builder) and Funding (contended, stays separate) end up in different modules despite their surface symmetry.

### The seam (what keeps it acyclic)

FundingStrategy depends on the builder, never the reverse. The dependency is one-way **because shortfall is a return value, not a callback**: the builder attempts a build at the current input set and returns *done-or-shortfall*; FundingStrategy decides whether to lease more and retry. The loop is *temporal*, not a structural cycle. Today's `generate_change` already returns `{ shortfall: N }` and `run_funding_loop` decides — the extraction must **preserve that direction**, not invent it. If the builder ever reaches down to fetch inputs, the cycle welds shut.

### Forward look to #192 (do not build now)

The chopped `noSend × sendWith` quadrants restore via `Engine::Batch` composing whole Actions. The scratch/commit boundary is a *precondition* for that (you cannot "not send" if building forces a commit) — but the boundary **already exists** in the monolith (deferred and internal paths build without broadcasting). What #192 needs is *addressability* (collaborators an orchestrator can drive) plus a funder whose notion of "what is fundable" can grow to include the batch's own in-flight outputs. The batch coupling concentrates in **this** layer, not the builder.

**One forward-compat instinct, zero forward-compat code:** keep FundingStrategy's *source of fundable coin* the injected `utxo_pool` (the AC already mandates this), not a hardcoded "the canonical spendable set". That leaves room for #192 without building any batch-awareness. We explicitly do **not** prejudge #192's chaining model (commit-per-item-then-chain-through-canonical vs hold-in-scratch-then-commit-atomically) — that is a #192 decision, likely its own ADR.

## Current implementation

The funding concern is smeared across four sites plus orchestration glue in `do_create_action`:

- **`Engine#select_inputs`** (`engine.rb:1067`) — thin wrapper over `utxo_pool.select`, builds `{ output_id:, vin: }` specs.
- **Phase-1 select + lock** (`action.rb:77-98`) — wallet-selected path calls `select_inputs(target: output_total)`, then `store.create_action(inputs:)` locks atomically. Caller-supplied inputs use `build_input_specs` as-is.
- **`Action#run_funding_loop`** (`action.rb:847-895`) — up to `spendable_count + 1` iterations of `generate_change`; on `{ shortfall: N }`, tops up via `select_inputs(exclude: locked)` + `store.lock_inputs`, re-vins against the locked count (`base_vin`). Caller-supplied inputs **skip** top-up and raise `InsufficientFundsError` (`:867`). The #213 site is `:888-889`: `locked < top_up.size` → `InsufficientFundsError` instead of retry.
- **`Action#generate_change`** (`action.rb:940+`) — the loop *body*: resolve inputs → build inputs + signing keys → derive change keys → build outputs → template → fee check → `distribute_change` → shuffle → sign. Returns built-tx or shortfall. **This is TxBuilder's territory** (next extraction); FundingStrategy must call it through the seam, not own it.
- **`Action#total_input_satoshis_for`** (`action.rb:899-901`) — re-runs `resolve_inputs_for_signing` purely to sum source sats for the post-loop exact-headroom check (`:150-153`). This is the redundant fetch the AC targets.

## Target design

`Engine::FundingStrategy.new(store:, utxo_pool:)` — a plain class, explicit DI, `Interface::` contract, **zero `engine.send(:private)`** reach-through. It owns:

- input selection (absorbs `select_inputs`),
- the fixpoint loop (absorbs `run_funding_loop`),
- the Phase-1 lock-retry on contention (#213).

It calls the build collaborator (`Action` today, `TxBuilder` after the next extraction) through the seam and gets back done-or-shortfall. `Action#do_create_action` calls FundingStrategy once instead of reaching into four privates. `select_inputs`, `run_funding_loop`, `total_input_satoshis_for` leave `Engine`/`Action`.

It returns the converged result **including the total input satoshis** so the post-loop headroom check no longer re-fetches (kills `total_input_satoshis_for`).

**Orchestrates atomic Store methods only; never opens `db.transaction`.** Selection (read) and locking (`store.lock_inputs`, INSERT … ON CONFLICT) stay on opposite sides of the Store boundary.

## What changes

Behaviour-preserving, with **one deliberate change**: #213. Today, select↔lock contention (`lock_inputs` returns fewer than requested, or Phase-1 `create_action` returns nil) → `InsufficientFundsError`. After, it becomes a **bounded retry**: release/skip the contended lease, re-select excluding it, retry the lock. A concurrent case that fails today will succeed. The retry is safe *precisely because* the lease is ephemeral — re-borrowing scratch, no canonical state to roll back. The retry bound is a deliberate policy value (not unbounded); pool depletion still terminates in `InsufficientFundsError`.

## Acceptance criteria (from the #290 specialist panel)

- [ ] Plain class, explicit DI (`store:` / `utxo_pool:`), `Interface::` contract, **zero `engine.send(:private)`** from `Action`.
- [ ] Orchestrates atomic Store methods only; never opens `db.transaction`.
- [ ] #213 lock-retry lands here (bounded retry, not immediate `InsufficientFundsError`), covering **both** lock paths.
- [ ] **≤ 1 `resolve_inputs_for_signing` per build attempt** — pass resolved inputs / the input-sat total by value; eliminate the redundant `total_input_satoshis_for` fetch. (See "surprises" — the literal "≤1 per action" is infeasible across top-ups; this is the achievable reading.)
- [ ] Preserves the 4-phase invariants (#183/#197) and inline-equals-delayed; composes for #192 (no shape forcing parallel architecture); fundable pool stays injected.
- [ ] Behaviour-preserving: existing engine specs green; `FundingStrategy` unit-tested in isolation.

## Hardest aspects / where surprises lurk

- **The extraction-ordering paradox (the make-or-break).** The loop *body* (`generate_change`) is mostly TxBuilder work, but we extract FundingStrategy *first*. The whole PR hinges on defining the seam — "attempt a build at this input set → done-or-shortfall, by value" — well enough that the TxBuilder extraction can later lift the body without re-cutting it. Get this interface right; the rest is mechanical.
- **`≤ 1 resolve` is infeasible as literally stated.** The loop genuinely re-resolves after each top-up lock because the input set changed. Reinterpret as "one resolve per build attempt; kill the redundant post-loop fetch by returning the sat-total from the build."
- **Two lock paths, not one.** Phase-1 `create_action(inputs:)` and the loop's `lock_inputs` top-up sit on opposite sides of the current boundary. #213's retry must cover both.
- **Change keys are re-derived every iteration** (`action.rb:952`, `random_derivation`). Shortfall iterations throw keys away. Confirm no derivation params persist before the final `sign_action` (looks pure — verify no early DB write).
- **Coupled fee estimators.** `sweep` / `consolidate_step` / `estimate_sweep_fee` (`engine.rb:756`) pre-compute fees by mirroring `generate_change`'s exact output shape. FundingStrategy must preserve the loop's fee math byte-for-byte or those estimators silently drift.
- **`pre_lock_balance` threading.** Limp-mode/headroom (`action.rb:67-71`, `:150-153`) capture balance *before* Phase-1 lock and reuse it post-loop. If headroom stays on Engine but the loop moves, that value must cross the new boundary cleanly.
- **Two modes behind one interface.** Caller-supplied inputs (no top-up, fail-fast) vs wallet-selected (top-up loop). Both live behind the one entry point.

## Non-goals (explicit)

- No batch-awareness, no intra-batch fundable pool — #192 only.
- Do not prejudge #192's chaining/commit model.
- Do not fold FundingStrategy into TxBuilder (the symmetry is surface; nature is opposite).
- Do not touch Phase 3→4 ordering (it's a gate enforced by ADR-023's composite FK, not a swappable sequence).

## Implementation steps (ordered)

1. Define `Interface::FundingStrategy` — the contract: entry point, the by-value seam (resolved inputs / sat-total in, done-or-shortfall out), the injected `store:` / `utxo_pool:`.
2. Create `Engine::FundingStrategy` — move `select_inputs` + `run_funding_loop`; call the build collaborator through the seam; return the converged result + input-sat total.
3. Land #213 as the bounded lock-retry, covering Phase-1 and top-up locks.
4. Rewire `do_create_action` to call FundingStrategy; delete `total_input_satoshis_for`; feed the returned sat-total into the post-loop headroom check.
5. Remove the now-dead privates from `Engine`/`Action`; assert zero `engine.send(:private)` from the new class.

## Specs

- `FundingStrategy` unit specs in isolation: selection, the fixpoint convergence, shortfall→top-up, pool depletion→`InsufficientFundsError`, caller-supplied fail-fast, and the #213 contention-retry (the new behaviour) — Postgres for the contention/lock paths.
- Existing engine specs stay green (behaviour preservation).
- Confirm the fee estimators (`sweep`/`consolidate`) still agree with the loop's output shape.

## Verify before committing

- Full spec + rubocop, Postgres primary + SQLite augmentation (run from `gem/bsv-wallet`).
- Grep the new class for `engine.send(` / `.send(:` — must be none reaching private state.
- Confirm `resolve_inputs_for_signing` is called once per build attempt and not again post-loop.
