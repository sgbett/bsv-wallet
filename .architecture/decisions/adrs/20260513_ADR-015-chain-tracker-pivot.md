# ADR-015: Chain-tracker pivot — SDK `Transaction::Tx#verify` over hand-rolled ancestry walking

## Status

Accepted.

**Decided:** 2026-05-13 (PR #100, feat/95-chain-tracker-pivot)

## Context

A wallet must do two things with a transaction's ancestry. To hand a peer a BEEF it must walk the input graph and attach each source transaction. To accept an incoming BEEF it must verify that graph — scripts execute, fees balance, and every proven leaf's merkle root is real for its block height. These are the same tree walk; only the second adds verification.

The wallet had built its own walker (`resolve_ancestor` / `collect_input_ancestry`) that did the first and skipped the second: it *collected* ancestry for BEEF construction but never *verified* it. Incoming BEEFs were structurally validated only — no merkle root was ever checked against a real block header, because no chain-tracker implementation existed (only test doubles), and the validation path bailed when none was injected. That gap — accepting unverified merkle roots — is the bug this pivot closes.

The SDK already carries the verified walk. `Transaction::Tx#verify(chain_tracker:)` (`bsv-sdk` 0.24.0) is a breadth-first traversal of the ancestry graph: a merkle-proven transaction short-circuits after its proof is checked against the injected chain-tracker; an unproven one has each input's source populated, its scripts executed, and an output ≤ input constraint enforced, then its sources are enqueued. That is precisely the wallet's hand-rolled walk, with the verification the hand-rolled version lacked, and ported from the reference implementation rather than written fresh here.

The SDK's `Transaction::ChainTracker` is the injection seam: a two-method duck type — `valid_root_for_height?(root, height)` and `current_height` — that `verify` calls through `MerklePath#verify` to answer "is this merkle root real at this height?" The SDK ships an HTTP implementation (`ChainTrackers::WhatsOnChain`) but the contract is open for the wallet to supply its own.

## Decision Drivers

* The SDK's `verify` is the same walk the wallet hand-rolled, with verification the hand-rolled one omitted, and carries the reference implementation's correctness confidence.
* The chain-tracker contract is two methods; supplying an implementation is cheap, and the SDK was built expecting one.
* Merkle-root answers need block headers, and headers are canonical chain state the wallet should own and persist — not refetch per verification.
* This is an architectural replacement; the hand-rolled walker resists incremental reshaping (see Alternatives).

## Decision

**Adopt `Transaction::Tx#verify(chain_tracker:)` as the verification path and delete the hand-rolled walker.** `resolve_ancestor`, `collect_input_ancestry`, `validate_beef!`, and `validate_fee_adequacy!` are removed wholesale. Ancestry collection for BEEF construction reduces to `wire_ancestor` — a ProofStore-only load-and-attach, used by `build_atomic_beef` (`gem/bsv-wallet/lib/bsv/wallet/engine/action.rb`); verification is the SDK's job.

**`BSV::Network::ChainTracker` is a write-through cache bridging the database and the network** (`gem/bsv-wallet/lib/bsv/network/chain_tracker.rb`). It inherits the SDK's `Transaction::ChainTracker` duck type. `valid_root_for_height?` answers from the local `blocks` table first (`Store#find_block`); on a miss it fetches the header through the `BSV::Network::Services` routing layer, persists it (`Store#record_block_header`), then answers. `current_height` reads the network, falling back to `Store#max_block_height`. It **fails closed** — any error returns `false`, so verification fails rather than passing on incomplete data. The header database thus self-populates through normal verification, with no separate orchestration.

**Incoming transactions are verified against real chain state.** `internalize_action` goes through `verify_incoming_transaction!`, which hard-requires `@engine.chain_tracker` (the network-backed `ChainTracker`) and runs full SPV — untrusted merkle roots are checked against real headers (`gem/bsv-wallet/lib/bsv/wallet/engine/action.rb`). Where no chain-tracker is configured it raises, rather than degrading to structural-only as the old path did: accepting unverified merkle roots is the bug being closed.

**Architectural components affected:** the engine's BEEF construction and verification paths (`build_atomic_beef`, `wire_ancestor`, `verify_incoming_transaction!`); the new `BSV::Network::ChainTracker`; the `blocks` table and its three Store accessors (`find_block`, `record_block_header`, `max_block_height`); `BSV::Network::Services` as the miss-path provider.

The egress side of the trust question — what guarantee the wallet must give about BEEFs it *emits* — was a later, separate decision and is recorded in **ADR-015 (egress-BEEF validation)**; the `TrustedSelfChainTracker` and `validate_for_handoff!` that close that gap are not part of this pivot.

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

### C. Pre-fetch / batch headers out of band
Populate `blocks` via a background header-sync rather than on verification miss.
**Pros:** verification never blocks on a network fetch.
**Cons:** speculative infrastructure for a problem not yet observed; the write-through miss-path already self-populates through normal operation with zero orchestration. A sync job can be added later if header-fetch latency proves to matter.
**Rejected (for now)** — write-through is simpler and sufficient; revisit if measured.

## Consequences

### Positive

* Incoming transactions get full SPV verification — scripts, fees, and merkle roots checked against real headers — where before only structure was checked.
* One verified walk, the reference implementation's, replaces a hand-rolled one that resisted reshaping; `resolve_ancestor`, `collect_input_ancestry`, `validate_beef!`, and `validate_fee_adequacy!` are gone.
* The `blocks` table self-populates as a write-through header cache; no separate header-sync to build or schedule.
* The integration uses the SDK at its intended seam — the wallet finally implements the `ChainTracker` duck type the SDK was built to receive.

### Negative

* The verification path now depends on SDK internals (`Transaction::Tx#verify`'s walk and `VerificationError` codes); a breaking SDK change ripples here. Accepted — the SDK is the deliberate home of stateless operations (ADR-018), and pre-1.0 the two move together.
* `verify_incoming_transaction!` hard-fails when no chain-tracker is configured, where the old path degraded to structural-only. This is intended — accepting unverified merkle roots is the bug being closed — but it makes a configured `ChainTracker` mandatory for `internalize_action`.
* `current_height` is read off the network with a stale-DB fallback; a provider returning a wrong height degrades the coinbase-maturity check. Bounded by the same fail-closed posture on `valid_root_for_height?`.

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

This is a correction, not a feature: the wallet duplicated a walk the SDK already performs and dropped the verification in the copy — the strongest case for deletion-and-cutover rather than adaptation. The write-through tracker is the minimal bridge (two methods, fail-closed) between the SDK's algorithm and the wallet's owned state, and it self-populates the `blocks` table that the schema already designates as canonical. The added SDK-internals coupling is the accepted cost of putting stateless verification where it belongs. No gold-plating; speculative header pre-fetch was correctly declined. **Approve.**

## Validation

* `BSV::Network::ChainTracker` inherits `BSV::Transaction::ChainTracker` and implements `valid_root_for_height?` (DB-first, network-miss, persist, fail-closed) and `current_height` (`gem/bsv-wallet/lib/bsv/network/chain_tracker.rb:15,29,63`).
* `resolve_ancestor`, `collect_input_ancestry`, `validate_beef!`, `validate_fee_adequacy!` are absent from the codebase; ancestry attach is `wire_ancestor` (ProofStore-only, `gem/bsv-wallet/lib/bsv/wallet/engine/action.rb:624`).
* Incoming verification calls `subject_tx.verify(chain_tracker: @engine.chain_tracker)` and raises when no tracker is configured (`gem/bsv-wallet/lib/bsv/wallet/engine/action.rb:1093-1096`).
* The miss path persists via `Store#record_block_header` (`gem/bsv-wallet/lib/bsv/network/chain_tracker.rb:75`); reads hit `Store#find_block` / `Store#max_block_height` (`:36,:67`); the `blocks` table is `bytea` merkle_root / block_hash (`docs/reference/schema.md`).

## References

* ADR-003 — schema as canonical state; the `blocks` table is the canonical "merkle root at height N", and the chain-tracker populates it.
* ADR-006 — one relational store; `blocks` and `tx_proofs` share the single ACID boundary the tracker writes into.
* ADR-008 — binary internally; merkle roots and block hashes are stored wire-order `bytea`, converted from the SDK's display-order hex at the tracker boundary.
* ADR-018 — stateless SDK / stateful wallet; `Transaction::Tx#verify` is the stateless operation, the header cache and proof state are the wallet's.
* ADR-015 (egress-BEEF validation) — the later, separate egress decision (`TrustedSelfChainTracker` / `validate_for_handoff!`); the trust asymmetry between incoming and own-egress data is settled there, not here.
* HLR #95 (chain-tracker pivot), PR #100 (`feat/95-chain-tracker-pivot`); builds on #79/#80 (`blocks` normalisation), #83 (Services routing).
* `.architecture/reviews/20260513_chain-tracker-pivot.md` — multi-perspective review (assessment: Strong).
* `gem/bsv-wallet/lib/bsv/network/chain_tracker.rb`; `gem/bsv-wallet/lib/bsv/wallet/engine/action.rb`; `docs/reference/schema.md`; `bsv-sdk` `lib/bsv/transaction/tx.rb` (`#verify`), `lib/bsv/transaction/chain_tracker.rb`.

## Unverified claims

* `Transaction::Tx#verify` was at `lib/bsv/transaction/tx.rb:633` and `Transaction::ChainTracker` at `lib/bsv/transaction/chain_tracker.rb:52` in the original ADR; these SDK line numbers are in a separate `bsv-sdk` repository not read in this pass — the method/class existence is confirmed by the wallet's use of them, but the exact SDK line numbers are not re-verified.
