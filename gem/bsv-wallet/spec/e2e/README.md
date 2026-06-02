# e2e on-chain harness (HLR #126)

Manual on-chain test that takes the wallet from "tested theory" to
"tested practice". One self-contained RSpec example: it resets the
test wallets, funds them from a single key, fans the funds out into a
large fragmented spendable set, then drives ~10,000 real broadcasts
through ARC over roughly an hour. **Not** part of CI — never run from a
workflow.

The harness is the on-chain *broadcast workload*. The reset, fund, and
fanout stages are preconditions it builds inline from the same
`Engine` machinery the rest of the suite already covers:

- the no_send fanout cascade — `spec/integration/stress_cascade_spec.rb` (#129)
- consolidate / sweep — `rake wallet:cleanup` + the `Engine#sweep_to_root` specs

So they are no longer separate "phase" specs; the harness exercises
them end-to-end against real chain state.

## When to run

Before declaring a wallet release production-ready. The CI suites
(#129 stress cascade, #130 consolidation dry-run) prove the data
layer and cleanup algorithm in isolation; this harness proves they
work end-to-end against real chain state.

## What it costs

The harness consumes mainnet sats. Stage 2 funds five test wallets
with 10,000,000 sats each (50m total) from the SDK key. Fees over the
~10k broadcasts in stage 4 add up to a few thousand sats. There is no
end-of-run sweep — stage 1 of the *next* run drains whatever this run
leaves behind back to the SDK root.

So across runs the 50m round-trips through the test wallets and back to
the SDK key, minus cumulative fees. An aborted run leaves the residual
on the test wallets; the next run's stage 1 recovers it, or you can
recover a single wallet standalone with `rake wallet:cleanup[wN]`.

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
| `BSV_ARC_TAAL_KEY`     | Optional. When set, the `ProviderStack` adds TAAL ARC to the broadcast fallback chain (mainnet only). Strongly recommended for stage 4's sustained throughput. |

`BSV_WALLET_WIF_W1..W5` are **not** required — they're derived
deterministically from `BSV_WALLET_WIF_SDK` (see
`support/wallet_derivation.rb`). The harness installs them into ENV
at boot so `CLI.boot(wallet_name: 'w1')` picks them up.

If any required var is unset, the harness skips cleanly with a
message listing exactly which vars are missing.

## Layout

```
spec/e2e/
  spec_helper.rb              — separate from spec/spec_helper.rb; never auto-loaded
  broadcast_spec.rb           — the harness: reset → fund → fanout → broadcast
  wallet_harness_spec.rb      — unit tests for the WalletHarness helper
  support_spec.rb             — unit tests for the three support modules
  support/
    wallet_derivation.rb      — child WIFs from SDK via deterministic multiplicative shift
    wallet_harness.rb         — installs derived WIFs in ENV + delegates to CLI.boot
    event_log.rb              — wraps BSV::Wallet.event_log into tmp/e2e-{ts}.log
    daemon_supervisor.rb      — spawns + manages one walletd subprocess per wallet
```

The fanout cascade itself lives in `spec/support/fanout.rb`, shared
with the #129 CI stress cascade.

## Safety gate: `E2E_MODE`

The harness spends real mainnet sats, so it will not fire just because
the env vars happen to be present. It is gated on `E2E_MODE`, which
defaults to a clean skip:

| `E2E_MODE` | Behaviour |
|---|---|
| unset / `skip` | Skipped. The default — env presence alone never triggers a live run. |
| `rehearse` | Every chain-touching send runs `no_send: true`, so nothing reaches ARC. Proves the full plumbing and every stage assert without broadcasting. Skips the `walletd` supervisor and the block-height gate (no real txs → no blocks to wait for). |
| `live` | The real thing: on-chain broadcasts, `walletd` subprocesses, block-boundary termination. |

`rehearse` is how you test the assert mechanism and the main loop
without committing to a broadcast — pair it with the small-scale
tunables below for a few-seconds smoke run.

## Running

```
cd gem/bsv-wallet

# The whole harness, end-to-end, on chain (~1 hour)
E2E_MODE=live bundle exec rspec spec/e2e/broadcast_spec.rb

# Smoke run — rehearse mode, tiny scale, ~seconds. Proves all four
# stages wire up and the asserts gate, with zero broadcasts.
E2E_MODE=rehearse FUND_SATS=100000 \
  FANOUT_L4_PAYMENTS=10 FANOUT_L5_PAYMENTS=10 FANOUT_MIN_SPENDABLE=20 \
  BROADCAST_CYCLES=5 BROADCAST_PER_CYCLE=5 BROADCAST_MIN_TX=10 \
  BROADCAST_MIN_BLOCKS=0 bundle exec rspec spec/e2e/broadcast_spec.rb

# Support unit tests (no env, no chain — safe anywhere)
bundle exec rspec spec/e2e/support_spec.rb spec/e2e/wallet_harness_spec.rb
```

The harness runs its stages in order within a single example; there is
no way to run a stage in isolation. To recover an aborted run without
running the whole thing, sweep each wallet with
`rake wallet:cleanup[wN]`.

## Tunables (dev iteration)

Env-var overrides let a developer iterate without committing to the
full 1-hour run.

Mode:
- `E2E_MODE` (default `skip`; `rehearse` | `live`) — see the safety gate above

Stage 1 — reset:
- `RESET_TARGET_INPUTS` (default 20) — consolidate floor before the terminal sweep

Stage 2 — fund:
- `FUND_SATS` (default 10_000_000) — per test wallet

Stage 3 — fanout:
- `FANOUT_L4_PAYMENTS` / `FANOUT_L5_PAYMENTS` (default 73)
- `FANOUT_L4_SATS` (50000) / `FANOUT_L5_SATS` (12000)
- `FANOUT_MIN_SPENDABLE` (default 500) — per-wallet spendable floor asserted after fanout

Stage 4 — broadcast:
- `BROADCAST_CYCLES` (400) / `BROADCAST_PER_CYCLE` (25)
- `BROADCAST_INTERVAL_S` (9)
- `BROADCAST_MIN_TX` (10_000) / `BROADCAST_MIN_BLOCKS` (3)
- `BROADCAST_AMOUNT_MEAN` (5000) / `BROADCAST_AMOUNT_SD` (1000)
- `BROADCAST_AMOUNT_MIN` (1000) / `BROADCAST_AMOUNT_MAX` (9000)

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
grep '\[event\] e2e\.broadcast\.cycle' tmp/e2e-*.log | tail
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

Stage lifecycle:
- `e2e.reset.{start,drain,complete}` plus `e2e.reset.drain.failed` / `e2e.reset.import.failed`
- `e2e.fund` (per wallet) / `e2e.fund.complete`
- `e2e.fanout.{start,l4,l5,complete}`
- `e2e.broadcast.{start,cycle,termination,complete}`
- `e2e.daemons.{up,down}`

Per-tx outcomes (stage 4):
- `e2e.bcast.accepted from=… to=… satoshis=… dtxid=…`
- `e2e.bcast.failed from=… to=… error_class=… error=…`

## Failure modes

**Stage 1 reset can't drain** — a test wallet's tracked state and the
chain disagree (e.g. a prior run's broadcast never confirmed). The
sweep emits `e2e.reset.drain.failed`; the wallet is skipped and the
SDK on-chain balance may then fall short. Inspect the wallet's DB and
`rake wallet:cleanup[wN]` it by hand.

**Stage 1 SDK balance falls short** — the precondition asserts the
SDK's *on-chain* root balance (read from WoC, not the DB — the
blank-slate sweep leaves the SDK DB empty by design) covers the run's
total funding (5 × `FUND_SATS`). If it fails the SDK key holds too
little at its root address. Top it up, or check that stage 1 actually
swept the prior run's residual back (grep `e2e.reset.drain`).

**Stage 4 stale-BEEF rate climbing** — `grep e2e.bcast.failed` shows
many "BEEF" / "stale" / "invalid merkle" errors. Expected if
chaintracks lag exceeds the per-tx window. The HLR says log it,
don't remediate. Eventually the daemon's proof-acquisition refreshes
proofs and rates recover.

**Daemon won't shut down** — the supervisor's `stop_all` falls back
to SIGKILL after `shutdown_timeout` (default 45s). Each daemon's
cooperative drain relies on `Scheduler#shutdown` (#233); if it
returns `false`, the harness emits `e2e.daemons.down killed=N` so the
cause is visible in the log.

## What we did NOT cover

- **Interoperability** with ts-sdk / wallet-tools. That's a separate
  HLR — this one only verifies Ruby↔Ruby.
- **Sustained operation past 1 hour.** The harness terminates as soon
  as the dual condition is met. Long-run behaviour (memory growth,
  proof_store size, DB bloat) is a future concern.
- **Multi-instance-per-DB safety.** Each wallet has its own DB —
  concurrent daemons against the same DB are out of scope for #126.
