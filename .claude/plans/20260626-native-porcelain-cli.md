# Native Porcelain CLI — bin/wallet dispatcher

**HLR:** #433
**Sibling:** #431 (BRC-100 CLI — `bin/brc100`)

## Context

Existing porcelain (`bin/send`, `bin/balance`, `bin/import`, `bin/receive`, etc.) routes through `BSV::Wallet::BRC100`, importing the spec's quirks (change-pool ambiguity, basket-required semantics, originator noise) into use cases that don't need conformance. #431 is settling the BRC-100 surface under `bin/brc100`. This HLR is the sibling: a native wallet-vocab surface that calls Engine methods directly, designs its own basket/change semantics, and stays shell-pipeable.

Outcome: a single `bin/wallet <command>` dispatcher replacing the 10+ standalone porcelain scripts, with a cleaner config story (one place for `--wallet`, `--database-url`, `--wif`) and a Git-style porcelain/plumbing split.

## Surface Allocation: `bin/wallet` vs `bin/brc100`

Both CLIs consume `BSV::Wallet::Engine`. The allocation rule that prevents drift:

- **`bin/brc100`** (#431): transport for methods on `Interface::BRC100` only. Spec-conformance dispatch — camelCase method names, `WERR_*` codes, BRC-100 hash-vocabulary JSON. No commands invented; the surface is the 28 spec methods.
- **`bin/wallet`** (this HLR): native wallet-vocab commands invoking Engine methods *not* in `Interface::BRC100`, or wrapping spec methods with non-spec semantics. Snake-case verbs, structured exit codes, flat JSON.
- **Overlap**: requires an explicit decision, recorded in an ADR. The default expectation is no overlap — a method either is or isn't part of BRC-100; the surface allocation falls out of that.

The same axis is the core/conformance principle (`docs/reference/core-vs-conformance.md`) viewed at the CLI transport layer rather than the Engine/Conformance layer.

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

## Secrets on the CLI

Three credential classes flow through the dispatcher; each has a safe-handling rule. Enforced in `parse_global_options` so every command inherits the policy.

**WIF (root private key) — env-only by default.**
- Preferred: `BSV_WALLET_WIF_<NAME>` shell ENV (the existing convention).
- Alternative: `--wif-file=<path>` with file mode-checked `0600` and owner-checked at parse time. Refuse the file otherwise.
- Argv `--wif=<wif>` is **refused on a TTY** with a clear error directing to the env/file paths. The only way to use `--wif=` on a TTY is `--allow-insecure-wif` (dev/test escape hatch). Rationale: WIF on argv leaks to shell history, `ps`, container logs, and process accounting — one capture is total wallet compromise. The TTY check distinguishes "human just pasted this" from "shell script piping" (where the env path is still preferred but the cost of argv is bounded by the calling context).

**Database password — `.pgpass`, never embedded in `--database-url`.**
- Preferred: `PGPASSFILE` / `.pgpass` (mode `0600`) per libpq convention.
- `--database-url=<url>` is accepted but the `userinfo` component **must not contain a password** (i.e. `postgres://user@host/db` is fine; `postgres://user:pass@host/db` is rejected at parse time). Same argv-leakage rationale as WIF.

**`--env=<file>` — permission-checked before load.**
- Stat the file: refuse mode `& 0077`, refuse non-owner, refuse symlinks unless `--env-allow-symlink` is set.
- Canonicalise the path via `File.realpath` to prevent cwd-relative hijacks.
- Loads only keys not already in process ENV (seed-mechanism semantics, unchanged from above).
- Valid keys are constrained to the documented `BSV_WALLET_*` and `DATABASE_URL_*` prefixes — arbitrary ENV injection from a writable env file is refused.

**Output and logging redaction.**
- No CLI command may serialise a WIF, derivation prefix/suffix, or raw key bytes to stdout or stderr. The `--json` writer applies a redaction layer over the payload before emit; the top-level rescue applies the same to exception messages. `KeyDeriver#inspect` and any key-bearing class override their `#inspect` to elide material. (Defended in code, not honour-system.)

## Per-Command Sketch

**Porcelain:**

| Command | Args | Engine call | Notes |
|---------|------|-------------|-------|
| `balance` | `[--basket NAME] [--outputs]` | `engine.spendable_outputs(aggregate: :sum)` or full `spendable_outputs` if `--outputs` | `--outputs` is shorthand for `list outputs` (always-spendable; the underlying `engine.spendable_outputs` has no non-spendable mode). |
| `list <noun>` | `outputs\|actions [--limit=<n>] [--all] [--offset=<n>] [filters]` | `engine.spendable_outputs` / `engine.list_actions` | Power-user query, noun-based. **Defaults:** `--limit=100`, `--all` is the explicit opt-out (no upper bound). `--json` emits NDJSON (one object per line) — never buffers the full result-set in memory. **Note:** `engine.list_actions(labels:)` is label-required (no unfiltered primitive); `list actions` requires at least one `--label=<name>` flag. Unfiltered actions listing is a follow-up engine addition (out of scope here). `list <noun>` is the extension point — future nouns (`baskets`, `certificates`) plug in via the dispatcher's noun registry. |
| `send <address> <sats>` | `[--broadcast=inline\|async] [--transmit=inline --target=<uri>] [--description=<text>]` | `engine.build_action(description:, accept_delayed_broadcast:, ...)` | Default: `--broadcast=inline --transmit=none`. `--description` defaults to `'cli-send'` if omitted (engine requires non-nil). Broadcast mapping (CLI must pass explicitly — engine's default `accept_delayed_broadcast: true` would otherwise force `:delayed`): `--broadcast=inline` → `accept_delayed_broadcast: false` (intent `:inline`, sync ARC dispatch); `--broadcast=async` → `accept_delayed_broadcast: true` (intent `:delayed`, daemon picks up). Failure → non-zero exit, action stays in valid pending state. |
| `receive` | `[--file=<path>] [--basket=<name>] [--description=<text>] [--force-basket]` | `engine.import_beef(tx:, outputs:, description:, ...)` | Reads BEEF bytes from `--file=<path>` if given, otherwise stdin (with `binmode`). **BEEF parsing is delegated to the SDK** (`BSV::Transaction::Beef.parse`) — no bespoke CLI parser. Input is size-capped (default 32 MiB) before parsing; exceeding the cap is a hard refusal. After parse: (1) extract subject `tx` (raw bytes) and output specs (`outputs` array with `output_index`, `protocol`, `insertion_remittance: { basket:, derivation_prefix:, derivation_suffix:, sender_identity_key: }`); (2) apply `--basket=<name>` ONLY to outputs whose envelope omits a basket — silent override of the sender's BRC-29 intent requires `--force-basket`; (3) `--description` defaults to `'cli-receive'` if omitted (engine requires non-nil). Then calls `engine.import_beef(tx:, outputs:, description:, ...)`. |
| `import` | `[--basket=<name>] [--inline] [--no-send]` | `engine.import_wallet(basket:, no_send:, accept_delayed_broadcast:, ...)` | Scanning form (root → spendable self-send). `--basket=<name>` routes imported outputs into named basket (parity with current `bin/import_root_utxo` HLR #436 semantics). **Default broadcast mode is `:delayed`** (`accept_delayed_broadcast: true`) — the daemon batches via OMQ, avoiding the N+1 ARC round-trip pattern when scanning a root with many UTXOs. `--inline` opts into synchronous per-UTXO broadcast (`accept_delayed_broadcast: false`); `--no-send` skips broadcast entirely (`no_send: true`, internal-completion path, outputs promoted in same DB transaction). **Engine surface gap:** `import_wallet` does not currently accept `basket:` — it iterates `import_utxo(...)` without forwarding a basket. Phase 5 adds `basket:` to `import_wallet` and forwards to `import_utxo(basket:)`. Each `import_utxo` is its own atomic `db.transaction`; the scan loop is N independent transitions (matches principle-of-state's atomic-transition framing). Pinpoint `import_utxo` dropped from CLI; engine method survives. |
| `reject <reference>` | — | `engine.reject_action(action_id:)` | Abandon pending action. CLI command resolves `reference` → `action_id` via `Engine::Action.find(engine:, reference:)` before the engine call (no engine surface change needed). Engine method signature stays as-is. |

**Plumbing:**

| Command | Args | Engine call | Notes |
|---------|------|-------------|-------|
| `build` | `--to=<addr>:<sats> [--to=...] --description=<text>` | `engine.build_action(description:, sign_and_process: false, ...)` | Parks an unsigned action via deferred signing. `--description` REQUIRED (engine contract). Note: `no_send: true` + `sign_and_process: false` is explicitly rejected by the engine (`#192`). Engine returns `{ signable: { atomic_beef:, reference: } }`; CLI flattens at the boundary to `{ "reference": "<ref>", "atomic_beef": "<hex>" }` (the `signable:` wrapper is engine-internal disambiguation, redundant at the CLI). |
| `sign <reference>` | `[--spends=<json>]` | `engine.sign_action(reference:, spends:)` | Completes deferred-signing flow |
| `broadcast <reference>` | `[--inline\|--async]` | `engine.broadcast_action(reference:, intent:)` | Engine has no public `broadcast(raw_tx)` — broadcast is by action only. CLI vocab maps to engine vocab: `--inline` → `intent: :inline` (sync ARC dispatch), `--async` → `intent: :delayed` (daemon picks up via OMQ). `--async` is CLI sugar for the engine's existing `:delayed` term. Phase 2 exposes `engine.broadcast_action(reference:, intent: :inline)` which: (1) looks up action by reference, (2) rehydrates `atomic_beef` from the parked `raw_tx` via `@hydrator.build_atomic_beef`, (3) calls internal `dispatch_broadcast(action_id, atomic_beef, intent:)` at `engine.rb:1296`. Lookup + rehydration live in the engine because `@hydrator` is engine-internal; the CLI never touches it. |
| `transmit` | `--reference=<ref> --target=<uri> [--counterparty=<key>] [--with-identity]` | `engine.transmit_action(reference:, target:, counterparty: nil, with_identity: false)` | Delivers BEEF to peer endpoint. **Egress hardening** (Phase 3): URI scheme allow-list (`https` default; `http` requires `--insecure-transmit`); reject private/loopback/link-local/cloud-metadata ranges (`127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`, `::1`, `fc00::/7`); resolve target host via `Resolv` + `IPAddr` before request. **Identity attachment is opt-in**: `--with-identity` attaches `sender_identity_key` to the BRC-29 envelope. Without the flag, transmit goes anonymous — prevents the wallet's identity key being correlated across every endpoint the operator transmits to (passive deanonymisation risk if `--target` is attacker-controlled or logged at the proxy). `--counterparty=<key>` accepts `self`, `anyone`, or hex pubkey per BRC-43. **Engine surface gap:** Engine currently sets `@transmission = Transmission.new(...)` with no public accessor; `Transmission#transmit` requires `counterparty:`, `action_id:`, `outputs:`, `sender_identity_key:`, `endpoint:`. Phase 3 adds `engine.transmit_action(...)` wrapper which: (1) looks up action by reference, (2) gathers `outputs` from action storage, (3) reads `sender_identity_key` from `key_deriver.identity_key` *only if* `with_identity: true`, (4) applies egress policy to `target`, (5) calls `Transmission#transmit(...)`. CLI stays a thin wrapper. |

**Operational:**

| Command | Args | Engine call | Notes |
|---------|------|-------------|-------|
| `sweep` | `--to=<root_key_hex> [--no-send]` | `engine.sweep(recipient:, no_send:)` | Spendable → root-key P2PKH; blank-slate tool |
| `consolidate` | `[--target-inputs=<n>] [--no-send]` | `engine.consolidate_step(target_inputs:, no_send:)` | Stays in spendable set; reduces UTXO count. `--no-send` forwards to engine's `no_send:` (default `false`, broadcasts inline). |

## CLI Module Additions

File: `gem/bsv-wallet/lib/bsv/wallet/cli.rb` (existing; extend, don't replace).

Add:
- `CLI::Dispatcher` — argv router. Parses global flags, splits at subcommand boundary, instantiates the command class. Holds the command registry: `Dispatcher::COMMANDS = { 'balance' => Commands::Balance, 'list' => Commands::List, ... }.freeze` — explicit, greppable, no autoload races. Unknown command → `raise UsageError, "unknown command: #{name}"`.
- `CLI::GlobalOptions` — value object passed to commands. **Shape**: `GlobalOptions = Data.define(:wallet_name, :network, :json, :wif_override, :database_url_override, :env_file)`. Immutable, keyword-constructible, deconstructable in `case/in`. Reads as a value object (which it is); `Struct` would invite accidental mutation.
- `CLI::parse_global_options(argv)` — NEW helper that parses global flags, returns `[GlobalOptions, remaining_argv]`. Distinct from `extract_wallet_name` (which stays as-is for `bin/walletd` and other positional callers). Enforces the secrets-on-the-CLI policy at this layer (TTY-WIF refusal, DB-URL userinfo check, env-file mode check).
- `CLI::Error` hierarchy:
  - `class CLI::Error < StandardError; def exit_code = 1; end`
  - `class UsageError < Error; def exit_code = 2; end` — bad flags, unknown command, missing required args
  - `class EngineError < Error; def exit_code = 1; end` — engine raised
  - `class NotRejectableError < Error; def exit_code = 3; end` — `reject` on broadcast action
  - `class InsecureWifError < UsageError; def exit_code = 2; end` — `--wif=` on TTY without `--allow-insecure-wif`
  - Commands `raise`; dispatcher `rescue`s at the top and translates to exit codes. No `abort` inside commands (untestable, bypasses the contract).
- `CLI::Commands::Base` — abstract class (not module — commands inherit, not mix in). Contract:
  - `#call(ctx, args) → Integer` — exit code. Subclasses must implement.
  - `#parser` — memoised OptionParser, banner format `"Usage: bin/wallet #{name} [options] <args>"`.
  - `#help` — prints `@parser.help` for per-command `--help`.
  - `#emit_json(payload)` — wraps `CLI::Output.write_json` with the redaction layer applied. Subclasses use this for stdout JSON; never `puts JSON.generate(...)` directly.
  - `#emit_human(line)` — writes to stderr via `warn`. For human progress / summary lines.
  - `#read_binary_input(file: nil)` — reads from `$stdin.binmode` or `File.binread(path)`. The single home for BEEF-shaped input; subclasses can't forget `binmode`.
  - `#parse_pubkey_hex(str)` — wraps `BSV::PublicKey.from_hex`; raises `UsageError` with a clear message on failure. All ingest points for `--counterparty`, `--to=<root_key_hex>`, etc. go through this.
  - All files: `# frozen_string_literal: true` at top.
- `CLI::Commands::<Verb>` — one class per command (12 classes). Each inherits `Base`, defines `#parser` and `#call(ctx, args)`. Approximate size: 30-80 lines per class.
- Every command class lands with `frozen_string_literal: true` and passes `bundle exec rubocop lib/bsv/wallet/cli/` — no mass disables.

Extend or keep:
- `CLI.boot` — signature extended to `CLI.boot(wallet_name:, network:, wif_override: nil, database_url_override: nil)`. Current signature only reads WIF/DB URL from `BSV::Wallet.config` / `Fixtures`; the new overrides let the dispatcher pass `--wif` / `--database-url` flag values through without mutating ENV. Backward-compatible for `bin/walletd` and other callers that don't pass the new kwargs.
- `CLI.extract_wallet_name` — UNCHANGED (parses positional first-arg wallet name). Used by `bin/walletd` and other surviving scripts; repurposing would break them. The dispatcher uses `parse_global_options` instead.
- `CLI::Output.write_json`, `write_binary` — unchanged.

Engine surface additions (across phases):

- **Phase 2** — `engine.broadcast_action(reference:, intent: :inline)`. NOT a thin wrapper — looks up the action by reference, rehydrates `atomic_beef` from the parked `raw_tx` via `@hydrator.build_atomic_beef(raw_tx, action_id)`, then calls the existing internal `dispatch_broadcast(action_id, atomic_beef, intent:)` at `engine.rb:1296`. The broadcast plumbing CLI verb (Phase 3) becomes a thin wrapper over this.
- **Phase 3** — `engine.transmit_action(reference:, target:, counterparty: nil)`. Wraps `@transmission.transmit(...)` — looks up action by reference, gathers `outputs` from action's stored outputs, reads `sender_identity_key` from `key_deriver.identity_key`, defaults `counterparty` to action's stored counterparty when omitted, calls `Transmission#transmit(counterparty:, action_id:, outputs:, sender_identity_key:, endpoint: target)`. Without this wrapper, the CLI would need direct access to `@transmission` (no public reader) and would carry parameter-gathering logic (violates "no business logic in CLI" hygiene).
- **Phase 5** — `basket:` kwarg added to `engine.import_wallet`, forwarded to `import_utxo(basket:)` (which already accepts it). Without this, `wallet import --basket=<name>` is unimplementable.

## DB Access Patterns

The plan introduces no schema changes, but four new read patterns benefit from explicit index assertions before they ossify into hot paths:

| Command(s) | Query shape | Index relied on | Status |
|------------|-------------|-----------------|--------|
| `reject`, `broadcast`, `transmit`, `sign` (lookup phase) | `actions WHERE reference = ?` | `actions.reference UNIQUE` (`uuid` B-tree) | Confirm before Phase 2; index already present per `001_create_schema.rb` |
| `list actions --label=<name>` | `labels JOIN action_labels JOIN actions WHERE labels.name = ?` | `labels(name) UNIQUE`, `action_labels(label_id, action_id)` composite | Confirm before Phase 1; add to `001_create_schema.rb` if missing (pre-release, so schema lives in 001) |
| `broadcast_action` rehydration | `actions WHERE id = ?` → `@hydrator.build_atomic_beef(raw_tx, action_id)` | Primary key on `actions.id` | Index-backed by construction |
| `list outputs` (paginated) | `spendable_outputs` with `LIMIT`/`OFFSET` | Existing indices on `outputs` | Verify engine pushes `LIMIT` to SQL, not Ruby-side |

`import_wallet` scanning: each `import_utxo` call is its own `db.transaction` (per-row atomicity, matches principle-of-state). The scan loop is N independent transitions, NOT one big transaction — avoids long-held locks and unbounded WAL growth on a wallet with many root UTXOs.

`list` pagination uses a stable `ORDER BY` (per-noun: `actions.created_at DESC, actions.id DESC` for actions; `outputs.id DESC` for outputs) so paged results don't drift between successive `--limit`/`--offset` pairs.

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

Each phase lands per-command unit specs in the SAME PR as the command (`spec/bin/wallet/<command>_spec.rb`). Phase 6 closes only the e2e rewrite. Rationale: deferring all specs to Phase 6 leaves five PRs shipping CLI surface against engine-only coverage — a regression in Phase 3 would not surface until Phase 6 rebuild. Co-located specs cost ~30 minutes per command and close the gap entirely.

1. **Phase 1 — Dispatcher scaffolding + balance + list.** `bin/wallet` exists, global flag parsing works, `balance` and `list outputs/actions` route through it. Lands: `CLI::Dispatcher`, `GlobalOptions`, `parse_global_options`, `Commands::Base` (full contract per CLI Module Additions), `Commands::Balance`, `Commands::List`. Specs: `spec/bin/wallet/balance_spec.rb`, `list_spec.rb`, `dispatcher_spec.rb` (global-flag parsing), `commands/base_spec.rb` (contract). Old `bin/balance`, `bin/list_outputs` deleted in same PR. Smallest viable demo of the surface.
2. **Phase 2 — Engine broadcast surface.** Expose `engine.broadcast_action(reference:, intent: :inline)` as public. Includes action lookup by reference + `atomic_beef` rehydration via `@hydrator.build_atomic_beef` before delegating to internal `dispatch_broadcast`. Includes engine-level spec for the new method. Small, isolated PR — not a pure wrapper.
3. **Phase 3 — Plumbing: build, sign, broadcast, transmit.** Adds the four elementary verbs + per-command specs (`build_spec.rb`, `sign_spec.rb`, `broadcast_spec.rb`, `transmit_spec.rb` — note: distinct from the e2e `spec/e2e/transmit_spec.rb`). Includes engine surface addition: `engine.transmit_action(reference:, target:, counterparty: nil, with_identity: false)` wrapper (lookup + parameter gathering for `Transmission#transmit` + egress hardening). No porcelain yet.
4. **Phase 4 — Porcelain: send, receive.** Built on Phase 3 plumbing. send is the macro, receive consumes BEEF. Lands: `Commands::Send`, `Commands::Receive`, `send_spec.rb`, `receive_spec.rb`.
5. **Phase 5 — Porcelain: import, reject + operational: sweep, consolidate.** Remaining commands + per-command specs (`import_spec.rb`, `reject_spec.rb`, `sweep_spec.rb`, `consolidate_spec.rb`). Includes engine surface addition: `basket:` kwarg added to `engine.import_wallet` and forwarded to `import_utxo(basket:)`. Old bins deleted.
6. **Phase 6 — E2E shape spec rewrite.** Rewritten `spec/e2e/transmit_spec.rb` against new `bin/wallet`. `wallet_actor.rb` rebuilt for the dispatcher's subcommand grammar. Per-command unit specs already exist from Phases 1, 3, 4, 5 — Phase 6 closes only the e2e layer.

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

**Boot-cost baseline (Phase 1 acceptance metric).** Measure `time bin/wallet --wallet=alice balance` against a representative DB. Target: cold start <500ms. Record in Phase 1 PR description as the baseline; subsequent phase PRs note any regression. Rationale: per-invocation CLIs amortise boot cost poorly under shell-loop bulk patterns; establishing the baseline pre-ossifies a regression signal before the surface ships.

## Decisions (resolved during planning)

1. **PR cadence — six phases.** Each phase is small enough to review thoroughly; merge overhead is the acceptable cost. Phases 1–2 can land in either order; 3–5 build on 2; 6 closes out the spec rewrite.
2. **Engine broadcast surface — `engine.broadcast_action(reference:, intent: :inline)`.** NOT a thin wrapper: performs action lookup by reference + `atomic_beef` rehydration via `@hydrator.build_atomic_beef`, then delegates to internal `dispatch_broadcast(action_id, atomic_beef, intent:)` at `engine.rb:1296`. `intent:` accepts `:inline` (default, sync ARC dispatch) or `:delayed` (enqueue for daemon) — matches the engine's existing `map_broadcast_intent` vocabulary. CLI surfaces `--async` as sugar for `:delayed`. The lookup/rehydration live engine-side because `@hydrator` is engine-internal; `reject` and `transmit` keep their lookup CLI-side (no hydrator needed).
3. **`reject` semantics — hard fail on non-rejectable state.** Aligns with the no-invalid-state invariant: pending actions are rejectable, broadcast actions are not. Failure mode is structured stderr + non-zero exit; the action stays in its current valid state.
4. **Plumbing layer (`build`/`sign`/`broadcast`/`transmit`) is KEPT.** Architecture review (`20260627_feature-native-porcelain-cli.md`) raised cutting the plumbing as a YAGNI candidate — the verbs lack a concrete user story today, and `transmit_action`/`broadcast_action` engine wrappers exist primarily because the CLI verbs do. Decision: keep them. The transmit/broadcast distinction is a load-bearing BSV protocol concept (HLR #385, ADR-025) that benefits from surfacing at verb level in the CLI vocabulary — the plumbing IS the documentation of the action lifecycle in shell verbs. The engine wrappers stay justified by the "no business logic in CLI" hygiene rule (engine-internal `@hydrator`, parameter gathering, egress hardening all belong engine-side).
5. **Per-command unit specs co-locate with the introducing phase.** Architecture review flagged the Phase-6-only spec deferral as a five-PR coverage gap; co-locating closes it at ~30 minutes per command. Phase 6 keeps only the e2e shape rewrite.
6. **Secrets-on-the-CLI policy: env-only by default.** WIF via env or `--wif-file=<path>` mode-checked; refuse argv `--wif=` on TTY without `--allow-insecure-wif`. DB password via `.pgpass`; reject userinfo `:` in `--database-url`. `--env=<file>` permission/owner/symlink-checked before load. Output redaction via `Secrets.redact` over `--json` payloads and exception messages. Enforced in `parse_global_options`; every command inherits.

## Follow-up Issues (to create)

- Lock + select_utxos commands (deferred — needs engine lock API design).
- Recipient registry / address book (deferred — wait until transmit infrastructure settles, BEEF Party lands).
- `bin/import_utxo` pinpoint form (drop from CLI, keep engine method; revisit if a need arises).
- **ADR for porcelain/plumbing/operational taxonomy** (post-Phase 6 — capture the three-tier CLI split + precedence/config model as an ADR once the surface has shipped and stabilised; recorded by architecture review `20260627_feature-native-porcelain-cli.md`).
- **Parser fuzz harness** for BEEF + `sign --spends` JSON under `spec/security/` (post-Phase 6 — the SDK is the BEEF parser, single audited source; fuzz harness is defence-in-depth, not blocking).
- **`--batch` stdin-driven mode for plumbing verbs** (`broadcast`/`sign`/`transmit`) — amortises engine boot cost across N references; revisit when shell-loop bulk patterns become a measured pain point.
- **`broadcast --format=ef|raw` operator flag** for ARC-vs-Arcade rejection debugging (Domain Expert recommendation; defer until reject-axis-is-raw-vs-EF actually bites in operations).

## Out of Scope (deliberate)

- BRC-100 HTTP/JSON-RPC transport (#223 — separate workstream).
- `bin/brc100` CLI surface (#431 — sibling HLR, parallel work).
- ABI/streaming transports (#180 future).
- `noSend` / `sendWith` reservation flow (#192).
