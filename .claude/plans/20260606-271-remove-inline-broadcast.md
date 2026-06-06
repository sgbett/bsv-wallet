# Plan — #271: Remove `Engine#inline_broadcast`

**Branch:** `feat/271-remove-inline-broadcast` off `feat/249-broadcast-network-boundary`
**Related:** #252 (unblocked this), #251 (submit machinery), #270 (categorisation fix — orthogonal)

## Context

With #252 landed, the daemon broadcast path reconstructs a fully-hydrated `Transaction` from `raw_tx` + `Store#resolve_inputs_for_signing` and emits EF on the wire. The inline path's only structural justification — "we have the live Transaction object; the daemon doesn't" — is gone.

`Engine#create_action` lines 258-276 currently route the inline broadcast through a one-off `Engine#inline_broadcast` method, then performs explicit dispatch on the returned hash (`accepted?` / `rejected?`) calling `promote_action_outputs` and `reject_action` as needed. Both of those store calls are *already* performed inside `Engine::Broadcast#submit`'s machinery:

- `Store#record_broadcast_result` promotes outputs atomically when `tx_status` is accepted (per #266's atomic-Phase-4 contract).
- `handle_submit_terminal` calls `reject_action` on terminal 400 responses.
- `handle_submit_backpressure` clears the `broadcast_at` stamp on 503.

The whole `if rejected? / elsif accepted? / handle_proof_from_broadcast` block, plus the `inline_broadcast` method itself, plus `accepted?` / `rejected?` / `handle_proof_from_broadcast` are duplicated machinery that `Engine::Broadcast` already does.

## Goal

Delete the duplicate. Inline broadcast becomes a direct call to `Engine::Broadcast#process(action_id)` — the same entry point the daemon's PULL worker uses.

## The change

### `lib/bsv/wallet/engine.rb`

- **Constructor:** instantiate `@broadcast_worker = Engine::Broadcast.new(store: @store, broadcaster: @broadcaster, callback_token: @callback_token)` when `@broadcaster` is present.
- **`create_action`** (and any sibling that has the same shape — line 316): the entire 19-line block at lines 258-276 collapses to:
  ```ruby
  @broadcast_worker&.process(action_result[:id]) if broadcast == :inline
  ```
- **Delete:**
  - `Engine#inline_broadcast` (1428-1480)
  - `Engine#accepted?` (1378)
  - `Engine#rejected?` (1399)
  - `Engine#handle_proof_from_broadcast` (1482-...) — replaced by an equivalent helper inside `Engine::Broadcast`.

### `lib/bsv/wallet/engine/broadcast.rb`

- `handle_submit_success` gains a call to a new private `#link_proof_if_present(action_id, data)` that mirrors what `Engine#handle_proof_from_broadcast` did: when `data[:merkle_path]` and `data[:block_height]` are present, build a normalised merkle path, call `save_proof` + `link_proof`. Both inline and daemon callers now eagerly link proofs when ARC happens to return them with the 202.
- No change to `#process`'s signature or behaviour.

### Specs

- **`spec/bsv/wallet/engine_spec.rb`** — remove the three `inline_broadcast` specs (lines 249, 306, 353). Their coverage migrates to `broadcast_spec.rb` (success, 503, terminal-rejection branches are already covered there; just confirm the proof-linking case has a home).
- **`spec/bsv/wallet/engine/broadcast_spec.rb`** — add one spec: when `data[:merkle_path]` is present on a successful response, `save_proof` + `link_proof` are called. (Covers both inline and daemon — same code path.)
- **`spec/integration/walletd_broadcaster_provider_spec.rb:131`** — switch from `engine.send(:inline_broadcast, action_id:, tx:)` to `engine.broadcast_worker.process(action_id)` (or an equivalent public seam).

### Live verification

`bin/create_action alice --inline --description "271 sanity"` produces the same on-chain outcome as before:
- Action created with `broadcast_intent: 'inline'`.
- Broadcasts row written by `Engine::Broadcast#submit`.
- Walletd's SSE listener resolves to MINED on the same wallet.

## What changes behaviourally

- **Event emission on inline path.** `process` emits `task.dispatched` / `task.succeeded` / `task.failed` / `task.aborted`. The current `inline_broadcast` emits nothing. After the swap, inline broadcasts also emit these — strict telemetry improvement.
- **Daemon path now eagerly links proofs.** Previously only the inline path called `handle_proof_from_broadcast`; the daemon dropped the proof material from ARC's 202 and waited for `Engine::TxProof`'s proof_acquisition cycle. After the move, both paths link the proof immediately when it arrives. Faster, simpler.
- **Categorisation gap (#270) is unified.** Pre-#271 the inline path inspected `response.data['txStatus']` directly. Post-#271 both paths flow through `terminal_failure?` and feel the same gap. #270 fixes both at once.

## What stays unchanged

- Wire format (EF either way).
- `Store#sign_action` / broadcasts-row creation contract.
- SSE applicator / Layer 2 code paths.
- `Engine::Broadcast`'s constructor signature (additive only).

## Implementation order

1. Add `#link_proof_if_present` helper inside `Engine::Broadcast` and wire it into `handle_submit_success`.
2. Add the broadcast_spec coverage for the proof-linking case.
3. Add `@broadcast_worker` to `Engine`'s constructor.
4. Collapse the inline block in `create_action` (and any sibling) to the single `process` call.
5. Delete `inline_broadcast`, `accepted?`, `rejected?`, `handle_proof_from_broadcast` from `Engine`.
6. Delete the three engine_spec inline_broadcast specs.
7. Update `walletd_broadcaster_provider_spec.rb`.
8. Run full unit suite + integration suite + rubocop.
9. Live verify against alice.
10. Single commit: `refactor(engine): collapse inline_broadcast into Engine::Broadcast#process (#271)`.

## Risks

- **Test fixture rehydration.** Inline-path specs that previously passed an in-memory `Transaction` will now go through `submit`'s `hydrated_transaction_for` which calls `Store#resolve_inputs_for_signing`. The fixture pattern from broadcast_spec applies — parseable raw_tx + stub returning matching source data. Small per-spec edit at most.
- **`@broadcast_worker` is nil-safe via `&.`** — engines constructed without a broadcaster (e.g. some unit specs) stay green; `if broadcast == :inline` with `@broadcast_worker == nil` silently skips, matching today's `'inline_broadcast called without broadcaster'` raise semantics if we make the same guard explicit. Decision in flight: silent skip vs raise; flag in commit.

## Out of scope

- `Store#sign_action` or broadcasts-row creation contract.
- Wire format (still EF either way).
- SSE applicator / Layer 2.
- Categorisation gap (#270 — orthogonal).
