# Plan — HLR #516: Persistent verification cache

> See [HLR #516](https://github.com/sgbett/bsv-wallet/issues/516).

## Premise

The wallet's `internalize_action` walks every ancestor in every incoming BEEF and runs full script + ECDSA verification on each unproven tx. The work is redundant — the same ancestor tx appearing in successive BEEFs is re-verified from scratch each time, even though verification is a permanent, tx-immutable fact. We persist the *bytes* (in `tx_proofs`) but not the *verification result*. That gap makes per-receive cost grow with cumulative state, not new state. PR #512's stress workload exposed it empirically — iter 1 cost ~1s, iter 100 cost 30+ minutes.

The fix: persist the verification fact alongside the bytes, short-circuit the verify-walk on cache hit. Three-tier cache (process memory → persistent → verify); this work adds the missing persistent tier.

## Decisions taken (resolving HLR open questions)

### 1. SDK extension vs wallet-side pruning → **SDK extension (`verified:` kwarg)**

Plan: add `Tx#verify(chain_tracker:, fee_model:, verified: nil)` to `bsv-ruby-sdk`. The SDK's existing implementation at `lib/bsv/transaction/tx.rb:633-640` already maintains an in-call `verified = {}` hash that short-circuits repeated ancestors within a single walk:

```ruby
def verify(chain_tracker:, fee_model: nil)
  verified = {}
  queue = [self]
  until queue.empty?
    tx = queue.shift
    wtxid = tx.wtxid
    next if verified[wtxid]   # <-- within-walk dedup, already there
    # ...
  end
end
```

The wallet's persistent cache is the cross-call version of the same data structure. Exposing the SDK's existing Hash as a `verified:` kwarg lets the caller pre-seed it from a persistent store. Two-line SDK change:

```ruby
def verify(chain_tracker:, fee_model: nil, verified: nil)
  verified = verified ? verified.dup : {}   # honour caller's pre-seed
  queue = [self]
  # ... rest unchanged ...
end
```

Why this is the right shape:
- The SDK already owns the recursion AND the dedup Hash. Adding a kwarg just exposes it; no new path.
- Naming aligns: the kwarg name `verified:` matches the existing internal Hash name. No new vocabulary.
- The wallet's `verifier_version + verified_via` gate ensures only validated entries are passed in — trust is the caller's concern, the SDK is just respecting an assertion.
- Confirmed orthogonal to SDK #881: the #881 plan's §5 explicitly notes ancestor dedup is "already in the code, no work needed" — #881 doesn't touch this path.
- Wallet-side pruning would have to mutate parsed BEEF state, which is invasive and would break round-tripping.

### 2. Reaper vs lazy chain-anchor check → **both, in order**

Lazy first (correctness baseline, works for CLI subprocesses):
- On cache hit for a tx with a merkle path: query chain_tracker to confirm the anchor is still on the canonical chain.
- For unproven txs (no merkle path): no anchor to check, free.
- Adds one chain_tracker call per cache hit for proven ancestors. Cached chain_tracker lookups are local DB hits — cheap.

Active reaper later (optimisation for walletd):
- Chain_tracker subscribes to "reorg detected" events.
- Reaper job batch-invalidates affected tx_proofs rows.
- Removes the per-hit lazy check overhead for daemon use.

The lazy check stays as a safety net even with the reaper running. Belt + braces.

### 3. Concurrency locking → **optimistic**

Verify is a pure function. Two concurrent processes verifying the same wtxid produce identical results. Write-wins is correct — both writers compute the same state, so last-writer-wins yields the right answer. Only cost is a wasted write under contention; acceptable.

No row locks, no advisory locks. Cache lookup is a plain read query.

### 4. Backfill on first deploy → **lazy (no-op)**

Pre-release: no production rows. Existing `tx_proofs` rows have `verified_at IS NULL` — treated as miss until next reference, which triggers verify-and-cache naturally. No backfill script needed.

If/when we do have production rows post-release, the same lazy strategy stays correct — the first verify after upgrade populates the cache, no upfront cost.

### 5. `'broadcast_ack'` distinct from `'spv'` → **yes, keep**

Different trust semantics:
- `'spv'` — full SPV walk against `chain_tracker` (the strongest claim)
- `'broadcast_ack'` — ARC has accepted, but we may not yet have a merkle proof (the network has it, but it isn't anchored to a header chain we've validated)
- `'self_built'` — wallet constructed it; trust the builder

Three values are mutually informative. Downstream consumers may want to know "is this on-chain yet" (distinguishes `'broadcast_ack'`/`'spv'` from `'self_built'`). Once a `'broadcast_ack'` row gains a validated merkle path, it can be upgraded to `'spv'`.

### 6. `'imported'` enum value → **deferred**

The HLR raised this for "trustSelf hydration of TXID-only entries where we have the bytes from our own history". The use case is currently absent — we don't accept TXID-only entries that we can't fully verify. Add the enum value if/when a concrete use case arises.

### 7. Schema migration discipline → **amend `001_create_schema.rb` in place**

Pre-release rule still applies (no release has shipped). Add the new enum + columns + CHECK to `001`. SQLite path uses the existing `c[:type]` hash trick to translate ENUM → TEXT + CHECK.

## Schema design (precise)

Additions to `001_create_schema.rb`:

```sql
-- New enum type (Postgres) / TEXT + CHECK (SQLite via hash trick)
CREATE TYPE verification_source AS ENUM ('self_built', 'spv', 'broadcast_ack');

-- tx_proofs gains three columns
ALTER TABLE tx_proofs
  ADD COLUMN verified_at      TIMESTAMPTZ          NULL,
  ADD COLUMN verified_via     verification_source  NULL,
  ADD COLUMN verifier_version INTEGER              NULL;

-- Coherent state: all three fields move together
ALTER TABLE tx_proofs ADD CONSTRAINT verification_state_coherent CHECK (
  (verified_at IS NULL AND verified_via IS NULL AND verifier_version IS NULL) OR
  (verified_at IS NOT NULL AND verified_via IS NOT NULL AND verifier_version IS NOT NULL)
);

-- Partial index for fast cache lookups
CREATE INDEX idx_tx_proofs_verified ON tx_proofs (wtxid)
  WHERE verified_at IS NOT NULL;
```

In Ruby (`Sequel::Migration`):

```ruby
add_column :tx_proofs, :verified_at, :timestamptz, null: true
add_column :tx_proofs, :verified_via, c[:verification_source], null: true  # hash-trick for SQLite
add_column :tx_proofs, :verifier_version, :integer, null: true

# constraint name: verification_state_coherent
constraint :verification_state_coherent,
  Sequel.lit(<<~SQL.strip)
    (verified_at IS NULL AND verified_via IS NULL AND verifier_version IS NULL) OR
    (verified_at IS NOT NULL AND verified_via IS NOT NULL AND verifier_version IS NOT NULL)
  SQL
```

The Postgres ENUM type goes alongside `broadcast_intent` at the top of `001`. SQLite gets TEXT + CHECK via the `c` hash. Both paths use the same column name in the model.

## SDK change required (separate PR)

Repo: `sgbett/bsv-ruby-sdk`. Change: `Tx#verify` accepts `verified:` kwarg that pre-seeds the existing in-call dedup Hash.

```ruby
# Before (lib/bsv/transaction/tx.rb:633)
def verify(chain_tracker:, fee_model: nil)
  verified = {}
  queue = [self]
  # ...
end

# After
def verify(chain_tracker:, fee_model: nil, verified: nil)
  verified = verified ? verified.dup : {}
  queue = [self]
  # ... rest unchanged ...
end
```

Acceptance:
- New kwarg defaults to nil (no behaviour change for existing callers).
- When provided, supplied wtxids are treated as already-verified — the SDK skips their subtree the same way it currently skips on-walk-repeats.
- `.dup` so the caller's set isn't mutated by the in-call additions.
- Spec: build a tx whose source_transaction has a deliberately-invalid input, verify with that source's wtxid in `verified:` → passes. Verify without it → fails.
- Spec: kwarg ignored for inputs with merkle_path (those still verify via chain_tracker; the kwarg is for unproven subtrees).
- Spec: caller's set unchanged after call (dup semantics).

Coordinates with SDK #881:
- The #881 plan's §5 explicitly lists ancestor dedup as "already in the code, no work needed". #881 touches the per-Tx sighash machinery; this change touches the verify-walk dedup. Orthogonal surfaces, no merge conflict.
- The verify body may grow other instrumentation as #881 phases land (Layer 1–5 caches). The kwarg's site (pre-seed the `verified` Hash at the top of the body) is stable regardless.
- Sensible to wait for #881 code to land before opening the PR for this kwarg — review of the kwarg PR is cleaner against the post-#881 verify body. Not strictly blocking, but tidier.

Sequencing: open the SDK issue alongside this branch's Phase 1; PR after #881 lands or in parallel if convenient. SDK release with the kwarg gates wallet Phase 5.

## ADR scope (for separate creation)

ADR-033: "Verification result is canonical persistent state"

Captures:
- **Principle**: verification result is permanent and tx-immutable; belongs persisted, not recomputed.
- **Pattern**: three-tier cache (process memory → persistent DB → full verify). The persistent tier is the load-bearing addition; it bridges process boundaries, daemon restarts, future cluster scaling.
- **Home**: `tx_proofs.verified_at` + `verified_via` + `verifier_version`. Same table as the bytes the verification concerns.
- **Invalidation**: chain-aware; two events (re-org, verifier-version bump). Lazy check + active reaper.
- **Composition**: with #513 (pool management — consolidators benefit from cached ancestor verification) and #515 (token protection — both surfaces classify-and-persist at ingress).

ADR landing: with Phase 1 commit (schema + constant). Same commit or sequential commit, plan-first style.

## Phased implementation

Each phase = one PR. Each PR's body links back to this HLR with `Closes #SUB-N` for its sub-issue.

### Phase 1: Foundation (schema + constant + ADR)

- Add `verification_source` enum / `c[:verification_source]` hash entry in `001_create_schema.rb`
- Add `verified_at`, `verified_via`, `verifier_version` to `tx_proofs` (with CHECK constraint)
- Add partial index on `(wtxid) WHERE verified_at IS NOT NULL`
- Add `BSV::Wallet::Engine::VERIFIER_VERSION = 1` constant
- Add `Store#mark_verified(wtxid:, via:, at: now)` and `Store#verified?(wtxid:)` interface methods
- ADR-033 (verification as canonical state)
- Specs: schema-coherent CHECK behaviour, constant exists, Store methods round-trip
- **No behaviour change yet** — cache is dormant until later phases write/read it

### Phase 2: Ingress write path (BeefImporter populates cache)

- After successful `verify_incoming_transaction!`, walk the BEEF's tx list
- For each wtxid: call `Store#mark_verified(wtxid:, via: 'spv', at: now)`
- Persists verification fact for the subject + every ancestor that was walked
- Spec: ingress of BEEF populates cache for subject + all ancestors
- Spec: ingress failure does NOT populate cache (no partial writes)

Independent of Phase 3, can land first.

### Phase 3: Egress write path (self_built)

- After successful sign/atomic-complete, call `Store#mark_verified(wtxid:, via: 'self_built')` for the new tx
- Touch points: `Action#sign!`, `Action#complete_internal!`, `BeefImporter`'s self-built side (atomic completion of incoming as internal)
- Spec: send populates cache as `self_built`
- Spec: internal action completion populates cache as `self_built`

Independent of Phase 2, can land in parallel.

### Phase 4: SDK extension (separate repo)

In `bsv-ruby-sdk`:
- File issue describing the change.
- Implement `Tx#verify(trusted_wtxids:)`.
- Release with version bump.

In wallet (after SDK release):
- Bump `bsv-sdk` gemspec dependency to the new version.
- No wallet code change in this phase — just dependency.

### Phase 5: Read path (the short-circuit)

- In `BeefImporter#verify_incoming_transaction!`:
  - Parse BEEF.
  - Collect the wtxid list.
  - Batch-query `Store#verified_wtxids(in: list)` → returns the subset with `verified_at IS NOT NULL AND verifier_version >= current`.
  - Pass that set as `trusted_wtxids:` to `subject_tx.verify(chain_tracker:, trusted_wtxids:)`.
- Spec: stress workload (PR #512's `three_wallet_stress_spec.rb`) shows **flat per-iteration cost** through iter 200. Target: iter 100 cost within 2× of iter 10 cost.
- Spec: cold (empty cache) vs warm (populated) receive timing reflects the cache's effect.

This is the win. Sequenced after Phases 1–4 land.

### Phase 6: Re-org invalidation (lazy)

- On cache hit for a tx with `merkle_path IS NOT NULL`: confirm chain_tracker still has the anchor block at the expected height with the expected root.
- If mismatch: clear `verified_at`, `verified_via`, `verifier_version` on that row; treat as miss; re-verify.
- Spec: simulated re-org (manually flip a stored block's merkle_root) → cache hit triggers re-verify.

### Phase 7: Re-org invalidation (active reaper, walletd only)

- Chain_tracker emits `:reorg_detected` events with affected height range.
- Walletd's reaper job consumes events; batch-update `tx_proofs` setting verification fields to NULL where `block_id IN (affected_blocks)`.
- Specs: reorg event → batch update; subsequent verify-walk re-runs.

Deferred until daemon event surface is settled.

### Phase 8: Broadcast ack upgrade

- When broadcast worker receives ARC acceptance (200/202): call `Store#mark_verified(wtxid:, via: 'broadcast_ack')` to upgrade `self_built` → `broadcast_ack`.
- Trust is unchanged (still valid), the metadata records the lifecycle stage.
- Spec: post-broadcast row reflects `'broadcast_ack'`.

Quality-of-implementation, low priority once the read-path win lands.

## Sub-issue structure

Filed against #516 as parent. Each one carries its own `Closes #N` for the eventual PR.

| Sub | Phase | Title | Depends on |
|-----|-------|-------|------------|
| 1   | 1     | Schema + verifier_version constant + ADR-033 | — |
| 2   | 2     | BeefImporter populates verification cache (ingress) | Sub 1 |
| 3   | 3     | Egress paths populate verification cache (self_built) | Sub 1 |
| 4   | 4     | SDK Tx#verify trusted_wtxids: kwarg (bsv-ruby-sdk) | — (cross-repo) |
| 5   | 5     | BeefImporter consults cache + short-circuits verify-walk | Sub 1, 2, 4 (SDK released) |
| 6   | 6     | Lazy re-org check on cache hit (anchor liveness) | Sub 5 |
| 7   | 7     | Active reaper in walletd (event-driven invalidation) | Sub 6 |
| 8   | 8     | Broadcast ack upgrades self_built → broadcast_ack | Sub 1, 3 |

Critical path: 1 → 2 → 4 → 5. Subs 3, 6, 8 can land independently around that path. Sub 7 is daemon-only and deferred.

## Acceptance criteria (HLR-level)

- [ ] All sub-issues 1–6 closed (5 + lazy invalidation = minimum viable; reaper and ack upgrade can follow)
- [ ] Schema changes land in `001_create_schema.rb` (Postgres + SQLite via hash trick)
- [ ] ADR-033 in `.architecture/decisions/adrs/`
- [ ] `BeefImporter#import` populates the cache on success, consults it on entry
- [ ] `three_wallet_stress_spec.rb` at N=200 dynamic /5 runs with **flat per-iteration cost** (within constant factor of iter 1 through iter 200)
- [ ] Re-org regression spec: simulated re-org clears cache, next verify re-runs
- [ ] Concurrency spec: two processes verify same wtxid simultaneously, both succeed, no deadlock

## Risks & mitigations

| Risk | Mitigation |
|------|-----------|
| Cache propagates verifier bugs | `verifier_version` invalidates on bumps; ADR records each version's semantics |
| Re-org window between event and reaper | Lazy chain-anchor check on hit catches stragglers; reaper is the optimisation |
| Migration of existing `tx_proofs` rows | Lazy backfill — NULL state = miss → re-verify on next reference. Pre-release, no production rows anyway. |
| Concurrent writers wasted work | Optimistic correctness — same input → same output → wasted write but no incorrect state |
| Cross-repo dependency (SDK Phase 4) | Sub 4 lands in `bsv-ruby-sdk` first; wallet Phase 5 only blocks on the release |
| Stress test as performance regression gate is fragile | Cap at "within 2× of iter 10 cost" rather than a hard timing target; allows for normal noise |

## Out of scope (this HLR)

- BUMP deduplication table — separate architectural concern. Worth its own HLR; touches schema in a different direction.
- Persisted BEEF cache (serialised envelopes) — derivable from BUMPs + tx_proofs + ancestor closure; no compute saving. Probably premature.
- Cross-process / cluster cache tier (Redis/memcached) — architecturally future-fit; not needed yet.
- Verifier-version migration tooling (ADR record, metrics surface) — defer until first version bump.

## Composition notes

- **#513 (UTXO pool management)**: any consolidator that touches deep ancestor graphs benefits enormously from this cache. Verifying a 50-input consolidation tx without the cache pays the full re-walk cost; with it, only new wtxids cost anything. Cache is a prerequisite for pool-management work to be performant.
- **#515 (token-bearing output protection)**: same hot path (`internalize_action` is where both classify-and-persist happen). Schema additions in both HLRs could land together on a coordinated `tx_proofs` + `outputs` migration if sequenced — but mechanically independent.
- **SDK #881 (BIP-143 memoise)**: orthogonal. SDK fix lowers per-verify cost. This HLR removes redundant verifies entirely. Both compound.

## Execution order — current branch

This branch (`feat/516-verification-cache`) lands **Sub 1 only** (Phase 1: schema + constant + ADR + Store methods). The PR's purpose is to set up the foundation that subsequent phases build on. The other phases each get their own branch + PR off `master` once this lands, sequenced per the dependency graph above.

Phase 1 commit-as-it-emerges plan:
1. **Plan + ADR-033** (this file + ADR draft) — first commit, plan-first.
2. **Schema additions** (migration + Sequel models + `c[]` hash entry).
3. **Constant + Store interface** (`VERIFIER_VERSION`, `Store#mark_verified`, `Store#verified?`).
4. **Specs** (schema coherence, constant exists, Store methods).
5. **Lint + final review**.

Each commit atomic, conventional message, references `#516` and the Sub-1 issue when filed.

---

## Specialist synthesis (2026-07-01)

Nine specialists reviewed the plan. Convergent themes and unique findings fold in below; Pragmatic Enforcer's cuts applied where no domain specialist defended.

### Load-bearing refinements

1. **`self_built` is NOT trusted for Sub 5 short-circuit.** Cryptography and security specialists concur: `self_built` asserts "wallet's signer produced this" — a construction-invariant claim, not an end-to-end verification. Sub 5 gates on `verified_via IN ('spv', 'broadcast_ack')` only. `self_built` remains a lifecycle-metadata value; downstream consumers can distinguish, but the short-circuit trust set excludes it.

2. **Transitive re-org invalidation is required.** Cryptography specialist: if ancestor Y (with merkle_path) re-orgs out, all descendants whose `'spv'` state depended on Y are stale — even if the descendants have no merkle_path of their own. Sub 6 as first-drafted only handled direct anchor loss. Extend to walk the descent graph clearing dependent rows.

3. **Version downgrade protection.** Security specialist: bare `>= verifier_version` comparison is symmetric; a rolled-back binary honours stale-higher rows under weaker logic. Add `wallet_meta.max_verifier_version_seen` (or a `settings` key); refuse boot if code's `VERIFIER_VERSION < max_seen`.

4. **Sub 5 and Sub 6 must co-release.** Security specialist: between Sub 5 (cache reads) and Sub 6 (re-org invalidation), orphaned anchors are honoured. Either ship together, or Sub 5 explicitly refuses hits on `merkle_path IS NOT NULL` rows until Sub 6 lands.

5. **Cache-write only for txs verified reached.** Domain specialist: non-atomic BEEF (BRC-62) may carry unrelated siblings; blindly marking all `beef.transactions.each` cache-writes wtxids that weren't in the verify walk. Enumerate reached wtxids explicitly.

### Interface / naming corrections (Ruby idiom, ruby specialist)

6. **`Store#verified_wtxids(wtxids:)` not `(in:)`.** `in:` is a Ruby reserved word — parses as kwarg but reads awkwardly and requires `binding.local_variable_get(:in)` for destructuring. Convention in this Store is `mark_X(wtxids:, ...)`.

7. **`BSV::Wallet::VERIFIER_VERSION`, not `Engine::VERIFIER_VERSION`.** Gem-level semantic-version stamp belongs in `lib/bsv/wallet/version.rb` alongside `BSV::Wallet::VERSION`. Store queries and Engine callers both reference without cross-namespace reaching.

8. **Frozen-string enum constants on the model.** `Store::Models::TxProof` exposes `VERIFIED_VIA_SPV = 'spv'`, etc. All write sites reference constants, not bare literals — matches `ArcStatus::ACCEPTED` idiom in-repo.

### Database refinements (performance + database)

9. **Add explicit `block_id` partial index for reaper.** Sequel FK on `tx_proofs.block_id` is NOT auto-indexed. Sub 7's `UPDATE ... WHERE block_id IN (...)` will seq-scan at scale. Add `INDEX ON tx_proofs (block_id) WHERE verified_at IS NOT NULL` at Sub 1.

10. **Reshape the read-path index.** The originally-proposed `(wtxid) WHERE verified_at IS NOT NULL` is redundant against the existing `UNIQUE (wtxid)` — planner will prefer the unique. Replace with `(wtxid) INCLUDE (verified_via, verifier_version) WHERE verified_at IS NOT NULL` — index-only scan for the batched read.

11. **`mark_verified` is a single atomic UPDATE** with monotonic predicate (`WHERE verifier_version IS NULL OR verifier_version <= ?`) — refuses to clobber a newer stamp with an older one. The `<=` (rather than strict `<`) admits three legal transitions: NULL → any (first write), N-1 → N (version upgrade), N → N (same-version metadata upgrade — e.g. `broadcast_ack`-upgrades-`self_built`). Refuses N+1 → N.

12. **`mark_verified_batch(rows)` from day one.** Sub 2's N-inserts-per-ingress is a footgun. Set-based `UPDATE ... WHERE wtxid = ANY(?)` — one statement, one plan-cache hit.

13. **`verified_wtxids(wtxids:)` chunks at 10k** for Postgres bind-parameter limit; empty input returns `[]` without hitting DB.

### SDK kwarg refinement (performance + systems architect)

14. **`Tx#verify(verified: Set)`, freeze-on-entry, no `.dup`.** Performance specialist flagged 3× allocation churn (wallet Set → SDK Hash → dup). Accept a `Set` directly; freeze on entry; internal walk uses `include?` semantics identical to the existing Hash-based `verified[wtxid]` check.

### Newcomer / documentation (maintainability)

15. **`docs/reference/verification-cache.md`** as a Phase 1 deliverable. Plan file gets archived; the reference doc is where a newcomer arrives. Registers in `docs/reference/index.md`; cross-linked from `hot-path-design.md` and `principle-of-state.md`. Covers three-tier framing, `verified_via` trust semantics table, lazy-vs-active reaper dichotomy signposted, `verifier_version` bump SOP.

16. **ADR-033's `verifier_version` bump-trigger clause.** Cryptography specialist's list: (a) script interpreter change; (b) BIP-143 preimage layout/field ordering; (c) `MerklePath#verify` change (including coinbase-maturity check); (d) FORKID sighash rules. Explicit exclusions: logging, performance-only refactors, error-message wording.

### Deferrals (Pragmatic Enforcer — accepted where undefended)

17. **Sub 8 broadcast-ack upgrade path DEFERRED.** Enum VALUE stays in Sub 1 (lifecycle metadata); active upgrade path (`'self_built'` → `'broadcast_ack'` on ARC 200/202) waits for a concrete downstream consumer. Cost of premature: two lines of write-path today, zero readers. Defer.

18. **Sub 7 active reaper remains deferred** as first-planned; walletd event surface must settle first.

19. **BUMP dedup, BEEF cache, cluster-tier Redis** — remain out-of-scope. Unchanged.

### Rejected

- **Pragmatic Enforcer's proposal to strip enum to boolean.** DEFENDED by cryptography (Sub 5 gate) and security (`self_built` differentiation). Kept.
- **Pragmatic Enforcer's proposal to strip `verifier_version`.** DEFENDED by cryptography (explicit bump-trigger clauses) and security (downgrade attack). Kept + augmented with `wallet_meta.max_verifier_version_seen`.
- **Pragmatic Enforcer's proposal to defer Sub 6.** DEFENDED by cryptography (transitive invalidation) and security (Sub 5/6 gap). Kept + extended.

### Additional test coverage (cross-specialist)

- Cross-wallet DB isolation: shared Postgres, cache in A not visible to B (security)
- Concurrent `mark_verified` on same wtxid (database)
- Cross-BEEF ancestor with mutated structural context (cryptography)
- Invalid-signature ancestor: no partial cache write on verify failure (security + cryptography)
- Coinbase 100-block maturity edge (cryptography)
- Boot with lower `VERIFIER_VERSION` than `max_seen` — refuses (security)
- `EXPLAIN` capture at 100k/1M `tx_proofs` for batch lookup and reaper update — commit as fixture (performance)
- GC allocation regression signal alongside wall-clock (performance)

### Updated critical path

**Sub 1 → (Sub 2 + Sub 3 parallel) → Sub 4 (SDK, coordinated with #881) → Sub 5 + Sub 6 co-released → (Sub 7, Sub 8 both deferred)**

Sub 8's active work drops out of the critical path; only its enum value lands (in Sub 1). Sub 7 remains deferred to walletd event work.

The persistent-cache win becomes viable after Sub 5+6 co-release. Sub 1 is now larger (schema + `wallet_meta` + reference doc + boundary APIs) but self-contained.
