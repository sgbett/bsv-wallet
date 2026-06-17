# Extract Engine::BeefImporter (#357)

Fourth extraction of the #291 Engine decomposition, after #323 (FundingStrategy), #336 (TxBuilder), #343 (Hydrator). ADR-024 records *why*. Behaviour-preserving move. Builds directly on #343's one-way `wire_ancestor` seam.

## Conceptual model

BeefImporter is the **ingress** counterpart to Hydrator's egress: where Hydrator wires our own proofs *out* into an Atomic BEEF, BeefImporter ingests an incoming BEEF *in* — parse, SPV-verify, persist ancestor proofs, and resolve the named outputs into the canonical UTXO set. It is a **standalone, pre-Action process**: the work runs before any action row exists, and `createAction` is not its only trigger — `internalizeAction`, the wbikd receive path, and (future) daemon background prefetch all import BEEFs with no outbound action in play.

Settled in discussion — **scope (b)**: the *whole* ingress flow moves. `BeefImporter.import(tx:, outputs:, …)` owns it end-to-end; `Engine#internalize_action` delegates directly; `Action.internalize` is deleted (and the `helper = new(engine:, row: {id: nil})` row-less-instance hack with it). Chosen over "orchestration stays on Action" because internalize is genuinely pre-Action — the action row is a midpoint artefact, not the subject, and there is no `createAction`-style 4-phase lifecycle for Action to own. It **consumes `Hydrator#wire_ancestor`** (the seam already wired in #343).

## Current implementation (master)

`Engine#internalize_action` (`engine.rb:197`) → `Action.internalize` (`action.rb:239`), a static orchestrator that dispatches private helpers through a row-less instance (`helper = new(engine:, row: {id: nil})`, `:246`). Flow:

1. `parse_beef` (`action.rb:553`) → beef + subject_tx
2. `hydrate_known_sources!` (`:580`, trustSelf) — **already** calls `engine.hydrator.wire_ancestor`
3. `verify_incoming_transaction!` (`:596`) — full SPV via `@engine.chain_tracker`
4. `store.create_action` (intent `none`) → `store.sign_action` → `store.save_proof`
5. `attach_labels`
6. `save_beef_proofs` (`:610`) — persist ancestor proofs
7. `replace_known_ancestors!` (`:652`, trustSelf) — TXID-only trimming
8. `resolve_internalize_output` (per output) + vout/satoshis validation against subject_tx
9. `store.promote_action` → `{ accepted: true }`

Other caller: the wbikd receive path (`internalize_wbikd_utxo`, `engine.rb:1252`) — **confirm** whether it routes through `Action.internalize` or its own logic; repoint accordingly.

## Target design

`Engine::BeefImporter.new(store:, chain_tracker:, hydrator:)` — plain class, store-reading, `Interface::BeefImporter` contract, **zero `engine.send`**. No `key_deriver` (ingress derives nothing — output derivation params are caller-supplied). Surface:

- `import(tx:, outputs:, description:, labels: nil, trust_self: nil, known_txids: nil, seek_permission: true, originator: nil)` → `{ accepted: true }` — the whole flow above.
- `parse_beef`, `verify_incoming_transaction!`, `hydrate_known_sources!`, `save_beef_proofs`, `replace_known_ancestors!`, `resolve_internalize_output` move in as privates.

`Engine` gains `@beef_importer = BeefImporter.new(store: @store, chain_tracker: @chain_tracker, hydrator: @hydrator)` + `attr_reader`. `Engine#internalize_action` and the wbikd path delegate to `beef_importer.import`.

## What changes

- The ingress flow + helpers move to BeefImporter; `Action.internalize` **and the row-less-helper hack** are deleted (the hack existed *only* to dispatch these helpers — it goes for free).
- `hydrate_known_sources!`'s `@engine.hydrator.wire_ancestor` becomes `@hydrator.wire_ancestor` (DI).
- `@engine.chain_tracker` → injected `chain_tracker`; `@engine.store` → injected `store`.
- Callers repointed: `Engine#internalize_action`, the wbikd receive path, and any spec calling `Action.internalize` directly.

## Acceptance criteria (from #357)

- [ ] Plain `Engine::BeefImporter`, DI `store:`/`chain_tracker:`/`hydrator:`, `Interface::BeefImporter` contract, **zero `engine.send(:`/`.send(:`**.
- [ ] Ingress flow + the 6 helpers moved; `Engine#internalize_action` + wbikd path delegate to `beef_importer.import`; `Action.internalize` + the row-less hack deleted.
- [ ] Consumes `Hydrator#wire_ancestor` (one-way: ingress → Hydrator).
- [ ] **Ordering invariants preserved exactly**: verify before persistence; `save_beef_proofs` *before* `replace_known_ancestors!`; the `make_txid_only` in-memory-pointer caveat (`action.rb:277-289`).
- [ ] Behaviour-preserving: engine + integration specs green; `BeefImporter` unit-tested in isolation.

## Deferred — captured, NOT done here

- `resolve_internalize_output` inference removal → **#60** (move preserves the inference verbatim).
- `verify_beef` dedup (ingress vs egress `Tx#verify`) → **#296** (comment 4725191167).
- `build_atomic_beef` count-parity guard → **#291** note (Hydrator surface).
- No #296 unified-hydration-primitive design — this is a move.

## Hardest aspects / surprises

- **The ordering invariants are the hinge.** `save_beef_proofs` must run *before* `replace_known_ancestors!` (else TXID-only trimming discards proofs not yet persisted); `verify` before any persistence; `make_txid_only` mutates the BEEF's entry list but not the in-memory `source_transaction` pointers `verify` already walked. The move must preserve this sequence verbatim — `action.rb:277-289` is the contract.
- **wbikd receive path** (`internalize_wbikd_utxo`) — confirm its relationship to `Action.internalize`; it may need its own delegation or already share the path. Verify before deleting `Action.internalize`.
- **Spec callers of `Action.internalize`** — `#286` (Sub-PR 3: Action.internalize) landed the current shape; its specs likely call `Action.internalize` directly and must repoint to `BeefImporter#import` (or `Engine#internalize_action`). Behaviour-preservation hinge, like #343's stub retarget.
- **No `key_deriver`** — confirm nothing in the ingress path derives keys (it shouldn't; output derivation params are caller-supplied). If something does, the DI set grows.
- **`resolve_internalize_output`'s inference stays** — do not "tidy" it here; #60 owns that. Moving it verbatim is correct.

## Implementation steps (ordered)

1. `Interface::BeefImporter` — contract: `import`; store-reading DI (`store:`/`chain_tracker:`/`hydrator:`); consumes Hydrator one-way.
2. `Engine::BeefImporter` — move `internalize`→`import` + the 6 helpers (privates); DI wiring; `@engine.hydrator`→`@hydrator`, `@engine.chain_tracker`→`@chain_tracker`, `@engine.store`→`@store`. Wire `@beef_importer` on `Engine` + `attr_reader`. Isolation specs.
3. Repoint `Engine#internalize_action` + the wbikd path → `beef_importer.import`; delete `Action.internalize` + the row-less hack + the moved helpers from `Action`; repoint spec callers.
4. Full suite + rubocop; dead-code sweep.

## Specs

- `BeefImporter` isolation specs: `parse_beef` (valid / invalid-BEEF → `InvalidBeefError`), `verify_incoming_transaction!` (the 5 `VerificationError` → `InvalidBeefError` wraps + the success delegate + nil-chain_tracker raise), trustSelf `hydrate_known_sources!` (wires from ProofStore via `hydrator.wire_ancestor`), `save_beef_proofs` (persists ancestors; subject proof_id linkage only with merkle_path), `replace_known_ancestors!` (TXID-only trimming, order-after-save), `resolve_internalize_output` (spec resolution + vout/satoshis validation), and `import` end-to-end (`{ accepted: true }`, `promote_action` called, the save→replace ordering).
- Repoint existing internalize specs (from #286) to `BeefImporter`/`Engine#internalize_action`.
- Existing engine + integration specs green (behaviour preservation).

## Verify before committing

- **Full `bundle exec rspec`** (the CI command — includes `spec/support`), Postgres primary + SQLite, + rubocop, from `gem/bsv-wallet`. (Do *not* use the narrow `spec/bsv spec/bin` as the final gate — it misses `spec/support`; cf. the #343 harness-flake lesson.)
- Grep `beef_importer.rb` for `engine.send(`/`.send(:`/`@engine` — none.
- Confirm `Action.internalize` and the `new(engine:, row: {id: nil})` hack are gone; the ingress helpers no longer on `Action`.
- Confirm the wbikd receive path still works (its internalize route repointed).
