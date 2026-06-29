# ADR-032: Opt-in SPV header trust model — PoW-validated headers vs trusted-service roots

## Status

Accepted.

**Decided:** 2026-06-29 — HLR #335. Extends ADR-015 (chain-tracker pivot, 2026-05-13): the SDK's `Transaction::Tx#verify` walks merkle proofs and asks a `ChainTracker` "is this root valid at this height?". That question has had one answer — trust a chain-query Service. This ADR adds a second, opt-in answer that trusts no service: validate the header chain by proof-of-work.

## Context

BEEF is the wallet's SPV envelope: an incoming transaction arrives with the merkle proofs that place its ancestry in blocks. `Transaction::Tx#verify(chain_tracker:)` (adopted in ADR-015 pivot) verifies each merkle *path* — but the *root* each path commits to is taken from `BSV::Network::ChainTracker`, a write-through cache that, on a miss, fetches the merkle root for a height from a Service (WhatsOnChain) and **trusts the answer** without proof-of-work validation.

So the wallet verifies the path and trusts the root. Every "is this confirmed" judgement rests on the Service being honest about block headers — the one remaining trust gap in the SPV story. A wallet that holds value without trusting an indexer needs to validate the header chain itself: proof-of-work says the root is real, not an API. The reference `wallet-toolbox` already does this (its "Chaintracks" subsystem); we took the write-through shortcut deliberately at ADR-015 ("the minimal bridge"), and HLR #335 closes it as an opt-in.

## Decision Drivers

* **Close the last SPV trust gap.** Path verification without root validation is half SPV.
* **Opt-in, not default.** Maintaining a validated header chain is a cost (storage, first-sync, ongoing upkeep) not every deployment wants. The default must reproduce today's behaviour exactly.
* **Phased.** Service-sourced-but-validated headers now; peer-to-peer sourcing (eclipse/withholding resistance) is a larger lift that fights the service model — deferred.
* **Checkpoint-anchored.** A baked-in recent checkpoint bounds first-sync cost and is a small, auditable trust root, versus validating from genesis (~64 MB, slow first boot).
* **Principle of state (ADR-003).** The header chain is a rebuildable projection of the globally-canonical PoW chain; validity must be structural, not a stored status.

## Decision

**Add an opt-in `trust_model` configuration axis selecting how the chain tracker answers root-for-height.**

- `:trusted_service` (default) — the existing write-through `ChainTracker`. Unchanged.
- `:spv_headers` (opt-in) — a new `SpvHeaderChainTracker` that maintains a PoW-validated, contiguous header chain anchored at a baked-in checkpoint and answers only from validated headers. Fail-closed: any height below the checkpoint, any header that fails validation, and any height the sync cannot reach all resolve to "not valid".

Selected at the single boot seam (`cli.rb`), a third sibling on the SDK `Transaction::ChainTracker` duck type alongside the trusted-service `ChainTracker` (ingress) and `TrustedSelfChainTracker` (egress, ADR-015 egress).

**The validation rigour is PoW-at-stated-target + contiguity from the checkpoint — not full difficulty-algorithm (DAA) validation.** Each header is checked for valid proof-of-work against its *stated* compact target (`nBits`) and linkage (`prev_hash`) to its already-validated predecessor. The wallet does *not* recompute that the stated target is itself correct per the difficulty-adjustment algorithm.

**Structural validity, no status column (ADR-003).** A header is "validated" iff its 80 bytes are present in `blocks.header` and it forms a PoW-valid chain back to the checkpoint — recomputable from the stored bytes, no `validated` flag. The `header_root_match` CHECK ties the embedded merkle root to the indexed `merkle_root` column so the two cannot drift. Header writes are append-or-reject: a validated row is never downgraded or overwritten, preserving the competing-header evidence #245's reorg handling will need.

**Scope is the BEEF-ingress verification path only.** Because `Transaction::Tx#verify` runs through the chain tracker, ingress BEEF verification becomes trustless under `:spv_headers` with no further change. The `import_utxo` proof path (`fetch_proof_for_imported_utxo!`) does *not* run through `Tx#verify` and is **not** covered here — see Consequences / the import limitation.

## The residual — stated honestly

`:spv_headers` is a large improvement over blind service-trust, **not** an airtight guarantee against a fully-malicious sole service.

Because we validate PoW at the *stated* target but not the target's correctness (no DAA recompute), a service that is the wallet's sole header source can serve a self-consistent **low-difficulty fork** from the checkpoint: lower the stated target, mine valid-PoW-for-that-easy-target headers cheaply, present a fabricated root at a height. PoW + contiguity does not catch this; cumulative-work comparison or DAA validation would.

**On BSV this residual is materially larger than the equivalent shortcut on Bitcoin.** BSV carries a minority share of total SHA256 hashrate, so the honest chain's difficulty is far lower than BTC's, and fabricating a target-consistent fork costs proportionally less real work. The PoW + contiguity gate raises the bar well above blind trust but does not approach Nakamoto-security on BSV specifically.

The residual is closed by any of: **full DAA validation** (source-independent — even a sole malicious service cannot forge a cheap fork), **multi-service cross-check** (≥2 independent providers must agree), or **P2P header sourcing** (the ultimate multi-source). All deferred; full DAA / cumulative-work also overlaps #245's fork-choice work.

## Alternatives Considered

### A. Full DAA validation now
Recompute each header's required difficulty so even a sole malicious service cannot forge a cheap fork. **Deferred, not rejected.** The BSV DAA is intricate and fork-sensitive; v1 ships the substrate (header storage, validator, tracker, toggle) that DAA validation builds on, plus a large improvement over blind trust. The residual is documented, not hidden.

### B. Multi-service cross-check
Require ≥2 independent header providers to agree at each height — defeats a single compromised provider without hand-rolling the DAA. **Deferred.** Needs a second header-serving provider wired in (only WhatsOnChain is wired today); a natural stepping stone to P2P.

### C. Trust a header-specialised service (Chaintracks) instead of validating
Delegate header validity to a purpose-built header service. **Rejected.** Still trusting a service — contrary to the point — and the SDK's Chaintracks client exposes only a per-height fetch (no range endpoint), so it offers no efficiency win over the already-wired WhatsOnChain call.

### D. Make PoW validation the default
**Rejected.** Maintaining a validated header chain is a real cost. The default must stay zero-cost and behaviour-preserving; trustlessness is opt-in for the deployments that want it.

## Consequences

### Positive
* **Trustless BEEF verification when enabled.** No service is trusted for a merkle root; every root is checked against a PoW-validated header.
* **Structural validity.** `blocks.header` present ⇔ locally PoW-validated; no status column, consistent with the principle of state. The chain is a rebuildable projection.
* **Substrate for #245.** `blocks.header` yields `prev_hash` + `bits`, so cumulative work is derivable; #245 adds fork-choice / reorg without a schema redo. Append-or-reject preserves the evidence it needs.

### Negative
* **First-sync cost, bounded by checkpoint recency.** No bulk header endpoint exists (neither WhatsOnChain nor the SDK Chaintracks client has one), so the cold sync is N sequential per-height fetches from the checkpoint up to a proof's height. A `MAX_SYNC_SPAN` cap bounds it (and refuses the absurd heights a malicious service could feed — a DoS bound). **The shipped mainnet checkpoint must be refreshed toward the tip each release** or first-sync cost grows.
* **The documented residual** (above) — a sole malicious service can still mount a low-difficulty-fork attack, worse on BSV than BTC. Closed by DAA / multi-source / P2P.
* **The import limitation.** `import_utxo` still blind-trusts its merkle root under `:spv_headers` — its proof path does not run through `Tx#verify`. A known limitation of this iteration, tracked as #485; operators relying on `import_utxo` for trustlessness do not yet get it.
* **Legacy-import-below-checkpoint.** A proof at a height below the shipped checkpoint fails closed. New wallets are unaffected; importing genuinely old UTXOs under `:spv_headers` requires lowering the checkpoint via the `spv_checkpoint` override, or using `:trusted_service` for that import.

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

The specialist review cut two speculative passengers and kept one defended escape hatch. **Cut:** the SDK Chaintracks integration (its client has no range endpoint — zero efficiency win over the wired WhatsOnChain call, confirmed against the SDK source) and a standalone `checkpoints.rb`-as-ceremony framing (a frozen constant suffices). **Kept (domain-defended):** the minimal `spv_checkpoint` override — the escape hatch for legacy-UTXO imports below a recent checkpoint *and* the injection seam that makes the integration tests deterministic without live network. The core surface (a header column, a pure validator, a tracker sibling selected at one seam, a config flag mirroring `parse_network`) is the minimum that satisfies the acceptance criteria. **Approve.**

## Validation

* `config.trust_model` is an explicit setting (`BSV_WALLET_TRUST_MODEL`, `parse_trust_model` mirroring `parse_network`); default `:trusted_service` reproduces prior behaviour, verified by the boot-selection spec.
* `BSV::Network::BlockHeader` validates PoW via Core `SetCompact` `nBits` decode (sign/zero/overflow guarded) and a little-endian hash-≤-target compare, reusing `BSV::Primitives::Digest.sha256d`; pinned against real mainnet vectors (genesis, height 1) plus a low-difficulty-but-valid header that must pass (documenting the residual).
* `SpvHeaderChainTracker#valid_root_for_height?` fails closed below the checkpoint, over-syncs to `height + 100` (coinbase maturity), and compares the validated header's wire-order merkle root; `current_height` is the validated tip, never the untrusted `:current_height` call.
* `HeaderSyncer` is fail-closed (stops at the first bad/missing header, never advancing the tip) and DoS-bounded (`MAX_SYNC_SPAN`, refused before any fetch).
* The shipped mainnet checkpoint (block 955000) self-verifies (`sha256d` of the embedded header equals the known block hash).
* Header writes are append-or-reject in the store; structural validity carries no status column.

## References

* ADR-015 (pivot) — chain-tracker pivot to the SDK's `Transaction::Tx#verify`; the seam this ADR extends.
* ADR-015 (egress) — egress-BEEF validation via `TrustedSelfChainTracker`; the trust-asymmetry pattern (untrusted ingress vs trusted own-state) this ADR adds a third member to.
* ADR-003 — schema as canonical state; structural validity, no status column.
* ADR-008 — binary internally, hex at boundaries; the wire/display byte-order convention the validator honours.
* `docs/reference/spv-header-verification.md` — the trust-model axis, validation rigour, the residual, and the operational constraints.
* HLR #335 — this requirement.
* #485 — the deferred `import_utxo` routing (the import limitation).
* #245 — reorg recovery / cumulative-work fork-choice, building on this substrate.

## Unverified claims

* The "BSV minority SHA256 hashrate makes the residual worse than on BTC" point is a qualitative security argument (relative cost of fabricating a target-consistent fork), not a measured figure. It is directionally sound and motivates closing the residual; it is not a quantified risk bound.
