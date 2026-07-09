---
title: Verification cache
parent: Reference
nav_order: 13
---

# Verification cache — persistent SPV results as state

`Transaction::Tx#verify` walks every ancestor in an incoming BEEF and runs full script + ECDSA on every unproven tx. That work is deterministic and tx-immutable — a wtxid is the hash of the tx bytes, so once we've verified a wtxid successfully, the result holds forever (modulo re-org and verifier-logic upgrade). The wallet persists this fact and short-circuits the walk when the same ancestor appears in later BEEFs.

Set by [ADR-033](../../.architecture/decisions/adrs/20260701_ADR-033-verification-result-as-canonical-state.md); an application of the [principle of state](principle-of-state.md); interacts with the [hot-path design](hot-path-design.md) rules for how the cache write path is shaped.

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
| `'broadcast_ack'` | ARC returned an accepted status; the network has it | Yes |

**`self_built` is excluded from the short-circuit trust set on purpose.** The wallet's sign path signs but does not run `Tx#verify_input` on what it just signed. `self_built` asserts construction provenance, not signature validity. A signer bug (or drift between the sign and verify sighash preimages) would cache a false verification claim if `self_built` were trusted. Conservative default; the async upgrade path (`self_built` → `spv` via a background worker) is tracked as HLR #517.

Lifecycle: `self_built` → (broadcast) → `broadcast_ack` → (proof arrives, verify re-runs) → `spv`. Downstream consumers can distinguish "wallet made this" from "network confirmed this" from "verify walked this".

## Invalidation — two events

Verification is permanent for the lifetime of the tx it concerns. Two events invalidate cached state:

### 1. Re-org

A tx anchored (via `merkle_path`) to a block that re-orgs out has stale `verified_at`. The wallet uses two invalidation paths:

- **Lazy anchor check** (correctness baseline). On cache hit for a merkle-anchored tx, verify anchor liveness against `chain_tracker`. Mismatch → clear the row's verification fields, treat as miss, re-verify. Free for unproven txs (no anchor).
- **Active reaper** (walletd only). `chain_tracker` emits reorg events; the reaper batch-updates affected rows. Removes the per-hit lazy overhead for daemon workloads.

Both required: lazy is the fail-safe (works for CLI subprocess use); active is the daemon optimisation. They cooperate.

**Transitive invalidation is mandatory.** If ancestor Y (with a merkle_path) re-orgs out, descendants whose `'spv'` state depended on Y's proof are also stale — an unproven descendant Z whose script verification succeeded *because* the chain of trust anchored on Y is broken when Y re-orgs. Both paths must clear the descent graph, not just the directly-anchored row.

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

## Egress is unaffected

The cache is a read-only optimisation for `BeefImporter#verify_incoming_transaction!`. It does not alter what the wallet emits. `Hydrator#build_atomic_beef` and `validate_for_handoff!` operate on bytes-and-proofs, structural checks only — they never consult the verification fact. This is deliberate: incoming trust and outgoing bytes are distinct concerns.

Do not wire the cache into egress. If you find yourself wanting to, revisit ADR-033 first.

## Concurrency

Optimistic. Verify is a pure function; two processes verifying the same wtxid produce identical results. `mark_verified` is a single atomic UPDATE with two composed gates:

1. **Monotonic version predicate** — `verifier_version IS NULL OR verifier_version <= ?` — an older writer cannot clobber a newer stamp. `<=` (rather than strict `<`) admits same-version writes.
2. **Same-version strength ratchet** — when the existing row is at the current `VERIFIER_VERSION`, the new `via` may only overwrite `verified_via` values at or below its own strength. Strength order is `self_built` < `broadcast_ack` < `spv`, so within one version `self_built` can only overwrite `NULL` or `self_built`, `broadcast_ack` can overwrite `NULL`/`self_built`/`broadcast_ack`, and `spv` can overwrite any. This makes trust ratchet forward within a version — a subsequent `self_built` write cannot silently demote a row Sub 2 already marked `'spv'`.

Cross-version writes (`existing verifier_version < current`) bypass the ratchet: the new verifier's classification is authoritative, and `Store#verified_wtxids(version_at_least:)` excludes stale marks from older binaries anyway. Version-upgrade demotions are safe to write; the read gate keeps the trust surface honest.

## The SDK seam

The wallet's persistent cache short-circuits the SDK's verify-walk via a `verified:` kwarg on `Tx#verify` (bsv-ruby-sdk #904). The SDK already has an in-call dedup Hash — the kwarg pre-seeds it with wtxids the caller has previously verified. The wallet builds this set from `Store#verified_wtxids(wtxids:, version_at_least:)`, gating on `verified_via IN ('spv', 'broadcast_ack')` (excluding `'self_built'`).

## Composition with other work

- **[Principle of state](principle-of-state.md)** — verification is state, belongs in the schema. This is a concrete application.
- **[Hot-path design](hot-path-design.md)** — the `mark_verified` write is on the receive hot path; batching + a single atomic UPDATE keeps it declarative.
- **UTXO pool management (HLR #513)** — consolidators touch deep ancestor graphs; the cache turns their cost from quadratic to linear in new state.
- **Token protection (HLR #515)** — same hot path (`internalize_action`); schema additions can land together.
- **bsv-ruby-sdk #881** — orthogonal per-tx sighash cache. Compounds; each addresses a different redundancy.
- **HLR #517** — async egress-verification worker upgrading `self_built` → `spv`.
