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
1. `--wif` / `--database-url` (explicit per-field)
2. `--wallet=<name>` (resolves through `Fixtures`)
3. Inline ENV (`WIF=... bin/wallet ...`)
4. `--env=<file>` (loads only what's unset)
5. Shell ENV (`BSV_WALLET_POSTGRES`, `BSV_WALLET_WIF_<NAME>`, `DATABASE_URL`)

**Subcommand router** dispatches to a `BSV::Wallet::CLI::Commands::<Command>` class. Each command class owns its own `OptionParser` for command-specific flags, calls Engine methods, prints JSON to stdout / human-readable to stderr.

## Per-Command Sketch

**Porcelain:**

| Command | Args | Engine call | Notes |
|---------|------|-------------|-------|
| `balance` | `[--basket NAME] [--outputs]` | `engine.spendable_outputs(aggregate: :sum)` or full `spendable_outputs` if `--outputs` | `--outputs` is shortcut for `list outputs --spendable` |
| `list <noun>` | `outputs\|actions [filters]` | `engine.spendable_outputs` / `engine.list_actions` | Power-user query, noun-based |
| `send <address> <sats>` | `[--broadcast=inline\|async] [--transmit=inline --target=<uri>] [--dry-run]` | `engine.build_action(...)` with appropriate `no_send` / `accept_delayed_broadcast` | Default: `--broadcast=inline --transmit=none`. Failure → non-zero exit, action stays in valid pending state. |
| `receive` | `[--file=<path>\|stdin] [--basket=<name>] [--description=<text>]` | `engine.import_beef(...)` | Reads BEEF from stdin or file. `--basket=<name>` routes received outputs into named basket (current `bin/receive` defaults to `'received'`; new dispatcher uses `nil` default = unbasketed pool, explicit `--basket` opts in). |
| `import` | `[--basket=<name>] [--no-send]` | `engine.import_wallet(...)` | Scanning form (root → spendable self-send). `--basket=<name>` routes imported outputs into named basket (parity with current `bin/import_root_utxo` HLR #436 semantics). Pinpoint `import_utxo` dropped from CLI; engine method survives. |
| `reject <action_id>` | — | `engine.reject_action(action_id:)` | Abandon pending action |

**Plumbing:**

| Command | Args | Engine call | Notes |
|---------|------|-------------|-------|
| `build` | `--to=<addr>:<sats> [--to=...] [--description=<text>]` | `engine.build_action(no_send: true, sign_and_process: false)` | Parks an unsigned action, prints `action_id` + atomic BEEF |
| `sign <action_id>` | `[--spends=<json>]` | `engine.sign_action(reference:, spends:)` | Completes deferred-signing flow |
| `broadcast <action_id>` | `[--inline\|--async]` | `engine.broadcast_action(action_id:, intent:)` | Engine has no public `broadcast(raw_tx)` — broadcast is by action_id only. Phase 2 exposes `engine.broadcast_action(action_id:, intent: :inline)` (wraps internal `dispatch_broadcast` at `engine.rb:1296`). |
| `transmit` | `--action-id=<id> --target=<uri> [--counterparty=<key>]` | `engine.transmission.transmit(...)` | Delivers BEEF to peer endpoint |

**Operational:**

| Command | Args | Engine call | Notes |
|---------|------|-------------|-------|
| `sweep` | `--to=<root_key_hex> [--no-send]` | `engine.sweep(recipient:, no_send:)` | Spendable → root-key P2PKH; blank-slate tool |
| `consolidate` | `[--target-inputs=<n>] [--no-send]` | `engine.consolidate_step(target_inputs:)` | Stays in spendable set; reduces UTXO count |

## CLI Module Additions

File: `gem/bsv-wallet/lib/bsv/wallet/cli.rb` (existing; extend, don't replace).

Add:
- `CLI::Dispatcher` — argv router. Parses global flags, splits at subcommand boundary, instantiates the command class.
- `CLI::GlobalOptions` — struct/dataclass passed to commands (wallet name, network, json flag, env-file path, explicit wif/db).
- `CLI::Commands::Base` — small abstract: defines `call(ctx, args)`, owns OptionParser banner, output helpers.
- `CLI::Commands::<Verb>` — one class per command (12 classes).

Keep unchanged:
- `CLI.boot(wallet_name:, network:)` — wraps store/migrate/engine assembly. Dispatcher calls it once after global-flag parse.
- `CLI.extract_wallet_name` — repurposed for `--wallet=<name>` global flag parsing.
- `CLI::Output.write_json`, `write_binary` — unchanged.

One small engine tweak:
- Expose `engine.broadcast_action(action_id:, intent: :inline)` as public (wraps current internal `dispatch_broadcast` at `engine.rb:1296`). Needed by `bin/wallet broadcast <action_id>`. Phase 2 lands this in isolation.

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
2. **Phase 2 — Engine broadcast surface tweak.** Expose `engine.broadcast_action(action_id:, intent: :inline)` as public. Tiny PR, isolated.
3. **Phase 3 — Plumbing: build, sign, broadcast, transmit.** Adds the four elementary verbs. No porcelain yet.
4. **Phase 4 — Porcelain: send, receive.** Built on Phase 3 plumbing. send is the macro, receive consumes BEEF.
5. **Phase 5 — Porcelain: import, reject + operational: sweep, consolidate.** Remaining commands. Old bins deleted.
6. **Phase 6 — Spec rewrite.** New `spec/bin/wallet/*` unit specs land. transmit_spec.rb rewritten against new bin/wallet. wallet_actor.rb rebuilt.

Phases 1–2 are independent and can land in either order. Phases 3–5 build on 2.

## Verification

End-to-end test of each phase against a funded test wallet (`alice` fixture):

```bash
cd gem/bsv-wallet
# Phase 1
bin/wallet --wallet=alice balance
bin/wallet --wallet=alice list outputs --limit=5

# Phase 3
ACTION=$(bin/wallet --wallet=alice build --to=<addr>:1000 --description="test")
bin/wallet --wallet=alice sign $ACTION
bin/wallet --wallet=alice broadcast $ACTION

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
2. **Engine broadcast surface — `engine.broadcast_action(action_id:, intent: :inline)`.** Wraps the current internal `dispatch_broadcast` at `engine.rb:1296`. `intent:` accepts `:inline` (default) or `:async` (enqueue for daemon).
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
