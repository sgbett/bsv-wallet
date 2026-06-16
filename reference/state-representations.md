# State Representations — conformance catalogue

A living register of **every place the schema represents state**, classified against the wallet's load-bearing principle that *state is read, not stored* (see [`principle-of-state.md`](principle-of-state.md), and the decisions [ADR-003 schema-as-canonical-state](../.architecture/decisions/adrs/20260505_ADR-003-schema-as-canonical-state.md) and [ADR-022 state-as-a-fk-row](../.architecture/decisions/adrs/20260610_ADR-022-state-as-a-fk-row.md)).

This document is **not** the principle (that is `principle-of-state.md`) nor a decision (those are the ADRs). It is the **conformance register**: the per-element inventory those documents' "tests for compliance" operate against. It is *living* — it changes whenever the schema changes — and answers one standing question: **are we actually compliant, and where are the conscious exceptions?**

Verified against migrations `001`–`012` and `lib/` on 2026-06-13 (post `012_promotions.rb` / #307).

## The taxonomy

The distinction that matters is not *current-state vs history* but **deltas vs facts**. History only makes current state expensive when you store *transitions* (an events table you must fold to learn the present). When you store *facts whose existence is the state*, the present is a membership test (`EXISTS` / anti-join), history is the immutable facts plus their timestamps, and the two are the same data viewed two ways. Every representation below is graded on that basis.

| Class | Definition | Stored how | Drift risk |
|---|---|---|---|
| **A. Structural fact** | State = existence of a row / relationship. Read = membership test. | a row | none |
| **B. Temporal fact** | State + *when* = presence of a timestamp on an otherwise-immutable row. | nullable timestamp | none |
| **C. Immutable intent** | A choice fixed at birth that never transitions; not derivable (a cause, not a consequence). | set-once column | none |
| **D. External-mirror scalar** | A genuinely mutable value tracking an external system; current value matters, history low-value. | mutable column | acceptable (truth = the external system) |
| **E. Value attribute** | Data about the row, not lifecycle state. | column | n/a |
| **F. Driftable flag** | A stored value duplicating what structure already implies. The anti-pattern. | mutable column | high |

The goal is zero class-F. A/B/C are the compliant forms; D/E are legitimate when consciously justified.

## Inventory

### A — Structural facts (compliant; the exemplars)
- **`spendable`** — a row ⟺ the output is in the UTXO set. Double-gated: FK `output_id → outputs`, and (post-#012) FK `action_id → promotions` `ON DELETE CASCADE`, so UTXO membership cannot exist without promotion authorisation. [ADR-004, ADR-022]
- **`inputs`** — a row ⟺ the output is spent/locked. The `NOT EXISTS` anti-join is the canonical "spent?" query; `UNIQUE(output_id)` is single-spend enforcement.
- **`promotions`** (#012) — a row ⟺ the action's outputs are canonical. **Replaced** the `outputs.promoted` flag — the worked example of converting a class-F flag to a class-A fact. Gated declaratively: composite FK `(action_id, intent) → actions(id, broadcast_intent)` (intent disjunction), conditional composite FK `(action_id, authorising_status) → broadcasts(action_id, tx_status)` (send-path status gate, NULL skips it via MATCH SIMPLE for the internal path), plus `promo_path` and `auth_not_rejected` CHECKs. [ADR-023, supersedes ADR-011 post-broadcast-promotion]
- **`actions.tx_proof_id`** (FK presence) — NULL = unproven, set = completed. Status from a join, not a column — and it is presence *plus* the joined proof data (`merkle_path`, `block_id`) that determines settlement.
- **`output_baskets` / `output_tags` / `action_labels`** — membership = row existence; absence of an `output_baskets` row = the default basket.

### B — Temporal facts (compliant; presence-of-timestamp = state + when)
- **`deleted_at`** on `baskets`, `labels`, `tags`, `action_labels`, `output_tags`, `certificates` — soft-delete as a timestamp; "active" derived via the partial unique index `WHERE deleted_at IS NULL`. A deliberate hybrid: keeps the definition and its history while keeping "active" a cheap query. The sophisticated form of "the appearance of a row/timestamp tells you when it became that state."
- **`actions.wtxid`** (presence) — NULL = unsigned, set = signed; load-bearing in `derived_status`.
- **`broadcast_at`**, the ubiquitous **`created_at`** — event timestamps on immutable facts.

### C — Immutable intent (compliant; never transitions)
- **`actions.broadcast_intent`** (`delayed|inline|none`) — set at creation, held immutable-while-broadcasting by the `ON UPDATE RESTRICT` composite FK from `broadcasts`. The canonical legitimate enum. [ADR-019]
- **`broadcasts.intent`** and **`promotions.intent`** — *denormalised* copies of the action's intent, kept in lockstep by composite FK to `actions(id, broadcast_intent)`. Not independent state — declarative-integrity devices that let the dependent CHECKs branch (`intent != 'none'` on broadcasts; `promo_path` on promotions). [ADR-019, ADR-023]

### D — External-mirror scalars (mutable, but correctly so — name them so they are not misread as oversights)
- **`broadcasts.tx_status`** (ARC enum) — mirrors ARC's lifecycle (`UNKNOWN…MINED…IMMUTABLE`). Current value is what matters; structuralising it would be event-sourcing for little gain. **Now pulls double duty**: it is also the FK target for `promotions.authorising_status` (`ON UPDATE CASCADE` keeps a promotion synced as status advances), so the ARC vocabulary is load-bearing for a referential constraint, not merely a column — additions to the enum (`SEEN_MULTIPLE_NODES`, `IMMUTABLE`) now touch a constraint.
- **`broadcasts.retry_count`** — a counter; intrinsically scalar mutable state.
- **`sse_cursors.last_event_id`** — external stream position (ARC SSE); a cursor is current-value-only by nature.

### E — Value attributes (data, not lifecycle state)
`actions`: `raw_tx`, `input_beef`, `reference`. `outputs`: `satoshis`, `vout`, `locking_script`, `output_type`*, `derivation_prefix/suffix`, `sender_identity_key`. `output_details`: `type`, `purpose`, `provided_by`, `description`, `custom_instructions`, `script_length/offset`. Plus `blocks.*`, `tx_proofs.merkle_path/raw_tx/block_index`, `certificates.*`, `certificate_fields.*`, `broadcasts.block_hash/height/merkle_path/provider/callback_token`, `settings.value`.
<br>*`output_type` is an immutable classification attribute, not lifecycle state.

### F — Driftable flags (the anti-pattern — target is empty)
- **`outputs.promoted` — RESOLVED.** Removed in #012; was a mutable boolean duplicating "is this canonical." Now class A (`promotions`). This is the catalogue's headline result.
- **`tx_reqs.status`** — the only literal `status` column the schema ever had; **removed entirely** in `004_drop_tx_reqs.rb`. Historical exemplar of the anti-pattern excised, not merely avoided.
- **`actions.satoshis` — RESOLVED.** A net-amount **stored aggregate** (Σ outputs − Σ inputs) on `actions`; **dropped** in `003_schema_constraints.rb` (the `add_column` in that migration's `down` block is the rollback, not the live state). A derivable denormalisation removed in favour of deriving the figure on demand — the [ADR-005](../.architecture/decisions/adrs/20260505_ADR-005-accounting-ledger-not-dag.md) instinct applied. (`outputs.satoshis` is unrelated and remains — a class-E value attribute.)
- **`actions.outgoing` — RESOLVED (#349).** A direction flag with **no load-bearing consumer**: its one runtime reader (`pending_proofs`) conjoined `outgoing: true` with `broadcast_intent != 'none'`, which already implies it (every `outgoing: false` action was created `broadcast_intent: 'none'`); the sibling reap query selects the same set on `broadcast_intent` alone. Its only echo, `action_to_hash`, fed an interface field no caller or spec consumed. Its only hard dependency was the `nlocktime_range` CHECK — a constraint on `actions.nlocktime`, itself never read by the builder (`lock_time` is threaded in-memory and baked into `raw_tx`) and recoverable from `raw_tx`. Column and constraint **dropped** in `013_drop_actions_outgoing.rb`; the interface field is now derived as `broadcast_intent != 'none'`.
- **`actions.nlocktime` / `actions.version` — RESOLVED (#351).** Stored projections of `raw_tx` — nLockTime is its trailing four bytes (LE), version its leading four. The builder reads neither (`lock_time`/`version` flow in-memory into `tx_builder.build`, baked into `raw_tx` at sign time); the sole reader, `action_to_hash`, now derives them from `raw_tx`. **Dropped** in `014_drop_actions_nlocktime_version.rb`. No constraint depended on them (the `nlocktime_range` guard went with `outgoing` in #349). Non-final transactions (#192) are unaffected — the nLockTime value stays in `raw_tx`; the non-final *intent* needs its own marker, not this value column.

No class-F representation remains in the live schema, and the open candidates are resolved.

## Open candidates (probes)
None outstanding. The two prior probes are resolved: `actions.outgoing` (#349) and `actions.nlocktime`/`version` (#351) were both dropped — see class F above. New candidates are added here as the audit (or future schema changes) surface them.

## Known documentation drift (finding)
[`principle-of-state.md`](principle-of-state.md) predates #012 and is stale in two places:
- its *"A note on scale"* still lists "a one-shot `promoted` flip" as one of two live `outputs` deviations — but #012 removed the column; promotion is now a `promotions` row, leaving only the failure-bounded delete as a deviation;
- its derived-status table gates `unproven` on "≥1 promoted output" — the code now gates on the existence of a `promotions` row (`Action#derived_status`).
Reconciling it (and adding a reciprocal link to this catalogue) is tracked as a probe in the audit HLR.

## Conformance summary
The schema is substantially compliant: the lifecycle is carried by structural and temporal facts (A/B), the only literal `status` column was deleted, and every prior denormalisation is resolved — the `promoted` flag (→ a `promotions` fact), the `actions.satoshis` aggregate (dropped), the `actions.outgoing` direction flag (dropped, #349), and `actions.nlocktime`/`version` (dropped, derived from `raw_tx`, #351). No open candidates remain. The standing residue is two principled value-column exceptions, named and kept by design (`broadcasts.tx_status`, `sse_cursors.last_event_id`/`retry_count`), and one stale companion document to reconcile (`principle-of-state.md`, tracked under #348).

## Related
- [`principle-of-state.md`](principle-of-state.md) — the principle this register tests against.
- [`state-boundaries.md`](state-boundaries.md) — the sibling principle (where state lives).
- [`schema.md`](schema.md) — the schema design that operationalises both.
- ADR-003 (schema-as-canonical-state), ADR-005 (accounting-ledger-not-dag), ADR-019 (broadcasts-intent-declarative-enforcement), ADR-022 (state-as-a-fk-row), ADR-023 (promotion-as-a-row).
