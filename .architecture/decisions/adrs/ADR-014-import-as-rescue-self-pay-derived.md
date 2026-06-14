# ADR-014: Import as rescue; self-pay to a derived address

## Status

Accepted.

## Context

A BRC-100 wallet's outputs are normally BRC-42 derived — every spendable UTXO carries `derivation_prefix`, `derivation_suffix`, `sender_identity_key`, and `output_type` is therefore NULL (ADR-010). But funds can arrive at the wallet's *root* key without any derivation: a payer who only knows the bare identity address (`hash160(identity_key)`), or a bootstrap from a non-BRC-100 source. Such a UTXO is real money the wallet can spend, but it has no derivation data and no upstream ancestry in our database — it does not fit the derived-output shape the rest of the wallet assumes.

A second case lands at the same place. `sweep_to_root` deliberately spends everything to the root P2PKH and does *not* re-track the result: the wallet database is left a blank slate, with funds safe on-chain at the root address, recoverable from the bare WIF alone. Recovering those funds back into a working wallet is the inverse operation — and it faces the same problem: a root-key UTXO with no derivation.

The question this ADR answers: how does a root-key UTXO enter the wallet without violating the invariant that every *spendable* UTXO is BRC-42 derived?

## Decision Drivers

* Every spendable UTXO should be BRC-42 derived; `output_type = 'root'` is a transitional shim for the ecosystem's non-BRC-100 edge, not a target state (ADR-010 names `root` the non-derived special case).
* An imported UTXO has no upstream ancestry in our database, so it cannot lean on an upstream merkle proof the way an ordinary spend does — it must carry its own.
* Recovery must be a deliberate, narrow act, not a general intake that quietly accepts anything at the root key.
* Bad data must never reach the database; an operation that fails to produce a usable result must fail loudly, not silently no-op (ADR-003).

## Decision

**`import_utxo` is a recovery-only path, scoped to the wallet's own root key.** It fetches the named transaction from the network provider, and verifies the targeted output is P2PKH to the wallet's root key — `locking_script.p2pkh? && locking_script.chunks[2].data == root_hash`, where `root_hash = @key_deriver.root_private_key.public_key.hash160`. An output that is not P2PKH to *our* root key is rejected (`InvalidParameterError`). It rescues funds at the root key; it is not a general "internalize an arbitrary UTXO" intake — that is what `internalize_action` is for, and that path arrives *with* derivation.

**An import is immediately followed by a self-pay to a BRC-42 derived address**, so the root UTXO does not remain the spendable form. `import_utxo` runs in two phases:

* **Phase 1** records the root-key UTXO atomically — `create_action(broadcast_intent: :none, outgoing: false)`, then `promote_action` writes one output with `output_type: 'root'` and (because `out[:output_type] == 'root'`) a matching `spendable` row. The root UTXO is briefly spendable.
* **Phase 2** issues a `create_action` that spends that imported output (`inputs: [{ output_id: imported_output_id }]`) with `outputs: [], change_count: 1`. The change-generation path picks a fresh BRC-42 self-key and writes a single derived output (NULL `output_type`, full derivation triple). The root UTXO is consumed as an input; only the derived output survives as spendable.

The net effect: the `'root'` shim exists for one transaction, then the funds sit in a normal derived output indistinguishable from any other wallet UTXO.

**An imported UTXO carries its own `tx_proof_id`.** Ordinary actions need no proof of their own — when the wallet assembles BEEF for a new transaction, the ancestry need only *terminate* at some proven ancestor, which may be many levels upstream. An import has no upstream in our database, so there is nothing to terminate at. `import_utxo` therefore obtains the merkle proof *before* creating any state (`fetch_proof_for_imported_utxo!`), and Phase 1 calls `save_proof` then `link_proof(action_id:, tx_proof_id:)` in the same transaction. Proof acquisition refuses at the boundary — an unconfirmed UTXO (no `blockheight`) or one whose merkle path the chain will not yield raises rather than registering an un-forwardable root.

**`internalize_action` yields a spendable output or fails loudly.** Its `outputs:` parameter is mandatory; the BEEF is fully SPV-verified before any state is written; a malformed bundle, a missing subject transaction, a `vout` that does not exist, or a declared-satoshis mismatch each raise (`InvalidBeefError` / `InvalidParameterError`). There is no path that accepts the call, writes nothing, and returns success.

## Alternatives Considered

### A. Leave the imported UTXO as a permanent `output_type = 'root'` spendable
Skip Phase 2; track the root UTXO as spendable indefinitely.
**Pros:** one phase, no self-payment, no fee.
**Cons:** makes `'root'` a standing spendable form, not a one-transaction shim; the rest of the wallet (and ADR-010) treats derived as the rule and `root` as the non-derived exception. Spending a root UTXO directly later still has to special-case the identity-key signing path on the hot send path.
**Rejected** — the shim should not persist; converting to derived once, at import, keeps the steady state uniform.

### B. Add a dedicated `received` / `imported` `output_type` value
Model imports as their own ENUM value rather than reusing `root`.
**Pros:** names the provenance explicitly.
**Cons:** the only non-derived spendable case *is* the root-key UTXO; ordinary receipts come through `internalize_action` *with* derivation and so are NULL-type. A new value adds a third constraint profile for no behaviour the existing two do not cover (ADR-010 rejected this same value for the same reason).
**Rejected** — `root` already denotes exactly this case.

### C. Treat `import_utxo` as a general UTXO intake
Accept any UTXO the caller names, not just one P2PKH to our root key.
**Pros:** more general; one entry point for "add a UTXO".
**Cons:** a UTXO that is not ours is unspendable by us and cannot be self-paid; arbitrary intake without derivation forces the wallet to guess ownership from shape — the inference defect ADR-010 bans. General receipt already has a home (`internalize_action`, which arrives with derivation).
**Rejected** — import is rescue of *our* root funds; the P2PKH-to-root check is the scope.

### D. Import without its own proof; rely on upstream anchoring
Treat an import like any other action and let BEEF anchoring find a proof upstream.
**Pros:** uniform with the ordinary spend path.
**Cons:** an import has no upstream in our database — there is no proven ancestor to terminate at, so a child BEEF can never be assembled. The imported root would be terminally un-forwardable.
**Rejected** — imports are precisely the case where the action must carry `tx_proof_id` itself.

### E. Let `internalize_action` silently no-op on an unusable bundle
Return success even when nothing spendable results.
**Pros:** lenient callers never see an error.
**Cons:** violates fail-loudly (ADR-003); a caller that internalises a payment and gets `{ accepted: true }` while no `spendable` row exists has been lied to, and the drift surfaces far from its cause.
**Rejected** — produce a spendable output or raise.

## Consequences

### Positive
* The "every spendable UTXO is BRC-42 derived" invariant holds in steady state; `'root'` lives for exactly one transaction per import.
* Imported funds are anchored by their own `tx_proof_id`, so BEEFs built atop them assemble and forward correctly.
* Recovery is a deliberate, scoped act (P2PKH-to-root-key only), not an open intake that could admit unspendable or mis-classified UTXOs.
* `sweep_to_root` (blank-slate, funds safe on-chain) has a clean inverse: `import_wallet` scans the root address and rescues each UTXO through this path.
* No silent failures: a malformed internalize or an unprovable import raises at the boundary.

### Negative
* The self-pay costs a network fee — the imported gross satoshis exceed the resulting spendable balance by that fee. The `import_utxo` return reports the on-chain (gross) value; the wallet balance reflects the net.
* Recovery is two transactions and a network round-trip for the proof, not a single insert.
* Phase 2 must broadcast (or be queued to) for the derived output to exist on-chain; a `no_send` import builds a derived output whose downstream spends will fail consensus until published. The rule is binary — every action in the run broadcasts, or none does.

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

The decision is the minimal way to admit a non-conforming input without weakening the invariant the rest of the wallet relies on: rescue the root UTXO, then immediately convert it to the standard derived form, so the exception does not propagate. Scoping `import_utxo` to P2PKH-to-our-root-key (rather than general intake) is the right narrowing — it keeps the operation honest about what it is for and sidesteps the ownership-inference trap ADR-010 already rejected. Requiring the import to carry its own proof is not gold-plating but a hard consequence of having no upstream ancestry. The fail-loudly stance on `internalize_action` is ADR-003 applied directly. The residual cost — an extra transaction and a fee per import — is inherent to converting root to derived and is bounded to a rare bootstrap/recovery path, not the hot path. **Approve.**

## Validation

* `import_utxo` verifies the output is P2PKH to `root_private_key.public_key.hash160` and rejects otherwise.
* Phase 1 writes one `output_type = 'root'` output with a `spendable` row; Phase 2 spends it and writes a single BRC-42 derived (NULL-type) output via `change_count: 1`.
* Phase 1 obtains the merkle proof first and links it (`save_proof` + `link_proof`) in the same transaction; an unconfirmed or unprovable UTXO raises.
* `internalize_action` requires `outputs:`, SPV-verifies the BEEF, and raises on a malformed bundle / missing subject tx / bad vout / satoshis mismatch — no silent no-op.
* `output_type = 'root'` carries no derivation fields and is permitted a `spendable` row; the six typed-vs-derived CHECK pairs and the `prevent_outbound_spendable` trigger hold (ADR-010).

## References

* ADR-010 — derivation on outputs; `output_type 'root'` as the non-derived special case (transitional shim), and the inference ban (import targets `root`, then self-pays to a derived output rather than guessing ownership from shape).
* ADR-003 — schema as canonical state; fail-loudly (`internalize_action` raises rather than no-ops), atomic per-phase transitions.
* ADR-004 — `spendable` as set membership; the root UTXO's `spendable` row is removed when Phase 2 claims it as an input.
* ADR-011 — outputs are the immutable log; an imported output's `tx_proof_id` anchors the BEEFs built atop it, and the derivation survives spending.
* `gem/bsv-wallet/lib/bsv/wallet/engine.rb` — `import_utxo`, `fetch_proof_for_imported_utxo!`, `internalize_action`, `sweep_to_root`, `import_wallet`.
* `gem/bsv-wallet/lib/bsv/wallet/engine/action.rb` — `Action.internalize`, `resolve_internalize_output`.
* `gem/bsv-wallet/lib/bsv/wallet/store.rb` — `promote_action`, `save_proof`, `link_proof`.
* `gem/bsv-wallet/db/migrations/001_create_schema.rb` (`actions.tx_proof_id` FK), `003_schema_constraints.rb` (`output_type` ENUM, CHECK pairs, `prevent_outbound_spendable`).
* `reference/schema.md` — `output_type` profiles (`root` = "imported UTXOs, transitional shim"); `tx_proof_id` as settlement receipt.
* HLR / PR: #296 (strict import — proof obtained before state), #297 (closed the `import_utxo` cross-call atomicity gap).

## UNVERIFIED CLAIMS

none.
