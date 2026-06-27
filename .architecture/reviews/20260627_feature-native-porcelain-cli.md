# Architecture Review: Native Porcelain CLI (`bin/wallet`)

**Date**: 2026-06-27
**Review Type**: Feature
**Reviewers**: Dr. Elena Vasquez (Systems Architect), James Thornton (BSV Domain Expert), Nadia Okafor (Security Specialist), Viktor Petrov (Performance Expert), Aisha Rahman (Maintainability Expert), Sam Oduya (Pragmatic Enforcer), Marcus Johnson (Ruby Expert), Dr. Lin Wei (Database Architect), Dr. Kenji Nakamura (Cryptography Reviewer)
**Target**: `.claude/plans/20260626-native-porcelain-cli.md` (merged via PR #451)
**HLR**: #433

## Executive Summary

The plan introduces `bin/wallet <command>` as the native wallet-vocab CLI dispatcher, replacing 16 standalone porcelain bins with a Git-style porcelain (6) / plumbing (4) / operational (2) split across six PR phases. It is a sibling to `bin/brc100` (#431), the spec-conformance CLI which remains pending. The plan is structurally sound, internally consistent (after three Copilot review rounds folded in pre-merge corrections), and honours load-bearing project principles — no-invalid-state, transmit/broadcast domain distinction, identity-key hex carve-out, replace-not-adapt blank-slate hygiene.

The architecture team's concerns cluster in three areas: (1) **secrets exposure on argv** — `--wif` and `--database-url=postgres://user:pass@host/db` leak to shell history, `ps`, and process accounting (Security and Cryptography flag as High); (2) **`Commands::Base` contract is underspecified** — twelve sibling command classes without a documented contract for exit codes, output channels, binary stdin handling, or error hierarchy (Systems Architect, Maintainability, and Ruby Expert all converge here); (3) **spec coverage gap across the rebuild** — Phase 6 lands replacement unit specs after five PRs of CLI surface changes have already shipped (Systems Architect and Maintainability call for per-command unit specs co-located with each phase). One reviewer (Pragmatic Enforcer) proposes more substantial cuts: drop the plumbing layer entirely as speculative, collapse to three phases. This is a minority position requiring deliberate consideration.

**Overall Assessment**: Strong with addressable concerns. The plan is ready to execute after a small set of tightening edits — none require revisiting the merged decisions, but several should land before Phase 1 begins.

**Key Findings**:
- Secrets exposure on argv (`--wif`, `--database-url`) is the highest-impact security concern; needs an env-only policy with `--wif-file=<path>` (mode-checked) as the alternative
- `Commands::Base` contract — exit-code scheme (`UsageError`/`EngineError`/`NotRejectableError`), stdout/stderr boundary, binmode for binary stdin, OptionParser convention — should be pinned upfront, not discovered class-by-class
- Per-command unit specs co-located with each phase (not deferred to Phase 6) close a five-PR coverage gap at near-zero cost

**Critical Actions**:
- Add a "Secrets on the CLI" subsection to the plan before Phase 1 — establishes WIF/DB-URL handling policy
- Document `Commands::Base` contract in the plan or as a Phase 1 deliverable
- Move per-command unit specs into the introducing phase; Phase 6 keeps only the e2e rewrite

---

## System Overview

The plan introduces a single-binary dispatcher (`bin/wallet`) replacing 16 standalone porcelain bins (`bin/send`, `bin/balance`, `bin/import`, `bin/receive`, plus the BRC-100 plumbing trio). The shape:

- **Twelve commands**: porcelain (`balance`, `list`, `send`, `receive`, `import`, `reject`), plumbing (`build`, `sign`, `broadcast`, `transmit`), operational (`sweep`, `consolidate`)
- **Single dispatcher**: global flags (`--wallet`, `--wif`, `--database-url`, `--env`, `--network`, `--json`) before subcommand; per-command `OptionParser` after
- **Three engine surface additions**:
  - Phase 2: `engine.broadcast_action(reference:, intent: :inline)` — lookup + `atomic_beef` rehydration + delegation to internal `dispatch_broadcast`
  - Phase 3: `engine.transmit_action(reference:, target:, counterparty: nil)` — wraps `Transmission#transmit` with parameter gathering
  - Phase 5: `basket:` kwarg added to `engine.import_wallet`, forwarded to `import_utxo(basket:)`
- **Six PR phases**: dispatcher + balance/list (1) → broadcast engine surface (2) → plumbing verbs (3) → porcelain send/receive (4) → import/reject + operational (5) → spec rewrite (6)
- **Blank-slate deletion**: 16 old bins + CLI-coupled specs deleted per `feedback_replace_not_adapt`; `spec/e2e/transmit_spec.rb` paused as shape reference
- **`bin/walletd` unchanged**: daemon survives via its inlined boot

Sibling work: `bin/brc100` (#431) covers BRC-100 spec-conformance dispatch. Sequencing decision recorded on #431: `#433 → #223 → #431`.

Project conventions in play: SOA architecture, principle-of-state, stateless SDK / stateful wallet axis, replace-not-adapt, blank-slate deletion, conventional commits, all changes via PR.

---

## Individual Member Reviews

### Dr. Elena Vasquez - Systems Architect

**Perspective**: The dispatcher is the wallet's new top-of-stack public surface; its boundaries determine how cheaply commands and engine internals can evolve thereafter. The interesting questions are not what `bin/wallet` does on day one but what shape it forces on Engine for the next two years.

#### Key Observations
- The plan adds three Engine entrypoints (`broadcast_action`, `transmit_action`, `import_wallet(basket:)`) that are *not* pure thin wrappers — they internalise lookup + hydration that was previously CLI-side. That moves the SOA boundary one step toward "Engine as façade", which is the right direction for the stateless/stateful axis.
- Porcelain/plumbing/operational is a Git-derived split, but the plumbing verbs (`build/sign/broadcast/transmit`) map 1:1 onto the action lifecycle phases — meaning the CLI shape is now a public reflection of the internal state machine. Phase changes in Engine become CLI compatibility events.
- `bin/wallet` and `bin/brc100` are described as siblings, but they share Engine. The plan never states the rule that prevents drift: which surface owns which Engine method, and how a new Engine method is allocated.
- Phase 1 ships dispatcher + two commands and *deletes* the old bins in the same PR. Until Phase 6, the CLI surface is half-rebuilt with no e2e net.
- `GlobalOptions` precedence is precise, but `CLI.boot`'s extended kwargs (`wif_override`, `database_url_override`) reach into config layering — a second config seam alongside `Fixtures`.

#### Strengths
1. **Engine surface additions are honestly scoped**: the plan flags `broadcast_action`/`transmit_action` as non-trivial wrappers and justifies the placement (hydrator is engine-internal). This is the correct dependency direction.
2. **Boundary discipline on BEEF parsing**: `receive` parses BEEF *at the CLI boundary* and hands Engine structured outputs. The CLI stays a translator, not a co-owner of import semantics.
3. **Phasing respects dependency direction**: Engine surface lands before the CLI verbs that depend on it (Phase 2 before 3; Phase 5 bundles `import_wallet(basket:)` with the verb that needs it).
4. **Deliberate divergence from BRC-100 vocab**: `--async`-as-sugar-for-`:delayed`, native basket semantics, positional `send <addr> <sats>` — explicitly rejects spec quirks rather than leaking them upward.

#### Concerns
1. **No stated allocation rule between `bin/wallet` and `bin/brc100`** (Impact: High)
   - **Issue**: Both consume Engine; sibling status is asserted, not defined. The next Engine method (say, `list_certificates`) has two homes and no rule.
   - **Why it matters**: Without a rule, drift produces overlapping commands, duplicated parsing, and a deprecation problem 18 months in.
   - **Recommendation**: Add a "Surface allocation" section: `bin/brc100` exposes only methods on `Interface::BRC100`; `bin/wallet` exposes Engine methods *not* in that interface (or wraps them with non-spec semantics). State it once in the plan, restate in `docs/reference/`.

2. **`engine.broadcast_action` couples reference-lookup into Engine permanently** (Impact: Medium)
   - **Issue**: Phase 2 lands `engine.broadcast_action(reference:, intent:)` doing lookup + hydration + dispatch. `reference` is a CLI-level identifier (UUID string); the internal `dispatch_broadcast` takes `action_id`. The new method conflates the two layers.
   - **Why it matters**: When a non-CLI caller (walletd OMQ replier, future BRC-100 binding) needs the same dispatch, it must either re-resolve `reference → action_id` itself or call the wrapper unnecessarily.
   - **Recommendation**: Keep `dispatch_broadcast(action_id, …)` public-ish (or `broadcast_by_id`); `broadcast_action(reference:)` is sugar on top. Same applies to `transmit_action` and `reject` lookup-by-reference.

3. **Phase 1 deletes old bins before the safety net is rebuilt** (Impact: Medium)
   - **Issue**: Old `spec/bin/*_spec.rb` and `spec/e2e/broadcast_spec.rb` are deleted Phase 1; new unit specs land Phase 6. Phases 2–5 ship CLI surface area against an engine-only test net.
   - **Why it matters**: Five PRs of CLI changes with no CLI-level coverage. Replace-not-adapt is fine; running with no coverage for five phases is a different proposition.
   - **Recommendation**: Move per-command unit specs into the phase that ships the command (Phase 1 ships its own `balance_spec.rb`, etc.). Keep Phase 6 for the e2e rewrite only. Cheap to do, large net.

4. **`CLI.boot` kwargs duplicate Fixtures layering** (Impact: Low-Medium)
   - **Issue**: `wif_override` / `database_url_override` sit alongside `Fixtures`, which already reads ENV. Two config-resolution paths converging in `CLI.boot`.
   - **Why it matters**: Future config questions ("where does the network default come from?") have two answers.
   - **Recommendation**: Express overrides as a one-shot `Fixtures` overlay (`Fixtures.with_override(name:, wif:, database_url:)`) rather than `CLI.boot` kwargs. Single resolution path.

#### Recommendations
1. **Document surface-allocation rule between `bin/wallet` and `bin/brc100`** (Priority: High, Effort: Small)
   - **What**: One paragraph in this plan + `docs/reference/core-vs-conformance.md` stating the allocation rule and what happens when a new Engine method appears.
   - **Why**: Cheapest moment to set the rule is before either CLI ships.
   - **How**: Rule = "BRC-100 interface methods → `bin/brc100`; everything else → `bin/wallet`; overlap requires explicit decision recorded in the relevant ADR".

2. **Split lookup-by-reference from dispatch in Engine additions** (Priority: High, Effort: Small)
   - **What**: `broadcast_action(reference:)` calls `broadcast_by_id(action_id:)`; same shape for `transmit`.
   - **Why**: Keeps CLI-layer identifier resolution out of the dispatch primitive; non-CLI callers reuse the inner verb.
   - **How**: Two-line refactor inside the same Phase 2/3 PRs.

3. **Per-command unit specs ship with each phase** (Priority: High, Effort: Small)
   - **What**: Move Phase 6's unit-spec work into Phases 1, 3, 4, 5 alongside each verb.
   - **Why**: No coverage gap across the rebuild; faster feedback on argv-parsing regressions.
   - **How**: Phase 6 keeps only the e2e shape rewrite.

4. **Promote `Commands::Base` to a contract, not a convenience** (Priority: Medium, Effort: Small)
   - **What**: Define `Base#call(ctx, args) → Integer` (exit code) and the JSON-on-stdout / human-on-stderr contract as part of the class API, not just a sketch in the plan.
   - **Why**: 12 commands × two output modes is enough surface to deserve a stated contract; otherwise each command interprets `--json` slightly differently.
   - **How**: One module method on `Base` for emit; commands call it.

5. **Record the porcelain/plumbing/operational split as an ADR** (Priority: Medium, Effort: Small)
   - **What**: Short ADR capturing the three-tier CLI taxonomy and the precedence/config model.
   - **Why**: This is a public-surface decision with downstream evolution implications — exactly the case for an ADR. Keeps `docs/reference/` free of decision-voice prose.
   - **How**: One ADR, ~150 lines, references this plan as the implementation.

---

### James Thornton - BSV Domain Expert

**Perspective**: The plan correctly identifies that native wallet vocabulary should not inherit BRC-100's conformance quirks, and the transmit/broadcast split aligns with ADR-025. But several spec-adjacent decisions risk leaking BRC-100 semantics back into the "native" surface, and a few BSV protocol nuances need tightening before Phase 3 lands.

#### Key Observations
- The transmit/broadcast separation (HLR #385 / ADR-025) is honoured at the verb level — `transmit` carries BEEF to peer, `broadcast` ships raw to miner via ARC. Good.
- `receive` parses BEEF and reconstructs BRC-29-shaped `insertion_remittance` (basket, derivation_prefix/suffix, sender_identity_key) at the CLI boundary — the BRC-29 envelope shape is being honoured even though the surface is "native".
- `send <address> <sats>` is honest old-school BSV positional — no recipient registry, no fake address-book. Correct call.
- `import` is correctly scoped as the scanning form (root → spendable self-send), which respects WBIKD recoverability (on-chain derivation, not DB IDs).
- `sweep --to=<root_key_hex>` accepts a root key directly — consistent with the blank-slate sweep semantics where root is the SAFU destination.

#### Strengths
1. **Transmit/broadcast distinction held**: Phase 3 keeps `transmit_action(reference:, target:, counterparty:)` and `broadcast_action(reference:, intent:)` as separate engine verbs — the BEEF-to-peer vs EF-to-miner domain boundary survives the CLI rewrite.
2. **BEEF parsing at the CLI boundary**: `receive` does the BEEF → tx + outputs decomposition at the boundary, with the engine receiving structured data — matches the binary-internal/hex-at-boundary principle.
3. **No-invalid-state invariant honoured**: `reject` decision (3) explicitly states pending-only, structured-failure on broadcast actions — failure leaves the action in a valid state, not a half-state.
4. **`sender_identity_key` reads from `key_deriver.identity_key`**: Correctly uses the hex-carve-out path for BRC-29 identity material rather than round-tripping bytes.
5. **WBIKD-scoped import**: `import` is scanning-form against root key, preserving on-chain recoverability rather than scanning by DB ID.

#### Concerns
1. **`transmit --target=<uri>` lacks BRC-29 protocol negotiation** (Impact: Medium)
   - **Issue**: The plan treats `--target` as a generic URI, but BRC-29 transmission carries an envelope with protocol/keyID context. There's no flag for protocol selection or BRC version.
   - **Why it matters**: A future second transport (BEEF Party, or a non-BRC-29 peer endpoint) will collide with the implicit assumption that `target` means BRC-29-shaped delivery.
   - **Recommendation**: Either constrain `transmit` to BRC-29 explicitly in v1 (document as such) or add `--protocol=brc29` with brc29 as default. Currently ambiguous.

2. **`broadcast` lacks raw-vs-EF flag** (Impact: Medium)
   - **Issue**: ARC requires Extended Format; Arcade accepts raw. The plan assumes `dispatch_broadcast` handles this internally, but the CLI offers no visibility/override.
   - **Why it matters**: Operational debugging of broadcast failures (the reject axis is raw-vs-EF per the ARC/Arcade memory) needs surface-level control.
   - **Recommendation**: Add `--format=ef|raw` plumbing flag (default `ef`) to `broadcast` for operator override; logs which format went over the wire.

3. **`--counterparty=<key>` accepts a hex string but no format validation noted** (Impact: Low)
   - **Issue**: Counterparty per BRC-43 is `'self'`, `'anyone'`, or hex pubkey. The plan accepts `<key>` without addressing which.
   - **Why it matters**: Identity-key hex carve-out means this stays hex throughout — but `'self'` / `'anyone'` are spec-valid sentinel values.
   - **Recommendation**: Document `--counterparty` accepts `self|anyone|<hex>`, matching BRC-43.

4. **`receive --basket` overrides parsed BRC-29 basket silently** (Impact: Medium)
   - **Issue**: BEEF envelopes carry their own intended basket via `insertion_remittance`; `--basket=<name>` blindly overwrites this.
   - **Why it matters**: BRC-29 basket signals sender intent; silent override breaks the receiver's audit trail.
   - **Recommendation**: Make `--basket` only fill outputs where the envelope omits one. Hard-override should require `--force-basket`.

#### Recommendations
1. **Document the "native" non-conformance contract** (Priority: High, Effort: Small)
   - **What**: Add a short header to `bin/wallet --help` and module docs stating: "Native wallet vocabulary. BRC-100 conformance lives in `bin/brc100`. Do not assume spec compatibility."
   - **Why**: Prevents future contributors from "fixing" native surface to match BRC-100 quirks (the change-pool ambiguity, basket-required semantics) that this surface deliberately avoids.
   - **How**: Single paragraph in CLI module RDoc, referenced from `--help`.

2. **Tighten transmit protocol surface** (Priority: Medium, Effort: Small)
   - **What**: Add `--protocol=brc29` to `transmit` with brc29 as default; reject unknown protocols early.
   - **Why**: Future-proofs against BEEF Party or other transports without ambiguity.
   - **How**: Single OptionParser flag, validated against an allowlist in `Commands::Transmit`.

3. **Expose broadcast wire format** (Priority: Medium, Effort: Small)
   - **What**: `broadcast --format=ef|raw` with `ef` default; thread through to `dispatch_broadcast`.
   - **Why**: Operators debugging ARC vs Arcade rejection paths need this; matches the reject-axis-is-raw-vs-EF reality.
   - **How**: Plumbing flag on `Commands::Broadcast`; engine surface either accepts `format:` or selects based on target.

---

### Nadia Okafor - Security Specialist

**Perspective**: Every flag, every byte, every endpoint is hostile until proved otherwise. The wallet CLI funnels the highest-value secrets in this codebase (WIFs, DB credentials, identity keys) through the lowest-trust environment (a shell), and then parses attacker-controllable BEEF and JSON on the other side.

#### Key Observations
- WIF and DB-URL with embedded password appear directly on the command line — both end up in shell history, `ps`, and any audit log that captures argv.
- `--env=<file>` has no documented permission check or path-trust model; a world-readable `.env` is trivially exfiltrated, and a relative path can be hijacked by `cwd`.
- `receive` parses BEEF from stdin or `--file`. BEEF is a known parser-attack surface (varint blow-ups, malformed merkle proofs, nested tx graphs).
- `transmit --target=<uri>` is unconstrained egress to an attacker-supplied endpoint, with the wallet's `identity_key` attached as `sender_identity_key`. That is a deanonymisation primitive on its own.
- `--json` output and error paths are not constrained — there is no rule about what may or must not appear in `{ ... }`. Today it's an action reference; tomorrow it's a derivation suffix or a raw WIF in an exception message.

#### Strengths
1. **Engine boundary**: Business logic stays in the engine; CLI is a thin shell. Smaller code path to harden.
2. **Action-by-reference broadcast**: `broadcast_action(reference:)` keeps raw signed tx and `atomic_beef` engine-internal — CLI never holds the broadcastable bytes.
3. **Precedence is explicit**: The four-tier resolution is written down. Easier to audit than ad-hoc env lookups.
4. **Plumbing/porcelain split**: `sign` taking `--spends=<json>` separately from `build` means signing material isn't required at intent time.

#### Concerns
1. **WIF on argv** (Impact: High)
   - **Issue**: `--wif=<wif>` leaks to `~/.bash_history`, `ps auxww`, process accounting, container logs, error reports.
   - **Why it matters**: WIF is the root key; one capture is total wallet compromise.
   - **Recommendation**: Reject `--wif=` with a hard error unless `BSV_WALLET_ALLOW_WIF_ARGV=1`. Accept `--wif-stdin`, `--wif-file=<path>` (mode 0600 enforced), or `BSV_WALLET_WIF` env-only. Document the env path as primary.

2. **DB URL with embedded password** (Impact: High)
   - **Issue**: `--database-url=postgres://user:pass@host/db` puts the DB password on argv.
   - **Why it matters**: Same disclosure vectors as WIF; also allows lateral movement to other tenants on the same Postgres.
   - **Recommendation**: Require `--database-url` to omit the password (PGPASSWORD/PGPASSFILE) or reject when `userinfo` contains `:`. Document `.pgpass` as the supported path.

3. **`--env=<file>` trust model** (Impact: High)
   - **Issue**: No file-permission check, no path canonicalisation, no protection against symlink swaps; precedence note says it seeds *unset* keys but doesn't say it never overrides.
   - **Why it matters**: A world-readable env loaded from `./.env` in a shared dir is a credential drop. A malicious env file can also inject `BSV_WALLET_POSTGRES` pointing at an attacker DB.
   - **Recommendation**: `stat` the file; refuse mode & 0077, refuse non-owner, refuse symlinks unless `--env-allow-symlink`. Canonicalise via `File.realpath`. Validate keys against an allow-list (no arbitrary `LD_PRELOAD`-style injection).

4. **BEEF parser hardening on `receive`** (Impact: High)
   - **Issue**: Plan says "CLI-side parsing at the boundary" of attacker-supplied BEEF with no bounds discipline mentioned (varint caps, max txs, max merkle depth, max output count, total byte ceiling).
   - **Why it matters**: BEEF from stdin/`--file` is untrusted; resource-exhaustion and memory-blowup attacks are the default unless explicitly defended.
   - **Recommendation**: Wrap input in a `LimitedReader` with hard caps (e.g. 32 MiB, 10k tx, depth 32). Reject early; never `read` an unbounded varint length into an allocation.

5. **`transmit --target=<uri>` SSRF + identity leak** (Impact: High)
   - **Issue**: Arbitrary URI plus the wallet's `identity_key` attached as `sender_identity_key`. No scheme allow-list, no host filter (loopback, RFC1918, link-local, metadata 169.254.169.254), no TLS pinning, no per-target identity policy.
   - **Why it matters**: SSRF to cloud metadata or internal services; correlation of wallet identity across attacker endpoints; passive deanonymisation by any logging proxy.
   - **Recommendation**: Scheme allow-list (`https` only by default), block private/loopback/link-local/metadata ranges, require TLS, and gate identity attachment behind `--with-identity` (opt-in, not default). Log target host before request to aid incident review.

6. **`sign --spends=<json>` deserialisation** (Impact: Medium)
   - **Issue**: JSON parsed from argv (size-bounded by ARG_MAX but still attacker-supplied for plumbing pipelines); no schema validation called out.
   - **Why it matters**: Type-confusion (string where bytes expected, oversize hex), and JSON nesting/depth attacks.
   - **Recommendation**: Strict schema (JSON Schema or hand-rolled), `max_nesting` low, total length cap, hex fields constrained to expected lengths. Reject unknown keys.

7. **`--json` / error output leakage** (Impact: Medium)
   - **Issue**: No rule forbidding WIFs, derivation suffixes, or raw key bytes from appearing in JSON output or exception messages bubbled to stderr.
   - **Why it matters**: A stray `inspect` on a `KeyDeriver` or `Engine` instance dumps everything to the log aggregator.
   - **Recommendation**: Redaction layer in `CLI::Output.write_json` and the top-level rescue: scrub keys matching `/wif|secret|priv|derivation_(prefix|suffix)/`. Override `#inspect` on key-bearing classes to elide material. Forbid `inspect`/`to_s` of `KeyDeriver` in error paths.

#### Recommendations
1. **Secrets policy doc** (Priority: High, Effort: Small)
   - **What**: Add a "Secrets on the CLI" subsection: WIF env-only, DB password via `.pgpass`, env files mode-checked.
   - **Why**: Single source of truth so reviewers can spot drift.
   - **How**: Ship in the dispatcher PR (Phase 1) before any new bin lands.

2. **Egress allow-list for `transmit`** (Priority: High, Effort: Medium)
   - **What**: Centralise URI validation in `Transmission` or a new `Egress::Policy`.
   - **Why**: Stops SSRF and cloud-metadata exfiltration regardless of which CLI verb calls in.
   - **How**: Resolve host, reject private ranges (`Resolv` + IPAddr checks), pin scheme to https, fail closed on unknown.

3. **Parser fuzz harness for BEEF + spends JSON** (Priority: High, Effort: Medium)
   - **What**: Property/fuzz specs under `spec/security/` driving `receive` and `sign` with malformed inputs.
   - **Why**: Boundary parsers are the highest-yield attack surface; fuzzing catches what code review misses.
   - **How**: Use `rantly` or hand-rolled mutators; corpus seeded from real BEEF samples; assert "no allocation > N MiB, no runtime > N ms, no exception other than the documented set".

4. **Redaction in output + logging** (Priority: Medium, Effort: Small)
   - **What**: Single `Secrets.redact(obj)` used by `write_json`, exception handler, and walletd logging.
   - **Why**: Stops accidental disclosure across all 12 subcommands at once.
   - **How**: Allow-list of safe keys, everything else passes through a deep-walker that elides matching field names and any 32/33-byte hex.

5. **Identity-key handling in `transmit_action`** (Priority: Medium, Effort: Small)
   - **What**: Make identity attachment explicit and per-counterparty.
   - **Why**: Default-attach correlates the wallet across every endpoint the user ever transmits to.
   - **How**: Engine wrapper accepts `sender_identity_key: nil` by default; CLI requires `--with-identity` or a registered counterparty to opt in. Document the tradeoff in the help text.

---

### Viktor Petrov - Performance Expert

**Perspective**: Per-invocation CLIs are pathological for cold-start cost — every `bin/wallet` call pays full engine boot, and the plan doesn't budget for it. With a millions-TPS aspiration, the CLI must not be the layer that normalises 200-500ms startup per command or N+1 round-trips per import.

#### Key Observations
- Every subcommand boots a full Engine: DB pool warm-up, migrations check (or `Sequel::Migrator.is_current?`), Fixtures load, KeyDeriver, `@hydrator`, `@transmission` — paid on each shell invocation.
- `list outputs` / `list actions` have no documented `--limit` default; an unbounded `spendable_outputs` scan on a wallet with millions of rows is a footgun.
- `import` (root-scan) iterates `import_utxo` per UTXO — N round-trips + N action commits + potentially N broadcasts when `--no-send` is omitted.
- `broadcast_action` rehydrates `atomic_beef` via `@hydrator.build_atomic_beef(raw_tx, action_id)` per call — ancestry walk cost is unspecified and unbounded in tx-graph depth.
- Action-lookup-by-reference (in `reject`, `transmit`, `sign`, `broadcast`) needs an index on `actions.reference` (UUID column) or every CLI invocation seq-scans.

#### Strengths
1. **Engine-side lookup + rehydration in Phase 2**: Keeping `@hydrator` access engine-internal avoids the CLI re-implementing ancestry walks badly. Single point to optimise.
2. **Plumbing/porcelain split**: Power users can call `build` → `sign` → `broadcast` separately, amortising one Engine boot across stages via a long-running shell, if we choose to support it.
3. **JSON-on-`--json` only**: Human output on TTY avoids JSON serialisation cost on the hot interactive path (small win, but consistent).

#### Concerns
1. **Per-invocation Engine boot cost** (Impact: High)
   - **Issue**: DB connect + Sequel model load + Fixtures + KeyDeriver every shell call. No measurement budget stated.
   - **Why it matters**: Shell loops (`for ref in $(...); do bin/wallet broadcast $ref; done`) pay boot N times. At 200ms boot, 1000 actions = 200s of pure overhead.
   - **Recommendation**: Add a `--batch` / stdin-driven mode for `broadcast`, `sign`, `transmit` that reads references line-by-line and reuses one Engine. Document boot cost in plan as a measured number.

2. **Unbounded `list outputs` / `list actions`** (Impact: High)
   - **Issue**: No default `--limit`. `spendable_outputs` returning millions of rows hydrates them all into Ruby objects.
   - **Why it matters**: At 10x scale, `list outputs` OOMs the CLI before printing the first line; JSON encoding is O(n) on top.
   - **Recommendation**: Default `--limit=100`, require explicit `--limit=0` (or `--all`) to disable. Stream JSON output line-by-line (NDJSON) rather than building a single array.

3. **`import` N+1 broadcast** (Impact: High)
   - **Issue**: `import_wallet` iterates `import_utxo` per UTXO; if `--no-send` is omitted, each calls ARC synchronously. N UTXOs = N HTTP round-trips serial.
   - **Why it matters**: Scanning a root with 1000 UTXOs at 100ms/ARC = 100s just on broadcasts. Plan should default `--no-send` for scans and follow with one batched broadcast pass, or pipeline via `:delayed` intent.
   - **Recommendation**: Default `import` to `accept_delayed_broadcast: true` so the daemon batches; document the trade-off.

4. **`actions.reference` lookup index** (Impact: Medium)
   - **Issue**: Plan assumes `Engine::Action.find(engine:, reference:)` is cheap. Not verified an index exists on `actions.reference`.
   - **Why it matters**: Every `reject`/`transmit`/`sign`/`broadcast` does this lookup; without an index it's a full scan per CLI call.
   - **Recommendation**: Confirm unique index on `actions.reference` in `001_create_schema.rb` before Phase 2 lands; add if missing.

5. **`broadcast_action` rehydration cost unmeasured** (Impact: Medium)
   - **Issue**: `@hydrator.build_atomic_beef` walks ancestry on every CLI broadcast. No cache hint, no depth budget.
   - **Why it matters**: Deep tx graphs make this O(ancestry_depth) DB round-trips per single-action broadcast.
   - **Recommendation**: Confirm hydrator already memoises within a single Engine instance; add a `--beef-from-stdin` escape hatch for callers that have the BEEF already.

#### Recommendations
1. **Add boot-cost measurement to Phase 1 acceptance** (Priority: High, Effort: Small)
   - **What**: Capture `time bin/wallet --wallet=alice balance` on a representative DB; record in PR description.
   - **Why**: Establishes a regression baseline before the surface ossifies.
   - **How**: Add to Verification block as a numbered metric, fail review if >500ms cold.

2. **NDJSON output mode for `list`** (Priority: High, Effort: Small)
   - **What**: `--json` emits one JSON object per line; never buffer the full result.
   - **Why**: Bounded memory regardless of result-set size; pipes cleanly to `jq`/`grep`.
   - **How**: `puts JSON.generate(row)` per row in the command; document in Per-Command Sketch.

3. **Default `--limit=100` on `list`, require `--all` to disable** (Priority: High, Effort: Small)
   - **What**: Pagination as a first-class concern, not an afterthought.
   - **Why**: Protects against accidental million-row scans; matches `git log` ergonomics.
   - **How**: Add `--limit` and `--offset` to `list` sketch row; document `--all` semantics.

4. **Batch-mode subcommand for plumbing verbs** (Priority: Medium, Effort: Medium)
   - **What**: `bin/wallet broadcast --batch < refs.txt` reuses one Engine across N references.
   - **Why**: Amortises boot cost; enables shell-pipeable bulk operations without inventing a daemon protocol.
   - **How**: Reference list on stdin, one Engine boot, loop internally; output one result-line per input-line.

5. **Confirm `actions.reference` index + add EXPLAIN to plan** (Priority: Medium, Effort: Small)
   - **What**: Verify unique index exists; if not, add to `001_create_schema.rb` in Phase 2.
   - **Why**: Lookup-by-reference is on the hot path of four commands.
   - **How**: `\d actions` on a dev DB, add `unique: true` index migration if missing.

---

### Aisha Rahman - Maintainability Expert

**Perspective**: A newcomer needs to navigate twelve sibling command classes, three new engine methods, and a half-rewritten spec tree mid-flight. The plan's bones are good — what's missing is a stated shape for the family so the twelfth class looks like the first.

#### Key Observations
- 12 command classes share no documented contract beyond "owns its own OptionParser, calls engine, prints output" — the boilerplate-per-class footprint is the dominant maintainability risk
- Three engine surface additions (`broadcast_action`, `transmit_action`, `import_wallet basket:`) are scattered across phases 2/3/5, each with its own justification but no shared "engine wrapper template"
- Test architecture splits cleanly (unit-stubbed vs e2e-subprocess) but Phase 6 lands AFTER deletions in Phases 1+5, leaving a multi-PR window with sparse CLI coverage
- Blank-slate deletion is correct per replace-not-adapt but the plan doesn't enumerate what porcelain consumers (scripts, README snippets, integration docs) need to migrate
- `list` is the only verb taking a noun argument — an inconsistency worth either embracing as a pattern or eliminating

#### Strengths
1. **Clear porcelain/plumbing/operational taxonomy**: The 6/4/2 split gives a reader an immediate mental model of why each command exists.
2. **Engine wrapper rationale is explicit**: Each new engine method states *why* it's not CLI-side (hydrator is engine-internal, etc.) — future maintainers won't relitigate.
3. **Spec layering is honest**: Unit specs at `spec/bin/wallet/<command>_spec.rb` mirror command structure 1:1; e2e shape spec is named as the single subprocess-driven test.
4. **Phasing acknowledges dependency order**: 1–2 parallel, 3–5 sequential, 6 closes spec rewrite — reviewable in isolation.
5. **Decisions section captures rationale at decision-time** — exactly what survives compaction.

#### Concerns
1. **No `Commands::Base` contract spec** (Impact: High)
   - **Issue**: 12 sibling classes with implicit conventions drift.
   - **Why it matters**: Class #12 author won't know whether to raise, exit, write to stderr, return a struct.
   - **Recommendation**: Add a "Commands::Base contract" subsection — `call(ctx, args) -> Integer` exit code, where output goes, error-handling protocol, OptionParser banner convention. One screen, settles a dozen micro-decisions.

2. **Phase 6 spec rewrite lags 5 phases of deletions** (Impact: High)
   - **Issue**: Phases 1 and 5 delete bins; Phase 6 lands replacement specs. PRs 1–5 ship with degraded CLI coverage.
   - **Why it matters**: A regression introduced in Phase 3 may not surface until Phase 6 rewrites the e2e.
   - **Recommendation**: Land minimal unit spec per command IN THE SAME PR as the command (Phase 1 adds `balance_spec.rb` + `list_spec.rb`). Keep Phase 6 for the e2e rewrite only.

3. **`list <noun>` inconsistency** (Impact: Medium)
   - **Issue**: Only verb with a positional sub-noun; every other command is verb-only.
   - **Why it matters**: Dispatcher router gains a special case; help text becomes inconsistent.
   - **Recommendation**: Either flatten to `list-outputs`/`list-actions` (verb-only family) or document the noun pattern as extensible (future `list utxos`, `list baskets`).

4. **Engine surface additions aren't grouped** (Impact: Medium)
   - **Issue**: Three engine methods land in three PRs with three rationales — easy to miss as a coherent surface change.
   - **Recommendation**: A short "Engine surface delta" section listing all three methods + their shared shape (`*_action(reference:, ...)`) so a future reader sees the family.

#### Recommendations
1. **Document Commands::Base contract upfront** (Priority: High, Effort: Small) — One subsection in the plan, ~20 lines. Codifies exit codes, stderr/stdout, error handling. Pays back across 12 implementations.
2. **Co-locate command and spec per PR** (Priority: High, Effort: Small) — Move per-command unit specs out of Phase 6 into the phase that introduces each command. Phase 6 keeps only the e2e rewrite.
3. **Decide `list` shape now** (Priority: Medium, Effort: Small) — Either `list-outputs` (consistent) or document `list <noun>` as the extension point. Don't leave it as the one odd verb.
4. **Add migration checklist for deletions** (Priority: Medium, Effort: Small) — Brief enumeration of README/docs/scripts that reference deleted bins, addressed per phase. Prevents stale doc drift.
5. **Group engine surface additions** (Priority: Low, Effort: Small) — Single subsection listing the three new `*_action` methods together, even though they land in different phases. Helps reviewers see the surface as one decision.

---

### Sam Oduya - Pragmatic Enforcer

**Perspective**: The plan does some things right (deferring lock, registry, ABI) but smuggles in three engine surface additions and a per-command class hierarchy that aren't justified by the problem at hand: deleting 16 standalone bins behind a dispatcher. The plumbing layer is the prime suspect — half of it exists to round out a Git-style metaphor, not to deliver demand.

#### Key Observations
- Six phases for ~12 small commands across one binary is high merge overhead for a solo+AI workflow that's already doing build-and-adjust.
- Three engine additions (`broadcast_action`, `transmit_action`, `import_wallet(basket:)`) bake into the engine to keep "CLI hygiene" — the dispatcher is generating demand on the engine, not vice versa.
- The plumbing quartet (`build/sign/broadcast/transmit`) is justified by Git-style symmetry, not by a concrete user story. `transmit_spec.rb` already proves the porcelain `send` path; nothing in scope requires the unsigned-park flow.
- Per-command unit specs *and* an e2e shape spec overlap heavily — argv parsing failures will show up in either.
- 12 `Commands::<Verb>` classes for what are mostly 10-line arg-to-engine-call shims is ceremony.

#### Strengths
1. **Genuine YAGNI deferrals**: Lock, recipient registry, BRC-100 transport, ABI streaming all properly punted to follow-ups.
2. **Replace-not-adapt discipline**: Old bins and their specs are deleted in the same PRs, not migrated — consistent with `feedback_replace_not_adapt`.
3. **Boundary conversions kept CLI-side**: BEEF parsing, reference→action_id lookup for `reject` stay in the CLI rather than colonising the engine.

#### Concerns
1. **Plumbing layer is speculative** (Impact: High)
   - **Issue**: `build`/`sign` exist to support a deferred-signing workflow no in-scope command uses. `broadcast`/`transmit` as standalone verbs require new engine wrappers that wouldn't otherwise exist.
   - **Why it matters**: Two of the three engine surface additions exist *only* because plumbing exists. Cut plumbing and the engine churn shrinks to one method (`import_wallet(basket:)`).
   - **Recommendation**: Defer plumbing to a follow-up HLR. Ship porcelain + operational (8 commands) in v1.

2. **Six phases is fragmentation, not safety** (Impact: Medium)
   - **Issue**: Phase 2 is a single engine method addition. Phase 6 is "spec rewrite." That's two PRs that each do one thing.
   - **Why it matters**: Merge overhead, review fatigue, and stale-branch rebasing cost outweigh the per-PR safety for a solo dev.
   - **Recommendation**: Collapse to three phases: (1) dispatcher + balance/list + delete old bins, (2) all remaining commands, (3) specs. If plumbing is cut, two phases.

3. **`engine.transmit_action` wrapper is paving the CLI's cowpath** (Impact: Medium)
   - **Issue**: The wrapper exists *because* the CLI verb exists. Without `transmit` as a plumbing verb, there's no caller.
   - **Recommendation**: Drop the verb, drop the wrapper. `send --transmit=inline` covers the porcelain case.

4. **Per-command unit specs + e2e overlap** (Impact: Low)
   - **Issue**: Unit specs stub the engine and assert argv parsing; the e2e shape spec exercises the same parsing live.
   - **Recommendation**: Skip per-command unit specs initially. Lean on the e2e shape spec + a single dispatcher-level spec for global-flag parsing.

5. **12 `Commands::<Verb>` classes is over-structured** (Impact: Low)
   - **Issue**: Most commands are ~10 lines. A class hierarchy with a `Base` abstract is overkill.
   - **Recommendation**: Try a single-file `case` dispatch with method-per-command. Promote to classes only when one grows past ~30 lines.

6. **`--env=<file>` seed mechanism** (Impact: Low)
   - **Issue**: Reinvents dotenv for a tool whose primary callers already export env vars (zshenv, CI secrets).
   - **Recommendation**: Cut. Users who need it can `set -a; source .env; set +a` before the call.

#### Recommendations
1. **Cut plumbing from v1** (Priority: High, Effort: Small)
   - **What**: Drop `build`/`sign`/`broadcast`/`transmit`. Ship 6 porcelain + 2 operational.
   - **Why**: Removes 2 of 3 engine surface additions; shrinks the diff; aligns with "solve the problem at hand."
   - **How**: Move to "Follow-up Issues" with a note: revisit when a concrete unsigned-park use case appears.

2. **Collapse phases** (Priority: High, Effort: Small)
   - **What**: Three phases: dispatcher+balance/list, remaining commands, specs.
   - **Why**: Halves merge ceremony.

3. **Start with method dispatch, not classes** (Priority: Medium, Effort: Small)
   - **What**: `Dispatcher#call` with a `case` over command names, methods inline.
   - **Why**: Lets the structure emerge from actual size, not anticipated size.

4. **Cut `--env=<file>`** (Priority: Low, Effort: Trivial)
   - **What**: Remove the seed mechanism.
   - **Why**: Speculative for current callers.

5. **Single spec layer** (Priority: Medium, Effort: Small)
   - **What**: One dispatcher unit spec for global flags + the rewritten `transmit_spec.rb` e2e.
   - **Why**: Tests the moving target once, not twice.

---

### Marcus Johnson - Ruby Expert

**Perspective**: The plan is structurally sound but underspecifies the Ruby-side mechanics — OptionParser conventions, dispatch shape, exit semantics, and stdin discipline. The class-per-verb layout is idiomatic; the gaps are in *how* each class is built and registered.

#### Key Observations
- Twelve `CLI::Commands::<Verb>` classes with a `Base` abstract and per-command `OptionParser` — classic, idiomatic, but registration mechanism is unspecified.
- `GlobalOptions` is called a "struct/dataclass" — undecided between `Struct`, `Data`, plain class, or `Hash`. Materially affects mutability and call sites.
- BEEF on stdin/file is binary; the plan doesn't mention `binmode`. On macOS it'll silently work, on Windows-ish IO it won't.
- Error handling is described as "non-zero exit" with "structured stderr" but no exception hierarchy is named.
- No mention of `frozen_string_literal: true` or how the new classes align with the existing RuboCop config (the rebuild has explicit RuboCop discipline elsewhere).

#### Strengths
1. **Class-per-verb over case/when**: One class per command scales for unit-testing in isolation and matches the `spec/bin/wallet/<command>_spec.rb` layout.
2. **`CLI::Commands::Base` as shared surface**: Centralising `call(ctx, args)`, banner, output helpers prevents the per-script drift that plagued the old `bin/*` scripts.
3. **`parse_global_options` distinct from `extract_wallet_name`**: Preserves `bin/walletd`'s positional-first contract without overloading one parser with two grammars.
4. **JSON flattening at the boundary**: Unwrapping `{ signable: {...} }` at the CLI is the right place — internal disambiguation shouldn't leak to shell consumers.

#### Concerns
1. **`GlobalOptions` shape unspecified** (Impact: Medium)
   - **Issue**: "Struct/dataclass" punts on the choice between `Struct.new`, Ruby 3.2 `Data.define`, or plain class.
   - **Why it matters**: `Data` gives immutability + keyword init + pattern-matching for free and is the modern idiom on Ruby 3.x. `Struct` invites accidental mutation. Plain class is verbose.
   - **Recommendation**: Use `Data.define(:wallet_name, :network, :json, :wif_override, :database_url_override, :env_file)`. Immutable, keyword-constructible, deconstructs in `case/in`.

2. **stdin handling for BEEF doesn't mention `binmode`** (Impact: High)
   - **Issue**: `receive` reads BEEF bytes from `$stdin` or `--file=<path>`. Default mode is text/UTF-8.
   - **Why it matters**: BEEF is raw bytes; a stray `\r\n` translation or invalid-UTF-8 error will corrupt the envelope silently or crash on import.
   - **Recommendation**: `$stdin.binmode; $stdin.read` and `File.binread(path)`. Document in `Commands::Base` as a helper (`read_binary_input(file:)`).

3. **Dispatch mechanism unstated** (Impact: Medium)
   - **Issue**: 12 classes, but no word on how `Dispatcher` maps `"send"` → `Commands::Send`.
   - **Why it matters**: `case/when` is brittle; `const_get` is magic. A registry hash (`COMMANDS = { 'send' => Send, ... }.freeze`) in `Dispatcher` is explicit, greppable, and avoids autoload races.
   - **Recommendation**: Frozen hash registry, populated at file load via explicit `require` of each command. Unknown command → structured exit with `available commands: ...`.

4. **Exit-code convention unnamed** (Impact: Medium)
   - **Issue**: "Non-zero exit" without a scheme. `abort` vs `raise` vs `exit N` have different ergonomics.
   - **Why it matters**: Shell pipelines distinguish `2` (usage), `1` (runtime), `>2` (domain). Without a convention, every command picks its own.
   - **Recommendation**: Define `CLI::Error` hierarchy (`UsageError` → exit 2, `EngineError` → exit 1, `NotRejectableError` → exit 3). `Dispatcher` rescues at the top and translates to exit codes — no `abort` inside commands.

5. **`OptionParser` discipline unspecified** (Impact: Low)
   - **Issue**: Plan says "each command owns its OptionParser" but not `parse` vs `parse!`, banner format, or how `--help` per command works.
   - **Why it matters**: `parse!` mutates ARGV (fine here) but `parse` keeps it intact (better for testing). Per-command `--help` should print the command's banner, not the global one.
   - **Recommendation**: Use `parse!(args)` on a local copy; banner is `"Usage: bin/wallet #{name} [options] <args>"`. `Base#help` prints `@parser.help`.

#### Recommendations
1. **Adopt `Data.define` for `GlobalOptions`** (Priority: High, Effort: Small)
   - **What**: `GlobalOptions = Data.define(:wallet_name, :network, :json, :wif_override, :database_url_override, :env_file)`.
   - **Why**: Immutable, keyword init, pattern-matchable, zero boilerplate. Reads as a value object, which is what it is.
   - **How**: Declare in `cli/global_options.rb`; `parse_global_options` returns `[GlobalOptions.new(...), remaining_argv]`.

2. **Frozen hash registry for command dispatch** (Priority: High, Effort: Small)
   - **What**: `Dispatcher::COMMANDS = { 'balance' => Commands::Balance, ... }.freeze`.
   - **Why**: Explicit, greppable, no autoload surprises, easy to spec (`expect(Dispatcher::COMMANDS).to include('send')`).
   - **How**: Top of `dispatcher.rb`, after requires. Unknown command → `raise UsageError, "unknown command: #{name}"`.

3. **`Base` as abstract class with `binmode` + JSON helpers** (Priority: High, Effort: Small)
   - **What**: `Commands::Base` provides `read_binary_input(file:)`, `emit_json(payload)`, `parser` (memoised), `call(ctx, args)` raising `NotImplementedError`.
   - **Why**: Concentrates the binary-stdin and JSON-output discipline in one place; subclasses can't forget `binmode`.
   - **How**: Plain class (not module — commands aren't mixed in, they inherit). `frozen_string_literal: true` at the top of every file.

4. **`CLI::Error` hierarchy + top-level rescue in `Dispatcher`** (Priority: Medium, Effort: Small)
   - **What**: `class Error < StandardError; end`, `UsageError`, `EngineError`, `NotRejectableError` each carrying an `exit_code`.
   - **Why**: Commands `raise`, dispatcher translates. Testable (`expect { ... }.to raise_error(UsageError)`) without `Kernel#exit` mocking.
   - **How**: `Dispatcher.call` wraps in `rescue CLI::Error => e; warn e.message; exit e.exit_code; end`.

5. **RuboCop alignment + `frozen_string_literal` from day one** (Priority: Medium, Effort: Small)
   - **What**: Every new file starts with `# frozen_string_literal: true`. Run `bundle exec rubocop lib/bsv/wallet/cli/` after each phase.
   - **Why**: The wallet has explicit RuboCop discipline; adding 13+ new files without it builds technical debt that's painful to retrofit.
   - **How**: Add to Phase 1 checklist. If any cop fires that can't be cleanly satisfied, surface it in the PR rather than mass-disabling.

---

### Dr. Lin Wei - Database Architect

**Perspective**: The plan is read-shape sound — no schema changes is the correct call — but several new read patterns deserve explicit index assertions before they ossify into hot paths.

#### Key Observations
- Action lookup by `reference` is introduced as a CLI primitive in three commands (`reject`, `broadcast`, `transmit`). `actions.reference` is a native `uuid` column with a UNIQUE constraint already, so the lookup is index-backed and O(log n).
- BEEF rehydration reads `actions.raw_tx` (bytea) for a single row already located by `action_id` — a covered single-row fetch, no read amplification.
- `import_wallet` iterates `import_utxo` per row; the plan does not state where the transaction boundary sits.
- `list actions` is label-required by engine contract — DB cost depends on the join shape across `actions`/`action_labels`/`labels`, which the plan does not name.
- `list outputs` pagination uses engine `spendable_outputs`; the plan inherits whatever pagination cost model already exists without re-examining it.

#### Strengths
1. **Reference lookup is constraint-aligned**: `actions.reference UNIQUE` already exists; `Engine::Action.find(reference:)` is a single-row equality probe on a uuid B-tree — no new index needed.
2. **No schema churn during a CLI refactor**: holding the schema still while the surface moves is the right discipline — avoids conflating CLI-shape decisions with state-model decisions.
3. **Rehydration kept engine-side**: `@hydrator.build_atomic_beef(raw_tx, action_id)` keeps the BEEF graph walk inside one logical unit — the CLI can't accidentally issue a chatty per-ancestor query loop.

#### Concerns
1. **`import_wallet` transaction boundary unspecified** (Impact: Medium)
   - **Issue**: Phase 5 forwards `basket:` through a per-row `import_utxo` loop; the plan doesn't say whether each iteration is its own DB transaction or whether the whole scan is one.
   - **Why it matters**: Per-row transactions on a large scan multiply commit cost; one-big-transaction risks long-held locks and bloats WAL.
   - **Recommendation**: State explicitly that `import_utxo` is the atomic unit (per-row `db.transaction`), and the scan is a loop of independent units — matches principle-of-state's "atomic transition" framing.

2. **`list actions --label` index coverage unverified** (Impact: Medium)
   - **Issue**: The plan asserts label-required but doesn't confirm the join path (`labels.label = ?` → `action_labels.label_id` → `actions`) has the composite index needed to avoid a labels-side seq scan at scale.
   - **Why it matters**: At 100k+ actions a missing `action_labels(label_id, action_id)` index turns a porcelain command into a table scan.
   - **Recommendation**: Verify `001_create_schema.rb` carries `action_labels(label_id, action_id)` and `labels(label) UNIQUE`; if absent, fold into the same PR (still pre-release, schema lives in 001). (Note: `labels_label_unique` is already present in the current schema; the composite still needs verification.)

3. **Pagination cost at high `--limit`** (Impact: Low)
   - **Issue**: `list outputs --limit=N` with no stated ceiling — engine's `spendable_outputs` may materialise all rows before slicing.
   - **Why it matters**: A power-user `--limit=100000` is a footgun if the engine doesn't `LIMIT` at the SQL boundary.
   - **Recommendation**: Cap CLI `--limit` at a sane default (1000) and confirm engine pushes `LIMIT` into the query, not Ruby-side.

#### Recommendations
1. **Document the index map in the plan** (Priority: Medium, Effort: Small)
   - **What**: Add a short "DB access patterns" subsection naming the index each new lookup relies on.
   - **Why**: Makes the no-schema-changes claim auditable; future readers see the assertion, not just the absence.
   - **How**: One-paragraph table: command → query shape → index used.

2. **Pin `import_wallet` atomicity contract** (Priority: Medium, Effort: Small)
   - **What**: State that each `import_utxo` call is one `db.transaction`; the scan is N independent transitions.
   - **Why**: Aligns with principle-of-state and prevents a future "wrap the whole scan" regression.
   - **How**: One line in the Phase 5 section.

3. **Add a `list` ceiling + ORDER BY note** (Priority: Low, Effort: Small)
   - **What**: Cap `--limit` and require a deterministic ORDER BY (e.g. `actions.created_at DESC, id DESC`) for stable pagination.
   - **Why**: Without ORDER BY, paged results drift; without a cap, an operator can DoS their own wallet.
   - **How**: Note in the per-command sketch for `list`.

---

### Dr. Kenji Nakamura - Cryptography Reviewer

**Perspective**: A CLI plan has a thin crypto surface, but every boundary where keys or BEEF cross from string into binary is a potential foothold for misuse. My focus is on the four places this plan touches secret/identity material: `--wif`, `--counterparty`, `transmit_action`'s identity-key read, and BEEF ingress on `receive`.

#### Key Observations
- `--wif=<wif>` exposes a raw private key on the command line — visible in `ps`, shell history, and parent process env scans.
- `transmit_action` correctly reads `sender_identity_key` from `key_deriver.identity_key` (hex per convention), keeping the BRC-29 carve-out intact.
- `--counterparty=<key>` and `sweep --to=<root_key_hex>` ingest hex pubkeys at the CLI boundary but the plan does not specify validation (length, parity byte, on-curve check).
- BEEF parsing happens CLI-side for `receive`, extracting per-output `derivation_prefix` / `derivation_suffix` / `sender_identity_key` — a non-trivial binary parse run before the engine sees anything.

#### Strengths
1. **Identity-key convention preserved**: `transmit_action` reads `key_deriver.identity_key` (hex, 66-char compressed) directly — no round-trip through `[hex].pack('H*')`, honouring the identity-hex / derived-binary split.
2. **Hex/binary boundaries are clearly named**: `--to=<root_key_hex>` and `atomic_beef: "<hex>"` flatten at the CLI; engine internals stay binary. The plan resists the temptation to surface derived keys as hex.

#### Concerns
1. **`--wif=<wif>` on the command line** (Impact: High)
   - **Issue**: Private key visible to anyone who can `ps auxe`, in shell history (`~/.zsh_history`), and in container/process inspection.
   - **Why it matters**: WIF is the entire wallet. One leak = total compromise. No amount of downstream crypto correctness recovers from this.
   - **Recommendation**: Document `--wif` as test/dev-only; for real use, prefer `--wif-file=<path>` or `WIF=<…> bin/wallet …` (env-only). Refuse `--wif` on a TTY without `--allow-insecure-wif`.

2. **No stated validation for `--counterparty` / `--to` hex pubkeys** (Impact: Medium)
   - **Issue**: Plan accepts hex pubkeys at the boundary but doesn't say where they're validated (length 66, prefix `02`/`03`, on-curve).
   - **Why it matters**: A malformed counterparty silently produces an unrecoverable BRC-42 derivation; a non-curve point in `sweep --to` produces an unspendable output. Failures surface late, far from the CLI.
   - **Recommendation**: Validate at the CLI boundary in `Commands::Base` — reject with clear stderr before the engine sees it. One `PublicKey.parse` call per ingest point.

3. **BEEF parser robustness on `receive`** (Impact: Medium)
   - **Issue**: CLI-side BEEF parsing extracts `output_index`, `derivation_prefix`, `derivation_suffix`, `sender_identity_key` per output, then hands them to `import_beef`. Malformed/oversized BEEF, mismatched output counts, or duplicated indices aren't called out.
   - **Why it matters**: An attacker-supplied envelope can drive the parser into pathological states before engine invariants apply.
   - **Recommendation**: Defer parsing to the SDK's BEEF parser (single source of truth) and size-cap `--file` ingest. Don't write a bespoke parser in `Commands::Receive`.

#### Recommendations
1. **Add CLI-boundary key validation helper** (Priority: High, Effort: Small)
   - **What**: `CLI::Commands::Base#parse_pubkey_hex(str)` returning a validated `PublicKey` or failing with a structured error.
   - **Why**: Centralises the hex→curve check; prevents three implementations drifting across `transmit`, `sweep`, and any future verb taking a pubkey.
   - **How**: Wrap `BSV::PublicKey.from_hex` (or equivalent), catch parse errors, emit `error: invalid public key` on stderr with non-zero exit.

2. **Treat `--wif` as a hostile surface** (Priority: High, Effort: Small)
   - **What**: Refuse `--wif` unless stdin is non-TTY *or* `--allow-insecure-wif` is set; prefer `--wif-file=<path>` (mode-checked 0600).
   - **Why**: Mirrors `ssh-keygen`/`gpg` conventions; closes the "I just pasted my WIF into a Slack screenshot" failure mode.
   - **How**: Add the check to `parse_global_options` so every command inherits it.

3. **Pin BEEF parsing to the SDK with explicit byte caps** (Priority: Medium, Effort: Small)
   - **What**: In `Commands::Receive`, cap `--file` at a documented byte limit and delegate parsing to `BSV::Transaction::Beef.parse` rather than ad-hoc CLI code.
   - **Why**: One BEEF parser, audited once; the CLI doesn't become a second-source attack surface for envelope handling.
   - **How**: Read bytes with a size guard, hand to SDK, let exceptions surface as structured CLI errors.

---

## Collaborative Discussion

**Opening Context**: Nine perspectives reviewed a 200-line markdown plan that defines a CLI dispatcher for the wallet. The plan is post-merge after three rounds of Copilot accuracy review, so the discussion focuses on architectural shape rather than line-level corrections.

**Elena Vasquez (Systems Architect)**: "The three engine surface additions are the most consequential decisions here. They permanently couple CLI-layer identifiers (UUID references) into engine method signatures. Once `broadcast_action(reference:)` is the public surface, the next non-CLI caller has to choose between calling it or duplicating the lookup."

**Sam Oduya (Pragmatic Enforcer)**: "Two of those three additions exist only because the plumbing layer exists. `broadcast_action` and `transmit_action` are CLI cowpaths paved into engine. Cut the plumbing layer and you cut two-thirds of the engine churn — and the plumbing is justified by Git-style symmetry, not a concrete user story."

**James Thornton (BSV Domain Expert)**: "I'd push back on cutting `transmit`. The transmit/broadcast distinction is a load-bearing BSV protocol concept (ADR-025, HLR #385). Even if no operator types `bin/wallet transmit` today, having the verb in the vocabulary reinforces the distinction for the operators who do think in shell. The plumbing classes aren't pure ceremony — they document the action lifecycle in shell verbs."

**Aisha Rahman (Maintainability Expert)**: "And there's a maintainability cost on Sam's side too. Twelve sibling classes without a documented `Commands::Base` contract drift. The newcomer who writes class #12 has to reverse-engineer how class #1 handled exit codes, stderr, binmode. Class-per-verb is fine — but only with a contract."

**Marcus Johnson (Ruby Expert)**: "Agreed. The contract is the cheap insurance: a `CLI::Error` hierarchy, `Data.define` for `GlobalOptions`, a frozen hash registry for dispatch, `binmode` discipline centralised in `Base#read_binary_input`. None of this is speculative — every one is a present-day correctness or testability win."

**Nadia Okafor (Security Specialist)**: "Before any of this, the secrets policy. `--wif=` and `--database-url=postgres://user:pass@host/db` both leak to shell history, `ps`, and process accounting. That's a one-incident-and-the-wallet-is-gone failure mode. Env-only WIF (or `--wif-file=<path>` mode-checked), `.pgpass` for the DB. Pin it in the plan as a 'Secrets on the CLI' subsection — single source of truth before Phase 1."

**Kenji Nakamura (Cryptography Reviewer)**: "Same conclusion from the crypto angle. WIF on argv is the highest-impact issue in the plan. I'd add boundary validation for hex pubkeys (`--counterparty`, `--to=<root_key_hex>`) in `Commands::Base` so failures surface at parse time, not deep in BRC-42 derivation."

**Viktor Petrov (Performance Expert)**: "Performance concerns are mostly latent — they bite at 10x scale rather than today — but two are worth pinning. List commands need a default `--limit` (currently unbounded). `import` defaults to inline broadcast which N+1s on root scans. Both are flag-level changes."

**Lin Wei (Database Architect)**: "Schema-stable is the right call; no migrations in this plan. But the `actions.reference` lookup is on the hot path for four commands. Confirm the unique index exists in `001_create_schema.rb` before Phase 2. And state the `import_wallet` transaction boundary — per-row `import_utxo` as atomic, not the whole scan."

**Elena (synthesising)**: "Three converging themes: (1) **Pin `Commands::Base` contract upfront** — Aisha, Marcus, and I all want this. Cheapest insurance. (2) **Secrets policy as a subsection** — Nadia and Kenji both call it out as the highest-impact gap. (3) **Per-command specs in their introducing phase** — Aisha and I agree the Phase 6 spec lag is a five-PR coverage gap with a near-zero-cost fix. Sam's plumbing-cut is a real debate but a minority position; we should record it and let Simon decide rather than pretend consensus."

### Common Ground

The team agrees on:
1. **`Commands::Base` contract — pin upfront, not discover class-by-class.** Includes exit-code hierarchy (`CLI::Error` → `UsageError`/`EngineError`/`NotRejectableError`), JSON-on-stdout / human-on-stderr discipline, `binmode` for binary stdin, `Data.define` for `GlobalOptions`, frozen hash registry for dispatch.
2. **Secrets-on-the-CLI policy as a Phase 1 deliverable.** WIF env-only or `--wif-file=<path>` (mode-checked); DB password via `.pgpass` not embedded in `--database-url`; `--env=<file>` permission-checked.
3. **Per-command unit specs co-locate with the phase that introduces the command.** Phase 6 keeps only the e2e rewrite. Five-PR coverage gap closed.
4. **No schema changes is correct** but document the index map (`actions.reference` UNIQUE, `action_labels(label_id, action_id)`) and pin `import_wallet`'s per-row atomicity contract.
5. **CLI-boundary validation for hex pubkeys** (`--counterparty`, `--to=<root_key_hex>`) before the engine sees them.
6. **Default `--limit` on `list` commands** with NDJSON streaming output; pagination as a first-class concern not afterthought.
7. **BEEF parsing delegated to the SDK** with explicit byte caps in `Commands::Receive`; no bespoke parser in the CLI.

### Areas of Debate

**Topic: Cut the plumbing layer (`build`/`sign`/`broadcast`/`transmit`)?**
- **Sam Oduya**: Plumbing is speculative — no in-scope user story requires the unsigned-park flow. Cutting it eliminates two of three engine surface additions and the engine churn that comes with them. Solo+AI workflow doesn't benefit from Git-style metaphor symmetry.
- **James Thornton**: The transmit/broadcast verb-level distinction reinforces a load-bearing BSV protocol concept (ADR-025). Even with no operator caller today, the vocabulary itself is the product. `transmit_action` engine wrapper is documentation as much as code.
- **Elena Vasquez**: The plumbing verbs map 1:1 onto the action lifecycle. Once shipped, they become a public reflection of engine state machine. Worth shipping IF that's the desired API surface — but Simon should explicitly confirm rather than ride momentum.
- **Resolution**: Recorded as a deliberate decision point for Simon. The team's split (1 cut, 2 keep, rest neutral) suggests neither path is wrong; the decision rests on whether the verb-level distinction is intended as a public API or just plumbing-grade convenience. If kept, both engine wrappers are justified; if cut, the engine churn shrinks meaningfully.

**Topic: Collapse six phases to three?**
- **Sam Oduya**: Phase 2 is one engine method addition. Phase 6 is "spec rewrite." Both are single-purpose PRs; merge overhead exceeds review-safety benefit for a solo dev.
- **Aisha Rahman**: Phase boundaries are also reviewability boundaries. Smaller phases get more careful review. Trade-off, not a clear win.
- **Resolution**: Tied to the plumbing decision. If plumbing is cut, Phase 3 vanishes and the collapse is natural (four phases: dispatcher+balance/list, send/receive, import/reject + operational, specs). If plumbing is kept, the current six-phase shape is justified by the dependency chain.

**Topic: Per-command unit specs at all?**
- **Sam Oduya**: Unit specs stub the engine and re-assert what the e2e spec exercises live. Overlap.
- **Aisha Rahman**: Unit specs catch argv-parsing regressions in seconds; e2e takes minutes and only covers happy-path. Different test layers, different failure modes.
- **Elena Vasquez**: Unit-level coverage is the standard. Skipping it is a Pragmatic outlier.
- **Resolution**: Keep per-command unit specs. Recorded as the team's majority position.

### Priorities Established

**Critical (Address Immediately — before Phase 1 starts)**:
1. **Secrets-on-the-CLI policy subsection** — pins WIF and DB-credential handling before any new code lands.
2. **`Commands::Base` contract subsection** — exit-code hierarchy, output channels, binmode discipline, `Data.define` for `GlobalOptions`, frozen hash registry for dispatch.
3. **Decision: keep or cut plumbing layer** — Simon's call. Affects engine surface additions count and phase shape downstream.

**Important (Address Soon — within Phase 1)**:
4. **Per-command unit specs co-located with each phase.** Phase 6 keeps only the e2e rewrite.
5. **Surface allocation rule between `bin/wallet` and `bin/brc100`.** One paragraph in the plan + `docs/reference/core-vs-conformance.md`.
6. **CLI-boundary pubkey validation** in `Commands::Base` for `--counterparty` and `--to=<root_key_hex>`.
7. **List default `--limit`** with NDJSON streaming output; `--all` as explicit opt-out.
8. **`import` defaults to delayed broadcast** to avoid N+1 ARC round-trips on root scans.

**Nice-to-Have (Consider During Phases 2–5)**:
9. **Index map documentation** in the plan; verify `actions.reference` UNIQUE and `action_labels(label_id, action_id)` composite indices exist.
10. **`import_wallet` transaction boundary** stated explicitly (per-row atomic, not whole-scan).
11. **Boot-cost measurement** added to Phase 1 verification block; establish baseline before surface ossifies.
12. **`list` shape decision**: `list <noun>` extensible or flatten to `list-outputs`/`list-actions`.
13. **`broadcast --format=ef|raw`** plumbing flag for operator debugging.
14. **`--counterparty=self|anyone|<hex>`** documented per BRC-43.
15. **Redaction layer** in `CLI::Output.write_json` and top-level rescue.
16. **Egress allow-list for `transmit`** (SSRF prevention).
17. **Parser fuzz harness** for BEEF and spends JSON under `spec/security/`.
18. **ADR for the porcelain/plumbing/operational taxonomy.**

---

## Consolidated Findings

### Strengths

1. **Replace-not-adapt discipline**: Blank-slate deletion of 16 bins + CLI-coupled specs is consistent with the project's stated principle. Sets up the rebuild cleanly.

2. **Engine surface additions are honestly scoped**: Each new engine method (`broadcast_action`, `transmit_action`, `import_wallet basket:`) carries an explicit rationale for why it's not CLI-side. No hidden engine work.

3. **Transmit/broadcast domain distinction held**: Phase 3 keeps `transmit_action` and `broadcast_action` as separate engine verbs, honouring HLR #385 / ADR-025. The BSV protocol distinction survives the CLI rewrite.

4. **Identity-key carve-out preserved**: `transmit_action` reads `key_deriver.identity_key` (hex per convention) rather than round-tripping bytes. Pubkey hex exception held.

5. **Boundary discipline on BEEF parsing**: `receive` parses BEEF at the CLI boundary; engine receives structured data. Matches binary-internal/hex-at-boundary principle.

6. **No-invalid-state invariant honoured**: `reject` decision states pending-only with structured failure on non-rejectable actions. Failure leaves state valid, not half-state.

7. **Decisions captured at decision-time**: Plan's "Decisions" subsection records rationale that survives compaction. Exactly the discipline `feedback_capture_rationale_at_decision_time` requires.

### Areas for Improvement

1. **`Commands::Base` contract spec**
   - **Current state**: 12 sibling classes with implicit conventions for exit codes, output channels, error handling, binmode.
   - **Desired state**: Documented contract — `CLI::Error` hierarchy, `call(ctx, args) → Integer` exit code, JSON-on-stdout / human-on-stderr, `binmode` discipline centralised in `Base#read_binary_input`, `Data.define` for `GlobalOptions`, frozen hash registry for dispatch.
   - **Gap**: Contract is implied, not specified. Class #12 author drifts.
   - **Priority**: High
   - **Impact**: Determines whether 12 classes look like a family or twelve idiosyncratic individuals.

2. **Secrets-on-the-CLI policy**
   - **Current state**: `--wif=<wif>` and `--database-url=postgres://user:pass@host/db` accept secrets on argv. `--env=<file>` has no permission check.
   - **Desired state**: WIF env-only (or `--wif-file=<path>` mode-checked 0600); DB password via `.pgpass` (reject `userinfo` containing `:` on `--database-url`); `--env=<file>` mode-checked, owner-checked, symlink-aware.
   - **Gap**: Plan introduces secret-bearing flags without a policy for handling them safely.
   - **Priority**: High
   - **Impact**: One shell-history capture is total wallet compromise.

3. **Per-command spec coverage gap**
   - **Current state**: Phase 1 + 5 delete old bins + specs; Phase 6 lands replacement unit specs. Five PRs ship between deletion and replacement.
   - **Desired state**: Per-command unit spec lands in the same PR as the command. Phase 6 keeps only the e2e rewrite.
   - **Gap**: Five-PR coverage hole at near-zero-cost fix.
   - **Priority**: High
   - **Impact**: Argv-parsing regressions in Phases 3–5 don't surface until Phase 6.

4. **Surface allocation rule between `bin/wallet` and `bin/brc100`**
   - **Current state**: Sibling status asserted; allocation rule for new engine methods not stated.
   - **Desired state**: One paragraph stating "`bin/brc100` exposes only `Interface::BRC100` methods; `bin/wallet` exposes Engine methods not in that interface (or wraps with non-spec semantics)."
   - **Gap**: Drift inevitable without a rule.
   - **Priority**: High
   - **Impact**: Cheapest moment to set the rule is before either CLI ships.

5. **Pagination defaults on `list`**
   - **Current state**: `list outputs --limit=N` with no documented default or ceiling.
   - **Desired state**: Default `--limit=100`, `--all` as explicit opt-out, NDJSON streaming output (one object per line).
   - **Gap**: Unbounded scan is the default behaviour at 10x scale.
   - **Priority**: Medium (today) / High (at scale)
   - **Impact**: Power-user OOM; protects against operator self-DoS.

6. **`import` N+1 broadcast pattern**
   - **Current state**: `import_wallet` iterates `import_utxo` per UTXO; default `accept_delayed_broadcast: true` not explicit at the CLI level.
   - **Desired state**: `import` defaults to delayed broadcast (daemon batches); `--inline` is opt-in.
   - **Gap**: Scanning 1000 UTXOs serially via ARC = 100s of wall-clock at 100ms/call.
   - **Priority**: Medium
   - **Impact**: Operational scaling.

7. **CLI-boundary pubkey validation**
   - **Current state**: Plan accepts hex pubkeys (`--counterparty`, `--to=<root_key_hex>`) without specifying validation.
   - **Desired state**: `Commands::Base#parse_pubkey_hex` validates length, prefix, on-curve before the engine sees the value.
   - **Gap**: Malformed pubkeys produce late, hard-to-diagnose failures.
   - **Priority**: Medium
   - **Impact**: Error ergonomics + future-proofing against silent BRC-42 derivation failures.

8. **`receive --basket` silently overrides BRC-29 envelope basket**
   - **Current state**: `--basket=<name>` overwrites parsed envelope basket.
   - **Desired state**: `--basket` fills only where envelope omits; hard override requires `--force-basket`.
   - **Gap**: BRC-29 sender intent silently lost.
   - **Priority**: Medium
   - **Impact**: Receiver audit trail integrity.

### Technical Debt

**High Priority**:
- **`Commands::Base` contract documentation** (Impact: drift across 12 classes; Resolution: ~20-line plan subsection; Effort: Small; Timeline: before Phase 1)
- **Secrets policy** (Impact: total compromise on shell history capture; Resolution: plan subsection + global-options enforcement; Effort: Small; Timeline: before Phase 1)
- **Phase 6 spec lag** (Impact: five-PR coverage gap; Resolution: co-locate unit specs with each phase; Effort: Small; Timeline: Phase 1 onwards)

**Medium Priority**:
- **Surface allocation rule for `bin/wallet` vs `bin/brc100`** (Resolution: plan paragraph + `docs/reference/`; Effort: Small)
- **Pubkey validation in `Commands::Base`** (Resolution: helper method; Effort: Small)
- **`list` pagination defaults + NDJSON output** (Resolution: per-command sketch update + implementation note; Effort: Small)

**Low Priority**:
- **Index map documentation in plan** (Resolution: short subsection; Effort: Small)
- **`import_wallet` transaction boundary statement** (Resolution: one line in Phase 5 section; Effort: Trivial)
- **ADR for porcelain/plumbing/operational taxonomy** (Resolution: ~150-line ADR; Effort: Small; Timeline: post-Phase 6)

### Risks

**Technical Risks**:
- **Secrets exposure via argv** (Likelihood: Medium, Impact: High)
  - **Description**: `--wif` / `--database-url` accepted on command line; leaks to `~/.bash_history`, `ps`, container logs, process accounting.
  - **Mitigation**: Env-only WIF policy; `.pgpass` for DB; refuse argv-WIF on TTY without explicit override.
  - **Owner**: Phase 1 PR author.

- **BEEF parser DoS** (Likelihood: Low for legitimate use, High for hostile, Impact: Medium)
  - **Description**: `receive` parses untrusted BEEF; varint blow-ups, deep merkle trees, oversized envelopes can OOM or hang.
  - **Mitigation**: Delegate parsing to SDK with documented byte caps; reject early.
  - **Owner**: Phase 4 PR author.

- **`transmit --target=<uri>` SSRF + deanonymisation** (Likelihood: Medium, Impact: High)
  - **Description**: Arbitrary URI + auto-attached identity key. Egress to attacker-controlled / cloud-metadata endpoints.
  - **Mitigation**: Scheme allow-list (`https` default), private-range blocklist, `--with-identity` opt-in.
  - **Owner**: Phase 3 PR author.

- **`actions.reference` lookup performance** (Likelihood: Low if index exists, Impact: High if missing)
  - **Description**: Reject/transmit/sign/broadcast all do `Engine::Action.find(reference:)` lookup; without UNIQUE index, full scan per CLI call.
  - **Mitigation**: Verify UNIQUE index exists in `001_create_schema.rb` before Phase 2.
  - **Owner**: Phase 2 PR author.

**Business Risks**:
- **Surface allocation drift between `bin/wallet` and `bin/brc100`** (Likelihood: Medium, Impact: Medium)
  - **Description**: Without an allocation rule, new engine methods land in both surfaces; users develop habits inconsistent across the two CLIs.
  - **Mitigation**: State allocation rule in plan + `docs/reference/core-vs-conformance.md`.

**Operational Risks**:
- **Coverage gap across rebuild** (Likelihood: High, Impact: Medium)
  - **Description**: Five PRs ship CLI surface changes against engine-only test net before replacement unit specs land in Phase 6.
  - **Mitigation**: Co-locate per-command unit specs with the phase that introduces each command.

- **CLI per-invocation boot cost** (Likelihood: High at scale, Impact: Medium)
  - **Description**: Every `bin/wallet` call pays full engine boot; shell-loop batch operations multiply the cost.
  - **Mitigation**: Measure boot cost in Phase 1 verification; consider `--batch` stdin-driven mode for plumbing verbs as a follow-up.

---

## Recommendations

### Immediate (0-2 weeks — before Phase 1 begins)

1. **Add "Secrets on the CLI" subsection to the plan**
   - **Why**: One captured shell history = total wallet compromise. Pin the policy before any flag handling is implemented.
   - **How**: Subsection in the plan covering WIF (env-only or `--wif-file=<path>` mode-checked 0600; reject argv `--wif` on TTY); DB password (`.pgpass`, reject `userinfo` containing `:` in `--database-url`); `--env=<file>` (stat the file, refuse mode & 0077, refuse non-owner, canonicalise via `File.realpath`).
   - **Owner**: Simon
   - **Success Criteria**: Plan PR (follow-up to #451) merged before Phase 1 branch is created.
   - **Estimated Effort**: 1 hour (~50 lines of markdown)

2. **Add `Commands::Base` contract subsection**
   - **Why**: 12 sibling classes need one stated contract or they drift.
   - **How**: Subsection covering: `CLI::Error` hierarchy (`UsageError` exit 2, `EngineError` exit 1, `NotRejectableError` exit 3); `Data.define` for `GlobalOptions`; frozen hash registry for dispatch (`Dispatcher::COMMANDS`); `Base#read_binary_input(file:)` with `binmode`; `Base#emit_json(payload)`; `frozen_string_literal: true` mandatory.
   - **Owner**: Simon
   - **Success Criteria**: Subsection in plan; ~20 lines.
   - **Estimated Effort**: 1 hour

3. **Decide: keep or cut the plumbing layer**
   - **Why**: Plumbing's existence drives 2 of 3 engine surface additions. Decision affects engine surface and phase shape.
   - **How**: Simon weighs: (a) Sam's case — speculative, no concrete user story, cuts engine churn; (b) James's case — verb-level distinction is the BSV protocol model surfaced in shell, plumbing classes document the action lifecycle. Record the decision and rationale in the plan's Decisions section.
   - **Owner**: Simon
   - **Success Criteria**: Plan reflects the choice; if cut, phases collapse from 6 to 4.
   - **Estimated Effort**: 30 minutes deliberation; minutes to update plan

4. **Document surface allocation rule between `bin/wallet` and `bin/brc100`**
   - **Why**: Cheapest moment is before either CLI ships.
   - **How**: One paragraph in the plan + restate in `docs/reference/core-vs-conformance.md`. Rule: "BRC-100 interface methods → `bin/brc100`; everything else → `bin/wallet`; overlap requires explicit decision recorded in the relevant ADR."
   - **Owner**: Simon
   - **Success Criteria**: Reference doc updated; allocation rule discoverable.
   - **Estimated Effort**: 30 minutes

### Short-term (2-8 weeks — Phase 1 through Phase 3)

5. **Co-locate per-command unit specs with introducing phase**
   - **Why**: Closes the five-PR coverage gap.
   - **How**: Phase 1 lands `balance_spec.rb` + `list_spec.rb` alongside the commands. Subsequent phases follow the pattern. Phase 6 keeps only the e2e rewrite.
   - **Owner**: Phase 1 PR author
   - **Success Criteria**: Each phase PR includes per-command unit specs.
   - **Estimated Effort**: ~30 minutes per command

6. **CLI-boundary pubkey validation in `Commands::Base`**
   - **Why**: Catches malformed pubkeys at parse time, not deep in BRC-42 derivation.
   - **How**: `Commands::Base#parse_pubkey_hex(str)` wrapping `BSV::PublicKey.from_hex`; raises `UsageError` on failure.
   - **Owner**: Phase 1 PR author (Base lands then)
   - **Success Criteria**: `--counterparty`, `--to=<root_key_hex>` parsed through this helper.
   - **Estimated Effort**: 1 hour

7. **`list` pagination defaults + NDJSON streaming output**
   - **Why**: Bounded memory at scale; protects against operator self-DoS.
   - **How**: Default `--limit=100` on `list`; `--all` explicit opt-out; `--json` emits one object per line.
   - **Owner**: Phase 1 PR author
   - **Success Criteria**: `bin/wallet list outputs` defaults to 100 rows; `--json` is NDJSON.
   - **Estimated Effort**: 2 hours

8. **Verify `actions.reference` UNIQUE index + document index map**
   - **Why**: Lookup-by-reference on hot path for 4 commands; missing index = full scan per call.
   - **How**: `\d actions` on dev DB; if missing, fold into Phase 2 PR. Add "DB access patterns" subsection to plan listing index used per command.
   - **Owner**: Phase 2 PR author
   - **Success Criteria**: Index confirmed/added; plan documents the lookup pattern.
   - **Estimated Effort**: 1 hour (mostly verification)

9. **`import` defaults to delayed broadcast**
   - **Why**: N+1 ARC round-trips serially on root scans = 100s at 1000 UTXOs.
   - **How**: `Commands::Import` passes `accept_delayed_broadcast: true` by default; `--inline` opt-in.
   - **Owner**: Phase 5 PR author
   - **Success Criteria**: `bin/wallet import` does not block on ARC per UTXO.
   - **Estimated Effort**: 1 hour

10. **`transmit` egress hardening**
    - **Why**: SSRF + identity-key correlation primitive.
    - **How**: Scheme allow-list (`https` default), reject private/loopback/link-local/metadata ranges via `Resolv` + `IPAddr`; identity attachment gated by `--with-identity` or registered counterparty.
    - **Owner**: Phase 3 PR author
    - **Success Criteria**: `transmit` to private-range URI fails by default.
    - **Estimated Effort**: 4 hours (centralised in `Egress::Policy` or `Transmission`)

### Long-term (2-6 months)

11. **ADR for the porcelain/plumbing/operational CLI taxonomy**
    - **Why**: Public-surface decision with downstream evolution implications.
    - **How**: ~150-line ADR; references this plan as the implementation; captures the three-tier split, precedence/config model, surface allocation rule.
    - **Owner**: Simon (post-Phase 6)
    - **Success Criteria**: ADR merged; surfaces in `architecture-status`.
    - **Estimated Effort**: 2 hours

12. **Parser fuzz harness for BEEF + spends JSON**
    - **Why**: Boundary parsers are highest-yield attack surface; fuzzing catches what code review misses.
    - **How**: `spec/security/` directory; `rantly` or hand-rolled mutators; corpus seeded from real BEEF samples; assertions on allocation cap + runtime cap + exception set.
    - **Owner**: Post-Phase 6
    - **Success Criteria**: CI runs fuzz harness on every PR touching parsers.
    - **Estimated Effort**: 1-2 days

13. **Redaction layer in `CLI::Output.write_json` and top-level rescue**
    - **Why**: Stops accidental secrets disclosure across all 12 subcommands at once.
    - **How**: `Secrets.redact(obj)` deep-walker eliding field names matching `/wif|secret|priv|derivation_(prefix|suffix)/` and any 32/33-byte hex strings; override `#inspect` on key-bearing classes.
    - **Owner**: Post-Phase 6
    - **Success Criteria**: Stray `inspect` of `KeyDeriver` returns redacted form.
    - **Estimated Effort**: 4 hours

14. **`--batch` stdin-driven mode for plumbing verbs**
    - **Why**: Amortises engine boot across N references; enables shell-pipeable bulk operations.
    - **How**: `bin/wallet broadcast --batch < refs.txt` reads references line-by-line, reuses one Engine, emits one result-line per input.
    - **Owner**: Post-Phase 6 (if plumbing kept)
    - **Success Criteria**: Bulk broadcast pays one boot, not N.
    - **Estimated Effort**: 1 day per verb

---

## Success Metrics

1. **Cold-start CLI boot time**:
   - **Current**: Unmeasured (existing `bin/balance` etc. boot is the baseline reference)
   - **Target**: <500ms cold start for `bin/wallet balance` on a representative dev DB
   - **Timeline**: Established in Phase 1 verification
   - **Measurement**: `time bin/wallet --wallet=alice balance` in Phase 1 PR description

2. **Per-command unit spec coverage**:
   - **Current**: 0% (specs deleted in Phase 1)
   - **Target**: 100% of new commands have unit specs in their introducing phase
   - **Timeline**: Phase 1 through Phase 5
   - **Measurement**: `spec/bin/wallet/<command>_spec.rb` exists for each command at phase merge

3. **Argv-secrets exposure**:
   - **Current**: `--wif` and `--database-url=postgres://user:pass@host/db` accepted as plain argv
   - **Target**: WIF on argv refused on TTY without explicit override; DB password rejected from `--database-url` userinfo
   - **Timeline**: Phase 1
   - **Measurement**: `bin/wallet --wif=X balance` on TTY exits non-zero with secrets-policy message

4. **List pagination default**:
   - **Current**: Unbounded
   - **Target**: Default `--limit=100`; `--all` opt-out
   - **Timeline**: Phase 1
   - **Measurement**: `bin/wallet list outputs --json` against million-row DB completes in bounded memory

5. **Engine surface additions count**:
   - **Current**: 3 planned (`broadcast_action`, `transmit_action`, `import_wallet basket:`)
   - **Target**: TBD pending plumbing-cut decision (3 if kept; 1 if cut)
   - **Timeline**: Decided before Phase 1
   - **Measurement**: Plan's Engine Surface section names the final count

---

## Follow-up

**Next Review**: After Phase 3 lands (estimated 4-6 weeks). Mid-rebuild recalibration to confirm the contract held; especially `Commands::Base` consistency across new classes and secrets-policy enforcement.

**Tracking**: Recommendations turn into GitHub issues or in-flight plan updates:
- Critical items (1–4) → follow-up PR to plan file, merged before Phase 1 branches
- Important items (5–10) → checklisted in each phase PR description
- Long-term items (11–14) → captured in this review document; revisit at recalibration

**Recalibration**:
After Phase 6 lands, conduct architecture recalibration:
```
"Start architecture recalibration for native-porcelain-cli"
```

**Accountability**:
- Simon owns the immediate plan-update items
- Each phase PR author owns the short-term items relevant to their phase
- Architecture review tracks resolution against this document

---

## Related Documentation

**Architectural Decision Records**:
- ADR-003 — Schema as canonical state (principle-of-state honoured by `reject` failure mode)
- ADR-008 — Binary internal, hex at boundaries (the pubkey hex carve-out applies)
- ADR-020 — Test taxonomy (informs unit-vs-e2e split)
- ADR-025 — Transmission domain (transmit vs broadcast distinction; referenced explicitly in plan)
- Future ADR — Porcelain/plumbing/operational CLI taxonomy (recommended above)

**Previous Reviews**:
- 20260513_chain-tracker-pivot — preceding architectural pivot; informs the wholesale-replacement discipline this plan applies
- 20260619_noSend-sendWith-design-notes — related signing/broadcast intent design

**Referenced Documents**:
- `.claude/plans/20260626-native-porcelain-cli.md` — the target of this review
- `docs/reference/core-vs-conformance.md` — should be updated with surface-allocation rule
- `docs/reference/principle-of-state.md` — invariant honoured by reject semantics
- `docs/reference/state-boundaries.md` — SDK/wallet axis the plan respects
- HLR #433 — parent HLR
- HLR #431 — sibling BRC-100 CLI
- HLR #385 + ADR-025 — transmit/broadcast distinction
- HLR #192 — noSend/sendWith reservation flow (out of scope here)

---

## Appendix

### Review Methodology

This review was conducted using the AI Software Architect framework with all nine architecture team members:

- **Dr. Elena Vasquez** (Systems Architect): Overall system coherence, dependency direction, surface allocation, evolutionary architecture
- **James Thornton** (BSV Domain Expert): BRC-100 conformance, BSV protocol distinctions, transmit/broadcast domain
- **Nadia Okafor** (Security Specialist): Secrets handling, input validation, attack surface, egress controls
- **Viktor Petrov** (Performance Expert): Boot cost, batch patterns, pagination, lookup performance
- **Aisha Rahman** (Maintainability Expert): Class contracts, test layering, spec coverage, family consistency
- **Sam Oduya** (Pragmatic Enforcer): YAGNI, complexity budgeting, scope control
- **Marcus Johnson** (Ruby Expert): Idioms, OptionParser, `Data.define`, dispatch shape, frozen literals
- **Dr. Lin Wei** (Database Architect): Index coverage, transaction boundaries, query patterns
- **Dr. Kenji Nakamura** (Cryptography Reviewer): Key handling, pubkey validation, BEEF parser robustness

Each member reviewed independently against the plan file at `.claude/plans/20260626-native-porcelain-cli.md`, then findings were synthesised into common ground, areas of debate, and prioritised recommendations.

**Pragmatic Mode**: Enabled (Balanced)
- All recommendations evaluated through YAGNI lens
- Sam Oduya's minority position on cutting the plumbing layer is recorded as a deliberate decision point for Simon, not pre-emptively rejected.

### Glossary

- **BRC-100**: Wallet protocol specification this codebase implements (`Interface::BRC100` in the SDK).
- **BRC-29**: Payment delivery protocol; defines `sender_identity_key` and `insertion_remittance` envelope shape used by `receive`.
- **BRC-42 / BRC-43**: Key derivation protocols; counterparty + protocol-id + key-id → derived public/private key.
- **BEEF**: Binary Encoded Extended Format — transaction envelope carrying ancestry + merkle proofs.
- **EF**: Extended Format — broadcast wire format ARC accepts (includes input source scripts).
- **Action**: A wallet's transaction lifecycle unit; row in `actions` table.
- **Reference**: Stable wallet-side action identifier (UUID, `actions.reference UNIQUE`).
- **action_id**: Internal DB primary key for actions; opaque outside the engine.
- **Hydrator**: Engine-internal service that builds `atomic_beef` from `raw_tx` + ancestor proofs.
- **Porcelain / Plumbing**: Git-derived split between high-level user commands (`send`) and elementary verbs (`build`/`sign`/`broadcast`).

---

**Review Complete**
