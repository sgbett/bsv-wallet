# ADR: Broadcast network boundary — stateless→SDK, stateful→wallet

- **Date:** 2026-06-03
- **Status:** Accepted
- **Supersedes:** —
- **Superseded by:** —
- **Related plan:** [`.claude/plans/20260603-broadcast-network-boundary.md`](../../../.claude/plans/20260603-broadcast-network-boundary.md)
- **Related issues:** wallet #126 (e2e umbrella), #235 (EF inline, merged), #240 (resolution reject_action), #245 (reorg), #246 (block-driven MINED); SDK #782, #790, #791, #792

## Context

The wallet must broadcast transactions and resolve their lifecycle states (RECEIVED → SEEN_ON_NETWORK → MINED, or → REJECTED / DOUBLE_SPEND_ATTEMPTED). Two upstream protocols are available on the same operator (GorillaPool):

- **ARC** (`arc.gorillapool.io`) — Bitcoin SV's standard transaction submission protocol (synchronous response carries txid + arc_status).
- **Arcade** (`arcade.gorillapool.io`) — operator-specific protocol that exposes a **Server-Sent Events stream at `/events`** scoped by callback token, in addition to webhooks.

Two structural facts shape every option:

1. **The SDK is stateless.** It owns no database, no clock-spanning state, no long-lived connections. Anything requiring persistence, restart-durability, or stream consumption cannot live in the SDK.
2. **ARC's pre-block status is per-metamorph-instance.** A 404 from `get_tx_status` means "this metamorph instance didn't see your tx," not "pruned." Polling can only ever hit one instance; behind a load balancer, repeated polls land on different instances. This is a real, observed flakiness ("you sometimes can't get status until there's a block" — corroborated by a separate BSV dev).

Today the wallet:

- Holds broadcast affinity in an **in-memory hash** (`BSV::Network::Services#@broadcast_affinity`) — process-local, wiped on restart, capped at 1000 entries, **txid-gated** (so Arcade's txid-less submit defeats it entirely).
- Resolves status via **per-tx polling** in the `broadcast_resolution` loop — vulnerable to the per-instance problem above.
- Has no inbound push consumer (a Rack `store/broadcast_callback.rb` endpoint exists for ARC webhooks but is unwired in production, and ARC's callback delivery semantics are undocumented).

SDK PR #791/#792 simultaneously committed the SDK to **semantic** porcelain commands (`:broadcast`, `:get_tx_status`, `:get_block_header`) and pushed canonical-shape normalisation **down into the protocol layer** for fields that are structurally identical across upstreams (Pattern A). Broadcast responses are structurally divergent across ARC vs Arcade and were explicitly left to the consumer (Pattern B). This forces the wallet to pick a position on broadcast orchestration rather than wait for the SDK to handle it.

## Decision

### 1. Boundary rule: stateless → SDK, stateful → wallet

The SDK owns only the slice that is **stateless and protocol-uniform**:

- Single-call wire dispatch (`:broadcast` over ARC or Arcade, returning a raw response).
- Optional: canonical-shape response normalisation (the thin Pattern-B slice the SDK may or may not ship).

Everything stateful lives in the wallet, *not by preference but by construction* — there is nowhere else it can live:

- Multi-endpoint selection and bookkeeping.
- Affinity persistence (which provider handled a given tx, durable across restart).
- Push-resolution consumption (SSE stream readers, webhook receivers, cursor management).
- Existence fallback (WoC reconciliation).

### 2. No protocol-named commands in the SDK

The SDK does **not** expose `:arc` or `:arcade` as commands. Per-call protocol overrides (`call(:broadcast, tx, via: :arc)`) are also rejected — they relocate protocol-awareness into the caller, which is the tell that selection has left the SDK Provider abstraction. SDK Providers remain clean single-`:broadcast` protocol routers; selection lives in the wallet.

### 3. Wallet home: `BSV::Network::Broadcaster`

A new `BSV::Network::Broadcaster` class — the natural promotion of what `BSV::Network::Services` already half-is (it already does affinity + `normalize_broadcast_response`). It owns:

- Provider composition and selection.
- Persisted affinity (the `broadcasts.provider` column).
- Push-resolution consumption (the Arcade SSE consumer).
- Existence fallback (WoC sweep).

The wallet's existing `Services#normalize_arcade_submit` / `normalize_broadcast_response` are SDK porcelain in the wrong gem; they may migrate later if the SDK ships canonical-shape porcelain, but the wallet does not need them once broadcast is single-protocol.

### 4. Push mechanism: Arcade SSE (`/events`)

The wallet uses **Arcade's Server-Sent Events stream** as the primary push channel, not ARC webhooks:

- **Outbound connection** — the wallet daemon connects out; no publicly-reachable, highly-available inbound webhook endpoint to operate.
- **Resumable** — `Last-Event-ID` (nanosecond timestamp) catchup on reconnect (verified against Arcade source, PR #50, merged 2026-04-28).
- **Coverage verified** — `tx_validator` publishes RECEIVED / REJECTED; `propagation` publishes SEEN_ON_NETWORK; `bump_builder` publishes MINED-class (verified by inspecting the publish sites in PR #50; REJECTED delivery confirmed live by #267 E4/E8 against `arcade.gorillapool.io` 2026-06-04).

This makes Arcade the primary broadcast + resolution path. The "switch GorillaPool default to ARC" HLR is **mooted for this path**. ARC's separable advantages (`/v1/policy` fees, granular synchronous reject taxonomy) become independent questions, not blockers.

### 5. Resolution model — two edges with different physics

"Resolution" is two distinct problems, not one:

| Edge | Transition | Primary mechanism | Fallback |
|------|------------|-------------------|----------|
| 1 | → MINED | Block-driven bulk resolver (#246) — match new block's txids against in-flight wtxids | Per-tx poll as late straggler |
| 2 | → SEEN_ON_NETWORK / REJECTED / DOUBLE_SPEND | Arcade SSE (push from the metamorph instance that holds the tx) | WoC existence sweep for stale SEEN_ON_NETWORK |

The block-driven resolver (Edge 1) reads **block data**, which is globally shared across all ARC instances — immune to the per-instance problem by construction. The per-tx poll, demoted to straggler fallback, fires *after* push silence, by which point a block likely exists — so its pre-block flakiness never bites in the fallback role.

Push is primary for Edge 2 because the **block resolver is structurally blind to mempool-only outcomes** (a rejected tx never lands in any block). An async double-spend that never mines has no other reliable signal — miss the push and the speculative promotion never unwinds (locked UTXOs never release; wallet view diverges from chain). This is why **SSE's resumable persistent stream beats a fire-and-forget webhook** for the one message that has no backstop.

### 6. Affinity: persisted bookkeeping, not the resolution backbone

Affinity moves from the in-memory hash to a **`broadcasts.provider` column** (`broadcasts` is one-row-per-action by `unique :action_id`, so a single column suffices for failover-affinity: "who I broadcast to, where to re-ask"). Keyed off the **wtxid the wallet computes pre-broadcast**, not the response txid — this fixes the Arcade-defeats-affinity bug without switching endpoints.

**Failover (column) now, fan-out (one-to-many) deferred.** SSE-on-Arcade implies a single primary endpoint; fan-out complicates which push stream is authoritative. Fan-out is parked as a scaling question.

Demoted role: with SSE (push from the right instance) + block-driven MINED (global block data), the per-instance problem is solved by mechanisms that don't depend on hitting the right instance. Affinity is now bookkeeping + straggler-poll routing, not the resolution backbone.

## Consequences

### Positive

- The wallet has a coherent answer to "where does broadcast orchestration live?" — `BSV::Network::Broadcaster`, the wallet, by construction.
- Resolution moves from per-tx polling (per-instance flaky) to push-primary (instance-independent) + block-driven (globally consistent). Both are mechanisms that route around the ARC per-instance problem.
- Affinity becomes durable across daemon restarts; the txid-gating bug is fixed by keying off the known wtxid.
- The SDK boundary is clean — no protocol identity smuggled into the command namespace; SDK broadcast porcelain stays minimal/optional.

### Negative / accepted trade-offs

- **Single primary endpoint.** The decision to go SSE-on-Arcade implies single-endpoint operation. If Arcade has an outage, the wallet's broadcast path is degraded — there is no automatic fail-over to ARC. Mitigation deferred to fan-out, which is parked.
- **Reject-reason granularity loss — confirmed live (#267 / E8).** Arcade surfaces double-spend as plain `REJECTED` without ARC's distinct `DOUBLE_SPEND_ATTEMPTED`. Verified end-to-end against `arcade.gorillapool.io` mainnet on 2026-06-04: a deliberate double-spend produced an SSE frame with `tx_status: "REJECTED"`, and every supplementary field nil (`extra_info: nil`, `competing_txs: nil`, `status: nil`, no block fields). The unwind still fires (REJECTED is terminal), but reason granularity is lost vs ARC, and there is no `competing_txs` callback to identify the winning conflict. Acceptable; note in telemetry. Wallet's `ArcStatus::REJECTED` set (`REJECTED`, `DOUBLE_SPEND_ATTEMPTED`) remains correct — `DOUBLE_SPEND_ATTEMPTED` is dead code on the Arcade SSE path today, but kept for ARC-webhook compatibility (the `store/broadcast_callback.rb` receiver is retained per Alt C).
- **SSE catchup is a current-status snapshot, not an audit log.** `Last-Event-ID` reconnect emits *the current* status of each token-scoped submission newer than `since` — a tx that went RECEIVED → REJECTED while disconnected emits only REJECTED. Fine for terminal-state semantics, but the SSE consumer's event-application core must be idempotent on current state (not a transition sequence) and must persist the cursor durably across reconnects (gaps under load are silent otherwise).
- **Delivery is best-effort.** Slow-consumer drops are non-blocking server-side; the poll fallback (#246) is mandatory, not optional. No exactly-once assumption.

### Migration impact

- `broadcasts.provider` migration (additive; nullable for back-compat).
- New `sse_cursors(token PK, last_event_id BIGINT, updated_at)` table (per-token, not per-broadcast).
- Refactor: extract transport-agnostic event-application core from `store/broadcast_callback.rb` for reuse by both the ARC webhook (existing) and the Arcade SSE consumer (new).
- Retire `BSV::Network::Services#@broadcast_affinity` hash and `Services#broadcast_transaction` once `Broadcaster` is the sole entrypoint.

### Coordination with SDK

- SDK keeps Providers as single-`:broadcast` protocol routers (already aligned with #791).
- SDK broadcast porcelain (canonical-shape Pattern B normalisation) is optional and **not a wallet blocker** — the wallet owns its taxonomy mapping (`ArcStatus`) and stays on one protocol (Arcade).
- The wallet consumes Arcade `/events` directly today without any SDK change; first-class SDK SSE support would be a future coordination item, not a prerequisite.

## Alternatives considered

### A. `Provider.new('GorillaPool')` registers ARC with `:arc` and Arcade with `:arcade`

**Rejected.** Breaks the semantic-command axis the SDK committed to. `:broadcast` / `:get_tx_status` / `:get_block_header` are verbs the consumer issues without knowing the wire protocol; `:arc` / `:arcade` are protocol selectors — a different axis. Smuggling protocol identity into the command namespace means `call(:arc, …)` doesn't say *what operation* it performs, and every consumer must learn per-provider command names.

### B. Per-call protocol override (`call(:broadcast, tx, via: :arc)`)

**Rejected.** Relocates protocol-awareness into the caller — the tell that selection has left the SDK Provider abstraction. If the caller is making protocol decisions, the right place for that logic is in the wallet, not buried in an SDK escape hatch.

### C. ARC webhooks as the push primary

**Rejected** for the SSE-primary slot. ARC webhooks (`X-CallbackUrl`) are documented but undocumented in delivery semantics (no published retry/backoff, no replay), and require a publicly-reachable, highly-available inbound HTTP endpoint to operate. The existing `store/broadcast_callback.rb` Rack endpoint is **retained as the ARC webhook receiver** for that path — the event-application core is shared with the SSE consumer — but ARC is no longer the primary resolution mechanism for this wallet.

### D. Keep polling primary, accept the per-instance flakiness

**Rejected.** The financially-consequential case — an async double-spend that never mines — has no reliable signal under polling. Missed rejections leave locked UTXOs forever locked; the wallet's view diverges from chain truth. The cost is real and the mitigation (push-primary) is available.

### E. Fan-out broadcast (one tx → N providers simultaneously)

**Deferred.** Would require a one-to-many `broadcasts` ↔ providers relation (child table or relaxing the `unique :action_id`). SSE-on-Arcade implies single primary endpoint (fan-out complicates which push stream is authoritative). Parked as a scaling question; revisit if single-endpoint operation proves insufficient.
