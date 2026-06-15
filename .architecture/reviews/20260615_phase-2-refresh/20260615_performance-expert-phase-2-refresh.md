# Performance Review — Issue #290 Phase 2 refresh (classification after #307 + #296)

**Reviewer:** Viktor Petrov, Performance Expert (`performance_expert`)
**Target:** Issue #290 comment *"Phase 2 refresh — classification after #307 + #296 egress landed (2026-06-15)"* — refreshed `Engine::Action` re-classification for the #291 Engine refactor.
**Scope:** Performance lens only. Classification (design) stage — no code under review yet.
**Date:** 2026-06-15

---

## Perspective

I ask one question of every design: *what happens at 10x scale?* For this wallet that is not rhetorical — ADR-002 names millions of transactions per second as the load-bearing assumption that justifies the immutability, partitioning, and tiered-pool costs taken elsewhere. So the bar for Phase 2 is narrow and specific: **the extraction must not add DB round-trips, per-call allocation, or cross-collaborator chatter to the hot send path** (`create_action` → `run_funding_loop` → `generate_change` → `build_atomic_beef` → broadcast). A pure-decomposition refactor that is behaviour-preserving is performance-neutral by definition. My job is to confirm the proposed boundaries *can* be cut behaviour-preservingly, and to flag the two places where they are tempting to cut otherwise.

## Assessment

**Classification is sound from a performance standpoint, with one redesign (the Hydrator/cache inversion) that is a net win and two boundaries that must be drawn as zero-copy collaborations rather than re-fetching ones.** Nothing in the table mandates a regression. But the refactor moves method bodies across object boundaries on the single hottest path in the wallet, and the natural Ruby instinct — "each collaborator owns its own data, so each re-resolves what it needs" — would silently triple `resolve_inputs_for_signing` calls per action. The extraction HLRs must make pass-through explicit. The design stage is the cheap place to bake that in; after extraction it is a profiling archaeology exercise.

This is a classification refresh, so I am deliberately not manufacturing findings. There are three scale risks worth carrying into the extraction HLRs (Concerns 1–3) and the rest is genuinely neutral.

## Strengths

1. **The Hydrator redesign is the single biggest performance improvement in the whole roadmap, and it is correctly motivated.** The plan (`20260609-beef-hydration.md` §2) names the exact pathology: `wire_ancestor` is a recursive DFS over `Store#find_proof`, and the seed UTXO appears in *every* BEEF of a cascade, so it is re-read and re-deserialised on every hop. That is O(hops × depth) redundant DB reads today. The wtxid-keyed monotonic cache collapses it to O(unique-wtxids) with short-circuit on cache hit. Inverting eviction from lifecycle (`handle_submit_success`/`_terminal`) to LRU-only is precisely right for the reforward workload: aggressive eviction was defeating the natural locality (every fresh BEEF that walks wtxid Y re-touches Y → LRU keeps hot ancestry hot for free). This is measurement-driven (it came out of a real CI-flake investigation), not speculative.

2. **Bytes-layer caching over Transaction objects is the correct memory and concurrency call.** Holding `{raw_tx, merkle_path}` (~500 bytes/entry, ~8MB for the 16K-wtxid stress-cascade worst case) instead of mutable `Transaction::Tx` graphs sidesteps both the mutation hazard *and* the per-object retained-graph cost. A 10K–50K LRU is single-digit MB. The "construct a fresh `Transaction.from_binary` per call" trade is the right one — object construction is microseconds; the DB read + recursive walk it replaces was the expense.

3. **`FundingStrategy` is the natural home for #213's contention-retry — and the retry belongs at the pool boundary, not retrofitted to today's `run_funding_loop`.** Lock contention under horizontal scaling (ADR-002's multi-worker model) is resolved structurally by the single-spend `UNIQUE`; the retry-on-contention loop is a hot-path concern that wants to live next to `select_inputs`/`lock_inputs`, exactly where the classification puts it.

4. **Correction 1 (verification is SDK-delegated, fold to one `verify_beef` helper) removes a phantom collaborator.** Fewer objects on the path, one fewer indirection. Performance-neutral-to-positive and correctly scoped.

## Concerns

### Concern 1 — `resolve_inputs_for_signing` fan-out across the new collaborators (Severity: HIGH)

This is the one that will bite if not designed in now. Today `resolve_inputs_for_signing(action_id:)` — a JOIN to recover `(source_satoshis, source_locking_script, derivation params)` per input — is already called **multiple times per send action** within `Action`:

- `run_funding_loop` → `generate_change` calls it (line 948) once per funding iteration;
- `total_input_satoshis_for` calls it again for the post-loop headroom check (line 900);
- `build_atomic_beef` calls it again (line 600).

Splitting `FundingStrategy` (owns the funding loop), `TxBuilder` (owns `build_transaction`/`build_inputs`), and `Hydrator` (owns `build_atomic_beef`) across three objects removes the implicit shared scope that *could* memoise this. The naive extraction has each collaborator independently re-resolve inputs for the same `action_id` — turning N calls into N collaborators × N calls, each a DB round-trip. At 10x throughput that JOIN multiplies directly into connection-pool pressure.

**Fix:** The extraction HLRs must specify that resolved-input data is **passed between collaborators as a value**, not re-fetched. `FundingStrategy` resolves once and hands the resolved set (and the live `Transaction::Tx` with source data already wired — the trailing `tx` the funding loop already returns, see lines 842–846) forward to `TxBuilder`/`Hydrator`. State a hot-path invariant in each HLR's acceptance criteria: *"`resolve_inputs_for_signing` is called at most once per `create_action` for a given action_id."* Today's code already threads the live `tx` forward for exactly this reason (the `to_ef` comment at line 527, 845); the extraction must not lose that threading by hiding it behind object boundaries.

### Concern 2 — Open question 1 (EF-mode derivation fetch) risks a parallel cache and a per-broadcast DB hit (Severity: MEDIUM)

The hydration plan's open question 1 acknowledges that `mode: :input_source` (EF serialisation for broadcast) needs `derivation_prefix`/`derivation_suffix`, which are **action-scoped, not wtxid-scoped**, so they cannot live in the wtxid-keyed substrate. The lean is "separate fetch," with an action_id-keyed adapter on top. That is acceptable, but the risk is two-fold at scale: (a) the adapter quietly reintroduces a per-broadcast `resolve_inputs_for_signing` DB hit that #269's hint cache was built to eliminate (`Broadcast#hydrated_transaction_for`, line 232–236, currently skips that JOIN on cache hit); (b) two caches with different keys and different eviction risk drifting into the "cache beside canonical state" anti-pattern the principle-of-state warns against.

**Fix:** The Hydrator extraction HLR (Phase 5) must explicitly preserve the #269 zero-query broadcast on cache hit. The EF-mode adapter should be populated from the *same producer-side data already in hand* (the producer built the BEEF and knows the derivation params — push them with the hint, per the plan's §"EF hint push" answer), not lazily re-fetched on the daemon's broadcast path. Make "broadcast on warm cache costs zero DB round-trips" an acceptance criterion so the regression is caught by design review, not production profiling.

### Concern 3 — Cache mutex contention under the fiber reactor at scale (Severity: LOW, worth a note not a redesign)

The monotonic cache becomes *the* cross-fiber rendezvous (plan §"Fiber concurrency") — producer create_action, daemon broadcast, `TxProof#process` proof-arrival enrichment, and future BEEF work all read/modify/write through one `Mutex`. The plan's justification (MRI Mutex doesn't park the reactor on uncontended acquire) is correct *today*, but `enrich` (read-modify-write under proof arrival) and `hydrate` (read + potential read-through `find_proof` populate) holding the lock across a **DB read** would serialise all fibers behind that DB latency. The current `HydratedTxCache` only ever holds the lock across in-memory hash ops (lines 63–85) — fast. A read-through-on-miss cache that does `find_proof` *inside* `synchronize` would change that profile.

**Fix:** Specify in the Hydrator HLR that the mutex is held only across in-memory cache mutation — the `find_proof` read-through happens *outside* the lock (compute-then-store, tolerate a benign double-fetch race rather than holding the lock across I/O). Keep the substrate's critical section as tight as today's. Not a blocker; a one-line design constraint that is free to state now and expensive to discover later.

## Recommendations

1. **Bake a hot-path round-trip budget into each extraction HLR's acceptance criteria.** Concretely: *"`resolve_inputs_for_signing` called ≤ once per action per `create_action`"* (Phases 3–5) and *"broadcast on warm cache = zero DB round-trips"* (Phase 5). These are cheap to assert at design time and are the regression class most likely to slip through a behaviour-preserving refactor whose specs check correctness but not query count.

2. **Make the inter-collaborator contract pass-by-value for resolved inputs and the live `Transaction::Tx`.** The funding loop already returns the wired `tx`; the extraction must thread it forward explicitly rather than letting each collaborator re-hydrate. Document the threading in the Phase 3/4 HLR signatures.

3. **Hold the Hydrator cache mutex across in-memory ops only — never across `find_proof` / DB I/O.** One sentence in the Phase 5 HLR; preserves the tight critical section the current cache already has.

4. **Carry the wtxid-keyed monotonic cache through as the highest-value item, and raise the default LRU size as the plan specifies** (1000 → 10K–50K via `BSV_WALLET_TX_CACHE_SIZE`). This is the one change here that *improves* hot-path performance rather than merely preserving it; sequence it (Phase 5, before BeefImporter) as the refresh already orders.

5. **No new performance-bearing abstractions beyond what the classification names.** The classification is appropriately lean (Correction 1 removed a collaborator). Resist any temptation in the extraction to add per-collaborator caches/indirection — the wtxid substrate is the only cache the send path needs.

## Verdict

Classification is performance-sound; the Hydrator/cache inversion is a measured improvement, not a risk. The single thing that must not be lost in extraction is the **shared resolved-input data** that today's monolithic `Action` gets for free from shared scope — Concern 1 is the one to nail down in the Phase 3–5 HLRs. Concerns 2 and 3 are cheap design constraints to state now. ADR-002's scale intent is preserved by the proposed boundaries provided the round-trip budget is made explicit rather than left implicit.
