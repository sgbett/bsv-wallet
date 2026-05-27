# Plan: Feature-testing umbrella (#126 + #129 + #130)

## Context

Before declaring the wallet production-ready we need three layered tests, each proving a different concern. The umbrella HLR is **#126 — E2E on-chain test: broadcast + sweep + observability**, with **#129 (CI stress-test)** and **#130 (consolidation dry-run)** restructured as sub-issues so the dependency relationship is visible in GitHub's UI.

The strategy doc that designs all three already lives on this branch at `.claude/strategies/Feature-testing.md` (commit `0fd1e9f`, rebased onto current master). It was authored before PR #197 merged but the design holds: each fanout level is a self-contained `no_send: true` action with Atomic BEEF handed off to `internalize_action`. No `sendWith` / `noSendChange` chained-send semantics are required (those remain parked at #192).

Critical dependencies confirmed via codebase exploration:

- **#128 closed** — `bin/walletd`, `BSV::Wallet::Daemon`, `Scheduler`, OMQ sockets, lifecycle events via `BSV::Wallet.emit(...)`. Drain/quiescence (`scheduler.shutdown(timeout:)`) not yet present.
- **#111 closed** — `Engine::Broadcast#submit` + outcome categorisation + `abort_action` wired for definitive ARC rejections.
- **`Engine#import_wallet`** exists at `engine.rb:536`. Scans the root address for UTXOs, imports each via `import_utxo`.
- **CLI tools ready:** `bin/walletd`, `bin/create_action`, `bin/internalize`, `bin/import`, `bin/balance`, `bin/list_outputs`. **Missing:** `bin/consolidate`, `bin/sweep`, daemon control surface (stop/status).
- **Logging:** `BSV.logger` global + `BSV::Wallet.emit(name, **payload)` structured events. **Missing:** per-event log sink separate from `[Store]` debug noise.
- **Network:** `BSV::Network::Services` single-provider (WhatsOnChain). Mainnet is the target per the HLR.

User decisions captured:
- **Network:** mainnet, per HLR. BSV_WALLET_WIF_SDK funded with 1 BSV out-of-band.
- **Harness location:** `gem/bsv-wallet/spec/e2e/` parallel to `spec/integration/`. Skipped unless `BSV_WALLET_WIF_SDK` is set.

---

## Restructure first

Convert #129 and #130 into sub-issues of #126 via GraphQL `addSubIssue`. Update each body to cross-reference the parent and the sibling. After restructuring, #126's "Dependencies" section reads as "sub-issues" rather than external prerequisites.

```bash
gh api graphql -f query='{ repository(owner:"sgbett", name:"bsv-wallet") {
  parent: issue(number: 126) { id }
  s129: issue(number: 129) { id }
  s130: issue(number: 130) { id }
}}'
# Then two addSubIssue mutations against the parent node ID.
```

---

## Implementation sequence

Three phases, each shippable independently as a PR closing one sub-issue. The umbrella #126 closes when its own scope (Phase C) ships.

### Phase A — #129 — CI stress-test (3-wallet cascade)

**Goal:** Prove the data layer holds under ~1700 spendable outputs across three wallets, with all payments `no_send: true` and BEEF handoff via `internalize_action`. Per-PR CI runs this.

**Scope (per strategy doc §Stress-test):**

- Three wallets ALICE / BOB / CAROL, each funded out of band via `BSV_WALLET_WIF_*` env vars (existing pattern).
- Five-level fanout cascade, payment unit 5000 sats: L1 root → L2 (1 payment + 8 change) → L3 (8×8) → L4 (64×8 = 512 change). Outputs match strategy doc §Predicted Change Fanout.
- Random not-self recipient at each layer, identity-key counterparty semantics, BEEF handoff, `internalize_action` at the receiver.
- All `no_send: true`. No ARC contact.
- Final database state report: spendable counts, total balance, BEEF ancestry depths.
- **Every transaction must succeed.** Failure is a data-layer bug, not a known flaky path.

**Files to add:**

- `gem/bsv-wallet/spec/integration/stress_cascade_spec.rb` — one large RSpec describing the cascade. Skips if any of `BSV_WALLET_WIF_ALICE/BOB/CAROL` is unset.
- `gem/bsv-wallet/spec/integration/support/cascade_helpers.rb` — fanout driver + summary reporter.

**Reuse:**

- `Open3.capture3(env, *cmd, stdin_data:)` pattern from existing `spec/integration/cli_spec.rb`.
- `BSV::Wallet::CLI.env_fetch(base_name, wallet_name)` for the per-wallet env resolution chain.
- `Dir.mktmpdir(...)` per-test DB isolation.
- `bin/create_action`, `bin/internalize`, `bin/balance`, `bin/list_outputs` — already ship with stdin/stdout JSON contract.
- `Engine#import_wallet` at `engine.rb:536` for root-key UTXO discovery.

**Acceptance criteria:**

- Cascade runs to completion across all three wallets.
- Final spendable count ≈ 1700 (~585 per wallet — ~512 L4 change + ~73 inbound payments).
- Every action's BEEF passes verification at the receiver.
- Summary report includes per-wallet balance, output counts, action counts, BEEF depths.
- Spec is `[skip]` when WIFs are not set, runs in CI when set (`actions/secrets` pattern).
- No regression on existing integration suite.

### Phase B — #130 — Consolidation dry-run

**Goal:** Prove the consolidation + sweep algorithm works against #129's terminal state (~585 spendable outputs per wallet). Every transaction `no_send: true`. CI run.

**Scope (per strategy doc §Consolidation Dry-Run):**

- For each wallet: while `spendable_count >= 20`, build a `no_send` self-payment consuming the 20 smallest outputs plus the 1 largest, producing a single output back to a derived key on the same wallet. Loop until `< 20`.
- Then one final `no_send` payment consuming all remaining spendable outputs, paying to a fresh ephemeral identity key (per-test `BSV::Primitives::PrivateKey.generate`, **not** `BSV_WALLET_WIF_SDK` — CI uses an in-memory routing target; the e2e in Phase C will swap this for the real SDK identity).
- Assert: zero spendable outputs per wallet, inputs table reflects every UTXO consumed, no infinite loop on dust, every BEEF validates, action count == consolidation rounds + 1.

**Files to add:**

- `gem/bsv-wallet/lib/bsv/wallet/engine.rb` — new private/public method `consolidate_step` that:
  - Selects the N smallest + 1 largest spendable outputs.
  - Computes net value after fee.
  - Returns a `no_send` action self-paying to a derived key.
- `gem/bsv-wallet/lib/bsv/wallet/engine.rb` — `sweep(to_identity_key:)` that consumes all spendable outputs and pays the balance (less fee) to the supplied identity.
- `gem/bsv-wallet/bin/consolidate` — CLI wrapper around `Engine#consolidate_step`.
- `gem/bsv-wallet/bin/sweep` — CLI wrapper around `Engine#sweep`.
- `gem/bsv-wallet/spec/bsv/wallet/engine/consolidation_spec.rb` — unit specs for both methods.
- `gem/bsv-wallet/spec/integration/consolidation_dry_run_spec.rb` — runs Phase A's cascade then exercises consolidate-loop + sweep on each wallet, asserting the four bullets above.

**Reuse:**

- `Engine#select_inputs` from #208 — gets the right shape, with `exclude:` already plumbed.
- The funding loop's exact post-loop fee check (engine.rb:225) — consolidation pays a self-derived output so surplus distribution is identical to a normal `no_send` action.
- `Engine#send_payment` / `Engine#create_action(no_send: true, ...)` — the underlying mechanic.

**Acceptance criteria:**

- `Engine#consolidate_step` and `Engine#sweep` exist, unit-tested in isolation against an in-memory wallet.
- `bin/consolidate` and `bin/sweep` exist with consistent stdin/stdout JSON contracts.
- The integration spec runs Phase A's cascade then loops the consolidation to terminal, then sweeps to an ephemeral identity. All assertions in the strategy doc pass.
- No regression on existing suites.

### Phase C — #126 — E2E on-chain harness

**Goal:** The manual on-chain test described in the HLR. 5 wallets deterministically derived from `BSV_WALLET_WIF_SDK`, wallet-daemon-per-wallet, 1-hour broadcast loop, sweep back to SDK.

**Scope (per HLR + strategy doc §End-to-End):**

- **Phase 1 — Setup:** drain existing test-wallet balances back to SDK (synchronous broadcast). Fund each test wallet with 10M sats from SDK. Wait for confirmation.
- **Phase 2 — Initial fragmentation:** Same shape as Phase A's cascade but with 10× multiplier (50k sat payments) and a 5th level (L5) fragmenting the 50k outputs into ~4700-sat units. All `no_send: true`.
- **Phase 3 — Broadcasting:** 25 tx every 9 seconds (absolute interval), 400 cycles, ~10k transactions over ~1 hour. `accept_delayed_broadcast: false`, `no_send: false`. Termination on `tx_count > 10_000 && block_height > start + 2`. Per-event structured logfile + database for post-run analysis.
- **Phase 4 — Cleanup:** invoke Phase B's `consolidate` + `sweep` on each wallet, but sweep target is `BSV_WALLET_WIF_SDK`'s identity (not the ephemeral key the CI run uses).

**Files to add:**

- `gem/bsv-wallet/spec/e2e/spec_helper.rb` — separate `spec_helper.rb` so `bundle exec rspec spec/bsv spec/bin` doesn't pull in the e2e tree. Skips loading unless `BSV_WALLET_WIF_SDK` is set.
- `gem/bsv-wallet/spec/e2e/support/wallet_derivation.rb` — the deterministic 5-wallet derivation from `BSV_WALLET_WIF_SDK` (strategy doc §On Chain Setup). Validate the snippet works against `BSV::Primitives::PrivateKey.from_wif`.
- `gem/bsv-wallet/spec/e2e/support/daemon_supervisor.rb` — manages one walletd subprocess per wallet via `Open3.popen3`. Tracks PIDs, sends SIGTERM on teardown, reads structured events from the daemon's logfile.
- `gem/bsv-wallet/spec/e2e/support/event_log.rb` — per-run logfile sink at `tmp/e2e-{timestamp}.log`. Wraps a tap on `BSV::Wallet.emit` so each event lands in the e2e log with the standard `key=value` shape (strategy doc §Observability lines 224–231 give the format).
- `gem/bsv-wallet/spec/e2e/setup_spec.rb` — Phase 1.
- `gem/bsv-wallet/spec/e2e/fragmentation_spec.rb` — Phase 2.
- `gem/bsv-wallet/spec/e2e/broadcast_spec.rb` — Phase 3. The bulk of the work.
- `gem/bsv-wallet/spec/e2e/cleanup_spec.rb` — Phase 4. Wraps Phase B's `bin/consolidate` + `bin/sweep`.
- `gem/bsv-wallet/spec/e2e/README.md` — operational notes: env-var checklist, expected wall time, what to look for in the log, how to re-run after an abort.

**Reuse:**

- `bin/walletd` for the daemon-per-wallet model (already accepts `wallet_name network` argv, env-driven config).
- `bin/import` for Phase 1's UTXO discovery against the chain.
- `Engine#create_action(accept_delayed_broadcast: false, no_send: false)` for Phase 3 inline broadcast.
- `Engine#internalize_action` at the receiver.
- `bin/consolidate` and `bin/sweep` from Phase B (with the sweep target swapped to the SDK identity).
- `BSV::Wallet.emit` event hook for the structured logfile.
- The same `Open3.popen3` subprocess pattern from existing `spec/integration/cli_spec.rb`, extended for long-running daemon processes.

**New scaffolding required (not covered by Phases A or B):**

- **Per-event log sink** with tail-friendly format per strategy doc §Observability. Sits behind `BSV.broadcast_log` or equivalent global, configured by `spec/e2e/spec_helper.rb`.
- **Multi-daemon subprocess management** — five concurrent `walletd` processes, each with its own DB, WIF, and logfile.
- **Termination loop** with absolute-interval cadence (`Time.now + 9` not `sleep 9`).
- **Stale-BEEF observability** — log the rate, do not remediate. The HLR is explicit on this: "behaviour is logged but not specifically remediated".

**Acceptance criteria (from HLR):**

- Wallet daemon process per test wallet, running for the duration.
- Every broadcast either reaches an accepted ARC status or is cleanly aborted via `abort_action`. No actions in limbo.
- ≥ 3 blocks mined during the test window.
- Per-event structured logfile written + retained.
- Database state queryable post-run.
- Final sweep returns > 95 % of funds to `BSV_WALLET_WIF_SDK`.
- Restart-aware: cleanup phase run standalone leaves wallets ready for a fresh run.
- Stale-BEEF behaviour observable in logfile (rate, outcome).
- Logfile is `tail -f` / `grep`-friendly per §Observability.

---

## Cross-cutting gaps to fix before Phase C

These don't have dedicated sub-issues but block Phase C. Land them as part of Phase C's PR unless they expand beyond one-line changes — in which case open follow-up issues.

| Gap | Why it matters | Where it lands |
|-----|----------------|----------------|
| Drain/quiescence API on `Scheduler` (`shutdown(timeout:)` returning when in-flight tasks are terminal) | Phase 4 sweep must not race with in-flight broadcasts/proofs | `lib/bsv/wallet/scheduler.rb` |
| Per-event log sink (`BSV.broadcast_log` or equivalent) | Phase 3 logfile separate from `[Store]` debug noise | `lib/bsv/wallet/events.rb` + `spec/e2e/support/event_log.rb` |
| Daemon control surface (`bin/walletd-status` or signal-driven stop) | Test harness needs to terminate daemons cleanly | Either a CLI tool or signal traps in `bin/walletd` |

If the drain API turns out to be non-trivial, hoist it to its own issue and close as a #128 follow-up; Phase C polls + sleeps as a stopgap.

---

## Verification

**Phase A (#129) green:**
```bash
cd gem/bsv-wallet && \
  BSV_WALLET_WIF_ALICE=... BSV_WALLET_WIF_BOB=... BSV_WALLET_WIF_CAROL=... \
  bundle exec rspec spec/integration/stress_cascade_spec.rb
```
Expect: ≈ 1700 spendable outputs reported, every BEEF verifies, summary report printed.

**Phase B (#130) green:**
```bash
cd gem/bsv-wallet && \
  bundle exec rspec spec/bsv/wallet/engine/consolidation_spec.rb \
                   spec/integration/consolidation_dry_run_spec.rb
```
Expect: each wallet ends at zero spendable, action count matches, no dust loop.

**Phase C (#126) manual run:**
```bash
cd gem/bsv-wallet && \
  BSV_WALLET_WIF_SDK=... \
  bundle exec rspec spec/e2e/
```
Expect: ~1 hour wall time. `tail -f tmp/e2e-{timestamp}.log` shows the broadcast lifecycle in real time. Final balance back at SDK ≥ 95 % of starting balance. No actions left in limbo (`SELECT * FROM actions WHERE broadcast IN ('delayed','inline') AND wtxid IS NOT NULL AND tx_proof_id IS NULL` returns zero rows after Phase 4).

**Branch / PR shape:**
- Phase A → PR closing #129, target `master`.
- Phase B → PR closing #130, target `master`.
- Phase C → PR closing #126, target `master`. Closes umbrella + own scope.
