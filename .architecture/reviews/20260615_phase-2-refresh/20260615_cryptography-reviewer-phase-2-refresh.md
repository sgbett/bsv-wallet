# Cryptography Review — Phase 2 Refresh (#290) Re-Classification

**Reviewer:** Dr. Kenji Nakamura, Cryptography Reviewer (`cryptography_reviewer`)
**Target:** Issue #290 comment "Phase 2 refresh — classification after #307 + #296 egress landed (2026-06-15)"
**Scope:** Crypto-correctness implications of the refreshed `Engine::Action` extraction map (`FundingStrategy` / `TxBuilder` / `ChangeGenerator` / `Hydrator` / `BeefImporter`), Correction 1 (SDK-delegated BEEF verification), sign-last ordering.
**Source reviewed:** `gem/bsv-wallet/lib/bsv/wallet/engine/action.rb` (`derive_signing_key` :773, `build_inputs` :696, `build_outputs` :658, `build_transaction` :810, `generate_change` :940, `apply_spends` :470, `validate_for_handoff!` :574, `verify_incoming_transaction!` :1093, `wire_ancestor` :620, `build_atomic_beef` :598); `key_deriver.rb`; `trusted_self_chain_tracker.rb`; ADR-008/015/018/023.

---

## Perspective

I evaluate against the protocol, not against "the tests pass". Three things matter here: (1) BRC-42 derivation produces the *exact same* key after the method moves to a new file — derivation is pure, so the risk is in *which arguments* the new collaborator passes, not in the maths; (2) no private-key material outlives the operation that needs it once it crosses a collaborator boundary; (3) the ECDSA sighash commits to the *final* output set — sign-last must survive a shuffle/sign split.

## Assessment

This is a **sound classification from a crypto standpoint, with no algorithm relocation.** Critically, none of the moving methods *implement* cryptography. `derive_signing_key`, `generate_change`'s change-key block, and both verify adapters are all thin call-sites over `@engine.key_deriver` and the SDK's `Transaction::Tx#verify`. The actual BRC-42 ECDH (`derive_child`/`compute_invoice_number`) stays in `KeyDeriver`; the merkle/SPV walk stays in the SDK. So the refactor moves *orchestration*, and the failure mode is wrong-argument plumbing, not broken primitives. Correction 1 is correct: the two verify methods (:574, :1093) differ only in injected chain-tracker and raised error class — there is no verification logic to extract. Approve the direction. The guardrails below are about preserving correctness *across* the new seams, and they are test-vector-expressible.

## Strengths

- **Derivation is centralised and stays put.** Both signing-key derivation (`derive_signing_key` → `derive_private_key`, protocol `[2, prefix]`, key_id = suffix, counterparty = `sender_identity_key || 'self'`) and change derivation (`generate_change` → `derive_public_key`, same protocol shape, counterparty `'self'`) funnel through the one `KeyDeriver`. `TxBuilder` and `ChangeGenerator` will each hold an `@engine`/`key_deriver` reference and call it — the derivation contract is unchanged by the move.
- **The signing/change-locking symmetry is real and must be preserved.** Change is locked to `hash160(derive_public_key(...))` (:958-960); the future spend re-derives the *private* key for the same `[2, prefix]/suffix/self` triple. `derive_public_key(...).public_key == derive_private_key(...).public_key` by construction (`key_deriver.rb` :90 vs :106). This round-trip is the load-bearing invariant a `ChangeGenerator`/`TxBuilder` split could silently break if either side drifts the protocol/counterparty tuple.
- **Correction 1 is cryptographically accurate.** `TrustedSelfChainTracker` (`valid_root_for_height? = true`) is *structural-only* and explicitly forbidden for incoming data; the network tracker does the real merkle-root check. Folding the two ~6-line adapters into one `verify_beef(tx, chain_tracker:, error:)` helper preserves exactly this distinction — the trust decision *is* the injected tracker. No correctness is lost by not creating a verifier collaborator.
- **Sign-last is currently correct and explicitly commented.** `generate_change` step I (:1017-1018) signs *after* `tx.fee(...)` (:1003) and *after* `tx.outputs.shuffle!` (:1009). The sighash therefore commits to final output values and positions. `build_outputs` (:658) shuffles before signing in `build_transaction` (:824). This is the property most at risk in the split.

## Concerns

### C1 — Sign-last invariant spans `ChangeGenerator` ↔ `TxBuilder` after the split (severity: HIGH)
Today fee-distribute → shuffle → **sign** are co-located in `generate_change` (:1003/1009/1018). The refresh puts `generate_change` in `ChangeGenerator` and the signing helpers (`build_inputs`, `derive_signing_key`) in `TxBuilder`. If signing migrates to `TxBuilder` while shuffle/fee stay in `ChangeGenerator`, an extraction that signs before the final shuffle (or re-shuffles after signing) produces signatures over a stale output set — every input's ECDSA sig becomes invalid, and the only symptom is a broadcast rejection (`mandatory-script-verify-flag-failed`), not a Ruby error.
**Fix:** Make sign-last a *contract of the seam*, not a comment. Whichever collaborator owns the final mutation of `tx.outputs` must own (or invoke last) the signing step. Add an integration assertion that re-verifies each input's unlocking script against the final serialised tx (or asserts `tx.verify`-clean for a self-spend round-trip) after a randomized build — a deterministic seeded-shuffle test vector is the right artifact. State this invariant in the Phase 4 extraction HLR's acceptance criteria.

### C2 — Change-derivation parameters must be carried, not re-guessed, across the seam (severity: MEDIUM)
`generate_change` emits `change_output_specs` carrying `derivation_prefix`/`derivation_suffix`/`sender_identity_key = identity_key` (:1027-1029). The future spend path (`derive_signing_key`, :780-786) reconstructs the key from exactly those stored fields, with `counterparty = sender_identity_key || 'self'`. For self-change the counterparty at *derivation* time is the literal `'self'` (:956) and at *spend* time is `identity_key` (own hex) — these resolve to the same point via `resolve_counterparty`, but the equivalence is implicit. If `ChangeGenerator` and `TxBuilder` are authored independently and one normalises `'self'` differently, derived keys diverge and the change becomes unspendable.
**Fix:** Pin the `'self'`-vs-`identity_key` counterparty equivalence with a test vector: derive change pubkey with `counterparty: 'self'`, then re-derive the private key with `counterparty: <identity_key hex>`, assert `priv.public_key == pub`. This vector guards both collaborators against drift and documents the equivalence the #60 inference removal relies on.

### C3 — No private-key lingering today; keep it that way in the seam (severity: LOW)
`signing_keys` (a `{idx => PrivateKey}` hash) is built and consumed within a single method scope in `build_transaction`/`generate_change`/`apply_spends`, and goes out of scope at method return. The split must not promote this hash to a collaborator instance variable (`@signing_keys`) to "pass it between TxBuilder and ChangeGenerator" — that would keep secret key material alive on a long-lived collaborator object across calls. Ruby gives us no zeroisation, so scope-bounded lifetime is the only control we have.
**Fix:** Keep derived `PrivateKey` objects as method-local values passed by return/argument, never stored on a collaborator that outlives the build. Note this constraint in the Phase 4 HLR.

## Recommendations

1. **Phase 4 HLR acceptance criteria must name three crypto invariants explicitly:** (a) sign-last — signatures cover the post-shuffle, post-fee output set (C1); (b) change round-trip — `derive_public_key` lock is spendable by `derive_private_key` for the same tuple (C2); (c) no key material on long-lived collaborator state (C3).
2. **Add seeded/deterministic test vectors before the split, not after.** A fixed-seed shuffle + self-spend round-trip that asserts `tx.verify`-clean is the regression net that makes the `ChangeGenerator`/`TxBuilder` boundary safe to move. These are cheap and currently absent at the seam level.
3. **Adopt Correction 1 as written** — one shared `verify_beef(tx, chain_tracker:, error:)` helper. Add one assertion that `TrustedSelfChainTracker` is *never* passed on the incoming path (e.g. a unit test that `verify_incoming_transaction!` rejects a structurally-complete-but-chain-invalid BEEF), so the egress shortcut can't leak into ingress during the BeefImporter extraction.
4. **No new crypto review needed for `Hydrator`/`wire_ancestor`** — it wires `source_transaction` pointers and attaches `merkle_path`; it computes no signatures or derived keys. Its correctness is the SDK's `verify` walk consuming what it assembles, already covered by #296's integrity assertions.
