# Native Porcelain CLI — bin/wallet dispatcher

**HLR:** #433
**Sibling:** #431 (BRC-100 CLI — `bin/brc100`)

## Context

Existing porcelain (`bin/send`, `bin/balance`, `bin/import`, `bin/receive`, etc.) routes through `BSV::Wallet::BRC100`, importing the spec's quirks (change-pool ambiguity, basket-required semantics, originator noise) into use cases that don't need conformance. #431 is settling the BRC-100 surface under `bin/brc100`. This HLR is the sibling: a native wallet-vocab surface that calls Engine methods directly, designs its own basket/change semantics, and stays shell-pipeable.

Outcome: a single `bin/wallet <command>` dispatcher replacing the 16 standalone porcelain scripts, with a cleaner config story (one place for `--wallet`, `--database-url`, `--wif`) and a porcelain/operational verb split. (Originally also planned a Git-style plumbing layer; deferred per ADR-030 — see Scope.)

## Surface Allocation: `bin/wallet` vs `bin/brc100`

Both CLIs consume `BSV::Wallet::Engine`. The allocation rule that prevents drift:

- **`bin/brc100`** (#431): transport for methods on `Interface::BRC100` only. Spec-conformance dispatch — camelCase method names, `WERR_*` codes, BRC-100 hash-vocabulary JSON. No commands invented; the surface is the 28 spec methods.
- **`bin/wallet`** (this HLR): native wallet-vocab commands invoking Engine methods *not* in `Interface::BRC100`, or wrapping spec methods with non-spec semantics. snake_case verbs, structured exit codes, flat JSON.
- **Overlap**: requires an explicit decision, recorded in an ADR. The default expectation is no overlap — a method either is or isn't part of BRC-100; the surface allocation falls out of that.

The same axis is the core/conformance principle (`docs/reference/core-vs-conformance.md`) viewed at the CLI transport layer rather than the Engine/Conformance layer.

## Scope

**Porcelain (6):** `balance`, `list`, `send`, `receive`, `import`, `reject`
**Operational (3):** `sweep`, `consolidate`, `transmit`

(Originally proposed a plumbing layer of `build`/`sign`/`broadcast`/`transmit`. Deferred — see ADR-030. The engine bundles action creation with publication; stateless CLI plumbing of those phases would violate principle-of-state. `transmit` survives as operational because it operates on a fully-committed action's BEEF, not on intermediate state.)

**Out of scope (follow-up issues):**
- Lock / select_utxos commands (deferred — engine has no native lock API yet).
- Recipient registry / phone-book resolution (`send <name>` → URI). For v1, `send` takes `<address> <sats>` (old-school BSV positional) and `transmit` requires explicit `--target=<uri>`.
- BRC-100 plumbing bins (`create_action`, `list_outputs`, `internalize`) — deleted here per blank-slate; their replacement (`bin/brc100`) lives under #431. A temporary gap exists between this PR landing and #431 landing where shell-driven BRC-100 dispatch is unavailable; internal Ruby callers use `engine.brc100` directly in the interim.
- **CLI plumbing layer** (`build`/`sign`/`broadcast` as separable verbs) — deferred per ADR-030. Returns as a follow-up after HLR #192 (noSend/sendWith reservation flow) provides the in-engine intermediate-state holding that plumbing-as-CLI requires.
- **Failed-broadcast retry** — separate primitive against the `broadcasts` row (not the action). Tracked as a follow-up issue.

## Dispatcher Design

Single binary `bin/wallet`. Grammar:

```
bin/wallet [global-flags] <command> [command-args]
```

**Global flags** (parsed by the dispatcher, before subcommand):

| Flag | Purpose |
|------|---------|
| `--wallet=<name>` | Resolve via `Fixtures` registry |
| `--wif=<wif>` | Explicit WIF on argv — refused on TTY by default; requires `--allow-insecure-wif` to override. See Secrets on the CLI. |
| `--wif-file=<path>` | Preferred WIF input — file must be mode `0600` and owned by the invoker. See Secrets on the CLI. |
| `--allow-insecure-wif` | Escape hatch: permits `--wif=<wif>` on a TTY (dev/test only). |
| `--database-url=<url>` | Explicit DB override — `userinfo` must not embed a password (`postgres://user@host/db`, never `postgres://user:pass@host/db`). DB password comes from `.pgpass`/`PGPASSFILE`. |
| `--env=<file>` | Load env file (dotenv-style; seed mechanism — only fills unset keys). File mode-checked (`& 0077` refused), owner-checked, symlinks refused. |
| `--env-allow-symlink` | Permits `--env=<path>` to resolve through a symlink. |
| `--network=mainnet\|testnet` | Network override |
| `--json` | Force JSON output (NDJSON for `list`) even on TTY |
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
- `File.lstat` the path FIRST to detect symlinks (a regular `File.stat` would silently follow them and miss the policy). If `File.symlink?(path)` and `--env-allow-symlink` is not set, refuse.
- Then `File.stat` (or `File.lstat` for the non-symlink case): refuse mode `& 0077`, refuse non-owner.
- Canonicalise via `File.realpath` only AFTER the symlink check passes — `realpath` resolves symlinks, so checking after it would defeat the policy.
- Loads only keys not already in process ENV (seed-mechanism semantics, unchanged from above).
- Valid keys are constrained to the documented `BSV_WALLET_*` and `DATABASE_URL_*` prefixes — arbitrary ENV injection from a writable env file is refused.

**Output and logging redaction.**
- No CLI command may serialise a WIF, derivation prefix/suffix, or raw key bytes to stdout or stderr. The `--json` writer applies a redaction layer over the payload before emit; the top-level rescue applies the same to exception messages. `KeyDeriver#inspect` and any key-bearing class override their `#inspect` to elide material. (Defended in code, not honour-system.)
- **Land in Phase 1.** The redaction helper (`CLI::Secrets.redact(obj)`) and the `#inspect` overrides on key-bearing classes (`KeyDeriver`, `Engine`) are prerequisites for the policy being enforceable from the first PR. Phase 1's `Commands::Base#emit_json` calls `Secrets.redact` before writing; the dispatcher's top-level rescue does the same on exception messages. This is the only engine-touching work in the CLI rebuild that isn't an engine surface addition; treat it as foundation work bundled with the dispatcher PR.

## Per-Command Sketch

**Porcelain:**

| Command | Args | Engine call | Notes |
|---------|------|-------------|-------|
| `balance` | `[--basket=<name>] [--outputs]` | `engine.spendable_outputs(aggregate: :sum)` or full `spendable_outputs` if `--outputs` | `--outputs` is shorthand for `list outputs` (always-spendable; the underlying `engine.spendable_outputs` has no non-spendable mode). |
| `list <noun>` | `outputs\|actions [--limit=<n>] [--all] [--offset=<n>] [filters]` | `engine.spendable_outputs` / `engine.list_actions` | Power-user query, noun-based. **Defaults:** `--limit=100`, `--all` is the explicit opt-out (no upper bound). `--json` emits NDJSON (one object per line) — never buffers the full result-set in memory. **Note:** `engine.list_actions(labels:)` is label-required (no unfiltered primitive); `list actions` requires at least one `--label=<name>` flag. Unfiltered actions listing is a follow-up engine addition (out of scope here). `list <noun>` is the extension point — future nouns (`baskets`, `certificates`) plug in via the dispatcher's noun registry. |
| `send <address> <sats>` | `[--broadcast=inline\|async] [--transmit=inline --target=<uri>] [--description=<text>]` | `engine.build_action(description:, accept_delayed_broadcast:, ...)` | Default: `--broadcast=inline --transmit=none`. `--description` defaults to `'cli-send'` if omitted (engine requires non-nil). Broadcast mapping (CLI must pass explicitly — engine's default `accept_delayed_broadcast: true` would otherwise force `:delayed`): `--broadcast=inline` → `accept_delayed_broadcast: false` (intent `:inline`, sync ARC dispatch); `--broadcast=async` → `accept_delayed_broadcast: true` (intent `:delayed`, daemon picks up). Failure → non-zero exit, action stays in valid pending state. |
| `receive` | `[--file=<path>] [--basket=<name>] [--description=<text>] [--force-basket]` | `engine.import_beef(tx:, outputs:, description:, ...)` | Reads BEEF bytes from `--file=<path>` if given, otherwise stdin (with `binmode`). **BEEF parsing is delegated to the SDK** (`BSV::Transaction::Beef.parse`) — no bespoke CLI parser. Input is size-capped (default 32 MiB) before parsing; exceeding the cap is a hard refusal. After parse: (1) extract subject `tx` (raw bytes) and output specs (`outputs` array with `output_index`, `protocol`, `insertion_remittance: { basket:, derivation_prefix:, derivation_suffix:, sender_identity_key: }`); (2) apply `--basket=<name>` ONLY to outputs whose envelope omits a basket — silent override of the sender's BRC-29 intent requires `--force-basket`; (3) `--description` defaults to `'cli-receive'` if omitted (engine requires non-nil). Then calls `engine.import_beef(tx:, outputs:, description:, ...)`. |
| `import` | `[--basket=<name>] [--inline] [--no-send] [--include-unconfirmed]` | `engine.import_wallet(basket:, no_send:, accept_delayed_broadcast:, include_unconfirmed:)` | Scanning form (root → spendable self-send). `--basket=<name>` routes imported outputs into named basket (parity with current `bin/import_root_utxo` HLR #436 semantics); CLI rejects empty `--basket=` since the schema requires basket names of 5-300 chars (omitting the flag entirely is the way to land in the unbasketed pool). **Default broadcast mode is `:delayed`** (`accept_delayed_broadcast: true`) — the daemon batches via OMQ, avoiding the N+1 ARC round-trip pattern when scanning a root with many UTXOs. `--inline` opts into synchronous per-UTXO broadcast (`accept_delayed_broadcast: false`); `--no-send` skips broadcast entirely (`no_send: true`, internal-completion path, outputs promoted in same DB transaction). `--include-unconfirmed` scans WoC's `/unspent/all` endpoint (mempool entries) instead of `/confirmed/unspent` (default; safer — confirmed UTXOs can't be reorged-away). E2E harness needs this flag to see just-broadcast sweep outputs without waiting for a block. **Engine surface gap:** `import_wallet` does not currently accept `basket:` — it iterates `import_utxo(...)` without forwarding a basket. Phase 3 adds `basket:` to `import_wallet` and forwards to `import_utxo(basket:)`. Each `import_utxo` is its own atomic `db.transaction`; the scan loop is N independent transitions (matches principle-of-state's atomic-transition framing). Pinpoint `import_utxo` dropped from CLI; engine method survives. |
| `reject <reference>` | — | `engine.reject_action(action_id:)` | Abandon pending action. CLI command resolves `reference` → `action_id` via `Engine::Action.find(engine:, reference:)` before the engine call (no engine surface change needed). Engine method signature stays as-is. |

**Operational:**

| Command | Args | Engine call | Notes |
|---------|------|-------------|-------|
| `sweep` | `--to=<root_key_hex> [--no-send]` | `engine.sweep(recipient:, no_send:)` | Spendable → root-key P2PKH; blank-slate tool |
| `consolidate` | `[--target-inputs=<n>] [--no-send]` | `engine.consolidate_step(target_inputs:, no_send:)` | Stays in spendable set; reduces UTXO count. `--no-send` forwards to engine's `no_send:` (default `false`, broadcasts inline). |
| `transmit <reference>` | `--target=<uri> [--counterparty=<key>] [--with-identity]` | `engine.transmit_action(reference:, target:, counterparty: nil, with_identity: false)` | Delivers BEEF to peer endpoint. Operational verb (per ADR-030) — operates on a fully-committed action's BEEF, no state transition. Distinct domain from broadcast (BEEF→peer vs BEEF→miner per ADR-025). **Egress hardening:** URI scheme allow-list (`https` default; `http` requires `--insecure-transmit`); reject private/loopback/link-local/cloud-metadata ranges (`127.0.0.0/8`, `10.0.0.0/8`, `172.16.0.0/12`, `192.168.0.0/16`, `169.254.0.0/16`, `::1`, `fc00::/7`); resolve target host via `Resolv` + `IPAddr` before request. **Identity attachment is opt-in**: `--with-identity` attaches `sender_identity_key` to the BRC-29 envelope. Without the flag, transmit goes anonymous — prevents the wallet's identity key being correlated across every endpoint the operator transmits to (passive deanonymisation risk if `--target` is attacker-controlled or logged at the proxy). `--counterparty=<key>` accepts `self`, `anyone`, or hex pubkey per BRC-43. **Engine surface addition:** `engine.transmit_action(reference:, target:, counterparty: nil, with_identity: false)` wrapper (Phase 4) — looks up action by reference, gathers `outputs` from action storage, reads `sender_identity_key` from `key_deriver.identity_key` only if `with_identity: true`, applies egress policy to `target`, calls `@transmission.transmit(...)`. CLI stays a thin wrapper. |

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
  - `#initialize(ctx:, global_options:)` — boot context (engine + identity_key + utxo_pool + ...) and `GlobalOptions` passed once; held as ivars for the command's lifetime.
  - `#call(args) → Integer` — exit code. Subclasses must implement. `args` is the per-command argv slice (global flags already consumed by the dispatcher). No `ctx` parameter — that came in via `#initialize`.
  - `#parser` — memoised OptionParser, banner format `"Usage: bin/wallet #{name} [options] <args>"`. Subclasses override `#build_parser`, which `#parser` memoises.
  - `#help` — prints `@parser.help` for per-command `--help`.
  - `#emit_json(payload)` — wraps `CLI::Output.write_json` with the redaction layer applied. Subclasses use this for stdout JSON; never `puts JSON.generate(...)` directly.
  - `#emit_human(line)` — writes to stderr via `warn`. For human progress / summary lines.
  - `#read_binary_input(file: nil)` — reads from `$stdin.binmode` or `File.binread(path)`. The single home for BEEF-shaped input; subclasses can't forget `binmode`.
  - `#parse_pubkey_hex(str)` — wraps `BSV::PublicKey.from_hex`; raises `UsageError` with a clear message on failure. All ingest points for `--counterparty`, `--to=<root_key_hex>`, etc. go through this.
  - All files: `# frozen_string_literal: true` at top.
- `CLI::Commands::<Verb>` — one class per command (9 classes — 6 porcelain + 3 operational, post-ADR-030 deferral of the plumbing layer). Each inherits `Base`, defines `#build_parser` and `#call(args)` (the boot `ctx` is passed via `#initialize`). Approximate size: 30-80 lines per class.
- Every command class lands with `frozen_string_literal: true` and passes `bundle exec rubocop lib/bsv/wallet/cli/` — no mass disables.

Extend or keep:
- `CLI.boot` — signature extended to `CLI.boot(wallet_name:, network:, wif_override: nil, database_url_override: nil)`. Current signature only reads WIF/DB URL from `BSV::Wallet.config` / `Fixtures`; the new overrides let the dispatcher pass `--wif` / `--database-url` flag values through without mutating ENV. Backward-compatible for `bin/walletd` and other callers that don't pass the new kwargs.
- `CLI.extract_wallet_name` — UNCHANGED (parses positional first-arg wallet name). Used by `bin/walletd` and other surviving scripts; repurposing would break them. The dispatcher uses `parse_global_options` instead.
- `CLI::Output.write_json`, `write_binary` — unchanged.

Engine surface additions (across phases):

- **Phase 3** — `basket:` kwarg added to `engine.import_wallet`, forwarded to `import_utxo(basket:)` (which already accepts it). Without this, `wallet import --basket=<name>` is unimplementable.
- **Phase 4** — `engine.transmit_action(reference:, target:, counterparty: nil, with_identity: false)`. Wraps `@transmission.transmit(...)` — looks up action by reference, gathers `outputs` from action's stored outputs, reads `sender_identity_key` from `key_deriver.identity_key` **only if** `with_identity: true` (passive-deanonymisation defence: anonymous transmission is the default), defaults `counterparty` to action's stored counterparty when omitted, applies egress policy to `target`, calls `Transmission#transmit(counterparty:, action_id:, outputs:, sender_identity_key:, endpoint: target)` (passing `nil` for `sender_identity_key` when `with_identity: false`). Without this wrapper, the CLI would need direct access to `@transmission` (no public reader) and would carry parameter-gathering + egress-policy logic (violates "no business logic in CLI" hygiene).

(`engine.broadcast_action` removed per ADR-030. The engine bundles persistence + publication; a separable publish primitive is engine work gated on HLR #192.)

## DB Access Patterns

The plan introduces no schema changes, but four new read patterns benefit from explicit index assertions before they ossify into hot paths:

| Command(s) | Query shape | Index relied on | Status |
|------------|-------------|-----------------|--------|
| `reject`, `transmit` (lookup phase) | `actions WHERE reference = ?` | `actions.reference UNIQUE` (`uuid` B-tree) | Index already present per `001_create_schema.rb` |
| `list actions --label=<name>` | `labels JOIN action_labels JOIN actions WHERE labels.label = ?` | `labels(label) UNIQUE` (already `labels_label_unique` in 001), `action_labels(label_id, action_id)` composite | Confirm `action_labels` composite before Phase 1; add to `001_create_schema.rb` if missing (pre-release, so schema lives in 001) |
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

Each phase lands per-command unit specs in the SAME PR as the command (`spec/bin/wallet/<command>_spec.rb`). Phase 5 closes only the e2e rewrite. Rationale: deferring all specs to the final phase would leave earlier PRs shipping CLI surface against engine-only coverage. Co-located specs cost ~30 minutes per command and close the gap entirely.

1. **Phase 1 — Dispatcher scaffolding + balance + list. DONE (PR #454, merged).** `bin/wallet` exists, global flag parsing works, `balance` and `list outputs/actions` route through it. Lands: `CLI::Dispatcher`, `GlobalOptions`, `parse_global_options`, `Commands::Base` (full contract per CLI Module Additions), `Commands::Balance`, `Commands::List`, plus the secrets foundation: `CLI::Secrets.redact` helper, `#inspect` overrides on `KeyDeriver` and `Engine`, secrets-policy enforcement in `parse_global_options`. Specs: `spec/bin/wallet/balance_spec.rb`, `list_spec.rb`, `dispatcher_spec.rb` (global-flag parsing), `commands/base_spec.rb` (contract), `secrets_spec.rb` (redaction + policy enforcement). Old `bin/balance`, `bin/list_outputs` deleted in same PR.
2. **Phase 2 — Porcelain: send, receive.** Lands: `Commands::Send`, `Commands::Receive`, `send_spec.rb`, `receive_spec.rb`. `send` calls `engine.build_action(no_send: false, ...)` — atomic create+publish in one shot (the engine's structural design, per ADR-030). `receive` parses BEEF at the CLI boundary and calls `engine.import_beef`.
3. **Phase 3 — Porcelain: import, reject + operational: sweep, consolidate.** Adds the remaining stateful porcelain + the two single-purpose operational verbs. Specs: `import_spec.rb`, `reject_spec.rb`, `sweep_spec.rb`, `consolidate_spec.rb`. Includes engine surface addition: `basket:` kwarg added to `engine.import_wallet` and forwarded to `import_utxo(basket:)`. Old bins `bin/import`, `bin/import_root_utxo`, `bin/reject`, `bin/sweep`, `bin/consolidate` deleted.
4. **Phase 4 — Operational: transmit.** Adds the BEEF-to-peer verb. Includes engine surface addition: `engine.transmit_action(reference:, target:, counterparty: nil, with_identity: false)` wrapper (lookup + parameter gathering for `Transmission#transmit` + egress hardening: scheme allow-list, private-range/cloud-metadata blocklist, opt-in identity attachment). Specs: `transmit_spec.rb` (unit, distinct from e2e). Old `bin/transmit` deleted.
5. **Phase 5 — E2E shape spec rewrite.** Rewritten `spec/e2e/transmit_spec.rb` against new `bin/wallet`. `wallet_actor.rb` rebuilt for the dispatcher's subcommand grammar. Per-command unit specs already exist from Phases 1–4 — Phase 5 closes only the e2e layer.

(Originally planned as six phases. Phase 2 was `engine.broadcast_action`; Phase 3 was the four plumbing verbs. Both removed per ADR-030 — the engine's create+publish bundling makes stateless CLI plumbing incompatible with principle-of-state until HLR #192 lands.)

Phases land in sequence — each builds on the dispatcher contract Phase 1 established.

## Verification

End-to-end test of each phase against a funded test wallet (`alice` fixture):

```bash
cd gem/bsv-wallet
# Phase 1
bin/wallet --wallet=alice balance
bin/wallet --wallet=alice list outputs --limit=5
bin/wallet --wallet=alice list actions --label=cli-test --limit=5  # --label required (no unfiltered primitive)

# Phase 2
bin/wallet --wallet=alice send <addr> 1000
bin/wallet --wallet=bob receive --file=envelope.beef --description=test

# Phase 3
bin/wallet --wallet=alice import
bin/wallet --wallet=alice reject <reference>
bin/wallet --wallet=alice sweep --to=<root_key>
bin/wallet --wallet=alice consolidate --target-inputs=10

# Phase 4
bin/wallet --wallet=alice transmit <reference> --target=https://peer.example/inbox --with-identity
```

Unit specs run fast: `cd gem/bsv-wallet && bundle exec rspec spec/bin/wallet/`.
Integration: `bundle exec rspec spec/e2e/transmit_spec.rb` (after Phase 5).

**Boot-cost baseline (Phase 1 acceptance metric).** Measure `time bin/wallet --wallet=alice balance` against a representative DB. Target: cold start <500ms. Record in Phase 1 PR description as the baseline; subsequent phase PRs note any regression. Rationale: per-invocation CLIs amortise boot cost poorly under shell-loop bulk patterns; establishing the baseline pre-ossifies a regression signal before the surface ships.

## Decisions (resolved during planning)

1. **PR cadence — five phases.** Each phase is small enough to review thoroughly; merge overhead is the acceptable cost. Phases land in sequence; each builds on the dispatcher contract Phase 1 established. (Originally six phases; revised per ADR-030 — Phase 2 engine.broadcast_action and Phase 3 plumbing verbs both removed, transmit reclassified into operational.)
2. **~~Engine broadcast surface — `engine.broadcast_action`~~ → REVERSED per ADR-030.** The original decision was to expose a public `broadcast_action(reference:, intent:)` as the Phase 2 engine surface — looking up the action by reference, rehydrating `atomic_beef`, then delegating to internal `dispatch_broadcast`. PR #456 attempted this and surfaced that the engine bundles persistence with publication: `Store#sign_action` inserts the broadcasts row in the same transaction as the signing artifacts. A separable broadcast_action only works for the retry case (broadcasts row already exists) — which is a different primitive (operates on the broadcasts row, not the action) and now lives as a follow-up. The publish primitive proper waits for HLR #192. PR #456 closed.
3. **`reject` semantics — hard fail on non-rejectable state.** Aligns with the no-invalid-state invariant: pending actions are rejectable, broadcast actions are not. Failure mode is structured stderr + non-zero exit; the action stays in its current valid state.
4. **~~Plumbing layer kept~~ → REVERSED per ADR-030. Plumbing layer (`build`/`sign`/`broadcast`) is DEFERRED.** The architecture review (Pragmatic Enforcer position) flagged plumbing as speculative; we initially overrode that on "BSV vocabulary at verb level" grounds. Phase 2's attempt to extract `engine.broadcast_action` (PR #456) surfaced the structural reason the review was right: the engine bundles action persistence with publication (the publish step lives at the tail of `build_action`/`sign_action`, with the broadcasts row created in the same DB transaction as the signing artifacts). Stateless CLI plumbing (`wallet build` → exit → `wallet sign`) would persist the engine's intermediate state across process boundaries, violating principle-of-state (the staged-but-unsigned action's wtxid is a placeholder hash of unsigned bytes — schema-valid but semantically half-done). The fix is engine work: HLR #192's noSend/sendWith reservation flow provides in-engine intermediate-state holding without polluting the `actions` table. Plumbing CLI verbs return as a follow-up after #192 lands. `transmit` reclassified as operational (no intermediate state — operates on a committed action's BEEF). PR #456 closed; rationale and survival table recorded in ADR-030.
5. **Per-command unit specs co-locate with the introducing phase.** Architecture review flagged a final-phase-only spec deferral as a multi-PR coverage gap; co-locating closes it at ~30 minutes per command. Phase 5 keeps only the e2e shape rewrite.
6. **Secrets-on-the-CLI policy: env-only by default.** WIF via env or `--wif-file=<path>` mode-checked; refuse argv `--wif=` on TTY without `--allow-insecure-wif`. DB password via `.pgpass`; reject userinfo `:` in `--database-url`. `--env=<file>` permission/owner/symlink-checked before load. Output redaction via `Secrets.redact` over `--json` payloads and exception messages. Enforced in `parse_global_options`; every command inherits.

## Follow-up Issues (to create)

- Lock + select_utxos commands (deferred — needs engine lock API design).
- Recipient registry / address book (deferred — wait until transmit infrastructure settles, BEEF Party lands).
- `bin/import_utxo` pinpoint form (drop from CLI, keep engine method; revisit if a need arises).
- **CLI plumbing layer** — returns after HLR #192 establishes where staged-action state lives. The verb decomposition is not yet determined: `build`/`sign`/`broadcast` was the placeholder name set pre-reversal; `publish` emerged during ADR-030's discussion as a more honest label for the publication stage that `build_action`/`sign_action` collapse; the actual verb set follows from #192's design choice about intermediate-state storage. See ADR-030.
- **Failed-broadcast retry verb** — operates on the `broadcasts` row, not the action. Different semantics from the plumbing layer; can land independently.
- **Parser fuzz harness** for BEEF + `sign --spends` JSON under `spec/security/` (post-Phase 5 — the SDK is the BEEF parser, single audited source; fuzz harness is defence-in-depth, not blocking).
- **`--batch` stdin-driven mode for shell-loop bulk patterns** — amortises engine boot cost across N references; revisit when boot-cost regressions become measurable.

## Out of Scope (deliberate)

- BRC-100 HTTP/JSON-RPC transport (#223 — separate workstream).
- `bin/brc100` CLI surface (#431 — sibling HLR, parallel work).
- ABI/streaming transports (#180 future).
- `noSend` / `sendWith` reservation flow (#192).
