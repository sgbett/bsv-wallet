# Engine::Action logical model — encapsulate the 4-phase lifecycle

**Issue:** #214
**Date:** 2026-06-07
**Status:** Plan — awaiting approval

## Goal

Introduce `BSV::Wallet::Engine::Action` as the third member of the logical-model trio (`Broadcast`, `TxProof`, `Action`). Engine's BRC-100 lifecycle methods (`create_action`, `sign_action`, `abort_action`, `internalize_action`, `list_actions`) become thin validation + delegation layers; the procedural helpers move onto `Action`.

The HLR explicitly defers extracting the funding loop into its own collaborator — **`Action` takes funding with it**. #213 (Phase 1 lock retry) will revisit the funding loop's internals anyway; pulling it out now would be churn ahead of that decision.

## Scope baseline (verified 2026-06-07)

- `engine.rb` — **2,333 LOC** (HLR snapshot said 2,120; drift from #249 umbrella's orchestration mass).
- `engine_spec.rb` — **3,326 LOC**.
- `Engine::Broadcast` — 584 LOC (the size precedent for a logical model that owns a lifecycle).
- `Engine::TxProof` — 104 LOC.

Methods to move (lines as of HEAD `a108716`):

| Method | engine.rb line | Destination |
|--------|----------------|-------------|
| `create_action` | 112 | `Action.create` (class) |
| `sign_action` | 288 | `Action#sign!` |
| `abort_action` | 329 | `Action#abort!` |
| `list_actions` | 351 | `Action.list` (class) |
| `internalize_action` | 368 | `Action.internalize` (class) |
| `run_funding_loop` | 2060 | `Action#run_funding_loop` (private) |
| `generate_change` | 2153 | `Action#generate_change` (private) |
| `build_atomic_beef` | 1425 | `Action#build_atomic_beef` (private) |
| `promote_with_outputs` | 1329 | `Action#promote_with_outputs` (private) |
| `apply_spends` | 2265 | `Action#apply_spends` (private) |
| `build_input_specs` | 1284 | `Action#build_input_specs` (private) |
| `build_output_specs` | 1341 | `Action#build_output_specs` (private) |
| `build_transaction` | (caller-side helper) | `Action#build_transaction` (private) |
| `save_beef_proofs` | (incoming-side helper) | `Action#save_beef_proofs` (private) |
| `wire_ancestor` | 1451 | `Action#wire_ancestor` (private) |
| `hydrate_known_sources!` | 1482 | `Action#hydrate_known_sources!` (private) |
| `parse_beef` | 1495 | `Action#parse_beef` (private) |
| `verify_incoming_transaction!` | (helper) | `Action#verify_incoming_transaction!` (private) |
| `query_change_outpoints` | 1370 | `Action#query_change_outpoints` (private) |
| `publish_beef_hint` | 1398 | `Action#publish_beef_hint` (private) |

Methods that stay on `Engine` (orchestrators / not action-lifecycle):

- `limp_mode?`, `headroom`, `enforce_limp_mode!`, `enforce_headroom_against!` — wallet-level state, not per-action.
- `select_inputs`, `attach_labels` — `Action` calls them but they belong to the Engine as collaborators (selection is wallet-pool scope, label lookup is across-actions).
- The non-action BRC-100 methods (`list_outputs`, `relinquish_output`, key-derivation, encrypt/decrypt, certificate, discover, header lookups) — orthogonal subsystems.
- Internal porcelain (`sweep`, `consolidate_step`, `import_utxo`, `import_wallet`, `send_payment`, `sweep_to_root`, `generate_receive_address`, `scan_receive_addresses`) — all currently delegate to `create_action`; they keep doing so via `Action.create`. No surface change.
- The `@broadcast_worker` instance + `@hints_socket` mutex — wallet-process-scoped collaborators.

## Class shape

```ruby
module BSV::Wallet
  class Engine
    autoload :Action, 'bsv/wallet/engine/action'

    # === Class ==================================================

    class Action
      # Class methods — entry points the Engine delegates to.
      def self.create(engine:, **params)        # → Action
      def self.find(engine:, reference:)        # → Action | nil
      def self.find_by_id(engine:, id:)         # → Action | nil  (internal)
      def self.list(engine:, **params)          # → { total_actions:, actions: }
      def self.internalize(engine:, **params)   # → Action

      # Instance ---------------------------------------------------

      attr_reader :engine, :id, :row  # row lazily loaded

      def initialize(engine:, row:)
        @engine = engine
        @row = row
        @id   = row[:id]
      end

      # Lifecycle methods invoked by Engine delegators or by porcelain.
      def sign!(spends:, no_send:, accept_delayed_broadcast:)  # → result_hash
      def abort!                                                # → { aborted: true }
      def broadcast!(mode: :inline | :delayed | :none)          # → self
      def promote!(outputs:, vout_mapping:)                     # → self  (internal-path Phase 4)
      def beef                                                  # → Atomic BEEF binary

      # Translation to the BRC-100 return shapes Engine currently produces.
      def to_create_result(return_txid_only:, no_send:, change:) # → Hash
      def to_signable_handle                                     # → Hash (deferred path)
      def to_sign_result(return_txid_only:, no_send:)            # → Hash
      def to_list_entry(includes:)                               # → Hash

      private

      # All the procedural helpers from engine.rb, lifted as instance methods.
      # @engine.store, @engine.utxo_pool, @engine.key_deriver, @engine.broadcaster,
      # @engine.broadcast_worker — accessed via attr_readers exposed on Engine.
    end
  end
end
```

## Engine collaborator surface that `Action` needs

`Action` reads collaborators from `@engine`. The existing readers (`@broadcaster`, `@broadcast_worker`, `@services`) cover most; we need to expose a few more **without making them part of the public surface** — `attr_reader` on a small grouping kept under a comment that flags "for Engine::Action use":

```ruby
# Engine collaborator surface exposed for Engine::Action and Engine::Broadcast.
# Not public API — these are internal handles for in-process logical models.
attr_reader :store, :utxo_pool, :key_deriver, :chain_tracker,
            :network_provider, :hydrated_tx_cache
```

(Pre-existing public readers: `:limp_threshold, :services, :broadcaster, :broadcast_worker`.)

Note: `Broadcast` already reaches into `@store` directly via constructor injection; for `Action` we route through `engine.store` because `Action` is constructed per-call and the engine is the natural single source of truth for the collaborator graph.

## Why not split funding out

Per HLR §"Out of scope" and the user's direction:

- #213's Phase 1 lock retry will need to share infrastructure with the funding loop's existing top-up retry. Pre-extracting a `FundingLoop` collaborator now would be designed against today's shape, not the post-#213 shape.
- `Engine::Broadcast` shipped at 584 LOC with similar internal layering and reads well. Funding + change generation will sit comfortably in `Action`'s private section.
- We commit to revisiting if `Action` exceeds ~700 LOC, OR if #213's design wants a shared `acquire_inputs` primitive — either condition reopens the extraction question with concrete shape data.

## Migration order

The change is too big for a single PR (engine_spec.rb alone is 3,326 LOC and most of it exercises `create_action`). Mirror the #249 umbrella pattern: one parent branch, sequenced sub-PRs onto it, single merge to master at the end. **And: this time, the parent PR's body lists every `Closes #N` for every sub-issue — last week's lesson.**

### Umbrella branch

`feat/214-engine-action`

### Sub-PRs (each onto the umbrella, each independently green)

#### Sub-PR 1 — skeleton + `Action.create` (the load-bearing one)

- Create `lib/bsv/wallet/engine/action.rb` with the class skeleton and constructor.
- Add `autoload :Action` to Engine.
- Move: `create_action` body, `run_funding_loop`, `generate_change`, `build_atomic_beef`, `promote_with_outputs`, `build_transaction`, `build_input_specs`, `build_output_specs`, `publish_beef_hint`, `query_change_outpoints`, `wire_ancestor`, `random_derivation`, `select_inputs`-style adapters.
- `Engine#create_action` collapses to: validate → `Action.create(engine: self, **params).to_create_result(...)`.
- Expose new `attr_reader`s for collaborator access.
- All porcelain methods (`sweep`, `consolidate_step`, `import_utxo`, `send_payment`, etc.) keep calling `create_action` — no change at those sites.
- Engine_spec.rb behavioral tests untouched; they now exercise the delegator and pass through to `Action`.
- Add minimal `spec/bsv/wallet/engine/action_spec.rb` for class-level smoke (`Action.create` returns an Action; round-trip via Engine still works).

**Risk surface:** This is the big diff. The funding loop's state plumbing (`locked_output_ids`, `change_count`, the `:shortfall` return shape) needs to move cleanly. Helped by the fact that all of these methods already take explicit `action_id:` and don't read instance state — they're already pure functions in disguise.

**Expected diff:** ~600 lines removed from engine.rb, ~600 lines added to action.rb. Engine drops to ~1,700 LOC.

#### Sub-PR 2 — `Action#sign!` + `Action#abort!`

- Move `sign_action` body and `apply_spends` to `Action#sign!`.
- Move `abort_action` body to `Action#abort!`.
- `Engine#sign_action` becomes: validate → find row → `Action.new(engine: self, row: row).sign!(...).to_sign_result(...)`.
- `Engine#abort_action` similarly.
- Same delegator pattern; engine_spec.rb stays green.

**Expected diff:** ~150 lines net moved. Engine drops to ~1,550 LOC.

#### Sub-PR 3 — `Action.internalize`

- Move `internalize_action` body, `parse_beef`, `verify_incoming_transaction!`, `hydrate_known_sources!`, `save_beef_proofs`.
- `Engine#internalize_action` becomes: validate → `Action.internalize(engine: self, ...).to_create_result(...)`.

**Expected diff:** ~200 lines moved.

#### Sub-PR 4 — `Action.list` + `Action.find`

- Move `list_actions` body to `Action.list`.
- Add `Action.find(engine:, reference:)` and `Action.find_by_id(engine:, id:)` as the canonical lookup points.
- `Engine#list_actions` becomes a one-line delegator.
- Audit any direct `@store.find_action(reference: …)` calls left in Engine and route through `Action.find` where the caller wants an `Action`, leave alone where it wants a row.

**Expected diff:** ~50 lines moved.

#### Sub-PR 5 — cleanup pass

- Remove any helpers that became dead code once their callers moved.
- Audit `engine_spec.rb` for any test that reaches into private methods directly — move those tests to `action_spec.rb` if they belong to `Action`'s surface now.
- Update `CLAUDE.md` / `reference/` notes that name procedural methods now gone.
- Final LOC: Engine target ~1,200–1,400 (depends on what porcelain looks like); `Action` ~700–900.

#### Umbrella PR onto master

Body lists `Closes #214` and each sub-PR's commit range. The full unit suite (Postgres + SQLite) + integration suite + rubocop must be green at the umbrella tip before merge.

## Acceptance criteria check

- [ ] `BSV::Wallet::Engine::Action` exists with `create`, `find`, `list`, `internalize` class methods and `sign!`, `abort!`, `broadcast!`, `promote!`, `beef` instance methods.
- [ ] `Engine#create_action`, `#sign_action`, `#abort_action`, `#internalize_action`, `#list_actions` collapse to validate + delegate + translate.
- [ ] Procedural helpers listed in HLR move onto `Action` (or are deleted if dead).
- [ ] `Engine` LOC drops materially: target ≤ 1,500 (relaxed from HLR's ~1,000 to reflect post-#249 baseline of 2,333).
- [ ] Existing public-API behavior unchanged — every BRC-100 method preserves return shape and side effects.
- [ ] Full unit suite (Postgres + SQLite) passes; existing tests untouched except where they referenced private methods directly.
- [ ] `Action` follows the same constructor pattern as `Broadcast` / `TxProof` (collaborators in, no surprise globals).
- [ ] Integration suite passes — bin/import, bin/create_action, bin/sweep, bin/sweep_to_root, the e2e broadcast spec all exercise `Action.create` end-to-end.
- [ ] Rubocop clean.

## Out of scope (deferred)

- Funding-loop extraction — defer to #213 (Phase 1 lock retry) so the design is informed by the contention-retry shape, not pre-empted by it.
- Process-action / chained-send (`sendWith`) — #192.
- Renaming `Engine::Broadcast` / `Engine::TxProof` — those are the pattern, not the target.
- Any behavior change found mid-refactor — file a separate issue, fix later.

## Risk register

| Risk | Mitigation |
|------|------------|
| Big diff in sub-PR 1 introduces subtle state leak from instance vars now scoped per-Action | All methods being moved are already explicit-`action_id:` style; no instance-vars to migrate beyond the new `@row`. Spec coverage on `create_action` is dense (3,326-line spec). |
| `@hints_socket` Mutex stays on Engine but `publish_beef_hint` moves to Action — cross-object mutex | Either keep `publish_beef_hint` on Engine and call from Action (simplest), or move the socket+mutex pair into a dedicated `Engine::HintPublisher` collaborator. **Recommend: keep on Engine for now**; it's wallet-process scope, not action scope. |
| Engine constructor surface grows with new `attr_reader`s | Keep them under a documented "for Engine::Action use" comment block. Same shape as Engine::Broadcast's collaborator-injection model, just on the read side. |
| `to_create_result` ends up with too many switches for the four return shapes (signed / deferred / no_send-internal / signable) | The branching already exists inside `Engine#create_action`; we're moving it, not creating it. If it bothers us post-move, file a follow-up to make `to_create_result` a proper case-table. |
| Sub-PR 1 lands but discoveries inside it make sub-PR 2's shape change | Each sub-PR is independently scoped; if we discover something material, that PR's plan section updates and the umbrella plan in this file gets a note. The umbrella merge waits for all sub-PRs green. |

## Construction model (resolved)

`Action` is a per-call business object — cheap to construct, discarded on completion, wraps a Sequel row hash. No identity map, no shared mutable state across instances; load-by-id when needed. Same shape as Sequel models on the data side; what `Action` adds is **knowledge** (derived status, BRC-100 translation) and **atomic actions** (`sign!`, `abort!`, `broadcast!`, `promote!`) — the behavioral layer that the procedural code in `engine.rb` is implicitly today.

## Testing strategy

- Existing `engine_spec.rb` tests stay in place — they document Engine's public surface, which doesn't change.
- New `spec/bsv/wallet/engine/action_spec.rb` covers:
  - Action class methods (`create`, `find`, `list`, `internalize`) at the unit level.
  - Lifecycle instance methods invoked directly without going through Engine.
  - Translation methods (`to_create_result` and friends) match the expected return shapes.
- No new behavior, so no new behavioral specs needed beyond what already exists.
- Run against **both** Postgres and SQLite each sub-PR. Integration suite at umbrella tip only (gated by funded WIFs).

## Tracking

Sub-issues to open under #214 once approved:

- [ ] #N+1 — sub-PR 1: skeleton + Action.create migration
- [ ] #N+2 — sub-PR 2: sign! + abort! migration
- [ ] #N+3 — sub-PR 3: Action.internalize migration
- [ ] #N+4 — sub-PR 4: Action.list + Action.find migration
- [ ] #N+5 — sub-PR 5: cleanup pass

Each sub-PR body must include `Closes #N+M` for its own sub-issue. The umbrella PR body must include `Closes #214` plus a sub-PR commit table for reviewer navigation.
