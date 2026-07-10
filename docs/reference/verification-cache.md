---
title: Verification cache
parent: Reference
nav_order: 13
---

# Verification cache — persistent SPV results as state

`Transaction::Tx#verify` walks every ancestor in an incoming BEEF and runs full script + ECDSA on every unproven tx. That work is deterministic and tx-immutable — a wtxid is the hash of the tx bytes, so once we've verified a wtxid successfully, the result holds forever (modulo re-org and verifier-logic upgrade). The wallet persists this fact and short-circuits the walk when the same ancestor appears in later BEEFs.

Set by [ADR-033](../../.architecture/decisions/adrs/20260701_ADR-033-verification-result-as-canonical-state.md); an application of the [principle of state](principle-of-state.md); interacts with the [hot-path design](hot-path-design.md) rules for how the cache write path is shaped.

## Contents

- [The three tiers](#the-three-tiers)
- [The schema](#the-schema)
- [`verified_via` — three trust levels](#verified_via--three-trust-levels)
- [Invalidation — two events](#invalidation--two-events)
  - [Re-org](#1-re-org) — anchor-liveness (Sub 6.1) + descent-graph (Sub 6.2) invariants
  - [Verifier version upgrade](#2-verifier-version-upgrade)
- [Bumping `verifier_version` — checklist](#bumping-verifier_version--checklist)
- [Egress writes, never reads](#egress-writes-never-reads)
- [Concurrency](#concurrency)
- [The SDK seam](#the-sdk-seam)
- [Composition with other work](#composition-with-other-work)
- [Trace paths on unexpected cache miss](#trace-paths-on-unexpected-cache-miss) — appendix (Sub 6.3)

## The three tiers

```
Layer 1 — Process memory      HydratedTxCache (bytes only; ephemeral per subprocess)
Layer 2 — Persistent          tx_proofs.verified_at + verified_via + verifier_version
Layer 3 — Full verify         Tx#verify walk + chain_tracker
```

Layer 2 is the one the wallet added — the persistent tier. Layer 1 is bytes; Layer 3 is unchanged verify semantics. Layer 2 bridges process boundaries:

- **CLI subprocess model.** Each `bin/wallet` boot starts with a cold L1. Without L2 the wallet re-verified everything on every cold boot.
- **`walletd` restart.** Same story at daemon scale — restart lost the accumulated fact.
- **Multi-node cluster (future).** A shared DB is a shared L2 for free. A future Redis-tier slots between L1 and L2 without disturbing L2's role.

## The schema

Three columns on `tx_proofs`, all NULL-default, coherent (all-or-none):

| Column | Type | Meaning |
|---|---|---|
| `verified_at` | `TIMESTAMPTZ` | When this wallet's verify last succeeded for this wtxid |
| `verified_via` | `verification_source` (enum) | How the trust was established — see below |
| `verifier_version` | `INTEGER ≥ 1` | Semantic version of the verifier that wrote it |

A `verification_state_coherent` CHECK enforces that the three move together. `verifier_version >= 1` is the monotonicity floor. A covering index `(wtxid) INCLUDE (verified_via, verifier_version) WHERE verified_at IS NOT NULL` supports the batched read path; a partial index `(block_id) WHERE verified_at IS NOT NULL` supports the reorg reaper.

## `verified_via` — three trust levels

| Value | Assertion | Trusted for short-circuit? |
|---|---|---|
| `'self_built'` | Wallet constructed this tx; trust comes from the builder, not from `Tx#verify` | **No** |
| `'spv'` | Passed `Tx#verify(chain_tracker:)` end-to-end — the strongest local trust | Yes |
| `'broadcast_ack'` | ARC returned an accepted status; the network has it | **No** (see below) |

**`self_built` is excluded from the short-circuit trust set on purpose.** The wallet's sign path signs but does not run `Tx#verify_input` on what it just signed. `self_built` asserts construction provenance, not signature validity. A signer bug (or drift between the sign and verify sighash preimages) would cache a false verification claim if `self_built` were trusted. Conservative default; the async upgrade path (`self_built` → `spv` via a background worker) is tracked as HLR #517.

**`broadcast_ack` is currently excluded from the short-circuit trust set** — HLR #516 synthesis originally included it, but the Sub 6 anchor-liveness pass joins `blocks` on `block_id`, and a `broadcast_ack` row (ARC accepted, not yet mined) carries `block_id = NULL` until proof acquisition upgrades it. Trusting an unanchored row without a liveness mechanism would leave orphaned or RBF'd broadcast_ack ancestors as permanent trust sources — a phantom-balance vector. Re-admitting `broadcast_ack` to the trust set is deferred until it ships with a liveness design (proof-acquisition escalation, TTL, or equivalent). Decision recorded on PR #537.

Lifecycle: `self_built` → (broadcast) → `broadcast_ack` → (proof arrives, verify re-runs) → `spv`. Downstream consumers can distinguish "wallet made this" from "network confirmed this" from "verify walked this".

## Invalidation — two events

Verification is permanent for the lifetime of the tx it concerns. Two events invalidate cached state:

### 1. Re-org

A tx anchored (via `merkle_path`) to a block that re-orgs out has stale `verified_at`. The wallet uses two invalidation paths:

- **Lazy anchor check** (correctness baseline). On cache hit for a merkle-anchored tx, verify anchor liveness against `chain_tracker`. Mismatch → clear the row's verification fields, treat as miss, re-verify. Free for unproven txs (no anchor).
- **Active reaper** (walletd only). `chain_tracker` emits reorg events; the reaper batch-updates affected rows. Removes the per-hit lazy overhead for daemon workloads.

Both required: lazy is the fail-safe (works for CLI subprocess use); active is the daemon optimisation. They cooperate.

**Transitive invalidation is mandatory.** If ancestor Y (with a merkle_path) re-orgs out, descendants whose `'spv'` state depended on Y's proof are also stale — an unproven descendant Z whose script verification succeeded *because* the chain of trust anchored on Y is broken when Y re-orgs. Both paths must clear the descent graph, not just the directly-anchored row.

#### The anchor-liveness invariant (HLR #516 Sub 6.1)

The anchor key is `(block_height, computed_root)` in **wire-order binary bytes** — not hex, not BUMP-encoded bytes. Two implementation consequences follow.

- **Computed root, not stored bytes.** The persisted `tx_proofs.merkle_path` is folded through the SDK's `MerklePath#compute_root` before comparison. BUMP-encoding variability closes at that computed root — offset-0 leaf duplicates, unbalanced-tree padding, and hash-side ordering all produce the same 32-byte root even when the on-wire BUMPs differ. Two BUMPs for the same wtxid with matching `(height, computed_root)` invalidate equivalently; two BUMPs for the same wtxid at the same height whose computed roots disagree both clear on the mismatched-hash branch.
- **Wire-order binary throughout.** Both sides of the comparison are the raw 32-byte SHA256d output. Hex conversion happens only at the debug-log boundary (`computed_root`/`current_root` in the `[Store#invalidate_stale_anchors!]` line), never in the predicate. This matches the `wtxid`/`blocks.merkle_root` convention documented in the top-level `CLAUDE.md`.

**`chain_tracker` unreachable ≠ mismatch.** A network error, an unknown height, or an empty tracker returns `nil` from `known_roots_for_heights` — the map entry is preserved for that height but marked "unknown". `Store#invalidate_stale_anchors!` treats `nil` values as a no-op and does not clear the row. This is a correctness invariant, not a nicety: a transient outage must not decay the trust set into an unrecoverable state.

**`Store#find_or_create_block` is append-or-reject.** A `save_proof` call whose supplied `(height, merkle_root)` disagrees with an existing `blocks` row at the same height raises `CompetingBlockHeaderError` rather than silently attaching to the stale row. Re-org handling is delegated to the anchor-liveness path — every invalidation goes through `invalidate_stale_anchors!`, never through a silent block-row swap.

#### Descent graph invalidation (HLR #516 Sub 6.2)

Once `invalidate_stale_anchors!` returns the set of action_ids whose anchor rows have just been cleared, every structural descendant of those actions must be coarse-cleared too. A descendant Z whose `'spv'` state came from an SPV walk running through the re-org'd ancestor's proof is stale even though its own row was never anchored.

The canonical implementation lives at `Store#descendant_action_ids_of(action_ids:, max_depth: 100)`. It is a recursive CTE (Sequel `Dataset#with_recursive`) walking the edge `inputs.output_id → outputs.id → outputs.action_id` transitively.

- **Coarse-clear rule.** Every structural descendant is walked *regardless* of whether that row's SPV walk went through the invalidated anchor. Inferring the answer requires replaying `Tx#verify`, which defeats the cache. The asymmetry favours coarse: wasted re-verify on next reference is safe; missed clear is a silent double-spend acceptance window. The cryptography reviewer vetoed any "walked-only" heuristic on this basis.
- **`verified_via IS NOT NULL` UPDATE gate.** The descent WALK is unbounded on the read side (structural descendants can be poisoned by an adversary grafting synthetic rows). The UPDATE — done by the shared primitive `Store#invalidate_verification(action_ids:)` — is bounded to rows carrying a trust mark. Rows without `verified_via` have no cache state to clear and would trip the coherent CHECK. This is the security specialist's DoS defence stitched onto the cryptography reviewer's coarse-clear rule.
- **Depth cap `D = 100`.** Natural coinbase-maturity ceiling — anything beyond 100 hops is definitionally past every re-org's reach. Also the cycle guard: contrived cyclic input graphs terminate at the cap, and `Set.new(...)` collapses duplicate rows on return.
- **Atomic combined invalidation.** `Engine::AnchorLivenessCache#filter_trusted` runs the anchor UPDATE and the descent UPDATE inside one `db.transaction`. Sequel nests transactions via savepoints (the spec DB wrapper uses `auto_savepoint: true`); the invariant we rely on is that nested `db.transaction` blocks do NOT introduce extra commit boundaries, so the caller (Sub 5 read path, forthcoming) can wrap the whole `filter_trusted` invocation in its own transaction and a failure mid-invalidation rolls back both.

The Option (C) alternative — a persistent descent-metadata table — is deferred (see ADR-033). The recursive CTE is the load-bearing implementation; Option (C) becomes worth pursuing only if measurements indicate the walk is a hot-path cost driver.

### 2. Verifier version upgrade

`BSV::Wallet::VERIFIER_VERSION` is a compile-time constant. It bumps when verification semantics change. A row with `verifier_version < current` is treated as a cache miss and re-verified. Existing rows are silently upgraded on first reference; no migration script needed.

**Downgrade protection.** A rolled-back binary would honour higher-version rows under weaker logic. Prevention: on boot, `MAX(tx_proofs.verifier_version)` is compared against `BSV::Wallet::VERIFIER_VERSION`; if the code is older, boot refuses. The MAX aggregate uses the covering index the read path also uses.

## Bumping `verifier_version` — checklist

Bump `BSV::Wallet::VERIFIER_VERSION` when any of these change:

- Script interpreter opcodes, limits, or execution rules
- BIP-143 sighash preimage layout, field ordering, or component construction
- `MerklePath#verify` behaviour (including coinbase-maturity check)
- FORKID sighash rules
- Any other rule that changes what `Tx#verify` accepts or rejects

Do **not** bump for:

- Logging, metrics, error-message wording
- Performance-only refactors that produce identical accept/reject outcomes
- Non-verify code paths

Version history is captured in ADR-033.

## Egress writes, never reads

The cache write path is bidirectional — both ingress and egress stamp `tx_proofs`.

- **Egress sites** (HLR #521) — `Action#sign_and_save!`, `#apply_caller_spends!`, and `#complete_internal!` record `verified_via = 'self_built'` after each sign path, as construction-provenance metadata.
- **Ingress site** (Sub 2, HLR #520) — `BeefImporter#import`'s atomic block records `'spv'` for the wtxid set `Tx#verify` walked. The same block also writes a transient `'self_built'` stamp on the subject before the SPV mark upgrades it — an ordering guard so a subsequent `mark_verified(via: 'self_built')` cannot silently downgrade the SPV row at the same version.

What egress does NOT do is *read* the cache: `Hydrator#build_atomic_beef` and `validate_for_handoff!` operate on bytes-and-proofs, structural checks only — they never consult `verified_via` to decide what the wallet emits. Incoming trust and outgoing bytes remain distinct concerns.

Do not wire the cache into egress *decisions*. If you find yourself wanting outgoing behaviour to branch on `verified_via`, revisit ADR-033 first.

## Concurrency

Optimistic. Verify is a pure function; two processes verifying the same wtxid produce identical results. `mark_verified` is a single atomic UPDATE with two composed gates:

1. **Monotonic version predicate** — `verifier_version IS NULL OR verifier_version <= ?` — an older writer cannot clobber a newer stamp. `<=` (rather than strict `<`) admits same-version writes.
2. **Same-version strength ratchet** — when the existing row is at the current `VERIFIER_VERSION`, the new `via` may only overwrite `verified_via` values at or below its own strength. Strength order is `self_built` < `broadcast_ack` < `spv`, so within one version `self_built` can only overwrite `NULL` or `self_built`, `broadcast_ack` can overwrite `NULL`/`self_built`/`broadcast_ack`, and `spv` can overwrite any. This makes trust ratchet forward within a version — a subsequent `self_built` write cannot silently demote a row Sub 2 already marked `'spv'`.

Cross-version writes (`existing verifier_version < current`) bypass the ratchet: the new verifier's classification is authoritative, and `Store#verified_wtxids(version_at_least:)` excludes stale marks from older binaries anyway. Version-upgrade demotions are safe to write; the read gate keeps the trust surface honest.

## The SDK seam

The wallet's persistent cache short-circuits the SDK's verify-walk via a `verified:` kwarg on `Tx#verify` (bsv-ruby-sdk #904). The SDK already has an in-call dedup Hash — the kwarg pre-seeds it with wtxids the caller has previously verified. The wallet builds this set from `Store#verified_wtxids(wtxids:, version_at_least:)`, gating on `verified_via IN ('spv')` — `broadcast_ack` and `self_built` are both excluded (see the trust-level table above for why each).

## Composition with other work

- **[Principle of state](principle-of-state.md)** — verification is state, belongs in the schema. This is a concrete application.
- **[Hot-path design](hot-path-design.md)** — the `mark_verified` write is on the receive hot path; batching + a single atomic UPDATE keeps it declarative. Also see hot-path-design's own cross-link back to [Re-org handling](#1-re-org).
- **UTXO pool management (HLR #513)** — consolidators touch deep ancestor graphs; the cache turns their cost from quadratic to linear in new state.
- **Token protection (HLR #515)** — same hot path (`internalize_action`); schema additions can land together.
- **bsv-ruby-sdk #881** — orthogonal per-tx sighash cache. Compounds; each addresses a different redundancy.
- **HLR #517** — async egress-verification worker upgrading `self_built` → `spv`.

## Trace paths on unexpected cache miss

When a wtxid that "should be" in the trust set is not, one of four things has happened. Each has a named call site — grep for it in the debug log and confirm.

### 1. Anchor mismatch (Sub 6.1)

The persisted `merkle_path` for this wtxid folded through `MerklePath#compute_root` disagreed with the tracker's current root at the same block height. `Engine::AnchorLivenessCache#filter_trusted` fed the resolved `{ height => current_root_bytes }` map into `Store#invalidate_stale_anchors!`; the row's three verification columns were cleared before the trust-set SELECT.

Debug log to grep:

```
[Store#invalidate_stale_anchors!] wtxid=<dtxid> cause=anchor_mismatch height=<H> computed_root=<hex> current_root=<hex>
```

The `computed_root` and `current_root` fields are hex-encoded at the log boundary; the underlying comparison is wire-order 32-byte binary. `computed_root` is derived from the persisted `merkle_path` via `MerklePath#compute_root` (BUMP-encoding variability closes there); `current_root` is what `chain_tracker.known_roots_for_heights` reports for the same height. If the two roots differ, this is expected re-org behaviour — the next verify walk will re-anchor if the tracker has moved on.

### 2. Transitive descent (Sub 6.2)

The wtxid's own row was never anchor-mismatched, but a *structural ancestor* of it was. The descent walk (recursive CTE at `Store#descendant_action_ids_of(action_ids:, max_depth: 100)`) unified the ancestor's `action_id` with every downstream `action_id` reachable via `inputs.output_id → outputs.action_id`; the shared clearing primitive `Store#invalidate_verification(action_ids:)` cleared the descendant row's verification columns, gated on `verified_via IS NOT NULL`.

Debug log to grep:

```
[Store#invalidate_verification] wtxid=<dtxid> cause=transitive_descent root_anchor=<dtxid>
```

The `root_anchor` field is either the row's own dtxid when the descendant itself carries `block_id` (usually meaning "verified independently and reachable via a coincidental input graph") or `unknown` for a pure descendant with no direct anchor. Precise attribution is not correctness-critical; the invalidation happened because the coarse-clear rule (cryptography specialist's veto on "walked-only") requires it.

### 3. Verifier-version bump (Sub 1)

The row's `verifier_version` was written by an older binary; the current `BSV::Wallet::VERIFIER_VERSION` is strictly greater. `Store#verified_wtxids(version_at_least: BSV::Wallet::VERIFIER_VERSION, ...)`'s `verifier_version >= ?` predicate excludes it, so it's not in the trust set even though the columns are still populated. On next reference the row will be re-verified under the new logic and re-stamped at the current version.

There's no debug log at the read site (would be one line per read on the hot path). Confirm by:

```sql
SELECT verifier_version FROM tx_proofs WHERE wtxid = <blob>;
```

If it's below `BSV::Wallet::VERIFIER_VERSION`, the version gate is why. This is expected and self-heals on re-verify.

### 4. `verification_state_coherent` CHECK trip

A malformed write attempted to leave the row in a mixed-state (`verified_at IS NOT NULL AND verified_via IS NULL`, or any other partial). The schema-level CHECK rejects the whole UPDATE, and Sequel raises `Sequel::CheckConstraintViolation`. The row's prior state (either "all NULL" or "all NOT NULL") is preserved.

This is a schema-level catch for an application bug — a code path that clears one column without the others (or writes one without the others). Never expected in production; if you see it, the offending write site needs fixing so all three columns move together. `Store#clear_verification_columns_for_proofs` is the shared clearing site; `Store#mark_verified_batch` is the shared writing site — both fold every column mutation into a single UPDATE.

Debug log will contain the DB error message; grep for `verification_state_coherent`. The fix is at the caller, not the schema.
