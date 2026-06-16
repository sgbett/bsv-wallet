# Extract Engine::TxBuilder (#336)

Second extraction of the #291 Engine decomposition, after #323 (FundingStrategy). ADR-024 records *why*. Behaviour-preserving move. Builds directly on the one-way `build:` seam #323 put in place.

## Conceptual model

TxBuilder is the **scribe** from the #323 model: it works in pure, private scratch — given a resolved input set, caller outputs, and a key deriver, it constructs, fee-balances, and signs a transaction. It is the *stateless* half of the build (ADR-018): no Store, no lock lifecycle, no clock. The quartermaster (FundingStrategy) owns the contended lease and hands the scribe a resolved input set; the scribe builds and reports done-or-shortfall **by value**; the quartermaster decides whether to lease more.

Two decisions settled in discussion before this plan:

1. **Resolve seam = (ii) store-free.** TxBuilder takes `resolved_inputs` **by value**; it does not call `resolve_inputs_for_signing`. That call moves to the caller — FundingStrategy (which already holds `store` and re-resolves after each top-up) and the deferred/`skip_change` paths in `do_create_action`. This keeps TxBuilder a pure function and preserves the `≤1 resolve per build attempt` property from #323.
2. **BEEF/egress deferred.** `build_atomic_beef`, `wire_ancestor`, `validate_for_handoff!` are hydration/egress (ProofStore + chain_tracker, ADR-015/#296), **not** tx construction. They stay on `Action` and are claimed by the later Hydrator/BeefImporter extraction.

## Current implementation (master, post-#323)

All on `Engine::Action`, reaching `@engine` for `store` + `key_deriver`:

- **`build_transaction`** (`action.rb:842`) — no-change path (deferred + `skip_change`). Resolves internally (`:843`), `build_outputs` + `build_inputs`, assemble, optional sign → `[wtxid, raw_tx, vout_mapping, tx]`.
- **`generate_change`** (`action.rb:901`) — funding-loop body, called through FundingStrategy's `build:` lambda (`action.rb:144`). Resolves internally (`:909`), `build_inputs`, derive BRC-42 change keys, build caller+change outputs, attach P2PKH templates, explicit fee check → `{shortfall: N}`, `distribute_change`, shuffle, sign, `change_output_specs` → `{wtxid, raw_tx, tx, vout_mapping, change_outputs}`.
- **`build_inputs`** (`action.rb:728`) — resolved inputs → `TransactionInput`s + signing keys; caller custom unlocking scripts; P2PKH key derivation via `@engine.send(:require_key_deriver!)` + `derive_signing_key`.
- **`build_outputs`** (`action.rb:690`) — caller outputs + shuffle/vout_mapping.
- Helpers: `resolve_locking_script`, `resolve_unlocking_script`, `derive_signing_key`, `find_caller_input`.
- The fee model is `SatoshisPerKilobyte.new(value: 100)` inline in `generate_change` (`:956`), mirrored by `estimate_sweep_fee`.

## Target design

`Engine::TxBuilder.new(key_deriver:, fee_model:)` — plain class, **store-free**, `Interface::TxBuilder` contract, **zero `engine.send`**. Surface:

- `build(resolved_inputs:, caller_outputs:, caller_inputs:, lock_time:, version:, randomize:, sign:)` — the no-change build (today's `build_transaction`).
- `build_change(resolved_inputs:, caller_outputs:, caller_inputs:, lock_time:, version:, randomize:, change_count:)` — the change/fee-fixpoint build (today's `generate_change`); returns the success hash or `{shortfall: N}`.
- `apply_spends(tx:, resolved_inputs:, spends:)` — the deferred-signing **finaliser** (today's `Action#apply_spends` core): re-attach source data, apply caller unlocking scripts, derive keys for unspent P2PKH inputs, sign → `[wtxid, raw_tx, tx]`. Store-free. *The transaction builder signs.*
- `build_inputs`/`build_outputs` + the helpers (`resolve_unlocking_script`, `derive_signing_key`, …) move in as privates.

ChangeGenerator stays folded in (`build_change` is the fee fixpoint body). `key_deriver` is injected; `require_key_deriver!`-style guarding becomes a TxBuilder concern over its own injected deriver.

**`apply_spends` cross-cut (decision (a), found in analysis — not in the original plan).** `Action#apply_spends` (`action.rb:507`, the signAction finaliser) directly used three helpers being moved (`resolve_unlocking_script`, `derive_signing_key`, `@engine.send(:require_key_deriver!)`). A wholesale move would break it, and `apply_spends` is itself *construction* (it finalises and signs). Resolution: its finalise-and-sign core moves into `TxBuilder#apply_spends` (store-free); `Action#apply_spends` becomes thin orchestration — load the unsigned tx, `resolve_inputs_for_signing`, validate the spend vins, delegate to `tx_builder.apply_spends`, return. This removes the **last** `require_key_deriver!` reach on the deferred path.

## The seam change (touches the just-merged FundingStrategy)

The `build:` callable gains a `resolved_inputs` argument; FundingStrategy resolves and passes it:

- **FundingStrategy#acquire** — after each lock (initial + top-up), resolve the current locked set and call the build: `resolved = @store.resolve_inputs_for_signing(action_id:); result = build.call(resolved)`. FundingStrategy already holds `store`, so this is consistent; resolve happens exactly once per build attempt.
- **`do_create_action`** — the funding-path `build:` lambda becomes `->(resolved) { tx_builder.build_change(resolved_inputs: resolved, caller_outputs:, …) }`. The deferred/`skip_change` paths resolve inline (`engine.store.resolve_inputs_for_signing`) and call `tx_builder.build(resolved_inputs:, …)`.

This is the expected payoff/cost of #323's seam: we now adjust *what flows across it* (resolved inputs in, done-or-shortfall out), one-way direction unchanged.

## What changes

- Pure move + the resolve relocation; no behavioural change to tx construction.
- DI replaces `@engine` reach-through (`@engine.store` gone from the build; `@engine.key_deriver` → injected; `@engine.send(:require_key_deriver!)` gone).
- `resolve_inputs_for_signing` call sites: removed from the build; added to FundingStrategy#acquire (loop) and the two `do_create_action` non-funding paths. (`build_atomic_beef`'s resolve at `:632` stays — BEEF deferred.)
- `Engine` gains `@tx_builder = TxBuilder.new(key_deriver:, fee_model:)` + `attr_reader`.

## Acceptance criteria (from #336)

- [ ] Plain `Engine::TxBuilder`, DI (`key_deriver:` + fee model), `Interface::TxBuilder` contract, **zero `engine.send(:`/`.send(:`** — kills `@engine.send(:require_key_deriver!)`.
- [ ] **Store-free**: takes `resolved_inputs` by value; no `store` dep, no `resolve_inputs_for_signing` inside; resolve relocated to FundingStrategy + the deferred/`skip_change` paths; `≤1 resolve per build attempt` preserved.
- [ ] One-way seam preserved: returns done-or-shortfall by value; never reaches for inputs.
- [ ] `build_transaction`/`generate_change`/`build_inputs`/`build_outputs` + helpers moved; FundingStrategy `build:` + deferred/`skip_change` repointed.
- [ ] `Action#apply_spends` finalise-and-sign core moves to `TxBuilder#apply_spends` (store-free); `Action#apply_spends` becomes thin (resolve, validate vins, delegate); last deferred-path `require_key_deriver!` reach removed.
- [ ] BEEF/egress methods remain on `Action` (out of scope).
- [ ] Fee model + `sweep`/`consolidate` `estimate_sweep_fee` coupling preserved byte-for-byte.
- [ ] Behaviour-preserving: engine + integration specs green; TxBuilder unit-tested in isolation.

## Hardest aspects / surprises

- **The resolve relocation is the delicate part.** Moving `resolve_inputs_for_signing` out of the build and into FundingStrategy's loop must keep it *once per build attempt* and must re-resolve *after* each top-up lock (the input set grew). Get the ordering wrong (resolve before the top-up lock) and the build sees a stale input set. The deferred/`skip_change` paths resolve once, inline — simpler.
- **Two build methods share a lot.** `build` (no-change) and `build_change` share resolve-consumption/`build_inputs`/assemble/sign. Keep them as two methods (behaviour-preserving); resist unifying in this move.
- **Fee model coupling.** `estimate_sweep_fee` hand-mirrors `build_change`'s tx shape and fee model. Do **not** centralise/de-dup the fee model in this move — preserve it byte-for-byte and keep the coupling guard test (sweep/consolidate specs).
- **`key_deriver` DI surface.** `build_change` uses `derive_public_key` + `identity_key`; `build_inputs` uses `derive_signing_key` + the deriver guard. All move behind the injected `key_deriver` — confirm no other `@engine` reach sneaks in.
- **InputSource** (`engine/input_source.rb`) is already separate — `build_inputs` calls `InputSource.attach!`; that stays a module call, no issue.

## Non-goals (explicit)

- BEEF assembly / egress validation (Hydrator extraction).
- No fee-model de-duplication / `estimate_sweep_fee` refactor.
- No batch-awareness (#192).
- No unifying `build` + `build_change`.

## Implementation steps (ordered)

1. `Interface::TxBuilder` — contract: `build` + `build_change`, the by-value `resolved_inputs` input, the done-or-shortfall return, store-free + DI `key_deriver`/fee model.
2. `Engine::TxBuilder` — move `build_transaction`→`build`, `generate_change`→`build_change`, the `apply_spends` finalise core→`apply_spends`, `build_inputs`/`build_outputs` + helpers; take `resolved_inputs` by value; inject `key_deriver` + fee model. Wire `@tx_builder` on `Engine` + `attr_reader`.
3. Relocate resolve: FundingStrategy#acquire resolves after each lock and calls `build.call(resolved)`; update the `build:` seam signature.
4. Repoint `do_create_action`: funding lambda → `tx_builder.build_change`; deferred/`skip_change` → resolve inline + `tx_builder.build`. Rewire `Action#apply_spends` to resolve + validate + delegate to `tx_builder.apply_spends`. Delete the moved methods/helpers from `Action`.
5. Specs + dead-code sweep.

## Specs

- `TxBuilder` isolation specs: `build` (no-change), `build_change` (convergence + `{shortfall: N}`), BRC-42 change derivation + `change_outputs` specs, caller custom unlocking script, randomize/`vout_mapping`, store-free assertion (no `store`/`resolve_inputs_for_signing` reference), zero `engine.send`.
- FundingStrategy specs updated for the resolve-in-loop change (resolve called once per build attempt, after each top-up).
- Existing engine + integration specs green (behaviour preservation); `sweep`/`consolidate` fee-coupling guard passes.

## Verify before committing

- Full spec + rubocop, Postgres primary + SQLite augmentation (from `gem/bsv-wallet`).
- Grep `tx_builder.rb` for `store`/`resolve_inputs_for_signing`/`engine.send(`/`.send(:` — must be none.
- Confirm `resolve_inputs_for_signing` is called exactly once per build attempt (FundingStrategy loop) and once each on the deferred/`skip_change` paths.
