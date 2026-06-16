# Extract Engine::Hydrator (#343)

Third extraction of the #291 Engine decomposition, after #323 (FundingStrategy) and #336 (TxBuilder). ADR-024 records *why*. Behaviour-preserving move. The BEEF/egress methods were explicitly deferred here by both prior extractions.

## Conceptual model

Hydrator is the **ProofStore→Tx wiring service**: given a signed transaction, it reads persisted proofs and wires the `source_transaction` ancestor graph until each branch terminates at a merkle-proven leaf, then assembles the Atomic BEEF and proves it valid before handoff. Unlike TxBuilder (store-free), Hydrator is **store-reading** — hydration is inherently a read over persisted proofs. It is the *dehydrated → hydrated* direction; the reverse (ingesting incoming BEEF into the ProofStore) is the later BeefImporter.

Settled in discussion:

1. **Narrow scope.** Hydrator owns the *deep* hydration only: `wire_ancestor` (recursive ProofStore wiring), `build_atomic_beef` (egress assembly), `validate_for_handoff!` (egress SPV honesty contract). The *shallow* broadcast EF hydration (`hydrated_transaction_for` + `HydratedTxCache`) stays in Broadcast — its cache invalidation is driven by the broadcast lifecycle (evict on reject/terminal), and dragging that coupling into a pure wiring service would be wrong. `InputSource` stays a standalone shared module.
2. **Machinery moves, orchestration stays.** Action keeps the egress *sequence* in `do_create_action` (build BEEF → validate → hand off); only the machinery methods move. `validate_for_handoff!` has no Action state, so the whole method moves and Action just calls it at the existing site — no thin wrapper (contrast #336's `apply_spends`, which needed one because it read Action state).
3. **One-way seam.** `wire_ancestor` is exposed as the primitive the next extraction (BeefImporter, ingress) consumes for trustSelf `hydrate_known_sources!`. Ingress depends on Hydrator, never the reverse.

## Current implementation (master, post-#336)

All on `Engine::Action`, reaching `@engine.store`:

- **`wire_ancestor`** (`action.rb:616`) — recursive: `store.find_proof(wtxid)` → `Tx.from_binary`; if `merkle_path` present, attach it and return (proven terminal); else recurse into each input's `prev_wtxid`, wiring `source_transaction`. `visited` set guards cycles.
- **`build_atomic_beef`** (`action.rb:590`) — `Tx.from_binary(raw_tx)`, `store.resolve_inputs_for_signing(action_id)`, wire each input's `source_transaction` via `wire_ancestor(resolved[:source_wtxid])`, `Beef.new.merge_transaction(tx)`, `to_atomic_binary`. Called **3×**: deferred (`:121`), sync (`:193`), and the signAction-completion path (`:463`, after `apply_spends`).
- **`validate_for_handoff!`** (`action.rb:566`) — parse the BEEF, find the subject entry, `subject_entry.transaction.verify(chain_tracker: TrustedSelfChainTracker.new)`; raise `EgressBeefInvalidError` if the subject is missing or verification fails. Pure `(atomic_beef, subject_wtxid) → verify-or-raise`; news its own `TrustedSelfChainTracker` (the egress self-trust model).

## Target design

`Engine::Hydrator.new(store:)` — plain class, store-reading, `Interface::Hydrator` contract, **zero `engine.send`**. Surface:

- `wire_ancestor(wtxid, visited: Set.new)` — the recursive ProofStore→Tx primitive. Public (BeefImporter consumes it).
- `build_atomic_beef(raw_tx, action_id)` — egress Atomic BEEF assembly (reads `store.resolve_inputs_for_signing` + `wire_ancestor`).
- `validate_for_handoff!(atomic_beef, subject_wtxid)` — egress SPV honesty contract; constructs its own `TrustedSelfChainTracker` internally (unchanged behaviour).

**DI is `store:` only.** `validate_for_handoff!` does *not* take an injected chain_tracker — it self-constructs `TrustedSelfChainTracker` (refines the HLR's looser "+ chain_tracker" wording; the tracker is an egress-specific trust model Hydrator owns, not an engine dependency). `build_atomic_beef` keeps resolving inputs internally by `action_id` — no by-value `resolved_inputs` needed (Hydrator holds `store` for `find_proof` regardless, unlike store-free TxBuilder).

`Engine` gains `@hydrator = Hydrator.new(store: @store)` + `attr_reader`. Action's three `build_atomic_beef` sites and its `validate_for_handoff!` site call `engine.hydrator.…`; the methods leave Action.

## What changes

- Pure move; no behavioural change.
- `wire_ancestor` / `build_atomic_beef` / `validate_for_handoff!` move to Hydrator; the 3 `build_atomic_beef` call sites + the `validate_for_handoff!` site repoint.
- `Engine` wires `@hydrator`.
- DI replaces `@engine.store` reach in the moved methods.

## Acceptance criteria (from #343)

- [ ] Plain `Engine::Hydrator`, DI `store:`, `Interface::Hydrator` contract, **zero `engine.send(:`/`.send(:`**.
- [ ] `wire_ancestor` + `build_atomic_beef` + `validate_for_handoff!` moved; the 3 `build_atomic_beef` sites (deferred/sync/signAction) + the `validate_for_handoff!` site repointed to `hydrator`.
- [ ] `wire_ancestor` public — the primitive BeefImporter will consume (one-way: ingress → Hydrator).
- [ ] Out-of-scope stays: `hydrated_transaction_for` + `HydratedTxCache` in Broadcast; `InputSource` standalone; ingress helpers (`parse_beef`/`verify_incoming_transaction!`/`save_beef_proofs`/`replace_known_ancestors!`/`hydrate_known_sources!`) on Action (→ BeefImporter later).
- [ ] Behaviour-preserving: engine + integration specs green; `Hydrator` unit-tested in isolation.

## Hardest aspects / surprises

- **`hydrate_known_sources!` straddles.** It's ingress (internalize trustSelf) but calls `wire_ancestor`. It must **stay on Action** this PR (it's BeefImporter's later) and keep calling `wire_ancestor` — but `wire_ancestor` is moving. So for this PR, `Action#hydrate_known_sources!` calls `engine.hydrator.wire_ancestor(...)`. Don't accidentally pull the ingress helpers into Hydrator; only `wire_ancestor` itself moves.
- **Three `build_atomic_beef` call sites**, one of them the signAction-completion path (`:463`) — all repoint.
- **`validate_for_handoff!` self-trust tracker.** Confirm it keeps constructing `TrustedSelfChainTracker` internally (not the engine's real chain_tracker) — that's the egress trust model and must not change.
- **`build_atomic_beef` resolves inputs by `action_id`.** Keep it store-reading (no by-value resolve) — Hydrator holds `store` for `wire_ancestor`'s `find_proof` anyway, so the TxBuilder by-value pattern doesn't apply here.
- **Recursion + cycles.** `wire_ancestor`'s `visited` guard must move intact; isolation specs should cover a cyclic/self-referential proof graph.

## Non-goals (explicit)

- Broadcast EF hydration (`hydrated_transaction_for`) + `HydratedTxCache` (stays in Broadcast).
- `InputSource` (shared standalone module).
- Ingress helpers (BeefImporter extraction).
- No consolidation of the two hydration depths.

## Implementation steps (ordered)

1. `Interface::Hydrator` — contract: `wire_ancestor`, `build_atomic_beef`, `validate_for_handoff!`; store-reading DI; note `wire_ancestor` is the public primitive for ingress.
2. `Engine::Hydrator` — move the three methods; DI `store:`; `validate_for_handoff!` self-news `TrustedSelfChainTracker`. Wire `@hydrator` on `Engine` + `attr_reader`.
3. Repoint Action: the 3 `build_atomic_beef` sites + the `validate_for_handoff!` site → `engine.hydrator`; `Action#hydrate_known_sources!` → `engine.hydrator.wire_ancestor`. Delete the moved methods from Action.
4. Specs + dead-code sweep.

## Specs

- `Hydrator` isolation specs: `wire_ancestor` (proven-terminal returns tx with `merkle_path`; unconfirmed recurses + wires `source_transaction`; missing/short proof returns nil; cycle-guard via `visited`), `build_atomic_beef` (assembles Atomic BEEF, wires subject inputs from resolved sources), `validate_for_handoff!` (passes for a complete graph; raises `EgressBeefInvalidError` for a missing subject / incomplete proof closure).
- Existing engine + integration specs green (behaviour preservation); the internalize trustSelf path (`hydrate_known_sources!` → `hydrator.wire_ancestor`) still green.

## Verify before committing

- Full spec + rubocop, Postgres primary + SQLite augmentation (from `gem/bsv-wallet`).
- Grep `hydrator.rb` for `engine.send(`/`.send(:` — none.
- Confirm `hydrated_transaction_for` + `HydratedTxCache` + `InputSource` untouched, and the ingress helpers still on Action.
