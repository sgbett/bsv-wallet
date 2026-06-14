# ADR-015: Chain-tracker pivot — SDK `Transaction::Tx#verify` over hand-rolled ancestry walking

## Status

Accepted.

## Context

A wallet must do two things with a transaction's ancestry. To hand a peer a BEEF it must walk the input graph and attach each source transaction. To accept an incoming BEEF it must verify that graph — scripts execute, fees balance, and every proven leaf's merkle root is real for its block height. These are the same tree walk; only the second adds verification.

The wallet had built its own walker (`resolve_ancestor` / `collect_input_ancestry`) that did the first and skipped the second: it *collected* ancestry for BEEF construction but never *verified* it. Incoming BEEFs were structurally validated only — no merkle root was ever checked against a real block header, because no chain-tracker implementation existed (only test doubles), and the validation path bailed when none was injected.

The SDK already carries the verified walk. `Transaction::Tx#verify(chain_tracker:)` (`bsv-sdk` 0.24.0, `lib/bsv/transaction/tx.rb:633`) is a breadth-first traversal of the ancestry graph: a merkle-proven transaction short-circuits after its proof is checked against the injected chain-tracker; an unproven one has each input's source populated, its scripts executed, and an output ≤ input constraint enforced, then its sources are enqueued. That is precisely the wallet's hand-rolled walk, with the verification the hand-rolled version lacked, and ported from the reference implementation rather than written fresh here.

The SDK's `Transaction::ChainTracker` (`lib/bsv/transaction/chain_tracker.rb:52`) is the injection seam: a two-method duck type — `valid_root_for_height?(root, height)` and `current_height` — that `verify` calls through `MerklePath#verify` to answer "is this merkle root real at this height?" The SDK ships an HTTP implementation (`chain_trackers/whats_on_chain.rb`) but the contract is open for the wallet to supply its own.

## Decision Drivers

* The SDK's `verify` is the same walk the wallet hand-rolled, with verification the hand-rolled one omitted, and carries the reference implementation's correctness confidence.
* The chain-tracker contract is two methods; supplying an implementation is cheap, and the SDK was built expecting one.
* Merkle-root answers need block headers, and headers are canonical chain state the wallet should own and persist — not refetch per verification.
* Incoming (untrusted) and own (already-validated) transactions warrant different trust, and the injection seam lets one `verify` call carry both by varying the tracker.
* This is an architectural replacement; the hand-rolled walker resists incremental reshaping (see Alternatives).

## Decision

**Adopt `Transaction::Tx#verify(chain_tracker:)` as the verification path and delete the hand-rolled walker.** `resolve_ancestor`, `collect_input_ancestry`, `validate_beef!`, and `validate_fee_adequacy!` are removed wholesale. Ancestry collection for BEEF construction reduces to `wire_ancestor` — a ProofStore-only load-and-attach with no Store lookups (`engine/action.rb`, used by `build_atomic_beef`); verification is the SDK's job.

**`BSV::Network::ChainTracker` is a write-through cache bridging the database and the network** (`lib/bsv/network/chain_tracker.rb`). It inherits the SDK's `Transaction::ChainTracker` duck type. `valid_root_for_height?` answers from the local `blocks` table first (`Store#find_block`); on a miss it fetches the header through the `BSV::Network::Services` routing layer, persists it (`Store#record_block_header`), then answers. `current_height` reads the network, falling back to `Store#max_block_height`. It **fails closed** — any error returns `false`, so verification fails rather than passing on incomplete data. The header database thus self-populates through normal verification, with no separate orchestration.

**A deliberate trust asymmetry: verify incoming, trust own.** Incoming transactions (`internalize_action`) go through `verify_incoming_transaction!`, which hard-requires `@engine.chain_tracker` (the network-backed `ChainTracker`) and runs full SPV — untrusted merkle roots are checked against real headers (`engine/action.rb:1093`). The wallet's *own* egress BEEF goes through `validate_for_handoff!` with `BSV::Wallet::TrustedSelfChainTracker` (`lib/bsv/wallet/trusted_self_chain_tracker.rb`), which answers `true` to every root lookup and returns a sentinel height. This is correct, not lax: the wallet's persisted proofs were already validated against a real chain-tracker at proof-arrival time (`import_utxo`, `save_beef_proofs`). At egress the wallet needs only *structural* completeness — does every input path terminate at a merkle path or wire through to one — which is exactly the `verify` walk with chain-validity neutralised. The trusted tracker's class comment forbids its use on incoming data; that path must use the network-backed `ChainTracker`.

**Architectural components affected:** the engine's BEEF construction and verification paths (`build_atomic_beef`, `wire_ancestor`, `verify_incoming_transaction!`, `validate_for_handoff!`); the new `BSV::Network::ChainTracker`; the new `BSV::Wallet::TrustedSelfChainTracker`; the `blocks` table and its three Store accessors (`find_block`, `record_block_header`, `max_block_height`); `BSV::Network::Services` as the miss-path provider.

## Alternatives Considered

### A. Keep the hand-rolled walker; bolt verification on
Extend `resolve_ancestor` / `validate_beef!` to also check merkle roots and fees.
**Pros:** no new dependency on SDK internals; reuses code already wired into BEEF construction.
**Cons:** reimplements, less well, a walk the SDK already verifies; the hand-rolled traversal is woven through `build_atomic_beef` / `collect_input_ancestry` and resists reshaping — bolting verification on yields two half-implemented walkers whose assumptions bleed into each other. Pre-1.0, there is no compatibility reason to preserve it.
**Rejected** — an architectural pivot is a clean replacement, not an adaptation: delete the old walk, cut over to the SDK's.

### B. Inject the SDK's own HTTP chain-tracker (`ChainTrackers::WhatsOnChain`)
Use the SDK's bundled WhatsOnChain tracker directly instead of writing one.
**Pros:** zero wallet code; works immediately.
**Cons:** every merkle-root check is a network round-trip with no local cache, and block headers — canonical chain state — never land in the wallet's store. Verification cost scales with ancestry depth × latency, and the `blocks` table (already in the schema as the source of truth for "merkle root at height N") stays empty.
**Rejected** — headers are state the wallet owns; the tracker must persist what it fetches.

### C. A single trust level — verify everything, including own egress
Run full SPV with the network-backed `ChainTracker` on outgoing BEEFs too.
**Pros:** one code path; no second tracker class to remember.
**Cons:** re-validates merkle roots the wallet already validated at proof-arrival time — redundant network work on the egress path, for data the wallet persisted *because* it was already proven. It also couples egress (which should always succeed for sound internal state) to network reachability.
**Rejected** — the asymmetry is the correct model: untrusted data is verified, the wallet's own validated state is trusted. The trusted tracker isolates the structural-completeness check from chain validity.

### D. Pre-fetch / batch headers out of band
Populate `blocks` via a background header-sync rather than on verification miss.
**Pros:** verification never blocks on a network fetch.
**Cons:** speculative infrastructure for a problem not yet observed; the write-through miss-path already self-populates through normal operation with zero orchestration. A sync job can be added later if header-fetch latency proves to matter.
**Rejected (for now)** — write-through is simpler and sufficient; revisit if measured.

## Consequences

### Positive

* Incoming transactions get full SPV verification — scripts, fees, and merkle roots checked against real headers — where before only structure was checked.
* One verified walk, the reference implementation's, replaces a hand-rolled one that resisted reshaping; `resolve_ancestor`, `collect_input_ancestry`, `validate_beef!`, and `validate_fee_adequacy!` are gone.
* The `blocks` table self-populates as a write-through header cache; no separate header-sync to build or schedule.
* Egress stays fast and network-independent: the wallet trusts its own already-validated proofs and checks only structural completeness.
* The integration uses the SDK at its intended seam — the wallet finally implements the `ChainTracker` duck type the SDK was built to receive.

### Negative

* The verification path now depends on SDK internals (`Transaction::Tx#verify`'s walk and `VerificationError` codes); a breaking SDK change ripples here. Accepted — the SDK is the deliberate home of stateless operations (ADR-018), and pre-1.0 the two move together.
* The trust asymmetry is a footgun if misused: `TrustedSelfChainTracker` on incoming data would accept forged proofs. Mitigated by the class comment's explicit prohibition and the separate `verify_incoming_transaction!` path that hard-requires the network-backed tracker.
* `verify_incoming_transaction!` hard-fails when no chain-tracker is configured, where the old path degraded to structural-only. This is intended — accepting unverified merkle roots is the bug being closed — but it makes a configured `ChainTracker` mandatory for `internalize_action`.
* `current_height` is read off the network with a stale-DB fallback; a provider returning a wrong height degrades the coinbase-maturity check. Bounded by the same fail-closed posture on `valid_root_for_height?`.

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

This is a correction, not a feature: the wallet duplicated a walk the SDK already performs and dropped the verification in the copy — the strongest case for deletion-and-cutover rather than adaptation. The write-through tracker is the minimal bridge (two methods, fail-closed) between the SDK's algorithm and the wallet's owned state, and it self-populates the `blocks` table that the schema already designates as canonical. The trust asymmetry is reasoned from where validation already happened, not from convenience — incoming data is verified, the wallet's own proven state is trusted — and the one real hazard (the trusted tracker on untrusted input) is fenced by a separate, chain-tracker-requiring entry point. The added SDK-internals coupling is the accepted cost of putting stateless verification where it belongs. No gold-plating; speculative header pre-fetch was correctly declined. **Approve.**

## Validation

* `BSV::Network::ChainTracker` inherits `BSV::Transaction::ChainTracker` and implements `valid_root_for_height?` (DB-first, network-miss, persist, fail-closed) and `current_height` (`lib/bsv/network/chain_tracker.rb`).
* `resolve_ancestor`, `collect_input_ancestry`, `validate_beef!`, `validate_fee_adequacy!` are absent from the codebase; ancestry attach is `wire_ancestor` (ProofStore-only).
* Incoming verification calls `subject_tx.verify(chain_tracker: @engine.chain_tracker)` and raises when no tracker is configured (`engine/action.rb:1093`).
* Egress validation calls `verify(chain_tracker: BSV::Wallet::TrustedSelfChainTracker.new)` and `TrustedSelfChainTracker#valid_root_for_height?` returns `true` unconditionally (`engine/action.rb:574`, `trusted_self_chain_tracker.rb`).
* The miss path persists via `Store#record_block_header`; reads hit `Store#find_block` / `Store#max_block_height`; the `blocks` table is `bytea` merkle_root / block_hash (`reference/schema.md`).

## References

* ADR-003 — schema as canonical state; the `blocks` table is the canonical "merkle root at height N", and the chain-tracker populates it.
* ADR-006 — one relational store; `blocks` and `tx_proofs` share the single ACID boundary the tracker writes into.
* ADR-008 — binary internally; merkle roots and block hashes are stored wire-order `bytea`, converted from the SDK's display-order hex at the tracker boundary.
* ADR-011 — the `tx_proofs` rows whose proofs the tracker validates were filled in at proof arrival; egress trust rests on that prior validation.
* ADR-018 — stateless SDK / stateful wallet; `Transaction::Tx#verify` is the stateless operation, the header cache and proof state are the wallet's.
* HLR #95 (chain-tracker pivot); builds on #79/#80 (`blocks` normalisation), #83 (Services routing), #296 (egress SPV-honesty contract).
* `.architecture/reviews/chain-tracker-pivot.md` — multi-perspective review (assessment: Strong).
* `gem/bsv-wallet/lib/bsv/network/chain_tracker.rb`; `gem/bsv-wallet/lib/bsv/wallet/trusted_self_chain_tracker.rb`; `gem/bsv-wallet/lib/bsv/wallet/engine/action.rb`; `reference/schema.md`; `bsv-sdk` `lib/bsv/transaction/tx.rb` (`#verify`), `lib/bsv/transaction/chain_tracker.rb`.

## Unverified claims

None.
