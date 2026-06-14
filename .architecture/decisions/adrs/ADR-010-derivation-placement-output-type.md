# ADR-010: Derivation data on outputs; output_type and the inference ban

## Status

Accepted.

## Context

A transaction the wallet builds produces outputs of different kinds. Some are wallet-derived (we hold the derivation that lets us spend them); some are outbound payments to other parties (no derivation, never spendable by us); a special case is a UTXO imported directly to the wallet's root key. Two questions follow: where does an output's derivation/identity data live, and how does the wallet know which outputs are its own?

Derivation data is `derivation_prefix`, `derivation_suffix`, `sender_identity_key` — the information needed to re-derive a spending key. It is fixed at the moment the key is derived.

## Decision Drivers

* Derivation is a fact about the *output*, set once at key-derivation time — not a fact about spendability.
* `spendable` must stay keys-only so the hot path is tiny (ADR-004).
* The wallet must be able to tell its own outputs from payments to others — explicitly, not by guessing.

## Decision

**Derivation data lives on `outputs`** — the immutable row — never on `spendable`. Because the row is immutable (ADR-011), the derivation survives spending (useful for audit and recovery); and `spendable` stays pure set membership.

**`output_type` makes "why is derivation absent?" a checkable property.** An ENUM (`root`, `outbound`; `NULL` = wallet-derived) gates cross-column CHECK pairs: a *typed* output carries no derivation (`typed_no_prefix/suffix/sender`), a *derived* (NULL-type) output must carry all three (`derived_needs_prefix/suffix/sender`). A `prevent_outbound_spendable` trigger makes it structurally impossible for an `outbound` output to hold a `spendable` row.

**The wallet states intent; code never infers it.** Ownership and type are declared by the caller (`output_type`), enforced by the schema. Application code must not infer "is this ours?" from the shape of the data (does it have a derivation prefix? a basket?). Deriving state belongs to the database, from data the code put there deliberately — not to the code, guessing from shape.

## Alternatives Considered

### A. Put derivation data on `spendable`
This was built (PR #59) and then reverted (PR #65/#66). It looked tidy — an outbound output simply gets no `spendable` row, so "no derivation" never needs representing. **Rejected**, for two reasons that only surfaced in use: derivation is a fact about the output fixed at derivation time, and hanging it on the mutable, deletable UTXO row conflates the log with the wallet; and it forced ownership *inference into the code* (`wallet_owned = derivation_prefix || output_type || basket`), which mis-classified a third-party payment as the wallet's own. Derivation belongs on the immutable output; ownership is stated, not inferred.

### B. Infer output type / ownership from data shape
**Rejected** — the same defect as A in general form. "Deriving state has leaked into the code." The code states intent explicitly; the schema derives.

### C. A dedicated `received` output_type value
**Rejected.** The only non-derived spendable case is a UTXO imported to the root key (`root`, ADR-014); ordinary receipts come through `internalize_action` *with* derivation, so they are derived (NULL-type). No extra value is needed.

## Consequences

### Positive
* Derivation survives spending on the immutable log — provenance for audit, debugging, recovery.
* `spendable` stays tiny (hot path) — keys-only.
* Ownership and type are explicit and constraint-enforced; the schema rejects the inconsistent combinations the inference approach allowed.

### Negative
* The caller must state `output_type` correctly; the schema enforces the consequences but the intent has to be supplied.

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

The rejected alternative is not hypothetical — derivation-on-`spendable` was implemented, shipped, and reverted, and the failure (inference leaking into the code, mis-classifying a payment) is the strongest possible evidence for the chosen design. Stating intent and letting the schema enforce it is simpler and safer than guessing from shape. **Approve.**

## Validation

* `derivation_prefix` / `derivation_suffix` / `sender_identity_key` are columns on `outputs`; `spendable` has no data columns.
* The six typed-vs-derived CHECK constraints and the `prevent_outbound_spendable` trigger hold.
* No code path infers ownership or type from data shape.

## References

* ADR-004 — `spendable` keys-only (this keeps it that way).
* ADR-003 — derived state; the database derives, the code states intent.
* ADR-011 — immutability, which is what lets derivation survive spending.
* ADR-014 — import as rescue (the `root` case; self-pay to a derived address).
* `reference/schema.md`.
