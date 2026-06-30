# Plan — HLR #516: Persistent verification cache

> See [HLR #516](https://github.com/sgbett/bsv-wallet/issues/516).

## Premise

The wallet's `internalize_action` walks every ancestor in every incoming BEEF and runs full script + ECDSA verification on each unproven tx. The work is redundant — the same ancestor tx appearing in successive BEEFs is re-verified from scratch each time, even though verification is a permanent, tx-immutable fact. We persist the *bytes* (in `tx_proofs`) but not the *verification result*. That gap makes per-receive cost grow with cumulative state, not new state. PR #512's stress workload exposed it empirically — iter 1 cost ~1s, iter 100 cost 30+ minutes.

The fix: persist the verification fact alongside the bytes, short-circuit the verify-walk on cache hit. Three-tier cache (process memory → persistent → verify); this work adds the missing persistent tier.

## Decisions taken (resolving HLR open questions)

### 1. SDK extension vs wallet-side pruning → **SDK extension**

Plan: add `Tx#verify(chain_tracker:, trusted_wtxids: Set.new)` to `bsv-ruby-sdk`. When recursing into an input's `source_transaction`, if that transaction's wtxid is in `trusted_wtxids`, treat it as a terminal (skip its subtree, skip its script verify). Tiny SDK change, opt-in via the new kwarg, no behavioural change for existing callers.

Why SDK-level over wallet-side graph pruning:
- The SDK already owns the recursion; intercepting at the recursion point is the right architectural seam.
- Wallet-side pruning would have to mutate parsed BEEF state to make terminals (re-shape `source_transaction` references), which is invasive and would break round-tripping.
- `trusted_wtxids` is a primitive concept — "set of wtxids the caller asserts are valid"; doesn't leak wallet-specific concerns into the SDK.
- BEEF V2 already supports TXID-only entries; this kwarg is essentially a "treat these as TXID-only for verify purposes" hook.

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

Repo: `sgbett/bsv-ruby-sdk`. Change: `Tx#verify` accepts `trusted_wtxids:` kwarg.

```ruby
# Before
def verify(chain_tracker: nil)
  # recursive walk
end

# After
def verify(chain_tracker: nil, trusted_wtxids: nil)
  # recursive walk; before recursing into source_transaction:
  #   next if trusted_wtxids&.include?(source_transaction.wtxid)
end
```

Acceptance:
- New kwarg defaults to nil (no behaviour change for existing callers).
- Recursion short-circuits at any input whose `source_transaction.wtxid` is in `trusted_wtxids`.
- Spec: build a tx whose source_transaction has a deliberately-invalid input, verify with that source's wtxid in trusted_wtxids → passes. Verify without it → fails.
- Spec: trust set ignored for inputs with merkle_path (those still verify via chain_tracker; trust is for unproven subtrees).
- SDK release with the feature gates the wallet's Phase 4.

Sequencing: file the SDK issue + PR alongside Phase 1 schema work. SDK lands, gem version bumped in wallet, wallet Phase 4 unblocks.

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
