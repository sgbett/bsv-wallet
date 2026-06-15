# Security Specialist Review — Phase 2 refresh (issue #290)

**Reviewer:** Nadia Okafor, Security Specialist (`security_specialist`)
**Target:** Issue #290 comment *"Phase 2 refresh — classification after #307 + #296 egress landed (2026-06-15)"*
**Scope:** Engine refactor (#291) re-classification of `Engine::Action` — `FundingStrategy` / `TxBuilder` / `ChangeGenerator` / `Hydrator` / `BeefImporter`; Correction 1 (one shared `verify_beef` adapter) and Correction 2 (#60 inference removal).
**Mode:** Design review. No code in this phase — the security question is whether the *shapes the classification commits to* preserve the trust boundaries currently enforced by the code.

---

## Perspective

I read this from the trust-boundary lens. Every BEEF that enters via `internalize` is hostile until SPV says otherwise; every BEEF that leaves carries the wallet's reputation for SPV honesty. The single most security-load-bearing fact in `Engine::Action` today is an *asymmetry of trust expressed only by which `ChainTracker` instance is passed to one SDK method*:

- `verify_incoming_transaction!` (action.rb:1093) verifies untrusted peer data against the **network-backed** `@engine.chain_tracker`, and hard-refuses if it is nil (line 1094).
- `validate_for_handoff!` (action.rb:574) verifies the wallet's own egress against `TrustedSelfChainTracker.new` (line 583) — a tracker whose `valid_root_for_height?` returns `true` for **every** root (trusted_self_chain_tracker.rb:37).

There is no type-level wall between these two trackers. The only thing stopping a forged merkle proof from being accepted on the incoming path is that the correct tracker instance reaches `verify`. Correction 1 proposes to fold both call sites into one helper. That is the proposal I scrutinise hardest, because de-duplication here means *removing the textual separation that currently makes the asymmetry self-evident at each call site*.

## Assessment

**Approve-with-changes.**

The classification is sound and the de-dup is legitimately small. But the merge of the two verify adapters concentrates the wallet's entire incoming/egress trust asymmetry into one helper's `chain_tracker:` argument. The design is safe **iff** the helper is built so that the trusted tracker can never be the default and the incoming path can never silently fall through to it. Two of my concerns are about locking that in at design time, before the extraction HLRs are written — cheaper now than as a post-hoc review nit on the PR.

## Strengths

1. **The asymmetry is correctly named, not erased.** The comment explicitly states the two adapters "differ only in (1) the chain-tracker … (2) the wallet error class", and that "untrusted-vs-own-egress *is* just which tracker you pass". The author understands the boundary is the tracker. That is the right mental model — my concern is purely about enforcing it structurally rather than relying on the caller to pass correctly.
2. **Verification stays SDK-delegated (ADR-018).** Not inventing a wallet-side verification collaborator is the right call. `Transaction::Tx#verify` is the stateless operation; the tracker is the wallet's injected state. The refusal to create a "bidirectional verifier" avoids re-implementing SPV in the wallet — which would be a far larger attack surface than a 6-line adapter. Good security instinct.
3. **`BeefImporter` owning "parse/store + tracker choice only"** keeps the trust decision (which tracker for incoming) co-located with the incoming-data owner. The tracker choice is *policy*; binding it to the importer that handles untrusted input is the correct placement.
4. **Egress validation stays wired (#296 Phase B / ADR-015).** The classification keeps `validate_for_handoff!` on `Action` (Action.create + sign!), so the SPV-honesty backstop is not dislodged by the move. The egress invariant survives the refactor intact.
5. **Correction 2 strengthens a boundary.** Removing the #60 inference in `resolve_internalize_output` (action.rb:1175) — stating `output_type` explicitly rather than guessing ownership from field-shape — eliminates a class of confused-deputy risk where a crafted incoming output spec's *absence* of fields decided ownership/type. Schema-enforced authorisation (ADR-019/023) is a real security upgrade over field-shape inference.

## Concerns

### C1 — `verify_beef(chain_tracker:)` must make `TrustedSelfChainTracker` un-defaultable on the incoming path. **(Severity: High)**

This is the sharp angle. After the merge, the *only* thing distinguishing "verify forged peer data, reject it" from "trust everything structurally" is the value of one keyword argument. Failure modes that would silently accept forged merkle proofs:

- **A default value.** If the extracted helper is written `def verify_beef(tx, chain_tracker: TrustedSelfChainTracker.new, error:)` — or any default at all — an incoming call site that omits the argument (a future refactor, a copy-paste, a new internalize-like path) silently trusts every root. Today `verify_incoming_transaction!` cannot do this: it has *no* tracker parameter and reads `@engine.chain_tracker` directly, then **hard-fails on nil** (line 1094). The merge must not trade that nil-guard away for a convenient default.
- **Loss of the nil-guard.** The incoming guard `raise InvalidBeefError, 'chain_tracker required …' unless @engine.chain_tracker` is a fail-*closed* check: no network tracker → no verification → reject. If the shared helper accepts whatever it's handed, an engine constructed with `chain_tracker: nil` (permitted — engine.rb:63 defaults it nil) would, on the incoming path, need *someone* to still fail closed. That guard must survive in `BeefImporter`, not evaporate into the shared helper.

**Fix (design-time, bake into the Phase 6 HLR acceptance criteria):**
- `chain_tracker:` is a **required** keyword on the shared helper — no default, ever. Make omission a `TypeError` at call time.
- `BeefImporter` retains the explicit nil-guard before calling the helper: incoming verify with a nil/absent network tracker must `raise InvalidBeefError`, fail-closed, never substitute the trusted tracker.
- `TrustedSelfChainTracker` is constructed **only** inside the egress path (`validate_for_handoff!` / its future home). The incoming path must have no lexical reference to that class. Consider an RSpec guard asserting `BeefImporter` source contains no `TrustedSelfChainTracker` reference — cheap, and it turns "don't misuse the footgun" (today a class comment) into a test.

### C2 — `derive_signing_key` moving to `TxBuilder` widens the key-handling blast radius. **(Severity: Medium)**

`derive_signing_key` (action.rb:773) returns a live `PrivateKey` (or the root private key, line 776). Today it is a private method on `Action`, reached only by `build_inputs` / `apply_spends` within the same object — a tight key-handling boundary. The classification moves it to `TxBuilder` alongside `build_transaction`, `build_inputs`, script resolution, etc.

The move is defensible (key derivation *is* transaction-assembly), but it changes who can reach a private-key-minting method. Security asks of the Phase 4 HLR:

- **`derive_signing_key` must stay private on `TxBuilder`.** It must not become part of `TxBuilder`'s public collaborator surface. A method that returns the *root private key* should never be callable from outside the assembly path.
- **No key material on the new object's instance state.** `Action` today holds no key state (keys are derived, used to `tx.sign`, and dropped within one method). `TxBuilder` must preserve that: derive → sign → discard, no `@signing_keys` memoisation living on a longer-lived collaborator. The `signing_keys` hash in `build_inputs`/`generate_change` is method-local today (action.rb:700, 949); keep it that way. A collaborator that *caches* derived keys across calls would be a new key-at-rest exposure that does not exist now.
- **Logging discipline carries over.** `derive_signing_key` logs `prefix=` at debug (line 779) but never the key — that restraint must move with the method. Re-confirm in the extracted form.

### C3 — egress and incoming verification end up in different objects; keep the asymmetry legible. **(Severity: Low)**

Post-refactor, `validate_for_handoff!` stays on `Action` while `verify_incoming_transaction!` moves to `BeefImporter` — yet Correction 1 says both call *one shared helper*. So the shared `verify_beef` helper has two callers in two different classes, each passing a different tracker. That is fine functionally, but the trust asymmetry is now split across two files, where today a reader sees both adapters adjacent in `action.rb` and the contrast is obvious.

**Fix:** wherever the shared helper lives, its docstring must state the contract explicitly — "callers on untrusted input MUST pass the network-backed `ChainTracker`; `TrustedSelfChainTracker` is egress-only" — mirroring the existing `TrustedSelfChainTracker` class comment (trusted_self_chain_tracker.rb:22). The two call sites should each carry a one-line boundary comment naming which side they are. This is documentation, not code — but it is the documentation that keeps C1's invariant from rotting.

## Recommendations

1. **Write C1 into the Phase 6 (`BeefImporter`) HLR as a hard acceptance criterion**, not a review-time hope: `verify_beef` takes a *required* `chain_tracker:`; the incoming nil-guard is preserved and fails closed; `TrustedSelfChainTracker` has zero references outside the egress path; add the source-scan spec.
2. **Write C2 into the Phase 4 (`TxBuilder`) HLR:** `derive_signing_key` stays private; no derived-key memoisation on the collaborator; logging restraint preserved.
3. **Keep the egress invariant test coverage** (`spec/integration/beef_egress_validity_spec.rb`) green across every extraction — it is the regression net for the egress side of the boundary. Add an incoming-side counterpart if one does not exist: assert that a BEEF with a forged/absent merkle root is *rejected* by the incoming path, so a future tracker-default mistake is caught by a test rather than shipped.
4. **No objection to the sequence or the collaborator set.** The de-dup is a genuine simplification; my changes are about how the helper's signature is shaped, not whether it should exist.

The refactor does not erode the trust boundary on paper. It concentrates it into one argument, so the work is to make that argument impossible to get wrong. Bake the three invariants into the extraction HLRs now and this is a clean Approve.
