---
title: State representations
parent: Reference
nav_order: 3
---

# State Representations — conformance catalogue

A living register of **every place the schema represents state**, classified against the wallet's load-bearing principle that *state is read, not stored* (see [`principle-of-state.md`](principle-of-state.md), and the decisions [ADR-003 schema-as-canonical-state](../../.architecture/decisions/adrs/20260505_ADR-003-schema-as-canonical-state.md) and [ADR-022 state-as-a-fk-row](../../.architecture/decisions/adrs/20260610_ADR-022-state-as-a-fk-row.md)).

This document is **not** the principle (that is `principle-of-state.md`) nor a decision (those are the ADRs). It is the **conformance register**: the per-element inventory those documents' "tests for compliance" operate against. It is *living* — it changes whenever the schema changes — and answers one standing question: **are we actually compliant, and where are the conscious exceptions?**

Verified against the consolidated migrations (`001` structure, `002` denormalised cascade FKs, `003` validation) and `lib/` on 2026-06-17.

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
- **`broadcasts.tx_status`** (ARC enum) — mirrors ARC's lifecycle (`UNKNOWN…MINED…IMMUTABLE`). Current value is what matters; it pulls double duty as the FK target for `promotions.authorising_status` (`ON UPDATE CASCADE` keeps a promotion synced as status advances), so the ARC vocabulary is load-bearing for a referential constraint — enum additions (`SEEN_MULTIPLE_NODES`, `IMMUTABLE`) touch a constraint, not just a column.

  **Why not an event table?** (the schema models lifecycle structurally, so this is a fair question — here is the rule-out for future wanderers):
  1. **It is external truth, not wallet state.** The wallet's *own* broadcast lifecycle is already structural — the `broadcasts` row's existence ("we attempted"), `broadcast_at` (when, class B), the `promotions` row (canonical), `tx_proof_id` (mined/proven). `Action#derived_status` consults `tx_status` for **one** thing only — detecting `:failed` (`REJECTED`); every other stage derives from structure. `tx_status` is not a stage the wallet transitions through; it is ARC's asynchronous verdict, observed and cached (it arrives via `Services`/`SSEListener`/`BroadcastCallback`), and re-pollable from ARC.
  2. **The durable milestones are already structural/temporal.** "Submitted" = `broadcast_at`; "mined/proven" = `tx_proof_id` + `tx_proofs.created_at`. The intermediate mempool statuses are transient; the daemon needs only the *current* one to decide poll-vs-terminal — an O(1) scalar read. An event log reintroduces the latest-per-broadcast fold the deltas-vs-facts model exists to avoid (see the taxonomy note above).
  3. **A live constraint forbids it (decisive).** The #012 promotion gate is a composite FK `promotions(action_id, authorising_status) → broadcasts(action_id, tx_status)` backed by `UNIQUE(action_id, tx_status)`. There is exactly **one** `broadcasts` row per action; the FK targets its *current* `tx_status`. An event log (many status rows per action) cannot be that FK target — "FK to the latest event" does not exist — so the refactor would break a constraint that exists today.

  **When this *would* change:** if a durable **audit trail** of ARC transitions is ever needed (forensics, a user-facing "tx journey", or distinguishing in-flight sub-states for reporting — the deferred-async subsystem may want the fuller enum, tracked in #198), add an append-only `broadcast_events` log **alongside** this column — never as a replacement; the scalar stays for the FK and the O(1) reads. Add-when-needed; it does not change today's classification.
- **`broadcasts.retry_count`** — a counter; intrinsically scalar mutable state.
- **`sse_cursors.last_event_id`** — external stream position (ARC SSE); a cursor is current-value-only by nature.

### E — Value attributes (data, not lifecycle state)
`actions`: `raw_tx`, `input_beef`, `reference`. `outputs`: `satoshis`, `vout`, `locking_script`, `spendable_intent`*, `derivation_prefix/suffix`, `sender_identity_key`. `output_details`: `type`, `purpose`, `provided_by`, `description`, `custom_instructions`, `script_length/offset`. Plus `blocks.*`, `tx_proofs.merkle_path/raw_tx/block_index`, `certificates.*`, `certificate_fields.*`, `broadcasts.block_hash/height/merkle_path/provider/callback_token`, `settings.value`.
<br>*`spendable_intent` is an immutable intent attribute stated by the decision-maker at construction time (HLR #467 / [`intent-and-outcomes.md`](intent-and-outcomes.md)), not lifecycle state. Replaces the conflated `output_type` column.

### F — Driftable flags (the anti-pattern — target is empty)
- **`outputs.promoted` — RESOLVED (#307, ADR-022 / ADR-023).** A mutable boolean duplicating "is this canonical." Now class A: the per-action fact is the existence of a `promotions` row. This is the catalogue's headline result. *Absent by design in the live schema — never created.*
- **`tx_reqs.status` — RESOLVED (#142).** The only literal `status` column the schema ever had, on a proof-harvesting work queue superseded by entity-driven structural queries (`Pushable` / `Fetchable` mixins). Historical exemplar of the anti-pattern excised, not merely avoided. *Absent by design — the table is never created.*
- **`actions.satoshis` — RESOLVED.** A net-amount **stored aggregate** (Σ outputs − Σ inputs) on `actions`. A derivable denormalisation removed in favour of deriving the figure on demand — the [ADR-005](../../.architecture/decisions/adrs/20260505_ADR-005-accounting-ledger-not-dag.md) instinct applied. *Absent by design — never created on `actions`.* (`outputs.satoshis` is unrelated and remains — a class-E value attribute.)
- **`actions.outgoing` — RESOLVED (#352).** A direction flag with **no load-bearing consumer**: its one runtime reader (`pending_proofs`) conjoined `outgoing: true` with `broadcast_intent != 'none'`, which already implies it (every `outgoing: false` action was created `broadcast_intent: 'none'`); the sibling reap query selects the same set on `broadcast_intent` alone. Its only echo, `action_to_hash`, fed an interface field no caller or spec consumed. Its only hard dependency was the `nlocktime_range` CHECK — a constraint on `actions.nlocktime`, itself never read by the builder (`lock_time` is threaded in-memory and baked into `raw_tx`) and recoverable from `raw_tx`. *Absent by design — column and constraint never created.* The interface field is now derived as `broadcast_intent != 'none'`.
- **`actions.nlocktime` / `actions.version` — RESOLVED (#352).** Stored projections of `raw_tx` — nLockTime is its trailing four bytes (LE), version its leading four. The builder reads neither (`lock_time`/`version` flow in-memory into `tx_builder.build`, baked into `raw_tx` at sign time); the sole reader, `action_to_hash`, now derives them from `raw_tx`. *Absent by design — never created.* No constraint depended on them (the `nlocktime_range` guard went with `outgoing`). Non-final transactions (#192) are unaffected — the nLockTime value stays in `raw_tx`; the non-final *intent* needs its own marker, not this value column.

No class-F representation remains in the live schema, and the open candidates are resolved.

## Open candidates (probes)
None outstanding. The two prior probes are resolved: `actions.outgoing` (#349) and `actions.nlocktime`/`version` (#351) were both dropped — see class F above. New candidates are added here as the audit (or future schema changes) surface them.

## Known documentation drift — RESOLVED
[`principle-of-state.md`](principle-of-state.md) predated #012 in two places, now reconciled: its *"A note on scale"* described the removed one-shot `promoted` flip (now noted as superseded by the `promotions` row, ADR-023), and its derived-status table gated `unproven`/`sending` on "promoted outputs" (now on the existence of a `promotions` row, matching `Action#derived_status`). A reciprocal link to this catalogue is in place.

## Conformance summary
The schema is substantially compliant: the lifecycle is carried by structural and temporal facts (A/B), the only literal `status` column was deleted, and every prior denormalisation is resolved — the `promoted` flag (→ a `promotions` fact), the `actions.satoshis` aggregate (dropped), the `actions.outgoing` direction flag (dropped, #349), and `actions.nlocktime`/`version` (dropped, derived from `raw_tx`, #351). No open candidates remain, and the `principle-of-state.md` drift is reconciled. The only standing residue is two principled value-column exceptions, named and kept by design (`broadcasts.tx_status`, `sse_cursors.last_event_id`/`retry_count`) — each justified in their entries above. The audit (#348) is complete.

## Related
- [`principle-of-state.md`](principle-of-state.md) — the principle this register tests against.
- [`state-boundaries.md`](state-boundaries.md) — the sibling principle (where state lives).
- [`schema.md`](schema.md) — the schema design that operationalises both.
- ADR-003 (schema-as-canonical-state), ADR-005 (accounting-ledger-not-dag), ADR-019 (broadcasts-intent-declarative-enforcement), ADR-022 (state-as-a-fk-row), ADR-023 (promotion-as-a-row).
