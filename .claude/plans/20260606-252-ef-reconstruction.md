# Plan — #252: EF reconstruction for the daemon broadcast path

**HLR:** sgbett/bsv-wallet#252
**Branch:** feat/251-sse-push-resolution (folded into #251 since it blocks SSE rejection accounting end-to-end)
**Related:** #251 (SSE push resolution), #269 (in-memory EF cache follow-up)

## Context

The daemon broadcast path (`Engine::Broadcast#submit`) currently ships the raw transaction bytes stored on `actions.raw_tx`. Arcade rejects raw submissions with `"'PreviousTx' not supplied"` because it can't validate inputs without the source `locking_script` + `satoshis` per input. The inline path (`Engine#inline_broadcast`) doesn't hit this — it passes the in-memory `Transaction` object with `source_satoshis` + `source_locking_script` wired on each input; the SDK's Arcade protocol calls `tx.to_ef_hex` to produce EF on the wire.

This was a known deferral when daemon-side broadcasting was first wired up: the assumption was that Arcade would ship a raw-submit endpoint that would fetch ancestry server-side, removing the need for EF reconstruction. That endpoint hasn't materialized, so every queued broadcast currently bounces.

## Current state

- `Engine::Broadcast#submit` (lib/bsv/wallet/engine/broadcast.rb:204):
  ```ruby
  response = @broadcaster.broadcast(action[:raw_tx], **broadcast_kwargs)
  ```
  Ships raw bytes — rejected by Arcade.

- `Engine#inline_broadcast` (lib/bsv/wallet/engine.rb:1437):
  ```ruby
  response = @broadcaster.broadcast(tx, **broadcast_kwargs)
  ```
  Ships a `Transaction` object — SDK's `arcade.rb` resolves to EF via `tx.to_ef_hex`.

- `Store#resolve_inputs_for_signing(action_id:)` (lib/bsv/wallet/store.rb:535) already returns the per-input source data we need, ordered by `inputs.vin`:
  ```ruby
  { vin:, sequence:, source_wtxid:, source_vout:,
    source_satoshis:, source_locking_script:, derivation_*, sender_identity_key: }
  ```
  The inline path uses it via `Engine#build_inputs` (engine.rb:2048) when constructing a fresh Transaction. The daemon path can reuse it to hydrate a Transaction parsed from `raw_tx`.

- `inputs` table has `vin` (integer, unique with `action_id`) — explicit ordering column. No migration needed.

## Approach

Reconstruct the `Transaction` at submit time. Parse `action[:raw_tx]` → `BSV::Transaction::Transaction`, walk `tx.inputs`, assign `source_satoshis` + `source_locking_script` from `Store#resolve_inputs_for_signing` in `vin` order, hand the Transaction to `@broadcaster.broadcast`.

This satisfies the HLR's "single shared code path produces EF" criterion: both inline and daemon now pass a `Transaction` to `Broadcaster#broadcast`; EF serialization happens once, in the SDK's `arcade.rb` `call_broadcast` via `tx.to_ef_hex`.

## Changes

### `lib/bsv/wallet/engine/input_source.rb` (new)

Single point of truth for wiring source-output data onto a `TransactionInput`. Used by both `Engine#build_inputs` (inline construction path) and `Engine::Broadcast#hydrated_transaction_for` (daemon path) so the "attach source data" step is provably identical across paths — satisfies the HLR's "no parallel implementations" criterion at the only place the two paths could meaningfully drift.

```ruby
module BSV
  module Wallet
    class Engine
      module InputSource
        module_function

        # Attach source-output data to a TransactionInput so the SDK can
        # serialize Extended Format. Source rows come from
        # +Store#resolve_inputs_for_signing+; both the inline (build-then-sign)
        # and daemon (parse-then-broadcast) paths converge here.
        def attach!(input, source)
          input.source_satoshis = source[:source_satoshis]
          input.source_locking_script = BSV::Script::Script.from_binary(source[:source_locking_script])
        end
      end
    end
  end
end
```

### `lib/bsv/wallet/engine.rb`

In `Engine#build_inputs` (engine.rb:2048), replace the two inline assignments:

```ruby
# before
input.source_satoshis = resolved[:source_satoshis]
locking_script = resolve_source_locking_script(resolved[:source_locking_script])
input.source_locking_script = locking_script

# after
InputSource.attach!(input, resolved)
locking_script = input.source_locking_script   # still needed for the p2pkh? branch below
```

`resolve_source_locking_script` becomes a thin wrapper if still used elsewhere; otherwise inline its `from_binary` call into `InputSource.attach!`. Either way, the assignment shape used by both paths is now single-sourced.

### `lib/bsv/wallet/engine/broadcast.rb`

Add private `#hydrated_transaction_for(action)` returning a fully-hydrated `Transaction`:

```ruby
def hydrated_transaction_for(action)
  tx = BSV::Transaction::Transaction.from_binary(action[:raw_tx])
  sources = @store.resolve_inputs_for_signing(action_id: action[:id])
  if tx.inputs.length != sources.length
    raise BSV::Wallet::Error,
          "input count mismatch action_id=#{action[:id]} " \
          "tx=#{tx.inputs.length} db=#{sources.length}"
  end

  tx.inputs.each_with_index { |input, idx| InputSource.attach!(input, sources[idx]) }
  tx
end
```

In `#submit`, replace the bare `action[:raw_tx]` argument:

```ruby
tx = hydrated_transaction_for(action)
response = @broadcaster.broadcast(tx, **broadcast_kwargs)
```

`broadcast_kwargs[:wtxid]` stays sourced from `action[:wtxid]` — it's the same value as `tx.wtxid` but avoids the recompute and matches the inline path's pre-broadcast validation.

### No store changes

`Store#resolve_inputs_for_signing` already returns the needed shape. Reusing it (rather than introducing a leaner `input_source_data` variant) keeps the data-fetch single-sourced. The slight name mismatch ("for signing" used in a non-signing context) is acceptable; if it becomes confusing, rename in a follow-up.

### No schema changes

`inputs.vin` already orders inputs. `outputs.satoshis` + `outputs.locking_script` already carry source data.

## Tests

### Unit (`spec/bsv/wallet/engine/input_source_spec.rb`, new)

- `InputSource.attach!` sets `source_satoshis` from the source hash.
- `InputSource.attach!` sets `source_locking_script` to a `BSV::Script::Script` parsed from the binary bytes.

### Unit (`spec/bsv/wallet/engine/broadcast_spec.rb`)

- `#submit` passes a `Transaction` object (not raw bytes) to the broadcaster — assert via a broadcaster double whose `broadcast` receives `kind_of(BSV::Transaction::Transaction)`.
- The Transaction's inputs carry `source_satoshis` + `source_locking_script` for each input.
- Input-count-mismatch scenario raises (defensive guard; should not fire in practice since `inputs.vin` matches `raw_tx`'s input order, but worth a regression spec).

### Unit (`spec/bsv/wallet/engine_spec.rb`)

- Existing `build_inputs` specs continue to pass after the `InputSource.attach!` refactor — no behavioral change to the inline path.

### Integration (Postgres, real Store)

- Seed an action with inputs whose source outputs exist in `outputs`. Call `submit`. Assert the broadcaster received a Transaction with the expected source data wired.
- Verify against an Arcade fake (or a contract test) that the wire payload is EF, not raw-tx.

### E2E (`spec/e2e/`)

- Queue a `:delayed` broadcast in a wallet whose inputs trace to its own outputs (e.g. alice's case from the live session). Run walletd. Assert the broadcast advances past Arcade's validation (no `'PreviousTx' not supplied`).
- The existing inline-path e2e specs must remain green — no behavioral regression there.

## Verification

1. Unit + integration specs pass on Postgres and SQLite.
2. Live: re-queue a 100k send on alice (the case that just failed against 0.22.0 and 0.23.1), run walletd, observe successful broadcast (RECEIVED via 202, then MINED via SSE).
3. RuboCop clean.

## Out of scope (explicit)

- **In-memory EF cache** (#269) — fallthrough to reconstruction is canonical; cache lights up later when a long-running process produces and consumes in the same address space.
- **Foreign inputs** — inputs spending outputs not in our `outputs` table. The HLR mentions chain-tracker fetch as the future approach. For #252, we assume every input traces to one of our own outputs (the current wallet's only scenario). A foreign input would surface as a `Store#resolve_inputs_for_signing` row with `nil` source data → input-count-mismatch raise (loud, not silent).
- **Persisted EF column on `actions`** — second option in the HLR; rejected on DRY grounds (source data already in `outputs`) and dead-weight grounds (EF unused post-mine).
- **Categorization fix for Arcade's broadcast-rejection shape** (`{error, reason}` vs `{txStatus, extraInfo}`) — a separate, smaller bug surfaced in the same session. Track and fix as its own ticket; reconstruction here just makes the synchronous path stop failing in the first place.

## Implementation order

1. Add `#hydrated_transaction_for` + update `#submit` in `engine/broadcast.rb`.
2. Update existing `broadcast_spec.rb` assertions for `submit` (the existing specs expect the raw-bytes call; update them to expect `Transaction`).
3. Add unit spec covering the hydration logic specifically.
4. Run unit suite — green.
5. E2E: queue a delayed broadcast for alice, run walletd, observe acceptance. Update or add an e2e spec.
6. Run full unit + e2e suites — green.
7. RuboCop clean.
8. Commit per CLAUDE.md style (`fix(daemon):` or `feat(broadcast):` — pick once the change shape is firm).
