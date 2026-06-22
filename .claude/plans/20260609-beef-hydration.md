# BEEF chain integrity + hydration as a unified architectural primitive

**Issue:** TBD (sibling HLR opens with this plan committed)
**Date:** 2026-06-09
**Status:** Plan — captures architectural reasoning from PR #294's CI failure investigation; HLR to be derived from this.

## Frame

PR #294's CI hit an intermittent failure in `consolidation_dry_run_spec` — the multi-wallet cascade where alice → bob → carol → ... fans payments and exchanges BEEFs. The failing assertion was deep in `Transaction#verify`:

```
SPV verification failed: input 0 of transaction 01a494d50c... has no
source locking script (missing_source)
```

The tx `01a494d5...` is alice's seed UTXO (the on-chain funding source). It has a merkle_path in alice's ProofStore. But the BEEF that reached the failing receiver had `01a494d5...` *without* its merkle_path attached — so verify walked into its inputs and found nothing.

The intermittence pattern matches `stress_cascade_spec` (the known flaky one): multi-hop only, randomised routing, single-wallet specs unaffected. The failure shape and the workload pattern both point at multi-wallet BEEF reforward — not at a single-wallet bug.

This plan starts from that specific failure and develops a broader architectural claim: the wallet's hydration machinery is currently three open-coded variants of one pattern, with no shared invariants and no shared substrate. Fixing the multi-wallet failure cleanly requires articulating the pattern, extracting a collaborator, and inverting one of #269's design assumptions about the EF hint cache. Phase A diagnoses; Phase D builds the durable architectural answer.

## The pattern: hydration

"Hydration" in the wallet means: **rebuild an in-memory Transaction object (or graph of them) from persisted bytes, so a downstream operation can walk it.**

Currently appears in three places, each open-coded for its consumer:

| Site | Depth | Consumer | Storage backing |
|---|---|---|---|
| `Engine::InputSource.attach!` + `Engine::Broadcast#hydrated_transaction_for` | 1 level (subject's inputs) | EF serialisation (`Transaction#to_ef`) for ARC broadcast | DB JOIN to resolve `(source_satoshis, source_locking_script, derivation params)` per input |
| `Engine::Action#wire_ancestor` + `#build_atomic_beef` | recursive to proven anchor | Atomic BEEF construction for outgoing payments | `Store#find_proof(wtxid)` — bytes + optional merkle_path |
| SDK `Transaction#verify` (during `Action#verify_incoming_transaction!`) | recursive | SPV verification of incoming BEEFs | walks the pre-wired `source_transaction` graph that the BEEF carries |

The third one isn't actually our code — we hand the SDK a pre-wired graph and it walks it. But it's the *consumer* of correctness everywhere else: if we fail to wire correctly, verify catches it.

These three appear unrelated in code but are variants of one pattern at different depths. The wallet has no unified primitive that expresses "hydrate(wtxid, mode: ...)" — each call site does its own walk against its own depth and its own data source.

## What's broken architecturally

### 1. No completeness invariant

`Action#save_beef_proofs` iterates the incoming BEEF and saves each entry's bytes + merkle_path. It silently skips `TxidOnlyEntry` (and any entry without `.transaction`). There is no post-condition check that says "the chain Bob just stored is rooted at proven anchors." If a hole exists, it surfaces three hops later when carol tries to verify a BEEF that bob reforwarded — and the error names a tx, not the boundary where the hole appeared.

### 2. No reuse, no memoisation

`wire_ancestor` is a recursive depth-first walk from `Store#find_proof`. When the same ancestor appears under two different children (common in deep cascades — the seed UTXO is in every BEEF), it gets re-read from the database and re-deserialised every time. Below tens of hops this is just wasteful; above that it's a real CI-flake driver.

### 3. Mutation hazard

`wire_ancestor` mutates the loaded tx:

```ruby
tx.merkle_path = BSV::Transaction::MerklePath.from_binary(proof[:merkle_path]).first
input.source_transaction = ancestor if ancestor
```

So a hydrated Transaction object is unsafe to share — a second consumer might mutate state the first relied on. This is *why* `Engine::HydratedTxCache` (today) is scoped narrowly to one consumer per cached entry and aggressively evicted on broadcast outcome. The cache doesn't trust the object enough to share it widely.

### 4. Aggressive eviction defeats the natural workload pattern

`Engine::Broadcast#handle_submit_success` and `#handle_submit_terminal` evict the cached entry on broadcast outcome. The LRU is documented as "the safety net" — meaning the lifecycle hooks are the primary policy. This implements an indexed-stack model: create_action pushes, broadcast pops.

That's exactly wrong for multi-wallet BEEF reforward, where re-broadcasts of growing chains *want* prior entries to stick around so the recursive walk in `wire_ancestor` short-circuits on cache hit. Aggressive eviction prevents reuse and forces every receive to re-walk the full chain back to anchors — exactly the cost the cache exists to avoid, and exactly the situation where chain-integrity bugs surface.

## The proposed architecture

### Hydrator — one primitive, three modes

A new collaborator, slotted alongside `BeefImporter` / `TxBuilder` in #290's Phase 2 extraction landscape:

```ruby
class Engine::Hydrator
  # Bytes-layer cache, keyed by wtxid, shared across fibers.
  # Holds { raw_tx, merkle_path-or-nil } per wtxid. Pure data; no
  # Transaction objects (sidesteps mutation hazard).
  def initialize(store:, cache:)
    @store = store
    @cache = cache
  end

  # Modes:
  #   :input_source — attach source_satoshis + source_locking_script
  #     to subject's inputs only. EF serialisation. (Replaces
  #     Engine::Broadcast#hydrated_transaction_for + InputSource.attach!)
  #
  #   :to_proof — recursive walk via source_transaction wiring,
  #     terminating at any ancestor with merkle_path. BEEF construction.
  #     (Replaces Action#wire_ancestor + build_atomic_beef.)
  #
  #   :fixed_depth(N) — bounded recursion. Diagnostic / future use.
  def hydrate(wtxid, mode:)
    # Reconstruct a fresh Transaction per call. Object construction is
    # cheap; the cache short-circuits the recursive ProofStore reads
    # underneath.
  end

  # Notify the cache that a new proof has arrived for wtxid. The
  # cache enriches its entry in place (monotonic upgrade); future
  # :to_proof hydrations terminate at this wtxid without descending.
  def proof_arrived(wtxid, merkle_path:, height:)
    @cache.enrich(wtxid, merkle_path: merkle_path, height: height)
  end
end
```

Each consumer asks the Hydrator for what it needs at the depth it needs. The Hydrator's cache backs all three; no consumer manages cache state directly.

### Monotonic cache — "asynchronously optimised LRU"

The cache's state property: **state only ever progresses.** New entries added; existing entries enriched when a proof arrives; nothing degraded except by LRU age-out under memory pressure. No lifecycle hooks, no broadcast-outcome eviction.

Concretely, behavioural changes vs today's `HydratedTxCache`:

| Property | Today | After |
|---|---|---|
| Keyed by | `action_id` | `wtxid` |
| Held value | `Transaction` (mutable) | `{ raw_tx, merkle_path-or-nil }` (immutable data) |
| Population | Producer pushes on `create_action`; daemon fetches on broadcast | Hydrator reads-through on first `hydrate(wtxid, ...)` miss |
| Eviction | Lifecycle (`handle_submit_success`/`_terminal`) + LRU safety net | LRU only |
| Enrichment | None | `proof_arrived(wtxid, ...)` upgrades entry in place |
| Cross-fiber | Mutex-guarded; safe but used by one consumer at a time | Mutex-guarded; freely shared across consumers |

Workload outcomes the new shape gets naturally:

- **Re-broadcast of growing chains** — second BEEF construction reuses the first's hydration. The seed (always referenced) stays warm. Deep cascade tests get faster AND become deterministic at the storage layer.
- **Block discovery (proof arrival)** — `TxProof#process` calls `Hydrator.proof_arrived(wtxid, ...)`. The cached entry enriches; future `:to_proof` hydrations now terminate at this wtxid. No invalidation needed.
- **Broadcast-and-mined tx age out** — once a tx is mined and nothing in flight references it, it stops getting touched. LRU drains it. No coordinator required.
- **In-flight unbroadcast chains keep themselves warm** — every fresh BEEF that walks through wtxid Y touches Y → LRU promotes it. Hot ancestry stays hot for free.

### Why bytes-layer caching

The cache holds `{ raw_tx, merkle_path-or-nil }` per wtxid, not Transaction objects. Three reasons:

1. **No mutation hazard.** Each call to `hydrate` constructs a fresh `Transaction.from_binary(raw_tx)`. Consumers mutate their own copy. Object construction is microseconds; what was expensive was the ProofStore read + recursive walk, which the cache short-circuits.
2. **Concurrency-safe by construction.** Mutex on the cache itself, not on the cached objects. Read-modify-write happens through `enrich(wtxid, ...)` which is mutex-guarded.
3. **Cheap memory budget.** Per-entry cost is `raw_tx.bytesize + merkle_path.bytesize` — a few hundred bytes for typical 2-in-2-out transactions. An LRU of 10K entries is single-digit MB.

### Fiber concurrency

Walletd runs many Async fibers on one reactor thread (SSE listener, broadcast pull, statuses pull, proof acquisition, hint receiver, scheduler discovery, plus per-broadcast inline tasks during a producer-driven boot). Fibers have separate stacks → no implicit sharing of local state. They share what they're given references to: module state, instance variables on shared objects.

The Hydrator's cache is *the* shared rendezvous point. Producer's `create_action` flow, daemon's broadcast flow, `TxProof#process` (proof arrival), and any future BEEF-related work all read/write through one Mutex-guarded structure. No fiber needs to coordinate explicitly — the cache state is the coordination.

This is the design model the current `HydratedTxCache` already nailed; we're just generalising its scope and inverting its eviction policy.

## Diagnostic phase — A

Add a multi-wallet round-trip integration spec that asserts BEEF storage + hydration completeness at every boundary in a controlled chain. The point is to *locate* the gap, not pre-suppose where it is.

```
fixture: alice (imported seed), bob, carol — all empty stores

Step 1: alice sends to bob (capture alice's outgoing BEEF as A_out)
Step 2: bob.internalize(A_out)
  ASSERT: bob's ProofStore contains every non-TxidOnly wtxid from A_out
  ASSERT: for every wtxid in A_out that had merkle_path, bob's
    find_proof(wtxid) returns merkle_path present
Step 3: bob sends to carol (capture bob's outgoing BEEF as B_out)
  ASSERT: B_out.wtxid_set == A_out.wtxid_set ∪ {bob's new tx}
  ASSERT: every wtxid in B_out that had merkle_path in A_out still
    has merkle_path in B_out's wire-format entry
Step 4: carol.internalize(B_out)
  ASSERT: verify completes without error (deterministic, not flaky)
Step 5: carol → alice (deepest hop)
  ASSERT: same chain invariants hold N hops in
```

Which assertion fails identifies the leak:

- **Step 2 (storage)** — `save_beef_proofs` is dropping entries. Likely `TxidOnlyEntry` skip + a code path that emits TxidOnly without `trust_self`, OR a subtle wtxid mismatch on round-trip.
- **Step 3 (forward)** — `wire_ancestor` / `build_atomic_beef` is emitting an incomplete chain even though the store has the data. Subject's BEEF doesn't carry an ancestor's merkle_path.
- **Step 4 with steps 2/3 green** — SDK's `Transaction#verify` walks the source_transaction graph incorrectly under some condition. File upstream.

Phase A is **a diagnostic spec, not a fix.** It runs in CI and stays. Future flakes that fit this shape have an immediate boundary-precise error message instead of "no source locking script" three hops downstream.

## Fix phase — B

Driven by what Phase A surfaces. Three pre-allocated branches:

- **B1 (storage gap):** `save_beef_proofs` either doesn't skip silently, or surfaces a post-condition error. Possible fixes: resolve TxidOnly entries from the receiver's existing store before deciding "skip"; add a "completeness check" that compares `beef.transactions` wtxids against post-save `find_proof` for each.
- **B2 (forward gap):** `wire_ancestor` raises when an ancestor's bytes are missing instead of returning nil. `build_atomic_beef` validates the constructed BEEF against an "every input chain terminates at a proof or has full ancestry" invariant before emitting.
- **B3 (SDK):** Upstream issue + workaround if needed; out of scope for this HLR's deliverable.

## Runtime invariants — C

Land the Phase A assertions as runtime invariants (probably opt-in via debug flag, on hot path of receive/forward). Silent partial completeness should not be possible by construction.

- `Action.internalize` post-condition: invoke completeness check after `save_beef_proofs`. Raises if a hole appeared.
- `Action#build_atomic_beef` post-condition: invoke completeness check before returning. Raises if the constructed BEEF would fail Phase A's step-3 assertion.

These are O(N) over the chain length and only run when the flag is set. Probably default-on in dev/test, default-off in production.

## Architectural target — D (the durable answer)

Extract `Engine::Hydrator` (as sketched above) and invert HydratedTxCache's eviction model:

- `Engine::Hydrator` becomes the single hydration primitive.
- `Action#wire_ancestor` / `#build_atomic_beef` collapse into `hydrator.hydrate(wtxid, mode: :to_proof)`.
- `Engine::Broadcast#hydrated_transaction_for` collapses into `hydrator.hydrate(subject_wtxid, mode: :input_source)`.
- `Engine::HydratedTxCache` becomes the bytes-layer wtxid-keyed substrate. Lifecycle eviction hooks are deleted. LRU is the sole policy.
- `Engine::TxProof#process` calls `hydrator.proof_arrived(wtxid, ...)` after persisting a new proof, enriching the cache entry in place.

Phase D depends on Phase A landing (so we have evidence the diagnostic spec passes after Phase B's fix); it composes with #290's Phase 2 Re-Classify (where `Hydrator` is exactly the kind of misclassified-as-Action-behavior collaborator that should be extracted). Sequence: A → B → D, with C lining up runtime invariants throughout.

## Sequencing summary

| Phase | What | When | Who triggers |
|---|---|---|---|
| A | Diagnostic spec — locate the gap | Standalone, lands now | This HLR |
| B | Fix the identified boundary | Immediately after A pinpoints it | This HLR |
| C | Runtime invariants as code | Lands with B | This HLR |
| D | Hydrator + monotonic cache extraction | After A/B/C; composes with #290 Phase 2 | #290 picks it up as one of the named collaborators |

A/B/C close the bug. D produces the durable architecture that prevents the next variant of the bug, and falls out cleanly from the #290 work we're already going to do.

## Open questions

1. **Hydrator's `mode: :input_source` for EF serialisation needs source `derivation_prefix`/`derivation_suffix` too** (the daemon's broadcast path uses these for re-signing if needed). The cache holds `{raw_tx, merkle_path}` only — derivation data is action-scoped, not wtxid-scoped. Either the Hydrator pulls derivation data separately (its own DB hit, just for EF mode), or the cache value is widened. **Lean: separate fetch.** The action_id-keyed shape that today's HydratedTxCache uses for the EF path stays — but it becomes a per-mode adapter sitting *on top of* the wtxid-keyed substrate, not a parallel cache.

2. **Does `proof_arrived` need to invalidate downstream cached chains?** No — the monotonic property says the chain *gets better*. A future `:to_proof` hydration starting deeper than the newly-proven entry now terminates earlier. Cached entries below the new anchor are still valid (their bytes haven't changed); they just won't be walked by future :to_proof requests because the walk stops sooner.

3. **Memory bounds with deep stress-cascade chains.** ~219 actions × ~73-deep chains = ~16K wtxids max. With ~500 bytes per entry that's ~8MB. Comfortable. Production single-wallet usage is much smaller. Default LRU size of 10K-50K entries is fine. (Today's HydratedTxCache defaults to 1000 entries via `BSV_WALLET_TX_CACHE_SIZE`; keep the same env var, raise the default.)

4. **Re-broadcast semantics with the new model.** If a tx fails terminal-reject and the operator manually retries, the cache entry is still valid (bytes are deterministic). No special re-broadcast logic needed.

5. **What about the EF hint push from producers (#269)?** Today's producer pushes the hydrated Transaction via OMQ socket. Under the new model, the producer doesn't need to push — both producer and daemon read through the same shared cache (in the same process? in different processes? — process boundary matters). For in-process, the cache is shared via Mutex; the push goes away. For multi-process (producer = CLI subprocess, daemon = walletd), the OMQ push remains the cross-process bridge, but its payload becomes "here's a wtxid + bytes + maybe merkle_path for the cache" instead of "here's an action_id + Transaction object." Simpler payload, same delivery.

## Acceptance criteria mirror (for HLR)

- [ ] Phase A diagnostic spec exists, runs in CI, deterministically pinpoints any chain-integrity boundary failure.
- [ ] Phase B fix lands at whichever boundary A identifies. The cascade tests become deterministically green.
- [ ] Phase C runtime invariants exist as opt-in checks at receive and forward boundaries.
- [ ] Phase D: `Engine::Hydrator` extracted; `Action#wire_ancestor` / `#build_atomic_beef` collapse to delegators; `Engine::HydratedTxCache` keyed by wtxid, lifecycle eviction deleted, `proof_arrived` enrichment added.
- [ ] `Engine::TxProof#process` notifies the Hydrator on new proof.
- [ ] Cache's memory bound is configurable; default raised to handle stress-cascade depth.
- [ ] #290's Phase 2 design includes the Hydrator extraction as a tracked collaborator (cross-link).
- [ ] CLAUDE.md / `docs/reference/` documents the hydration discipline as one of the wallet's architectural patterns.

## Out of scope

- General BeefImporter / TxBuilder extraction — #290 Phase 2 territory.
- Replacing the BEEF chain protocol with txid-only / known-ancestor pruning — #192.
- Multi-process EF hint delivery details — separate concern when/if the producer-daemon split becomes a deployment.
- SDK fixes if Phase A's step 4 fails with everything else green — file upstream.
