# ADR-010: Derivation data on outputs; the inference ban

## Status

Accepted.

**Decided:** 2026-05-06 (PR #65/#66 — restored derivation data to `outputs`, stripped `spendable` to pure membership; `692d08a`, merged `30ab3ac` (#67). The inference ban is articulated as HLR #60, "wallet decides, constraints enforce".)

## Context

A transaction the wallet builds produces outputs of different kinds. Some are wallet-derived — we hold the BRC-42 derivation that lets us spend them; some are outbound payments to other parties, never spendable by us. Two questions follow from this mixture: where does an output's derivation/identity data live, and how does the wallet know which outputs are its own?

Derivation data is `derivation_prefix`, `derivation_suffix`, `sender_identity_key` — the information needed to re-derive a spending key. It is a fact fixed at the moment the key is derived, not a fact about whether the output is currently spendable.

This ADR settles the *placement* of that data and bans a tempting shortcut: letting application code *guess* an output's ownership or type from the shape of its fields. (The `output_type` ENUM itself — its values, and the `root` special case — is a separate, earlier decision, recorded in ADR-014.)

## Decision Drivers

* Derivation is a fact about the *output*, set once at key-derivation time — not a fact about spendability.
* `spendable` must stay keys-only so the hot path is tiny (ADR-004).
* The wallet must be able to tell its own outputs from payments to others — explicitly, not by guessing (ADR-003: the code states intent; the schema derives).

## Decision

### (a) Derivation data lives on `outputs`, never on `spendable`

Derivation data (`derivation_prefix`, `derivation_suffix`, `sender_identity_key`) is carried on the immutable `outputs` row, alongside `satoshis`, `vout`, and `locking_script` (ADR-004(a)). It is **not** hung on the `spendable` row. Because `outputs` is the immutable log (ADR-011), the derivation survives spending — useful for audit, debugging, and recovery — and `spendable` stays pure set membership with no data columns of its own (ADR-004(c)).

`output_type` is the column that makes "why is derivation absent?" a *checkable* property rather than a guess. A derived output (NULL `output_type`) must carry all three derivation fields; a typed output (`root`, `outbound`) carries none. Six cross-column CHECK constraints enforce the mutual exclusivity in the schema, so the inconsistent combinations are structurally rejected. The `output_type` ENUM values and the typed/derived distinction are defined in ADR-014; here they bear only on *where derivation lives* and *that its presence is constraint-checked, not inferred*.

* `outputs` carries `derivation_prefix` / `derivation_suffix` / `sender_identity_key` — `gem/bsv-wallet/db/migrations/001_create_schema.rb:150-152`.
* `spendable` has no data columns — `gem/bsv-wallet/db/migrations/001_create_schema.rb:158-162`.
* The six typed-vs-derived CHECK pairs — `gem/bsv-wallet/db/migrations/003_schema_constraints.rb:93-98`.

### (b) The wallet states intent; code never infers it

Ownership and type are *declared* by the decision-maker that creates the output, and *enforced* by the schema. Application code must not reverse-engineer "is this ours?" from the shape of the data — does it have a derivation prefix? a basket? Deriving state from structure is the database's job (ADR-003), working from data the code put there deliberately; it is not the code's job to guess intent after the fact from field presence.

This is the anti-pattern HLR #60 ("wallet decides, constraints enforce") targets. Two inference sites are named there: `promote_with_outputs` ("no `output_type` + no `derivation_prefix` + has basket → must be change") and `resolve_internalize_output` ("basket insertion without `derivation_prefix` → must be root"). The decision is that `output_type` is set *explicitly at the decision point* (`create_action`, `internalize_action`, `sign_action`); downstream code receives it as a given, and the constraints verify the required fields are present — they are a safety net, never the inference engine.

* HLR #60 names `promote_with_outputs` and `resolve_internalize_output` as the inference sites to eliminate.
* `promote_with_outputs` — `gem/bsv-wallet/lib/bsv/wallet/engine/action.rb:536`.
* `resolve_internalize_output` — `gem/bsv-wallet/lib/bsv/wallet/engine/action.rb:1175`; its `:basket_insertion` branch sets `output_type = 'root'` from a stated *protocol-level* convention (`gem/bsv-wallet/lib/bsv/wallet/engine/action.rb:1192-1194`), not from inference — a residual the audit must confirm.

## Alternatives Considered

### A. Put derivation data on `spendable`

This was built (PR #59) and then reverted (PR #65/#66). It looked tidy — an outbound output simply gets no `spendable` row, so "no derivation" never needs representing. **Rejected**, for two reasons that only surfaced in use: derivation is a fact about the output fixed at derivation time, and hanging it on the mutable, deletable `spendable` row conflates the log with the wallet; and it forced ownership *inference into the code* (`wallet_owned = derivation_prefix || output_type || basket`), which mis-classified a third-party payment as the wallet's own. Derivation belongs on the immutable output; ownership is stated, not inferred.

### B. Infer output type / ownership from data shape

**Rejected** — the same defect as A in general form. "Deriving state has leaked into the code." The code states intent explicitly; the schema derives. This is the rule HLR #60 exists to enforce.

## Consequences

### Positive

* Derivation survives spending on the immutable log — provenance for audit, debugging, recovery.
* `spendable` stays tiny (hot path) — keys-only (ADR-004).
* Ownership and type are explicit and constraint-enforced; the schema rejects the inconsistent combinations the inference approach allowed.

### Negative

* The decision-maker must set `output_type` correctly at the point of decision; the schema enforces the consequences but the intent has to be supplied.
* Removing inference is ongoing work, not a finished state — HLR #60 is open, and residual conveniences (the basket-insertion `root` default in `resolve_internalize_output`) still need confirming against the "stated, not inferred" rule.

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

The rejected alternative is not hypothetical — derivation-on-`spendable` was implemented, shipped, and reverted, and the failure (inference leaking into the code, mis-classifying a payment) is the strongest possible evidence for the chosen design. Stating intent and letting the schema enforce it is simpler and safer than guessing from shape, and it keeps `spendable` keys-only so ADR-004's hot-path purity holds. The inference ban is the same principle viewed from the application side: the code that *makes* the decision records it; nothing downstream re-derives it. **Approve.**

## Validation

* `derivation_prefix` / `derivation_suffix` / `sender_identity_key` are columns on `outputs`; `spendable` has no data columns.
* The six typed-vs-derived CHECK constraints hold (`003_schema_constraints.rb:93-98`).
* No code path infers ownership or type from data shape — the `wallet_owned` reads in `Store` consult `output_type`/`derivation_prefix` as *stated* facts, not as inference of intent (HLR #60 tracks elimination of the remaining inference sites).

## References

* ADR-003 — derived state; the database derives, the code states intent.
* ADR-004 — `spendable` keys-only; derivation data on `outputs` (this keeps it that way).
* ADR-011 — immutability, which is what lets derivation survive spending.
* ADR-014 — the `output_type` ENUM and the `root` value (defined there); import as the `root` case, self-pay to a derived output rather than guessing ownership from shape.
* HLR #60 — "wallet decides, constraints enforce" — the open requirement to eliminate the inference sites.
* `gem/bsv-wallet/db/migrations/001_create_schema.rb` — `outputs` derivation columns, keys-only `spendable`.
* `gem/bsv-wallet/db/migrations/003_schema_constraints.rb` — the typed-vs-derived CHECK pairs.
* `docs/reference/schema.md`.

## Unverified claims

None.
