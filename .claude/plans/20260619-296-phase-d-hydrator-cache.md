# #296 Phase D — Hydrator-owned monotonic wtxid cache

> Branch `feat/296-beef-hydration`. Phase C (ingress proof-closure invariant)
> landed as commit `c6f8064`. This plan covers Phase D only.
> Forks settled 2026-06-19 (see Decisions).

## Goal

Replace the lifecycle-coupled, `action_id`-keyed EF hint cache (`HydratedTxCache`,
#269) with a single **wtxid-keyed, immutable-bytes, LRU-only, monotonically
enriched** cache owned by `Engine::Hydrator`. It becomes the shared substrate
that both egress paths read through — shallow EF (broadcast → miner) and deep
BEEF (`wire_ancestor` → peer) — and that proof-arrival enriches in place, so
recursive ancestry walks short-circuit on cached merkle-proven terminals.

## Decisions (settled forks)

1. **Convert the one cache** (not a second cache for the deep path). The single
   wtxid cache serves both the EF and BEEF paths. The existing cache *is* the
   EF hint cache, so this forces the broadcast EF read path to be rebuilt — the
   main risk, see D3.
2. **`proof_arrived` lives on the Hydrator** (per the issue AC). Hydrator owns
   the cache privately; `Broadcast` and `TxProof` depend on the Hydrator.
   `Hydrator#proof_arrived(wtxid, raw_tx:, merkle_path:)` is the single named
   enrichment entry point; the cache's `enrich` is its private primitive.

## Now (current state)

- `HydratedTxCache`: `action_id` → fully-wired mutable `Transaction::Tx`.
  - Writer: `Broadcast#hints_pull!` only (cross-process producer hints).
    Intra-process `create_action` does **not** prime it.
  - Reader: `Broadcast#hydrated_transaction_for` — hit serves EF; miss
    reconstructs via `from_binary` + `resolve_inputs_for_signing` (#252 floor).
  - Eviction: `Broadcast` evicts on terminal broadcast (`broadcast.rb:339,389`).
  - Owned by `Engine::Broadcast` as `@hydrated_tx_cache`. `Hydrator` and
    `TxProof` have no handle. `Hydrator#wire_ancestor` reads `store.find_proof`
    directly, no memoisation.
- Two in-memory cache instances per process pair: inline Engine
  (`@hydrator` + `@broadcast_worker`) and daemon (`Broadcast` + `TxProof`).
  `Engine#publish_beef_hint` bridges inline → daemon over OMQ.
- **EF source-data floor:** per-input satoshis + locking script live in the
  `inputs` table (`resolve_inputs_for_signing`), populated at sign time,
  independent of proofs. The proof-shaped cache only holds a parent's bytes
  when we have it (proof or hint), so it *accelerates* but does not replace the
  JOIN.

## After (target)

- `HydratedTxCache`: `wtxid` → immutable `{ raw_tx:, merkle_path: }` (bytes;
  `merkle_path` nil until a proof arrives). No Tx objects — sidesteps the
  concurrent-fiber `source_transaction` mutation hazard.
- LRU is the **sole** eviction policy. No lifecycle hooks.
- `proof_arrived` enriches `merkle_path` in place — monotonic, never
  invalidates. A hit-with-merkle in `wire_ancestor` is a terminal (no descent).
- Owned by `Hydrator`; one instance per process, injected into `Broadcast`
  (EF reads + hint writes) and reachable by `TxProof` (via the Hydrator).
- Principle-of-state clean: the value mirrors a `tx_proofs` row; drop the cache
  and rebuild from DB → identical behaviour. (`reference/principle-of-state.md`)

## Wiring design

```
                 HydratedTxCache (wtxid → {raw_tx, merkle_path})
                        ▲            ▲              ▲
            wire_ancestor│   EF reads │   proof_arrived│
                         │  hint write│                │
                    Hydrator ◀──────── Broadcast    TxProof ──▶ Hydrator#proof_arrived
            (owns cache; proof_arrived)  (holds cache)  (holds Hydrator)
```

- **Hydrator** constructed with the cache. Public surface gains
  `proof_arrived(wtxid, raw_tx:, merkle_path:)`. `wire_ancestor` becomes
  cache-aware (read-through + populate). `build_atomic_beef` /
  `validate_for_handoff!` unchanged behaviourally, now cache-warmed.
- **Broadcast** holds the same cache instance for `hydrated_transaction_for`
  (per-input source reassembly) and `hints_pull!` (writes). The eager-proof
  path (`link_proof_if_present`) calls `hydrator.proof_arrived` — so Broadcast
  also holds the Hydrator. (Inline Engine already has both; daemon constructs a
  Hydrator and shares it.)
- **TxProof** holds the Hydrator; on a freshly saved proof calls
  `hydrator.proof_arrived`.
- **Engine ctor**: one cache, shared by `@hydrator` + `@broadcast_worker`.
- **Daemon `run!`**: construct one cache + one Hydrator; inject into the
  daemon's `Broadcast` and `TxProof`.

## Staged steps (sequential commits on the branch)

### D1 — Rewrite `HydratedTxCache`
- wtxid key; value `{ raw_tx:, merkle_path: }`; LRU-only; drop `evict`.
- `put(wtxid, raw_tx:, merkle_path: nil)`, `get(wtxid)`,
  `enrich(wtxid, merkle_path:)` (monotonic — no-op if already set; never clears).
- Keep Mutex + insertion-order LRU. `capacity: 0` = always-miss.
- Files: `engine/hydrated_tx_cache.rb`, new isolation spec.

### D2 — Hydrator integration
- Inject `cache:`. `wire_ancestor`: check cache → hit-with-merkle terminates;
  hit-without recurses over cached `raw_tx`; miss reads `store.find_proof` and
  populates the cache. Preserve the cycle-guard and the raw_tx-too-short guard.
- Add `proof_arrived(wtxid, raw_tx:, merkle_path:)` → `cache.put` then
  `cache.enrich`.
- Files: `engine/hydrator.rb`, `interface/hydrator.rb`, hydrator spec.

### D3 — Broadcast EF path (highest risk)
- `hydrated_transaction_for`: parse `action[:raw_tx]`; for each input try
  `cache.get(prev_wtxid)` → parse → `outputs[vout]` → `InputSource.attach!`;
  on any miss fall back to `resolve_inputs_for_signing` for the whole set
  (the #252 / `inputs`-table floor).
- `hints_pull!`: write wtxid entries (`cache.put` per BEEF tx) instead of one
  `action_id` → Tx.
- **Delete** the two lifecycle `evict` calls (success / terminal).
- `link_proof_if_present`: also `hydrator.proof_arrived` on the eager proof.
- Files: `engine/broadcast.rb`, broadcast spec(s).

### D4 — TxProof enrichment
- After `save_proof` + `link_proof`, call
  `hydrator.proof_arrived(wtxid:, raw_tx: action[:raw_tx], merkle_path:)`.
- Files: `engine/tx_proof.rb`, tx_proof spec.

### D5 — Wiring + config
- Engine ctor: build one cache, inject into `@hydrator` and `@broadcast_worker`
  (Broadcast also gets the Hydrator).
- Daemon `run!`: one cache + one Hydrator → daemon `Broadcast` + `TxProof`.
- Bump `tx_cache_size` default for the stress-cascade working set
  (issue: ~16K wtxids). Keep `BSV_WALLET_TX_CACHE_SIZE` override.
- Files: `engine.rb`, `daemon.rb`, `config.rb`, `config/config.example.rb`.

### D6 — Docs
- Reverse the "Not the Hydrator's concern" note in `interface/hydrator.rb`
  (the EF cache now IS the Hydrator's concern).
- Rewrite the `HydratedTxCache` class doc (monotonic / wtxid / LRU-only).
- Hydration-discipline note in `reference/` + CLAUDE.md pointer (per AC).
- Cross-link #290 Phase 2 (Hydrator as tracked collaborator) — comment only.

## Risks

- **D3 EF correctness** (inline + daemon). The cache reassembles source data
  from proof-shaped parent bytes; `resolve_inputs_for_signing` stays the floor.
  Spec both: warm-cache hit path AND cold-miss JOIN fallback, EF byte-identical.
- **Deleting lifecycle evicts** — confirm no spec asserts post-broadcast
  eviction as a behaviour (it was a #269 invariant); rewrite those to LRU.
- **Stress-cascade memory** — the raised default holds ~16K bytes-entries; cheap
  vs Tx objects, but confirm under the cascade spec.

## Acceptance criteria (from #296)

- [ ] `HydratedTxCache` keyed by wtxid; lifecycle eviction deleted;
      `proof_arrived` enrichment added.
- [ ] `Engine::TxProof#process` notifies the Hydrator on new proof.
- [ ] Cache memory bound configurable; default raised for stress-cascade depth.
- [ ] `wire_ancestor` / `build_atomic_beef` cache-warmed (collapse already done
      in #343; this wires the cache through them).
- [ ] #290 Phase 2 cross-link; CLAUDE.md / `reference/` hydration discipline.

## Out of scope

- Egress `validate_for_handoff!` relocation to `Engine::Transmission` — #385.
- BeefImporter / TxBuilder further extraction — #290 Phase 2.
- TxidOnly / known-ancestor pruning protocol — #192.
