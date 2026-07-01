# ADR-033: Verification result is canonical persistent state

## Status

Accepted.

**Decided:** 2026-07-01 — HLR #516. Extends ADR-003 (Principle of state — canonical DB, atomic transitions, invalid state structurally impossible) by identifying a class of state the wallet had been recomputing on every reference rather than persisting.

## Context

`Engine::BeefImporter#verify_incoming_transaction!` calls `Transaction::Tx#verify(chain_tracker:)`. The SDK's verify walks every ancestor in the incoming BEEF: for each unproven ancestor (no `merkle_path`), it runs full script execution and ECDSA verification on every input. Within a single walk, the SDK dedupes via an in-call `verified[wtxid] = true` Hash (`lib/bsv/transaction/tx.rb:634`); across walks, no memory. Each subsequent BEEF that references the same ancestor pays the full verify cost again.

Empirical evidence: the three-wallet stress spec (`spec/integration/three_wallet_stress_spec.rb`, PR #512) at dynamic /5 payment amounts showed per-iteration cost growing from ~1 s at iter 1 to 30+ minutes at iter 100. Profiling and DB inspection (this session's thread ending in bsv-ruby-sdk #881) showed the redundancy — not chain depth, not ECDSA rate, but *number of redundant verifies* of already-known ancestors.

The wallet already persists the bytes each verify concerns (`tx_proofs.raw_tx`, `tx_proofs.merkle_path`). It does not persist the verification fact — the outcome of "did the wallet's own verify pass for this wtxid".

## Decision Drivers

* **Verification result is tx-immutable.** A wtxid is the hash of the tx bytes; the bytes can't change without the wtxid changing. Once verified, the result holds for the lifetime of that wtxid, modulo re-org and verifier-logic upgrade.
* **Principle of state (ADR-003).** State the wallet needs to reason about repeatedly belongs in the schema, not recomputed. Verification outcome fits the pattern.
* **Bridging deployment topologies.** CLI subprocess, walletd daemon, multi-daemon cluster — a persistent tier of verification facts is the mechanism that lets each of those honour work done by the others without changing the abstraction.
* **Composability.** Downstream work (UTXO pool management #513, token-bearing output protection #515) touches deep ancestor graphs; the cache is prerequisite for their throughput.
* **Trust placement.** Caching means trusting our past self. That trust must be scoped, versioned, and invalidatable.

## Decision

**Persist the verification result on `tx_proofs`, treat it as canonical state alongside the tx bytes, and short-circuit the verify-walk on cache hit.**

### Three-tier cache

```
Layer 1 — Process memory      HydratedTxCache (bytes only; ephemeral per subprocess)
Layer 2 — Persistent          tx_proofs.verified_at + verified_via + verifier_version (NEW)
Layer 3 — Full verify         Tx#verify walk + chain_tracker (unchanged)
```

Layer 2 bridges process boundaries (each cold CLI subprocess sees what previous ones learned), daemon restarts (walletd reboot doesn't lose the fact), and — in principle — cluster scale (shared DB is a shared L2). A future Redis-tier would slot between L1 and L2 without disturbing this decision.

### Schema home

`tx_proofs` gains three columns, all NULL-default, coherent (all-or-none) via CHECK:

- `verified_at TIMESTAMPTZ` — when this wallet's verify last succeeded for this wtxid
- `verified_via verification_source` — enum recording *how* the trust was established
- `verifier_version INTEGER` — the semantic version of the verifier that wrote it (≥ 1)

The columns live where the bytes live. No parallel table. `tx_proofs` becomes the single home for "everything the wallet knows about a tx" — bytes, proof-if-any, verification fact.

### `verified_via` enum values

```
'self_built'    - Wallet constructed this tx. Trust comes from the builder,
                  not from Tx#verify. Lifecycle metadata; NOT trusted for
                  Sub 5 short-circuit.
'spv'           - Passed Tx#verify(chain_tracker:) end-to-end. The strongest
                  trust; trusted for short-circuit.
'broadcast_ack' - ARC returned an accepted status; the network has it, but
                  we may not yet hold a merkle proof. Trusted for short-
                  circuit (the network's acceptance is a real assertion).
```

Each value carries different downstream semantics; keeping them distinct lets consumers reason about lifecycle (send → broadcast_ack → spv when proof arrives) without collapsing meaning.

**`self_built` explicitly excluded from short-circuit trust set.** The wallet's build path signs but does not run `Tx#verify_input` on what it just signed. `self_built` asserts construction provenance, not signature validity. A signer bug or drift between sign and verify sighash preimages could produce a locally-cached "verified" claim for a tx that fails external verification. Excluding `self_built` from the trust set is the conservative default; HLR #517 tracks the async upgrade path (`self_built` → `spv`) via a background worker that runs verify after sign.

### `verifier_version` and downgrade protection

The version is a compile-time constant (`BSV::Wallet::VERIFIER_VERSION`). It bumps whenever verification semantics change. On read, a row with `verifier_version < current` is treated as miss and re-verified.

**Downgrade attack**: a rolled-back binary would honour higher-version rows under weaker logic. Prevention: boot-time check that `BSV::Wallet::VERIFIER_VERSION >= MAX(tx_proofs.verifier_version)`; refuse to start otherwise. The MAX aggregate uses the covering index the read path also uses — no extra table needed.

**`verifier_version` bump triggers.** A bump is required when any of these change:

- Script interpreter opcodes, limits, or execution rules
- BIP-143 sighash preimage layout, field ordering, or component construction
- `MerklePath#verify` (including the coinbase-maturity check)
- FORKID sighash rules

Explicitly exclusive: logging, performance-only refactors, error-message wording. The version is a semantic-verification stamp, not a code-version stamp.

### Invalidation

Two events invalidate cached verification:

1. **Re-org.** A tx anchored (via `merkle_path`) to a block that re-orgs out has stale `verified_at`. Two paths:
   - **Lazy** (correctness baseline): on cache hit for a merkle-anchored tx, verify anchor liveness against `chain_tracker`. Mismatch → clear + re-verify. Free for unproven txs.
   - **Active reaper** (walletd only): `chain_tracker` emits reorg events; batch-update affected rows. Removes the per-hit lazy overhead.
   
   Both required: lazy is the fail-safe; active is the optimisation. **Transitive**: descendants whose `'spv'` state depended on the re-org'd anchor are also cleared — an unproven descendant Y whose script verification succeeded *because* the chain of trust anchored on X's proof is stale when X re-orgs out.

2. **Verifier version upgrade.** New `VERIFIER_VERSION` invalidates all rows with lower version. Re-verify on next reference; write with new version.

### Egress is unaffected

The cache is a read-only optimisation for `BeefImporter#verify_incoming_transaction!`. It does not alter what the wallet *emits* — `Hydrator#build_atomic_beef` and `validate_for_handoff!` operate on bytes-and-proofs, structural checks only, no verification-fact consultation. This is deliberate: incoming trust and outgoing bytes are distinct concerns. Documented here so future refactors do not accidentally wire the cache into egress.

### Concurrency

Optimistic. Verify is a pure function; two concurrent processes verifying the same wtxid produce identical results. Last-writer-wins is correct because the state written is identical. `mark_verified` is a single atomic UPDATE with a monotonic predicate (`WHERE verifier_version IS NULL OR verifier_version < new_version`) to prevent an older writer clobbering a newer stamp.

## The residual — stated honestly

The cache trades one substitution: rather than trusting the SDK's verify at every reference, we trust our own past invocation of the SDK's verify, scoped by `verified_via` and `verifier_version`. If our verifier was ever buggy at write time and produced an incorrect `verified_at`, the bug propagates through every cache hit until `VERIFIER_VERSION` bumps.

Mitigations:

- **Version stamp is the escape hatch.** Bump on any verify-semantic change; existing rows lazily re-verify under new logic.
- **`verified_via` scope-limits trust propagation.** Excluding `self_built` from the short-circuit trust set means the highest-risk state (unverified sign-path output) never enters the trust chain until an independent Tx#verify has run.
- **Re-org invalidation is chain-aware.** SPV state on a merkle-anchored tx cannot outlive its anchor.

The trade is small compared to the recomputation cost. Not zero.

## Alternatives Considered

### A. Cache ECDSA verify results at the `(pubkey, msg, sig)` level

Higher granularity but wider security risk (a buggy verify-result cache silently approves invalid signatures against pubkeys the wallet might not otherwise trust). Narrower applicability. Deferred as SDK-side optimisation (bsv-ruby-sdk #881 §5).

### B. Wallet-side BEEF pruning before verify

Walk the incoming BEEF, replace verified subtrees with TXID-only entries, hand the pruned BEEF to `Tx#verify`. Invasive — requires mutating parsed BEEF state, breaks round-tripping. Rejected in favour of the SDK-side kwarg (bsv-ruby-sdk #904).

### C. Ephemeral verification cache (Layer 1 only, no persistence)

Extend `HydratedTxCache` to remember verification results in memory. Covers the daemon case; loses everything across CLI subprocess boundaries. Rejected — misses the load-bearing bridging use case (CLI cold boot, walletd restart, cluster share).

### D. Boolean `verified` flag (no enum, no version)

Simpler surface. Would collapse the lifecycle (`self_built` / `spv` / `broadcast_ack`) into one bit — losing the trust-source distinction and forcing either "trust everything" or "trust nothing" downstream. Rejected on the specialist review (crypto + security both defended the enum). The `verifier_version` similarly earns its keep against downgrade attacks.

## Consequences

### Positive

- Receive-path cost becomes linear in *new* wtxids per receive, not cumulative. The three-wallet stress spec's iter 100 becomes comparable to iter 10.
- Cross-process bridging: CLI subprocesses stop paying the full verify cost each cold boot.
- Cluster path exists without further design: shared DB is a shared L2.
- Downstream throughput work (#513, #515) has a load-bearing prerequisite.

### Negative

- One more column set on `tx_proofs`, one covering index, one partial index for the reaper. Storage cost small; lookup cost negative (index-only scan replaces post-filter on unique).
- `verifier_version` becomes a checklist item on any change to the verify path. Documented here and in `docs/reference/verification-cache.md`.
- Re-org handling is more complex — lazy check + active reaper both needed. Transitive invalidation is the subtle case cryptography specialist surfaced.

### Neutral / requiring follow-up

- Egress verification (`self_built` → `'spv'` upgrade) tracked as HLR #517. Not required for cache correctness; the trust set's exclusion of `self_built` is the safeguard.
- BUMP dedup as a first-class table — orthogonal architectural work, separate HLR if pursued.
- Persisted BEEF cache — probably premature; derivable from BUMPs + tx_proofs + closure.

## Related

- **HLR #516** — this ADR's parent work.
- **HLR #517** — egress-verification worker follow-up (upgrade `self_built` → `spv` asynchronously).
- **ADR-003** — Principle of state (canonical DB, atomic transitions, invalid state structurally impossible). This ADR identifies verification result as a class of state the wallet had been recomputing.
- **ADR-015** — Chain-tracker pivot (SDK `Tx#verify` walks proofs; wallet answers root-for-height). The kwarg PR (bsv-ruby-sdk #904) is the seam between the SDK's walk and the wallet's persistent cache.
- **bsv-ruby-sdk #881** — Russian-doll sighash + wire cache. Orthogonal per-tx optimisation; compounds with this ADR's cross-call cache.
- **bsv-ruby-sdk #904** — Tx#verify `verified:` kwarg. The SDK seam this decision requires.
