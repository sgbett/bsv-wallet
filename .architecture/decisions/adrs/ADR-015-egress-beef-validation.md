# ADR-015: Egress-BEEF validation — the wallet must never ship an invalid BEEF

## Status

Accepted.

**Decided:** 2026-06-10 (PR #297, #296 Phase B; egress fix `9cd6dbb`, refinement `847941f`)

## Context

The chain-tracker pivot (ADR-015, chain-tracker pivot) settled *incoming* verification: untrusted BEEFs run full SPV through the network-backed `BSV::Network::ChainTracker`. It did not settle the dual question — what guarantee the wallet must give about BEEFs it *emits*.

That gap surfaced as a real fault. Multi-wallet payment cascades intermittently failed SPV verify on the receiver side with errors of the form "input N of transaction X has no source locking script". Tx X was typically a proven ancestor (a merkle_path existed in the sender's ProofStore), but the BEEF that reached the failing receiver carried X *without* its merkle_path attached — so the receiver's `verify` walked into X's inputs and found nothing. Reproduced in `stress_cascade_spec` and `consolidation_dry_run_spec`, both characterised as "intermittent", and pattern was multi-hop only; single-wallet flows were unaffected because their ancestry is always local. (HLR #296.)

The wallet was therefore *emitting* structurally invalid BEEF: a BEEF whose ancestry does not close — some input path neither terminates at a merkle_path nor wires through to one. Two causes combined: a UTXO imported while its proof material was momentarily unavailable (WoC flake at import time) left an unforwardable root, and nothing checked completeness at the point of emission. Wallet→wallet handoff cannot lean on ARC to catch this — ARC does not forward BEEFs to peers, and ARC affinity makes "did ARC accept?" insufficient. The wallet must self-validate before it emits.

This is the egress mirror of the incoming-verify decision, made roughly a month later, against a concrete observed failure rather than a design-time argument.

## Decision Drivers

* The SPV honesty contract requires every BEEF the wallet emits to be peer-verifiable; an emitted BEEF whose ancestry does not close violates it.
* ARC cannot be relied on to catch egress invalidity — the wallet is in ARC's seat for wallet→wallet handoff.
* The wallet's own persisted proofs were already validated against a real chain-tracker at proof-arrival time, so egress needs only a *structural* completeness check, not a re-run of on-chain validation.
* The originating cause (a UTXO imported without proof material) should be refused at the source, not papered over at egress.

## Decision

**(a) Egress validity assertion — `Engine::Action#validate_for_handoff!`.** Every outgoing BEEF is verified before it leaves the wallet (`engine/action.rb:574`). The assertion parses the constructed atomic BEEF, finds the subject transaction by wtxid, and runs `Transaction::Tx#verify` against a `BSV::Wallet::TrustedSelfChainTracker` — a chain-tracker whose `valid_root_for_height?` returns `true` unconditionally and whose `current_height` returns a sentinel (`lib/bsv/wallet/trusted_self_chain_tracker.rb`). Neutralising on-chain validity reduces `verify` to a pure structural-completeness check: the BEEF passes iff every leaf terminates at a merkle_path or wires through to one. Failure raises `BSV::Wallet::EgressBeefInvalidError` (`lib/bsv/wallet/errors.rb`), surfacing the underlying `VerificationError` code. It is wired into both `Action.create` and `Action#sign!` (`engine/action.rb:171,434`).

This is correct, not lax: re-validating merkle roots the wallet already validated at proof-arrival time would be redundant network work, and would couple egress (which should always succeed for sound internal state) to network reachability. The trusted tracker isolates the structural check from chain validity. Its class comment forbids its use on incoming data — that path must use the network-backed `ChainTracker` (the incoming/own-egress trust asymmetry is the substance of this decision).

**(b) Strict import — `Engine#fetch_proof_for_imported_utxo!`.** Importing a UTXO now refuses to register it without on-chain proof material (`engine.rb:1314`): it requires a confirmed `blockheight` from `get_tx_details` and a non-empty merkle_path from `get_merkle_path`, raising otherwise. This eliminates the silent-no-op path in the previous `fetch_and_link_proof` that left imported UTXOs unforwardable — closing the originating cause upstream so the egress assertion is a backstop, not the only line of defence.

**Architectural components affected:** `Engine::Action#validate_for_handoff!` and its wiring into `Action.create` / `Action#sign!`; the new `BSV::Wallet::TrustedSelfChainTracker`; `BSV::Wallet::EgressBeefInvalidError`; `Engine#fetch_proof_for_imported_utxo!` (strict import), with `import_utxo` re-pointed off the lenient `fetch_and_link_proof`.

## Alternatives Considered

### A. Verify egress against the network-backed `ChainTracker` (single trust level)
Run full SPV with the real chain-tracker on outgoing BEEFs too.
**Pros:** one code path; no second tracker class to remember.
**Cons:** re-validates merkle roots the wallet already validated at proof-arrival time — redundant network work on the egress path, for data the wallet persisted *because* it was already proven. It also couples egress (which should always succeed for sound internal state) to network reachability.
**Rejected** — the asymmetry is the correct model: untrusted data is verified, the wallet's own validated state is trusted. `TrustedSelfChainTracker` isolates the structural-completeness check from chain validity.

### B. Rely on ARC acceptance as the egress check
Treat a successful ARC submission as proof the BEEF is sound.
**Pros:** no new wallet code.
**Cons:** ARC does not forward BEEFs to peers, and ARC affinity makes "did ARC accept?" insufficient for wallet→wallet handoff. The receiver — not ARC — is the party that runs `verify`, so the wallet must self-validate before emission.
**Rejected** — the wallet is in ARC's seat for peer handoff; it must check the BEEF it ships.

### C. Fix only the import path; no egress assertion
Make strict import refuse proof-less UTXOs and assume that suffices.
**Pros:** addresses the originating cause directly; no per-emit cost.
**Cons:** leaves no backstop for any *other* path that could produce an incomplete BEEF; a future closure gap would again ship silently. The diagnostic was a one-line egress check — cheap to keep as a standing invariant.
**Rejected (as sole fix)** — adopted *together* with strict import: import refuses at source, egress asserts as backstop.

## Consequences

### Positive

* The wallet does not ship structurally invalid BEEF to peers under any circumstance — the SPV honesty contract holds at emission.
* The previously intermittent multi-wallet cascade specs (`consolidation_dry_run_spec`, `stress_cascade_spec`) become deterministic.
* The egress check is structural-only and network-independent, because the wallet trusts its own already-validated proofs; emission stays fast and does not depend on network reachability.
* Strict import closes the originating cause at source, so the egress assertion is a backstop rather than load-bearing.

### Negative

* `TrustedSelfChainTracker` is a footgun if misused: applied to incoming data it would accept forged proofs. Mitigated by the class comment's explicit prohibition and the separate `verify_incoming_transaction!` path, which hard-requires the network-backed tracker.
* The egress invariant is enforced in application code (`validate_for_handoff!`), not in the schema — the database does not natively express "every emitted BEEF's ancestry closes". This is a conscious, flagged deviation from ADR-003's database-enforcement principle (see `reference/principle-of-state.md`, "Where it leaks today"). Tightening would mean encoding the closure invariant into the schema; flagged as #296 Phase D / future work.
* Strict import refuses UTXOs whose proof material is momentarily unavailable (e.g. WoC flake), where the old path silently no-opped. This is intended — an unforwardable UTXO is worse than a refused import — but makes import sensitive to provider availability at import time.

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

This is a correction to an observed, reproduced fault — the wallet shipping invalid BEEF — not a speculative feature; the strongest case for action. The fix is minimal and reasoned: a structural-only assertion at the single emission boundary, plus refusing the proof-less import that caused it, so the assertion is a backstop rather than the sole defence. The trust asymmetry (trust own validated proofs, verify incoming) is argued from where validation already happened, and the one hazard — the trusted tracker on untrusted input — is fenced by a separate, network-tracker-requiring entry point. The one real concession is that the egress invariant lives in app code with no DB backstop; this is consciously flagged against ADR-003 rather than hidden, and routed to #296 Phase D. **Approve.**

## Validation

* `Engine::Action#validate_for_handoff!` parses the BEEF, finds the subject by wtxid, and runs `verify(chain_tracker: BSV::Wallet::TrustedSelfChainTracker.new)`, raising `EgressBeefInvalidError` on `VerificationError` (`engine/action.rb:574-590`).
* It is wired into `Action.create` (`engine/action.rb:171`) and `Action#sign!` (`engine/action.rb:434`).
* `BSV::Wallet::TrustedSelfChainTracker < BSV::Transaction::ChainTracker`; `valid_root_for_height?` returns `true` and `current_height` returns `SENTINEL_HEIGHT = 1_000_000` (`lib/bsv/wallet/trusted_self_chain_tracker.rb:31,35,37,38`).
* `BSV::Wallet::EgressBeefInvalidError < Error` (`lib/bsv/wallet/errors.rb:38`).
* `Engine#fetch_proof_for_imported_utxo!` raises unless `get_tx_details` returns a `blockheight` and `get_merkle_path` returns a non-empty array; `import_utxo` calls it (`engine.rb:293,1314-1342`).

## References

* ADR-015 (chain-tracker pivot) — the prior, separate decision this mirrors on the egress side; the network-backed `ChainTracker` and incoming `verify_incoming_transaction!` live there.
* ADR-003 — schema as canonical state; the egress invariant is a flagged application-layer deviation (`reference/principle-of-state.md`, "Where it leaks today"), tracked for schema encoding as #296 Phase D.
* ADR-008 — binary internally; the subject is matched on its wire-order wtxid, with the dtxid surfaced only in error prose.
* ADR-018 — stateless SDK / stateful wallet; `Transaction::Tx#verify` is the stateless operation, the persisted proofs the egress check trusts are the wallet's state.
* HLR #296 (BEEF chain integrity), PR #297 (#296 Phase A diagnostic + Phase B fix). `.claude/plans/20260609-beef-hydration.md` — full architectural reasoning (Phases A–D).
* `gem/bsv-wallet/lib/bsv/wallet/engine/action.rb`; `gem/bsv-wallet/lib/bsv/wallet/trusted_self_chain_tracker.rb`; `gem/bsv-wallet/lib/bsv/wallet/errors.rb`; `gem/bsv-wallet/lib/bsv/wallet/engine.rb`.

## Unverified claims

None.
