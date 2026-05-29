# e2e on-chain harness (HLR #126)

Manual on-chain test that takes the wallet from "tested theory" to
"tested practice". Drives ~10,000 real broadcasts through ARC over
roughly an hour, then sweeps every test wallet back to a single
funding key. **Not** part of CI — never run from a workflow.

## When to run

Before declaring a wallet release production-ready. The CI suites
(#129 stress cascade, #130 consolidation dry-run) prove the data
layer and cleanup algorithm in isolation; this harness proves they
work end-to-end against real chain state.

## What it costs

The harness consumes mainnet sats. Phase 1 funds five test wallets
with 10,000,000 sats each (50m total). Fees over the ~10k Phase 3
broadcasts add up to a few thousand sats. Phase 4 sweeps the residual
back to the SDK identity — the recovery floor is 95% (default
configurable via `CLEANUP_RECOVERY_FLOOR`).

So a clean run round-trips 50m sats minus a few hundred thousand sats
in fees. An aborted run leaves the residual on the test wallets;
re-running Phase 4 standalone recovers it.

## Environment

The harness reads everything from `.env` at the repo root (loaded via
`Dotenv` in `spec_helper.rb`). The CLI tools (and any spawned
`walletd` subprocesses) inherit the same env, so the wallets all
agree on which DB belongs to which name.

Required:

| Var | What |
|---|---|
| `BSV_WALLET_WIF_SDK`   | Funding key. Must hold >= 50m sats at the start of a fresh run. |
| `DATABASE_URL_SDK`     | Postgres URL for the funding wallet. |
| `DATABASE_URL_W1..W5`  | Postgres URLs for the five derived test wallets. |
| `BSV_ARC_TAAL_KEY`     | Optional. When set, the `ProviderStack` adds TAAL ARC to the broadcast fallback chain (mainnet only). Strongly recommended for Phase 3's sustained throughput. |

`BSV_WALLET_WIF_W1..W5` are **not** required — they're derived
deterministically from `BSV_WALLET_WIF_SDK` (see
`support/wallet_derivation.rb`). The harness installs them into ENV
at boot so `CLI.boot(wallet_name: 'w1')` picks them up.

If any required var is unset, every phase skips cleanly with a
message listing exactly which vars are missing.

## Layout

```
spec/e2e/
  spec_helper.rb              — separate from spec/spec_helper.rb; never auto-loaded
  setup_spec.rb               — Phase 1: drain + fund + confirm
  fragmentation_spec.rb       — Phase 2: 5-level no_send cascade
  broadcast_spec.rb           — Phase 3: 25 tx/9s × 400 cycles
  cleanup_spec.rb             — Phase 4: consolidate + sweep to SDK
  wallet_harness_spec.rb      — unit tests for the WalletHarness helper
  support_spec.rb             — unit tests for the three support modules
  support/
    wallet_derivation.rb      — child WIFs from SDK via deterministic multiplicative shift
    wallet_harness.rb         — installs derived WIFs in ENV + delegates to CLI.boot
    event_log.rb              — wraps BSV::Wallet.event_log into tmp/e2e-{ts}.log
    daemon_supervisor.rb      — spawns + manages one walletd subprocess per wallet
```

## Running

```
cd gem/bsv-wallet

# Whole harness, end-to-end (~1 hour)
bundle exec rspec spec/e2e

# Phase by phase (must run in order on a fresh start)
bundle exec rspec spec/e2e/setup_spec.rb
bundle exec rspec spec/e2e/fragmentation_spec.rb
bundle exec rspec spec/e2e/broadcast_spec.rb
bundle exec rspec spec/e2e/cleanup_spec.rb

# Standalone cleanup (restores wallets after an aborted run)
bundle exec rspec spec/e2e/cleanup_spec.rb
```

Phase 4 is the only phase that's restart-safe in isolation. The
others assume the prior phase's end state.

## Tunables (dev iteration)

Each phase exposes env-var overrides so a developer can iterate
without committing to the full 1-hour run.

Phase 1 — `setup_spec.rb`:
- `SETUP_CONFIRM_TIMEOUT_S` (default 1500)
- `SETUP_CONFIRM_POLL_S` (default 30)

Phase 2 — `fragmentation_spec.rb`:
- `FRAG_L4_PAYMENTS` / `FRAG_L5_PAYMENTS` (default 73)
- `FRAG_L4_SATS` (50000) / `FRAG_L5_SATS` (12000)

Phase 3 — `broadcast_spec.rb`:
- `BROADCAST_CYCLES` (400) / `BROADCAST_PER_CYCLE` (25)
- `BROADCAST_INTERVAL_S` (9)
- `BROADCAST_MIN_TX` (10_000) / `BROADCAST_MIN_BLOCKS` (3)
- `BROADCAST_AMOUNT_MEAN` (5000) / `BROADCAST_AMOUNT_SD` (1000)
- `BROADCAST_AMOUNT_MIN` (1000) / `BROADCAST_AMOUNT_MAX` (9000)

Phase 4 — `cleanup_spec.rb`:
- `CLEANUP_TARGET_INPUTS` (20) / `CLEANUP_MAX_STEPS` (200)
- `CLEANUP_CONFIRM_TIMEOUT_S` (1500) / `CLEANUP_CONFIRM_POLL_S` (30)
- `CLEANUP_RECOVERY_FLOOR` (0.95)
- `CLEANUP_FUND_PER_WALLET` (10_000_000)

## Observability

Two views, one per-run identifier:

**Harness event log** at `gem/bsv-wallet/tmp/e2e-{ISO timestamp}.log`.

Captures every `BSV::Wallet.emit('e2e.*', …)` call in the canonical
`<ISO-8601> [event] name key=value …` format. Tail-able and
grep-friendly:

```
tail -f tmp/e2e-*.log
grep result=stale_beef tmp/e2e-*.log | wc -l
grep '\[event\] e2e\.bcast\.failed' tmp/e2e-*.log
grep '\[event\] e2e\.phase3\.cycle' tmp/e2e-*.log | tail
```

**Per-wallet walletd logs** at
`gem/bsv-wallet/tmp/walletd-{wallet}-{timestamp}.log`. Captures each
`walletd` subprocess's stderr — the standard `[Store]` /
`[Engine]` debug stream plus the per-wallet event emissions. Useful
when something fails on a single wallet only.

**Database** — every wallet's Postgres DB stays intact after the run.
Use the standard `psql` workflow against the URLs in `.env` to
inspect actions, outputs, broadcasts, tx_proofs post-run.

## Event taxonomy

Phase-level lifecycle: `e2e.phase{1..4}.{start,complete}` plus
`e2e.phase{n}.balances.start`, `e2e.phase{n}.daemons.{up,down}`.

Per-tx outcomes (Phase 3):
- `e2e.bcast.accepted from=… to=… satoshis=… dtxid=…`
- `e2e.bcast.failed from=… to=… error_class=… error=…`

Cleanup detail (Phase 4):
- `e2e.cleanup.consolidate wallet=… step=… dtxid=… remaining=…`
- `e2e.cleanup.sweep wallet=… dtxid=…`
- `e2e.cleanup.confirm.poll dtxid=… status=…`

Supporting infra:
- `e2e.engines.booted count=… sdk=…`
- `e2e.drain dtxid=… satoshis=…` / `e2e.fund dtxid=… satoshis=…`
- `e2e.confirm.poll dtxid=… status=…`

## Failure modes

**Phase 1 confirmation timeout** — the funding tx didn't reach a
mined status within `SETUP_CONFIRM_TIMEOUT_S`. Either ARC is slow
(blocks > 10min apart) or the provider stack is wedged. Check
`tmp/walletd-*.log` for repeated rate-limit / 5xx responses.

**Phase 3 stale-BEEF rate climbing** — `grep e2e.bcast.failed` shows
many "BEEF" / "stale" / "invalid merkle" errors. Expected if
chaintracks lag exceeds the per-tx window. The HLR says log it,
don't remediate. Eventually the daemon's proof-acquisition refreshes
proofs and rates recover.

**Phase 4 recovery below floor** — fees ate more than 5% of funded
balance. Either Phase 3 ran longer than intended (more fees) or the
fee rate (100 sats/kb) is mis-estimated against current network
load. Re-running Phase 4 alone won't recover more — the funds are
spent on miner fees by then.

**Daemon won't shut down** — the supervisor's `stop_all` falls back
to SIGKILL after `shutdown_timeout` (default 45s). Each daemon's
cooperative drain relies on `Scheduler#shutdown` (#233); if it
returns `false`, the harness emits `e2e.phase3.daemons.down
killed=N` so the cause is visible in the log.

## What we did NOT cover

- **Interoperability** with ts-sdk / wallet-tools. That's a separate
  HLR — this one only verifies Ruby↔Ruby.
- **Sustained operation past 1 hour.** The harness terminates as soon
  as the dual condition is met. Long-run behaviour (memory growth,
  proof_store size, DB bloat) is a future concern.
- **Multi-instance-per-DB safety.** Each wallet has its own DB —
  concurrent daemons against the same DB are out of scope for #126.
