# Intent and Outcomes

A load-bearing principle of the wallet, alongside [`principle-of-state.md`](principle-of-state.md), [`state-boundaries.md`](state-boundaries.md), and [`core-vs-conformance.md`](core-vs-conformance.md). Each frames a different axis of the same design; this one frames *how decisions enter the schema*. The principle is named here because we have been applying it instinctively in places (`broadcast_intent`, ADR-019) and missing it in others (the `output_type`/`typed_no_*` inference, ADR-010); HLR #467 is the first schema fix driven by it.

## Statement

> **Intent is stated explicitly by the decision-maker and persisted as a stable column on the grain at which it varies. Outcomes are persisted as rows on the immutable log as they happen. The wallet derives forward from intent and outcomes; it never reverse-engineers intent from the outcome shape after the fact.**

Two operations. One direction.

## Derive vs infer

The vocabulary matters because the operations look superficially alike and have opposite consequences:

| | direction | input | output | role |
|---|---|---|---|---|
| **Derive** | forward | stated intent + recorded outcomes | a fact about the present | the schema's job (ADR-003) |
| **Infer** | backward | the present shape of a row | a guess at what was intended | the anti-pattern |

Derivation is `is this output spendable?` answered by *does a `spendable` row exist for it?* — set membership over canonical state, computable in one query, never wrong because the rows are the truth.

Inference is `was this output meant to be ours?` answered by *does it have a `derivation_prefix`?* — reading a downstream field as an intent oracle. The reading is brittle (derivation columns serve provenance, not classification), it conflates separate concerns (a third-party output may carry our provenance under BRC-29), and it is not subject to a schema check — the schema cannot reject a wrong guess about something the code was supposed to *state*.

## Why a state machine forbids inference

A wallet operation is not one DB write. `create_action` writes `actions`, then `inputs`, then `outputs`; on success or failure it later writes `promotions`, `broadcasts`, `spendable`. These are atomic transitions through valid states (`principle-of-state.md`) — each commit moves the database from one valid configuration to another. Between transitions the row set is partial *by design*.

If `Engine#promote_action_outputs` infers "was this output meant to be spendable?" from the shape of an `outputs` row, the inference rule has to be true at *every* intermediate state where promotion might fire. The shape changes across phases — a missing `derivation_prefix` might mean "outbound payment" at one moment, "not yet populated" at another, "outbound with provenance stripped" at a third — and inference cannot tell those apart. Only the original decision-maker knows which it is, and that knowledge has to be persisted at the point the decision is made.

State the intent. The schema then guards every transition against rows that contradict it.

## The outcome-row-deletion catastrophe

There is a stronger reason than intermediate states. Outcomes get deleted.

`spendable` rows are deleted when an output is spent (ADR-004). That is correct — spendability is set membership, and spending removes the row. But it means *any* property inferred from "is there a `spendable` row?" disappears the moment the output is spent. The historical truth — *we meant to be able to spend this* — is gone.

If the intent has been stated on `outputs` (the immutable log, ADR-011), the truth survives the spend. The output row is still there; the intent column on it is still there; the audit query "what did we mean this output to be?" is still answerable a year later. If the intent was only inferred from `spendable`'s existence, the question has no answer once the row has been swept away.

Intent lives on the immutable log because that is the only place it can survive its outcome. `spendable` carries the *current* state; `outputs` carries the *original* decision.

## The living register of intent points

Two intent points are settled in the schema today; further sites will accrete here as they are surfaced and named:

| Intent | Grain | Column | Values | Settled by |
|---|---|---|---|---|
| `broadcast_intent` | per-action | `actions.broadcast_intent` | `delayed`, `inline`, `none` | #221, ADR-019 |
| `spendable_intent` | per-output | `outputs.spendable_intent` | `spendable`, `none` | HLR #467, this PR |

Both follow the same shape:

- **Stated by the decision-maker** at the point the row is first created. `broadcast_intent` is set by `Engine#create_action`; `spendable_intent` is set by every CLI command, every Engine internal method, every `TxBuilder` change-output construction.
- **Persisted as an ENUM column** on the table whose grain matches the intent's variability — per-action on `actions`, per-output on `outputs`.
- **Denormalised onto downstream tables** that need to enforce a cross-table consequence declaratively. `broadcasts.intent` denormalises `actions.broadcast_intent`; `spendable.spendable_intent` denormalises `outputs.spendable_intent`. The composite FK keeps the denormalised copy honest (it cannot disagree with its source). See [`hot-path-design.md`](hot-path-design.md) for the pattern.

Additions to the register follow the same shape. A new intent point lands as a column on the grain at which the intent varies, with the values enumerated and the decision-maker named. HLR #60 is the open audit register for further inference sites the wallet still relies on; each elimination promotes an inference to an explicit intent column and earns a row in the table above.

## The enum convention

Intent columns are ENUMs, never booleans, even when there are only two values.

The reason is symmetry and extensibility. `broadcast_intent` was always going to have more than two values (`delayed`, `inline`, `none`); `spendable_intent` has two today (`spendable`, `none`) but may grow a third (e.g. `held_for_reservation` under HLR #192). An ENUM keeps the schema's vocabulary uniform across intent points and accommodates a third value without a column rename. The cost over a boolean is one TYPE definition; the saving is one breaking schema change avoided.

A second reason: ENUM values are typed by the schema (`broadcast_intent` cannot hold `'pending'` even if a typo would produce one). A boolean cannot reject `nil` as semantically meaningless; an ENUM with `NOT NULL` forces every row to carry an explicit value.

## Intent-placement rule — pick the grain

Intent lives on the row whose grain matches the intent's variability:

- **Per-action intent** lives on `actions`. `broadcast_intent` describes the action as a whole — every output the action creates inherits the same broadcast lifecycle, so the intent does not vary per output.
- **Per-output intent** lives on `outputs`. `spendable_intent` describes one output — a `send_payment` action creates one outbound output (`'none'`) and a change output (`'spendable'`) in the same atomic transition, so the intent varies per output and the column has to sit there.

The wrong grain forces inference back in. If `spendable_intent` were on `actions`, the change-output decision-maker would have to look up the action's intent and combine it with the output's role to compute the per-output answer — exactly the kind of backward computation this principle forbids.

## Per-wallet CHECK literal

`spendable_intent` (HLR #467) needs the schema to reject a row where the intent contradicts the locking script's shape — a root P2PKH output with `spendable_intent = 'none'` is incoherent; a non-root output with no derivation controls and `spendable_intent = 'spendable'` has no recoverable spending key. The check requires the schema to know *this wallet's* root P2PKH script literal, because it is wallet-specific.

The mechanism: the per-wallet root P2PKH script is **embedded into the `spendable_recoverable` CHECK as a literal at migration time**, via `BSV::Wallet::Migration.identity_pubkey_hash` populated by `Store#migrate!` immediately before `Sequel::Migrator.run`. No function call on the hot path; the comparison is `locking_script = <literal bytes>`, constant-folded by Postgres.

`docs/reference/schema.md` carries the full mechanism (column definitions, constraint text, model-layer mirror). The principle here is "the schema can enforce wallet-specific structural rules when the literal is baked in at migration emission"; the operational detail of how the bake-in happens is the schema doc's responsibility.

## Threat-model note

The per-wallet literal is the wallet's root P2PKH locking script — `hash160(identity_pubkey)` wrapped in the standard P2PKH script bytes. The hash is the public address the wallet receives funds at; it is on chain in every funding transaction. A schema dump exposes nothing the chain does not already publish.

No protection against a DBA is implied or asserted. A DBA with INSERT/UPDATE on the wallet's tables can alter rows by definition; the schema constraints are integrity guards against application bugs and operator misconfiguration, not access controls. Threat-model: a buggy decision-maker writing an inconsistent row, or a restore that points the wallet at the wrong database; not an adversarial operator.

## WIF rotation

The CHECK literal is tied to the WIF for the wallet's lifetime. Rotating the WIF means rotating the identity key, which means rotating the root P2PKH hash, which means the literal in the existing schema no longer matches the new identity — every legitimate root insertion would be rejected.

The wallet does not support WIF rotation in place; rotating the WIF means a new wallet (a fresh database, a fresh migration with the new literal baked in). `Store#verify_schema!` reads the CHECK definition at boot and asserts the literal matches the current `identity_pubkey_hash`, raising `SchemaIntegrityError` on mismatch — this catches both schema-drift and restore-to-wrong-DB cases.

## BRC-100 alignment

The principle aligns with BRC-100 but is not spec-mandated. The spec assumes self-owned outputs in `createAction` (no per-output spendability flag in the canonical method signature); we make the spec's implicit assumption explicit at the schema layer. BRC-100 callers continue to drive `createAction` as before; the conformance wrapper translates the spec's implicit "outputs are mine" assumption into `spendable_intent: 'spendable'` for each output, and allows an explicit override where the BRC-100 input carries one (see `brc100.rb`).

A future BRC-100 revision adding a per-output spendability flag would map onto our intent column without schema change. The schema is one ENUM ahead of the spec for the same reason `broadcasts.intent` is — the wallet records the decision-maker's intent regardless of which interface drove the call.

## Related

- [`principle-of-state.md`](principle-of-state.md) — *what* the wallet maintains (the schema is canon). Intent-and-outcomes is its corollary on the decision axis.
- [`state-boundaries.md`](state-boundaries.md) — *where* statefulness lives (SDK vs wallet). Intent decisions are wallet concerns by construction.
- [`core-vs-conformance.md`](core-vs-conformance.md) — *what* concerns belong to the wallet. Stated intent flows from any decision-maker (CLI, BRC-100 wrapper, Engine method) into the schema uniformly.
- [`hot-path-design.md`](hot-path-design.md) — the declarative-beats-trigger mechanism for enforcing intent across tables.
- [`schema.md`](schema.md) — the per-wallet CHECK literal, the model-layer mirror, the table-by-table reference.
- ADR-003 — schema as canonical state; this principle is its corollary on the decision axis.
- ADR-010 — derivation placement and the inference ban; banned inference in code while encoding it structurally via `typed_no_*` (the blindspot HLR #467 closes).
- ADR-019 — `broadcast_intent` as the declarative cross-table invariant (the worked example this principle generalises from).
- ADR-031 — the decision record naming this principle.
- HLR #60 — the living audit register for remaining inference sites.
- HLR #467 — the first principle-driven schema fix (drops `output_type`, states `spendable_intent` explicitly).
