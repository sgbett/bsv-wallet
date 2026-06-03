# Broadcast network boundary — wallet position

- **Date:** 2026-06-03
- **Status:** position / coordination input (not yet an implementation plan)
- **Purpose:** define what broadcast work lands in the **wallet** vs the **bsv-ruby-sdk**, and record the decisions reached this session.
- **Related:** wallet #126 (e2e umbrella), #235 (EF inline), #240 (resolution reject_action), #245 (reorg removal), #246 (block-driven resolution); SDK #782, #790, #791, SDK plan `20260529-arcade-protocol.md`.
- **SDK-facing sections** (paste to the SDK side): §1, §2, §5, §7. The rest is wallet-internal record.

## TL;DR — decisions reached

1. **Boundary rule: stateless → SDK, stateful → wallet.** The SDK is stateless, so it can only ever own the thin "canonicalize one broadcast response" slice. All stateful broadcast orchestration (endpoint selection, affinity, push-resolution, fallback) is wallet-side *by construction*, not preference.
2. **No protocol-named commands in the SDK** (`:arc` / `:arcade`). Keep Providers as single-`:broadcast` protocol routers.
3. **Wallet home: `BSV::Network::Broadcaster`** — the evolution of today's `BSV::Network::Services` broadcast role.
4. **Push resolution: Arcade SSE** (`/events`). Decided. Consequence: the primary broadcast **and** resolution path is Arcade (`arcade.gorillapool.io`); the "switch GorillaPool default to ARC" HLR is mooted for this path.
5. **Resolution is two edges:** → MINED is block-level (#246 block-driven resolver, primary); → SEEN_ON_NETWORK / REJECTED / DOUBLE_SPEND is mempool-level (SSE primary). Poll = late straggler fallback; WoC = scarce double-spend backstop.
6. **Affinity: persist as `broadcasts.provider`, but it's bookkeeping, not the backbone.** Single-endpoint (failover) now; fan-out deferred.

## 1. The boundary: stateless → SDK, stateful → wallet

"How much broadcast porcelain do we want in the SDK?" splits cleanly along statelessness:

- **Stateless** — canonicalize one broadcast response into a common shape. This is the *only* slice the SDK can own (no DB, no clock-spanning state). Small, optional, low-stakes. Vestigial for the wallet once the wallet broadcasts via a single protocol and is the main consumer.
- **Stateful** — multi-endpoint selection, affinity bookkeeping, callback/SSE consumption, existence fallback. Every one needs state the SDK structurally cannot hold. Lands in the wallet *regardless* of how we feel about porcelain.

So "state in the SDK smells bad; persist in the wallet" is forced, not a preference. The wallet is not fighting the SDK — it is correctly declining to put stateful logic in a stateless layer.

## 2. No `:arc` / `:arcade` commands

The SDK committed (per #791) to **semantic** commands: `:broadcast`, `:get_tx_status`, `:get_block_header` — verbs the consumer issues without knowing the wire protocol. `:arc` / `:arcade` are **protocol selectors** — a different axis. Smuggling protocol identity into the command namespace means `call(:arc, …)` doesn't say *what operation* it performs, and every consumer must learn per-provider command names. That inverts the porcelain abstraction.

The least-bad SDK form for one Provider speaking both protocols is a per-call override (`call(:broadcast, tx, via: :arc)`) — but that just relocates protocol-awareness into the caller, which is the tell that **selection belongs in the wallet**, not the SDK Provider. Keep Providers as clean single-`:broadcast` routers.

## 3. Wallet home: `BSV::Network::Broadcaster`

The natural promotion of what `BSV::Network::Services` already half-is (it already does affinity + `normalize_broadcast_response`). Owns: provider composition/selection, affinity persistence, push-resolution consumption, existence fallback.

The wallet's `Services#normalize_arcade_submit` / `normalize_broadcast_response` are **SDK porcelain in the wrong gem**. They can migrate to the SDK if/when it ships a canonical-shape porcelain — but that is optional and low priority (see §7); the wallet does not need it.

## 4. Resolution model — two edges with different physics

"Resolution" is not one thing. The per-instance fact (ARC status is per-instance: a 404 means "this metamorph instance didn't see your tx," not "pruned") splits it:

**Edge 1 — → MINED (block-level).** #246's **block-driven bulk resolver** is primary: on each new block, match the block's txids against in-flight wtxids and mark them MINED en masse. Block data is **global**, so this is immune to the per-instance problem by construction. The per-tx poll becomes a **late straggler fallback** — it fires *after* push silence, by which point a block likely exists, so it is reliable exactly when it runs. Its pre-block flakiness never bites in the fallback role.

**Edge 2 — → SEEN_ON_NETWORK / REJECTED / DOUBLE_SPEND (mempool, pre-block).** The block resolver is **structurally blind** here (a rejected tx never lands in any block). The poll is per-instance flaky precisely in this pre-block window. So **push (SSE) is primary**.

**The sharp edge (endpoint-independent):** an async double-spend that *never mines* has no reliable fallback — the block resolver never sees it, and the poll stays per-instance-flaky forever (no block ever makes its status instance-independent). The **push event is the only reliable signal**; miss it and the speculative promotion never unwinds (locked UTXOs never release; wallet view diverges from chain). This is why push *delivery robustness* matters here specifically, and why SSE (persistent, resumable) beats a fire-and-forget webhook for the one message that has no backstop. Last-ditch backstop: a WoC reconciliation sweep over long-lived SEEN_ON_NETWORK rows (scarce/rate-limited → stragglers only).

Corroboration: a BSV dev reports you "sometimes can't get status until there's a block" on ARC. That is the metamorph (per-instance tx tracking) / blocktx (network-wide block monitoring, shared) seam — pre-block only the receiving instance knows; post-block any instance answers. It argues for routing pre-block resolution to **push**, not poll.

## 5. Push mechanism: Arcade SSE (decided)

Both GorillaPool hosts document push:

- `docs.gorillapool.io/arc` (ARC): `X-CallbackUrl`, `X-CallbackToken`, `X-MerkleProof`, `X-WaitForStatus`. `X-CallbackUrl` is documented as the *"double spend and merkle proof notification"* endpoint — which maps onto exactly our two edges. **But delivery semantics (which transitions fire, retry/backoff, body shape) are undocumented.**
- `arcade.gorillapool.io` (Arcade): `X-CallbackUrl` + `X-CallbackToken` (webhook, `Authorization: Bearer <token>`) **and** a **Server-Sent Events stream at `/events`**, scoped by callback token.

**Decision: use Arcade SSE.** Rationale:

- **Outbound connection** — the wallet daemon connects out to `/events`; no publicly-reachable, highly-available inbound webhook endpoint to stand up and operate.
- **Resumable / persistent** — least likely to drop the async-double-spend message that has no fallback (§4).

**Consequence:** the primary broadcast + resolution path is Arcade (broadcast registers the callback token; `/events` is scoped by it). The "switch GorillaPool default to ARC" HLR is **mooted for this path**. ARC's separable advantages (`/v1/policy` fees, granular *synchronous* reject taxonomy) become independent questions, not blockers — revisit only if needed.

**Machinery.** `store/broadcast_callback.rb` is an inbound **ARC webhook** Rack endpoint (parses camelCase `TransactionStatus`). Its **event-application core is transport-agnostic**: decode → `find_action(wtxid:)` → `reject_action` (terminal) or `record_broadcast_result`, with the three invariant guards (`CannotRejectInternalActionError` → bump retry; `CannotRejectAcceptedActionError` → log + ACK, don't retry; parser error → 400). The SSE consumer **reuses that core** and replaces only (a) ingestion (outbound stream reader in the Async reactor vs Rack `call(env)`) and (b) `decode_event` (Arcade event shape vs ARC camelCase). Extract the core; don't duplicate it.

**SSE coverage verified (Arcade PR #50, merged 2026-04-28).** Three publish sites cover both edges:

- `tx_validator/validator.go` — publishes **RECEIVED / REJECTED** (Edge 2 ✓).
- `propagation/propagator.go` — publishes post-broadcast status (SEEN_ON_NETWORK).
- `bump_builder/builder.go` — publishes MINED-class status (Edge 1, secondary to #246's block-driven resolver).

Wire shape per frame: `id: <ns-timestamp>\nevent: status\ndata: {"txid","txStatus","timestamp"}`. Connect with `?callbackToken=<token>`; the server filters by `store.GetSubmissionsByToken` per event.

**Catchup is a current-status snapshot, not a historical replay.** `sendSSECatchup` iterates token-scoped submissions and emits each one's *current* status if `Timestamp > Last-Event-ID`. A tx that went RECEIVED → REJECTED while disconnected re-emits only REJECTED. Consequences for the wallet SSE consumer:

1. **Event-application must be idempotent on current state**, not assume a transition sequence — the extracted core already is (terminal-state guards), but verify on reuse.
2. **`Last-Event-ID` MUST be persisted across reconnects** (per-token cursor, durably stored — a `sse_cursor` column on the broadcaster's state or a small table). Slow-consumer drops are non-blocking server-side; reconnect-with-cursor is the *only* recovery path. Without durable cursor, gaps under load are silent.
3. Catchup requires the token query param — always connect with `?callbackToken=…`, never bare.

**Delivery is best-effort → the poll fallback (#246) is mandatory, not optional.** Do not assume exactly-once.

## 6. Affinity: persist, but bookkeeping not backbone

Today: `@broadcast_affinity` is an **in-memory hash** (`services.rb:29`), **txid-gated** (`services.rb:343-344` — bails with no txid, so Arcade's txid-less submit never records), capped at 1000, **process-local** (wiped on restart). It survives within a running daemon but is not durable state.

- **Persist as a `broadcasts.provider` column.** `broadcasts` is one-row-per-action (`unique :action_id`, `migrations/001:117`), so a single column models **failover affinity** ("who I broadcast to, where to re-ask").
- **The txid-gating is self-inflicted.** Affinity can key off the **wtxid the wallet already knows** (it computed it pre-broadcast), not the response txid. So Arcade's txid-less submit defeating affinity is a wallet-side fix, *not* a reason to switch endpoints.
- **Demoted by §4/§5.** With SSE (push comes from the instance that has the tx) + block-driven MINED (global block data), the per-instance problem is solved by mechanisms that don't depend on hitting the right instance. Affinity-based polling was the fragile middle path; the robust design routes around it. Affinity is now bookkeeping + straggler-poll routing, not the resolution backbone.
- **Failover vs fan-out: decided — failover (column), fan-out parked.** A single `provider` column cannot represent **fan-out** (one tx → N providers at once); that needs one-to-many (child table or relax the unique). The SSE-on-Arcade decision implies a **single primary endpoint** (fan-out complicates which push stream is authoritative), and fan-out is parked as a scaling question.

## 7. What this asks of / coordinates with the SDK

- Keep Providers as single-`:broadcast` protocol routers; **no protocol-named commands**.
- SDK broadcast porcelain = the **optional thin stateless canonical-shape slice** only. It is **not a wallet blocker** — the wallet owns the stateful orchestration regardless.
- **Canonical cross-protocol shape (Option 1 ARC-strings vs drop):** the wallet does **not** need it — it owns its taxonomy mapping (`ArcStatus`) and stays on one protocol (Arcade). The SDK may keep broadcast porcelain minimal/deferred without blocking the wallet. Keep-or-drop is the SDK's call; the wallet's position is "we don't need it for our path."
- **Arcade SSE** can be consumed **directly today** without an SDK change. If the SDK later wants to expose `/events` as a first-class capability, that is a coordination item, not a blocker.
- **#782 was a correct fix** — it distinguished Arcade from ARC and modeled the real Arcade host faithfully. It was not a wrong-endpoint blunder; its only gap was not probing the sibling ARC host. Don't retcon it.

## 8. Wallet-side work (separate items, not SDK)

- `BSV::Network::Broadcaster` + provider composition (promotion of `Services`' broadcast role).
- Affinity persistence (`broadcasts.provider`), keyed off the **known wtxid**, not the response txid.
- **Arcade SSE consumer** — new outbound ingestion + Arcade-shape decode; **reuse** the reject/record core extracted from `broadcast_callback.rb`.
- **#246** block-driven MINED resolver (+ **#245** reorg removal half) — already specced.
- **WoC reconciliation sweep** for stale SEEN_ON_NETWORK (double-spend backstop).
- **EF source-data for the `:delayed` daemon path** (#235 follow-on): the daemon submits `action[:raw_tx]` (raw hex), so it cannot produce Extended Format without a reconstructed `Transaction` (per-input source sats/scripts) or persisted EF. This is **wallet-side**, not SDK protocol divergence.

## Open / to confirm

- **Arcade SSE event coverage + resumption — RESOLVED** via Arcade PR #50 (merged 2026-04-28). REJECTED published by `tx_validator`; `Last-Event-ID` implemented as nanosecond timestamp; catchup is current-status snapshot (not historical replay) — see §5 for design consequences. Live-stream validation can come during the SSE consumer build; the contract is now sufficient to design against.
- **Reject-reason granularity loss.** Arcade's taxonomy likely surfaces a double-spend as plain `REJECTED` (no distinct `DOUBLE_SPEND_ATTEMPTED`). The unwind still fires (REJECTED is terminal), but reason granularity is lost vs ARC. Acceptable; note in telemetry.
- **~~Failover vs fan-out~~ — RESOLVED** (§6): failover-affinity (column) now; fan-out parked.
