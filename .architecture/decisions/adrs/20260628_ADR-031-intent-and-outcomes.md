# ADR-031: Intent stated explicitly; outcomes persisted as rows; never reverse-engineer intent

## Status

Accepted.

**Decided:** 2026-06-28 — articulated as a principle after two examples surfaced it from opposite sides. `broadcast_intent` (ADR-019, 2026-05-27) settled it correctly for the per-action grain via the declarative pattern. `output_type` + the `typed_no_*` constraints (ADR-010, 2026-05-06) encoded the same inference structurally in the schema while banning it in code — a blindspot HLR #467 surfaced via the `send_beef_spec.rb` regression in PR #466.

## Context

The wallet has two operations that look superficially alike and have opposite consequences:

- **Derive** — read forward from canonical facts (stated intent + recorded outcomes) to compute the current truth. The schema's job (ADR-003).
- **Infer** — read backward from the present shape of a row to guess what was intended. The anti-pattern.

We have been applying "state intent explicitly, derive consequences from canonical state" correctly in places and incorrectly in others. Two examples make the gap visible:

**`broadcast_intent` (settled correctly).** Every action carries a `broadcast_intent` ENUM (`delayed`, `inline`, `none`) set by the decision-maker at creation time. The send-path / internal-path distinction is *stated*, not guessed from the action's downstream artefacts (presence of a `broadcasts` row, absence of a `tx_proof_id`). ADR-019 encodes the cross-table consequence declaratively via a composite FK + CHECK; the schema rejects a `broadcasts` row for a `'none'` action without any procedural code. This is the pattern.

**`output_type` + `typed_no_*` (settled incorrectly).** ADR-010 banned the inference pattern in code (`HLR #60`, "wallet decides, constraints enforce"). It also added an `output_type` ENUM (`root`, `outbound`, NULL=derived) and six `typed_no_*` / `derived_needs_*` constraints structurally encoding the rule that `output_type = 'outbound'` ⇒ no derivation columns, and so on. In doing so the schema baked the inference into its structure — the *value* of `output_type` was meant to be stated, but the *combination of `output_type` + derivation column presence* served as an oracle for "is this output ours?". Downstream code (`Engine::Action.canonical_outputs`, `Store#do_create_action_outputs`, `Store#promote_action_outputs`, `Engine::BeefImporter#resolve_internalize_output`, `BRC100#validate_output_ownership!`) read the combination shape as an ownership signal instead of consulting an explicitly-stated intent. The regression PR #466 (`send_beef_spec.rb`) surfaced the consequence: a BRC-29 outbound payment was mis-classified as self-spendable because the shape rule (no `output_type`, no `derivation_prefix` ⇒ "must be change") fired on a row whose intent was outbound.

The blindspot is what ADR-010 names but does not eliminate: HLR #60 lists `promote_with_outputs` and `resolve_internalize_output` as inference sites to remove, but the *schema-level* inference encoding (`output_type` + the six constraints) is what was supplying the inferred fact those sites consumed. Banning inference in code while leaving the schema as the inference engine produces exactly the drift PR #466 caught.

The principle was implicit in `broadcast_intent` from the start and absent from `output_type`. This ADR names it so subsequent decisions defer to it explicitly, and HLR #467 lands the first principle-driven schema fix.

## Decision Drivers

* **The schema enforces, always (ADR-003).** Any invariant the wallet relies on has to have a schema backstop. When that backstop is itself an inference oracle (rather than enforcement of stated intent), the schema becomes part of the problem, not part of the solution.
* **Outcome rows get deleted (`spendable`, ADR-004).** An intent inferred from a downstream artefact disappears the moment the artefact is removed. Intent stated on the immutable log (`outputs`) survives its outcome and remains queryable for audit and recovery.
* **State machines forbid inference (ADR-019 echo).** A wallet operation is a sequence of atomic transitions through valid states. Inference rules have to be true at every intermediate state where they might fire; the row shape changes across phases and inference cannot tell those phases apart.
* **Convergence with the other load-bearing principles.** Principle-of-state (ADR-003) defines *what* is canonical; state-boundaries (ADR-018) defines *where* statefulness lives; core-vs-conformance (ADR-027) defines *what* concerns belong to the wallet; this principle defines *how decisions enter the schema*. The four together form the architectural skeleton.
* **Past decisions need a common explanation.** ADR-019 settled `broadcast_intent` correctly; ADR-010 settled `output_type` incorrectly. Both decisions read as locally coherent. The unnamed principle is what would have caused ADR-010 to read as wrong at the time. Naming it now turns the next decision in the same shape into a filter application, not first-principles work.

## Decision

**Intent is stated explicitly by the decision-maker and persisted as a stable ENUM column on the grain at which it varies. Outcomes are persisted as rows on the immutable log as they happen. The wallet derives forward from intent and outcomes; it never reverse-engineers intent from the outcome shape after the fact.**

For every new schema concern, the filter is:

1. **Does this concern require knowing what the decision-maker intended?** If yes, the intent must be an explicit column on the row whose grain matches the intent's variability — per-action on `actions`, per-output on `outputs`.
2. **Is this concern about the current state, the outcome?** If yes, derive it from canonical state at read time. There is no "status" column; the row set itself is the status.
3. **Does the rule cross tables?** If yes, denormalise the parent's intent column onto the child and constrain declaratively (composite FK + CHECK; see `hot-path-design.md`). No triggers on the hot path.

The principle's statement, manifestations, register of settled intent points, and the per-wallet CHECK literal mechanism are at [`docs/reference/intent-and-outcomes.md`](../../../docs/reference/intent-and-outcomes.md). The hot-path implementation rule is at [`docs/reference/hot-path-design.md`](../../../docs/reference/hot-path-design.md).

**Concrete consequences enforced by this ADR:**

1. **Every intent point lands as an ENUM column on the right grain.** The settled register: `actions.broadcast_intent` (per-action), `outputs.spendable_intent` (per-output, HLR #467). Additions follow the same shape.
2. **ENUM, not boolean, even for two values.** Symmetry and extensibility. A two-value boolean cannot grow a third value without a schema change.
3. **Cross-table consequences are denormalised + constrained declaratively, not enforced by triggers on the hot path.** This generalises ADR-019's mechanism beyond `broadcast_intent`.
4. **Schema constraints enforce stated intent; they do not supply inferred intent.** The `typed_no_*` constraints (ADR-010) blurred this — replaced under HLR #467 by `spendable_recoverable` + `controls_all_or_nothing`, both of which check stated intent against the row's structural shape rather than producing intent from absence of fields.
5. **HLR #60 remains the living audit register for further inference sites.** Each elimination promotes an inferred fact to an explicit intent column and earns a row in the `intent-and-outcomes.md` register.

## Alternatives Considered

### A. Continue inferring intent from row shape where it is "obvious"

Allow the application to read "no `derivation_prefix` ⇒ outbound" and similar shape-reads where the inference seems unambiguous at the call site.

**Rejected.** ADR-010 already rejected this for code; the gap was extending the rejection to the schema. PR #466 demonstrated the failure mode — an inference rule that looked unambiguous mis-classified a BRC-29 outbound payment because the row shape was structurally identical to a no-derivation self-payment. "Obvious" is the wrong test; "stated by the decision-maker who knew" is the right test.

### B. State intent only in application-layer Ruby models, not in the schema

Keep intent as an attribute on the Engine's output spec, validated by `validate` in the Sequel model, but no schema column.

**Rejected.** This breaks ADR-003 — an invariant held only by application code has no database backstop, and a new write path that forgets the validation persists contradictory state. The principle requires the schema to be the gate; application validation is the friendlier-error mirror, not the canon.

### C. Add a generic `kind` or `status` column on every table and use it for all intent points

A single uniform column name (e.g. `outputs.kind`, `actions.status`) for every decision a row records.

**Rejected.** Different intent points have different value spaces and different decision-makers; conflating them under one column name loses the per-intent type discipline that ENUM types provide. The register approach (`broadcast_intent`, `spendable_intent`, future names) keeps each intent's vocabulary scoped to its concern.

### D. Defer naming the principle until a third intent point lands

Wait for one more example before generalising.

**Rejected as the cost of deferral has already been observed.** ADR-010's blindspot existed for two months between settlement and discovery; a stated principle at that time would have caught the schema's `typed_no_*` encoding as wrong on inspection. Naming the principle now is cheap (the two examples are sufficient to settle the shape) and prevents the next blindspot. The decision is "name what we've learned", not "decide what to do".

## Consequences

### Positive

* **The next intent-shaped schema decision becomes a filter application.** "Where does this concern's intent live?" → ENUM column on the grain at which intent varies; cross-table consequence denormalised + declaratively constrained. No re-derivation from first principles.
* **HLR #60's audit register has a forward-direction target.** Inference sites land as explicit intent columns; the register's table is the running record of which sites have been promoted.
* **Schema-as-inference-oracle becomes a reviewable error.** A future schema change adding a column whose presence/absence serves as an ownership oracle is visible as an instance of the same anti-pattern; ADR-031 is the citation a review can use.
* **Intent survives outcome deletion.** Stating intent on the immutable log (`outputs`) means a year-old audit query "what did we mean this output to be?" is still answerable after the output was spent and its `spendable` row deleted.

### Negative

* **One extra column per intent point.** `actions.broadcast_intent`, `outputs.spendable_intent`, and any future intent points each cost an ENUM column and a constraint. The cost is small and bounded; the alternative (re-derived inference, with the failure modes above) is worse.
* **The decision-maker has to know its intent at the point of writing.** Every CLI command, every Engine method, every `TxBuilder` change-output construction now states `spendable_intent:` explicitly. This is more verbose than letting the schema infer; the verbosity is the principle's correct shape — the decision was made at one of those sites, and the writing-down has to happen there.
* **Per-wallet CHECK literal mechanism adds a migration-time hook.** `spendable_intent`'s `spendable_recoverable` constraint embeds the wallet's root P2PKH script as a literal at migration time (via `Migration.identity_pubkey_hash`). The mechanism is new and carries operational considerations (schema dumps differ across wallets, WIF rotation requires a fresh wallet). Documented in `intent-and-outcomes.md` and `schema.md`.

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

This ADR names a principle that has produced one correct decision (`broadcast_intent`, ADR-019) and exposed one incorrect one (`output_type` + `typed_no_*`, ADR-010, schema-side encoding of inference). The principle is not speculative — it is recovered from the gap between two existing decisions that should have followed the same rule. Naming it now costs the ADR write-up and the two doc pages (`intent-and-outcomes.md`, `hot-path-design.md`); the forward saving is that the next intent-shaped concern lands as a filter application rather than a re-derivation. No new abstraction is built; the schema gets one intent column (HLR #467); the code surface that has to state intent already exists — the change is moving from "infer at the consumer" to "state at the producer". **Approve. This is naming what we've been doing wrong, not adding speculation.**

## Validation

* `actions.broadcast_intent` is an ENUM column set explicitly at action creation; the send-path / internal-path distinction is never inferred from downstream artefacts.
* `outputs.spendable_intent` (HLR #467) is an ENUM column set explicitly at output creation by every decision-maker; the schema's `spendable_recoverable` + `controls_all_or_nothing` constraints enforce stated intent against the row's structural shape rather than producing intent from field absence.
* No code path reads "absence of `derivation_prefix`" as an ownership signal after HLR #467 lands. (Five inference sites removed: `engine/action.rb:124`, `store.rb:198`, `store.rb:224`, `beef_importer.rb:329`, `brc100.rb#validate_output_ownership!`.)
* The living register at [`docs/reference/intent-and-outcomes.md`](../../../docs/reference/intent-and-outcomes.md) classifies every intent point in the schema. HLR #60 tracks remaining inference sites to be promoted.

## References

* [`docs/reference/intent-and-outcomes.md`](../../../docs/reference/intent-and-outcomes.md) — the principle's statement, register, and per-wallet CHECK literal mechanism.
* [`docs/reference/hot-path-design.md`](../../../docs/reference/hot-path-design.md) — the declarative-beats-trigger rule for cross-table consequences.
* [`docs/reference/principle-of-state.md`](../../../docs/reference/principle-of-state.md) — the parent principle (schema is canon); this ADR is its corollary on the decision axis.
* [`docs/reference/state-boundaries.md`](../../../docs/reference/state-boundaries.md) — companion structural axis (where statefulness lives).
* [`docs/reference/core-vs-conformance.md`](../../../docs/reference/core-vs-conformance.md) — companion principle (what concerns belong to the wallet).
* ADR-003 — schema as canonical state.
* ADR-010 — derivation placement and the inference ban; banned inference in code while encoding it structurally; HLR #467 closes the blindspot.
* ADR-019 — `broadcast_intent` as the declarative cross-table invariant (the worked example this principle generalises from).
* HLR #60 — "wallet decides, constraints enforce" — the living audit register for further inference sites.
* HLR #467 — the first principle-driven schema fix; drops `output_type` and the six `typed_no_*` constraints, states `spendable_intent` explicitly, encodes the wallet-specific structural rule via `spendable_recoverable` + `controls_all_or_nothing`.
* PR #466 — surfaced the spendable-controls inference defect via `send_beef_spec.rb` (BRC-29 outbound mis-classified as self-spendable).

## Unverified claims

None.
