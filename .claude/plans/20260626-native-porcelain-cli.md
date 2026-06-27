# Native Porcelain CLI — bin/wallet dispatcher

**HLR:** #433
**Sibling:** #431 (BRC-100 CLI — `bin/brc100`)

## Context

Existing porcelain (`bin/send`, `bin/balance`, `bin/import`, `bin/receive`, etc.) routes through `BSV::Wallet::BRC100`, importing the spec's quirks (change-pool ambiguity, basket-required semantics, originator noise) into use cases that don't need conformance. #431 is settling the BRC-100 surface under `bin/brc100`. This HLR is the sibling: a native wallet-vocab surface that calls Engine methods directly, designs its own basket/change semantics, and stays shell-pipeable.

Outcome: a single `bin/wallet <command>` dispatcher replacing the 10+ standalone porcelain scripts, with a cleaner config story (one place for `--wallet`, `--database-url`, `--wif`) and a Git-style porcelain/plumbing split.

## Scope

**Porcelain (6):** `balance`, `list`, `send`, `receive`, `import`, `reject`
**Plumbing (4):** `build`, `sign`, `broadcast`, `transmit`
**Operational (2):** `sweep`, `consolidate`

**Out of scope (follow-up issues):**
- Lock / select_utxos commands (deferred — engine has no native lock API yet).
- Recipient registry / phone-book resolution (`send <name>` → URI). For v1, `send` takes `<address> <sats>` (old-school BSV positional) and `transmit` requires explicit `--target=<uri>`.
- BRC-100 plumbing bins (`create_action`, `list_outputs`, `internalize`) — replaced by `bin/brc100` under #431.

## Dispatcher Design

Single binary `bin/wallet`. Grammar:

```
bin/wallet [global-flags] <command> [command-args]
```

**Global flags** (parsed by the dispatcher, before subcommand):

| Flag | Purpose |
|------|---------|
| `--wallet=<name>` | Resolve via `Fixtures` registry |
| `--wif=<wif>` | Explicit WIF override |
| `--database-url=<url>` | Explicit DB override |
| `--env=<file>` | Load env file (dotenv-style; existing process env wins) |
| `--network=mainnet\|testnet` | Network override |
| `--json` | Force JSON output even on TTY |
| `--help`, `-h` | Help |

**Precedence (highest → lowest):**
1. `--wif` / `--database-url` (explicit per-field flags on the CLI)
2. `--wallet=<name>` (resolves through `Fixtures` registry; Fixtures itself reads process ENV)
3. Process ENV (`BSV_WALLET_POSTGRES`, `BSV_WALLET_WIF_<NAME>`, `DATABASE_URL` — includes both shell-exported vars and inline `WIF=... bin/wallet ...` invocations; the CLI can't distinguish them)

`--env=<file>` is **not a precedence tier** — it's a seed mechanism. Loaded BEFORE process ENV is read, populating only the keys that are currently unset (dotenv-style). The values it seeds then participate in process ENV at tier 3.

**Subcommand router** dispatches to a `BSV::Wallet::CLI::Commands::<Command>` class. Each command class owns its own `OptionParser` for command-specific flags, calls Engine methods, prints JSON to stdout / human-readable to stderr.

## Per-Command Sketch

**Porcelain:**

| Command | Args | Engine call | Notes |
|---------|------|-------------|-------|
| `balance` | `[--basket NAME] [--outputs]` | `engine.spendable_outputs(aggregate: :sum)` or full `spendable_outputs` if `--outputs` | `--outputs` is shorthand for `list outputs` (always-spendable; the underlying `engine.spendable_outputs` has no non-spendable mode). |
| `list <noun>` | `outputs\|actions [filters]` | `engine.spendable_outputs` / `engine.list_actions` | Power-user query, noun-based. **Note:** `engine.list_actions(labels:)` is label-required (no unfiltered primitive). `list actions` requires at least one `--label=<name>` flag; an unfiltered listing primitive is a follow-up engine addition (out of scope here). |
| `send <address> <sats>` | `[--broadcast=inline\|async] [--transmit=inline --target=<uri>] [--description=<text>]` | `engine.build_action(description:, accept_delayed_broadcast:, ...)` | Default: `--broadcast=inline --transmit=none`. `--description` defaults to `'cli-send'` if omitted (engine requires non-nil). Broadcast mapping (CLI must pass explicitly — engine's default `accept_delayed_broadcast: true` would otherwise force `:delayed`): `--broadcast=inline` → `accept_delayed_broadcast: false` (intent `:inline`, sync ARC dispatch); `--broadcast=async` → `accept_delayed_broadcast: true` (intent `:delayed`, daemon picks up). Failure → non-zero exit, action stays in valid pending state. |
| `receive` | `[--file=<path>] [--basket=<name>] [--description=<text>]` | `engine.import_beef(tx:, outputs:, description:, ...)` | Reads BEEF bytes from `--file=<path>` if given, otherwise stdin. CLI-side parsing at the boundary: (1) parse BEEF → extract the subject `tx` (raw bytes) and the output specs (`outputs` array with `output_index`, `protocol`, `insertion_remittance: { basket:, derivation_prefix:, derivation_suffix:, sender_identity_key: }`); (2) apply `--basket=<name>` by setting each output's basket field (default `nil` = unbasketed); (3) `--description` REQUIRED by engine, CLI defaults to `'cli-receive'` if omitted. Then calls `engine.import_beef(tx:, outputs:, description:, ...)`. |
| `import` | `[--basket=<name>] [--no-send]` | `engine.import_wallet(basket:, no_send:, ...)` | Scanning form (root → spendable self-send). `--basket=<name>` routes imported outputs into named basket (parity with current `bin/import_root_utxo` HLR #436 semantics). **Engine surface gap:** `import_wallet` does not currently accept `basket:` — it iterates `import_utxo(dtxid:, vout:, no_send:, accept_delayed_broadcast:)` without forwarding a basket. Phase 5 adds `basket:` to `import_wallet` and forwards it to `import_utxo(basket:)` (which already accepts the kwarg). Pinpoint `import_utxo` dropped from CLI; engine method survives. |
| `reject <reference>` | — | `engine.reject_action(action_id:)` | Abandon pending action. CLI command resolves `reference` → `action_id` via `Engine::Action.find(engine:, reference:)` before the engine call (no engine surface change needed). Engine method signature stays as-is. |

**Plumbing:**

| Command | Args | Engine call | Notes |
|---------|------|-------------|-------|
| `build` | `--to=<addr>:<sats> [--to=...] --description=<text>` | `engine.build_action(description:, sign_and_process: false, ...)` | Parks an unsigned action via deferred signing. `--description` REQUIRED (engine contract). Note: `no_send: true` + `sign_and_process: false` is explicitly rejected by the engine (`#192`). Engine returns `{ signable: { atomic_beef:, reference: } }`; CLI flattens at the boundary to `{ "reference": "<ref>", "atomic_beef": "<hex>" }` (the `signable:` wrapper is engine-internal disambiguation, redundant at the CLI). |
| `sign <reference>` | `[--spends=<json>]` | `engine.sign_action(reference:, spends:)` | Completes deferred-signing flow |
| `broadcast <reference>` | `[--inline\|--async]` | `engine.broadcast_action(reference:, intent:)` | Engine has no public `broadcast(raw_tx)` — broadcast is by action only. CLI vocab maps to engine vocab: `--inline` → `intent: :inline` (sync ARC dispatch), `--async` → `intent: :delayed` (daemon picks up via OMQ). `--async` is CLI sugar for the engine's existing `:delayed` term. Phase 2 exposes `engine.broadcast_action(reference:, intent: :inline)` which: (1) looks up action by reference, (2) rehydrates `atomic_beef` from the parked `raw_tx` via `@hydrator.build_atomic_beef`, (3) calls internal `dispatch_broadcast(action_id, atomic_beef, intent:)` at `engine.rb:1296`. Lookup + rehydration live in the engine because `@hydrator` is engine-internal; the CLI never touches it. |
| `transmit` | `--reference=<ref> --target=<uri> [--counterparty=<key>]` | `engine.transmit_action(reference:, target:, counterparty: nil)` | Delivers BEEF to peer endpoint. **Engine surface gap:** Engine currently sets `@transmission = Transmission.new(...)` with no public accessor; `Transmission#transmit` requires `counterparty:`, `action_id:`, `outputs:`, `sender_identity_key:`, `endpoint:` — far more than `reference + target`. Phase 3 adds `engine.transmit_action(reference:, target:, counterparty: nil)` wrapper which: (1) looks up action by reference, (2) gathers `outputs` from the action's stored outputs, (3) reads `sender_identity_key` from the wallet's `key_deriver.identity_key`, (4) defaults `counterparty` to the action's stored counterparty when `--counterparty` omitted, (5) calls `@transmission.transmit(counterparty:, action_id:, outputs:, sender_identity_key:, endpoint: target)`. CLI stays a thin wrapper. |

**Operational:**

| Command | Args | Engine call | Notes |
|---------|------|-------------|-------|
| `sweep` | `--to=<root_key_hex> [--no-send]` | `engine.sweep(recipient:, no_send:)` | Spendable → root-key P2PKH; blank-slate tool |
| `consolidate` | `[--target-inputs=<n>] [--no-send]` | `engine.consolidate_step(target_inputs:, no_send:)` | Stays in spendable set; reduces UTXO count. `--no-send` forwards to engine's `no_send:` (default `false`, broadcasts inline). |

## CLI Module Additions

File: `gem/bsv-wallet/lib/bsv/wallet/cli.rb` (existing; extend, don't replace).

Add:
- `CLI::Dispatcher` — argv router. Parses global flags, splits at subcommand boundary, instantiates the command class.
- `CLI::GlobalOptions` — struct/dataclass passed to commands (wallet name, network, json flag, env-file path, explicit wif/db).
- `CLI::parse_global_options(argv)` — NEW helper that parses `--wallet=<name>` and other global flags, returning `[GlobalOptions, remaining_argv]`. Distinct from `extract_wallet_name` (which stays as-is for `bin/walletd` and other positional callers).
- `CLI::Commands::Base` — small abstract: defines `call(ctx, args)`, owns OptionParser banner, output helpers.
- `CLI::Commands::<Verb>` — one class per command (12 classes).

Extend or keep:
- `CLI.boot` — signature extended to `CLI.boot(wallet_name:, network:, wif_override: nil, database_url_override: nil)`. Current signature only reads WIF/DB URL from `BSV::Wallet.config` / `Fixtures`; the new overrides let the dispatcher pass `--wif` / `--database-url` flag values through without mutating ENV. Backward-compatible for `bin/walletd` and other callers that don't pass the new kwargs.
- `CLI.extract_wallet_name` — UNCHANGED (parses positional first-arg wallet name). Used by `bin/walletd` and other surviving scripts; repurposing would break them. The dispatcher uses `parse_global_options` instead.
- `CLI::Output.write_json`, `write_binary` — unchanged.

Engine surface additions (across phases):

- **Phase 2** — `engine.broadcast_action(reference:, intent: :inline)`. NOT a thin wrapper — looks up the action by reference, rehydrates `atomic_beef` from the parked `raw_tx` via `@hydrator.build_atomic_beef(raw_tx, action_id)`, then calls the existing internal `dispatch_broadcast(action_id, atomic_beef, intent:)` at `engine.rb:1296`. The broadcast plumbing CLI verb (Phase 3) becomes a thin wrapper over this.
- **Phase 3** — `engine.transmit_action(reference:, target:, counterparty: nil)`. Wraps `@transmission.transmit(...)` — looks up action by reference, gathers `outputs` from action's stored outputs, reads `sender_identity_key` from `key_deriver.identity_key`, defaults `counterparty` to action's stored counterparty when omitted, calls `Transmission#transmit(counterparty:, action_id:, outputs:, sender_identity_key:, endpoint: target)`. Without this wrapper, the CLI would need direct access to `@transmission` (no public reader) and would carry parameter-gathering logic (violates "no business logic in CLI" hygiene).
- **Phase 5** — `basket:` kwarg added to `engine.import_wallet`, forwarded to `import_utxo(basket:)` (which already accepts it). Without this, `wallet import --basket=<name>` is unimplementable.

## Deletions

**bin/ scripts to delete** (CLI-spec coverage dies with them):
```
bin/balance, bin/create, bin/create_action, bin/derive, bin/import,
bin/import_root_utxo, bin/internalize, bin/list_outputs, bin/lock,
bin/receive, bin/reject, bin/select_utxos, bin/send, bin/sweep,
bin/transmit, bin/consolidate
```

**bin/ scripts to keep:**
- `bin/walletd` (daemon — orthogonal subsystem, inlines its own boot, unaffected)
- `bin/brc100` (will land via #431 — out of scope here, mentioned for symmetry)

**CLI-coupled specs to delete** (per replace-not-adapt; git history is the reference):
- All `spec/bin/*_spec.rb` (CLI-level coverage of the deleted bins).
- `spec/e2e/broadcast_spec.rb`, `spec/e2e/e2e_workload_spec.rb` (CLI-driven workloads on the old bins).
- `spec/support/e2e/daemon_supervisor.rb`, `event_log.rb`, `sse_test_listener.rb` (broadcast_spec.rb-coupled).

**Specs to PAUSE as shape reference** (not kept green during rebuild):
- `spec/e2e/transmit_spec.rb` — clean shape (setup → act → assert on-chain economic outcome); the rubocop-disable cluster around `ScatteredSetup`/`ScatteredLet` gets cleaned in the rewrite.
- `spec/support/e2e/wallet_actor.rb` — rewritten against `bin/wallet` subcommands once the dispatcher lands.
- `spec/support/e2e/wallet_harness.rb`, `wallet_derivation.rb`, `e2e/spec_helper.rb` — survive (CLI-independent infrastructure).

**Untouched:** engine/store/integration specs that exercise the engine directly (not via bin/). The rebuild swaps the CLI surface, not the engine surface.

## Specs (New)

Two layers:

1. **Per-command unit specs** at `spec/bin/wallet/<command>_spec.rb` — drive `CLI::Commands::<Verb>` directly with a stubbed engine, assert argv parsing, output shape, error exit codes. Fast, no DB, no network.
2. **End-to-end shape spec** — rewritten `spec/e2e/transmit_spec.rb` (clean version) drives the dispatcher via subprocess. Replaces wallet_actor.rb's shellouts.

Don't carry e2e/integration coverage of the rebuild in flight — it slows iteration and tests the moving target. Reinstate after the dispatcher lands.

## Phasing (PR cadence)

Each phase is one PR. Order matters — earlier phases unblock later ones.

1. **Phase 1 — Dispatcher scaffolding + balance + list.** `bin/wallet` exists, global flag parsing works, `balance` and `list outputs/actions` route through it. Old `bin/balance`, `bin/list_outputs` deleted in same PR. Smallest viable demo of the surface.
2. **Phase 2 — Engine broadcast surface.** Expose `engine.broadcast_action(reference:, intent: :inline)` as public. Includes action lookup by reference + `atomic_beef` rehydration via `@hydrator.build_atomic_beef` before delegating to internal `dispatch_broadcast`. Small, isolated PR — not a pure wrapper.
3. **Phase 3 — Plumbing: build, sign, broadcast, transmit.** Adds the four elementary verbs. Includes engine surface addition: `engine.transmit_action(reference:, target:, counterparty: nil)` wrapper (lookup + parameter gathering for `Transmission#transmit`). No porcelain yet.
4. **Phase 4 — Porcelain: send, receive.** Built on Phase 3 plumbing. send is the macro, receive consumes BEEF.
5. **Phase 5 — Porcelain: import, reject + operational: sweep, consolidate.** Remaining commands. Includes engine surface addition: `basket:` kwarg added to `engine.import_wallet` and forwarded to `import_utxo(basket:)`. Old bins deleted.
6. **Phase 6 — Spec rewrite.** New `spec/bin/wallet/*` unit specs land. transmit_spec.rb rewritten against new bin/wallet. wallet_actor.rb rebuilt.

Phases 1–2 are independent and can land in either order. Phases 3–5 build on 2.

## Verification

End-to-end test of each phase against a funded test wallet (`alice` fixture):

```bash
cd gem/bsv-wallet
# Phase 1
bin/wallet --wallet=alice balance
bin/wallet --wallet=alice list outputs --limit=5
bin/wallet --wallet=alice list actions --label=cli-test --limit=5  # --label required (no unfiltered primitive)

# Phase 3
REF=$(bin/wallet --wallet=alice build --to=<addr>:1000 --description="test" --json | jq -r .reference)
bin/wallet --wallet=alice sign $REF --spends='{...}'
bin/wallet --wallet=alice broadcast $REF

# Phase 4
bin/wallet --wallet=alice send <addr> 1000
bin/wallet --wallet=bob receive --file=envelope.beef

# Phase 5
bin/wallet --wallet=alice import
bin/wallet --wallet=alice sweep --to=<root_key>
bin/wallet --wallet=alice consolidate --target-inputs=10
```

Unit specs run fast: `cd gem/bsv-wallet && bundle exec rspec spec/bin/wallet/`.
Integration: `bundle exec rspec spec/e2e/transmit_spec.rb` (after Phase 6).

## Decisions (resolved during planning)

1. **PR cadence — six phases.** Each phase is small enough to review thoroughly; merge overhead is the acceptable cost. Phases 1–2 can land in either order; 3–5 build on 2; 6 closes out the spec rewrite.
2. **Engine broadcast surface — `engine.broadcast_action(reference:, intent: :inline)`.** NOT a thin wrapper: performs action lookup by reference + `atomic_beef` rehydration via `@hydrator.build_atomic_beef`, then delegates to internal `dispatch_broadcast(action_id, atomic_beef, intent:)` at `engine.rb:1296`. `intent:` accepts `:inline` (default, sync ARC dispatch) or `:delayed` (enqueue for daemon) — matches the engine's existing `map_broadcast_intent` vocabulary. CLI surfaces `--async` as sugar for `:delayed`. The lookup/rehydration live engine-side because `@hydrator` is engine-internal; `reject` and `transmit` keep their lookup CLI-side (no hydrator needed).
3. **`reject` semantics — hard fail on non-rejectable state.** Aligns with the no-invalid-state invariant: pending actions are rejectable, broadcast actions are not. Failure mode is structured stderr + non-zero exit; the action stays in its current valid state.

## Follow-up Issues (to create)

- Lock + select_utxos commands (deferred — needs engine lock API design).
- Recipient registry / address book (deferred — wait until transmit infrastructure settles, BEEF Party lands).
- `bin/import_utxo` pinpoint form (drop from CLI, keep engine method; revisit if a need arises).

## Out of Scope (deliberate)

- BRC-100 HTTP/JSON-RPC transport (#223 — separate workstream).
- `bin/brc100` CLI surface (#431 — sibling HLR, parallel work).
- ABI/streaming transports (#180 future).
- `noSend` / `sendWith` reservation flow (#192).
