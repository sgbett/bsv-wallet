# ADR-022: State as a FK row

## Status

Accepted.

**Decided:** 2026-06-10 (commit `2854d2b`, "docs(reference): add principle-of-state + state-boundaries"). This is the date the *general* pattern was first articulated in prose, not a discrete code-decision date — the technique itself was seeded by ADR-004(c) at the original schema (`d08edd3`, 2026-05-05). `principle-of-state.md` is where the specific `spendable` case was first stated as a reusable rule ("Pure set membership. The presence of the row IS the state."). No separate decision commit generalised it; this ADR records the principle that the documentation surfaced, dated to that documentation.

## Context

ADR-003 settled the broad rule: state is derived from structure, never stored as a flag that can drift. But "derived from structure" admits several concrete forms — a status computed from a JOIN of several columns (the `actions` status table in `principle-of-state.md`), a derived count, a structural predicate over relationships. This ADR isolates *one* of those forms and names it, because it recurs and because reaching for it deliberately keeps the schema honest.

The form is this: a single state fact — a yes/no membership — is encoded by **whether a row exists in a dedicated table**, not by a boolean or enum column on an existing row. ADR-004(c) took this decision for the `spendable` set specifically. The seed grew into a pattern the schema reuses, and `principle-of-state.md` generalised it ("the presence of the row IS the state"). What follows is the general statement, the test for when to reach for it, and the concrete places the schema applies it — each verified against the migrations.

## Decision Drivers

* A boolean/enum column that *says* a fact can disagree with the structure that *is* the fact — the predecessor's "four fields that must agree" failure (ADR-003). A row's existence cannot disagree with itself.
* Set membership has a natural, contention-free home in the relational model: `INSERT` to add, `DELETE` to remove, `UNIQUE` to forbid duplicates, `INSERT … ON CONFLICT DO NOTHING` to resolve a race in the database rather than in Ruby (ADR-004(b)).
* Adding/removing a membership fact often happens at a *different* time from when the host row is written — recording derivation data at signing without yet declaring an output spendable, for instance (ADR-004(c), Alternative E). A separate row lets the two facts move independently; a column on the host row forces them to move together.
* A membership table that is keys-only stays tiny: the hot path scans the set, not the data (ADR-002, ADR-004(a)).

## Decision

**Represent a binary state fact as the presence or absence of a row in a dedicated table, keyed by a FK to the entity the fact is about. The row's existence is the fact. Do not add a boolean or enum column to the host row to carry the same fact.**

This is the representational technique; ADR-003 is the principle it serves. The distinction is deliberate:

* **ADR-003** says, broadly, *state is derived, not stored* — no `status` column anywhere. It does not prescribe a representation.
* **ADR-022** (this ADR) prescribes *one* representation for *one* shape of state — a membership fact — and says: use a dedicated FK row, not a flag. Other derived state (the computed `actions` status, a count) is derived differently and is out of scope here.
* **ADR-004(c)** is the original, specific instance — the `spendable` set. This ADR is the generalisation drawn out of it; it does not restate that decision.

### The pure form — keys-only membership

In its cleanest form the membership table carries *no data columns at all*: a primary key and the FK, nothing else. The row exists, or it does not; there is nothing on it to drift, and nothing to read but the entity it points at. `spendable` is the archetype.

* `spendable` — `gem/bsv-wallet/db/migrations/001_create_schema.rb:158-162`: `output_id` FK `null: false, unique: true` at `:161`, no data columns. A denormalised `action_id` CASCADE key (for reaper cleanup) is made `NOT NULL` in `003_schema_constraints.rb:104`; it remains a key, not data. An output is spendable iff a `spendable` row references it.

Keeping the pure form pure is a standing guard (ADR-010): the moment a data column appears on `spendable`, set membership and data have been conflated onto one row and can no longer move independently — the regression ADR-004(c) Alternative E rejected.

### The mixed form — membership-plus-relationship-attributes

The *presence-encodes-state* half of the technique still applies when the relationship the row records has its own attributes that belong nowhere else. The row's existence is the fact; the columns describe the relationship, not the fact.

* `inputs` — `gem/bsv-wallet/db/migrations/001_create_schema.rb:192-205`. The presence of an `inputs` row referencing an output **is** the spend; `UNIQUE(output_id)` at `:203` forbids a second claim (ADR-004(b)). The row is not keys-only — `vin`, `nsequence`, `description` (`:197-199`) are the spend relationship's own attributes — so it is the mixed form: membership encoded by presence, with relationship data attached. There is no `spent` boolean on `outputs`; the fact is the row.

The discriminator between the pure and mixed forms is whether the attached columns describe *the fact* (forbidden — that is a status column in disguise) or *the relationship the row records* (allowed). `inputs` carries the latter.

### What is *not* this pattern

Honesty about the boundary matters more than a longer list of examples.

* `broadcasts` (`:96-125`) is **not** a membership row. Its presence does coincide with "a broadcast was attempted", and `UNIQUE(action_id)` at `:117` makes it at-most-one-per-action — so a reader could mistake it for membership. But it carries a body of *mutating lifecycle state* — `tx_status`, `arc_status`, `block_hash`, `competing_txs` (`:103-113`) — that is updated in place as ARC's verdict converges. A membership row's content does not change; a `broadcasts` row's does. It is a state-bearing record, not a membership marker. (The derived-status table in `principle-of-state.md` reads `broadcasts` as one input among several; that is consistent — its *presence* contributes to derivation, but the row itself is not the technique this ADR names.)
* The pure-join-table rows (`action_labels`, `output_tags`, `output_baskets`) are association rows, not state facts about a single entity. They encode a relationship between two entities; that is ordinary relational modelling, not the state-as-membership pattern.

### When to reach for it

Adding a binary state fact to the schema and tempted to add a boolean? Ask:

1. Is the fact genuinely binary membership (in/out), not a multi-valued lifecycle? → membership row.
2. Does the fact need to appear or disappear at a different time from when the host row is written? → membership row (a column would force them together).
3. Does the "relationship" have attributes of its own? → mixed form (`inputs`); else the pure form (`spendable`).
4. Is the fact a status that converges over time through several updates? → **not** this pattern; that is a state-bearing record (`broadcasts`), or derived from several inputs (the `actions` status).

## Alternatives Considered

### A. A boolean/enum column on the host row
Carry the fact directly — `outputs.spendable`, `outputs.spent`. **Rejected** — the column can drift from the structure it claims to describe; this is precisely ADR-003's originating failure and ADR-004's Alternatives B and D. The membership row cannot drift: its existence *is* the statement.

### B. A single membership table for everything (polymorphic "facts" table)
One `state_facts(entity_type, entity_id, kind)` table. **Rejected** — it trades the type-safe per-entity FK (RESTRICT, CASCADE, composite keys) for a stringly-typed polymorphic key the schema cannot constrain, and it puts unrelated hot and cold sets in one table. Dedicated tables keep each FK enforceable and each set independently scannable.

### C. Always keys-only (forbid the mixed form)
Insist every membership table be keys-only; push relationship attributes elsewhere. **Rejected** — the spend relationship's attributes (`vin`, `nsequence`) belong to neither the output nor the action (ADR-004(b)); forcing them off `inputs` invents a satellite table for no benefit. The pure form is the default; the mixed form is correct where the relationship genuinely owns attributes.

## Consequences

### Positive
* A membership fact cannot drift — no column to disagree with structure.
* Add/remove is `INSERT`/`DELETE`; a duplicate is forbidden by `UNIQUE`; a race resolves in the database (ADR-004(b)).
* Membership and host-row data move on independent timelines.
* The pure form keeps the hot set tiny and scannable (ADR-002, ADR-004(a)).

### Negative
* More tables, and reads JOIN to the host row for its data.
* The pure/mixed discriminator ("does this column describe the fact or the relationship?") is a judgement call that needs holding — a column smuggled onto a membership row regresses it to a status flag without tripping any constraint.

### Neutral / Reversibility
* A specialisation of ADR-003, applied wherever the schema already uses it; reversing it means reintroducing the flags ADR-003 and ADR-004 rejected. Not foundational on its own — it is a pattern the foundation (ADR-003) sanctions and the original schema (ADR-004(c)) first used.

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

This ADR names a pattern already in the schema rather than introducing new mechanism — its cost is documentation, not code. The value is a sharp test ("does the column describe the fact or the relationship?") that catches the regression ADR-004(c) Alternative E and PR #56 actually suffered: data columns creeping onto `spendable` until set membership and data could no longer move independently. Naming the boundary case (`broadcasts` is *not* a membership row) is the discipline that stops the pattern being over-applied. **Approve.** The standing guard is the pure form's purity — keys only on `spendable` (ADR-010).

* Necessity 7, Complexity 3, **Ratio 0.43** — within the balanced target (<1.5).

## Validation

* `spendable` carries only keys (`{id, output_id, action_id}`) — no data column; an output is spendable iff a row exists.
* No `spent` or `spendable` boolean exists on `outputs`; the spend is the `inputs` row, the spendability is the `spendable` row.
* `inputs` presence encodes the spend, with relationship attributes (`vin`, `nsequence`, `description`) attached — the mixed form, correctly used.
* A new binary state fact is reviewed against the four-question test before any boolean column is added.

## References

* ADR-003 — derived, not stored (the principle this technique serves).
* ADR-004 — sub-decision (c) spendable-as-a-FK-row (the seed), (b) inputs-as-the-lock, (a) the partition that keeps the set tiny.
* ADR-002 — the scale target that rewards keys-only membership.
* ADR-010 — keep data off `spendable`; the inference ban (the standing guard on the pure form).
* `docs/reference/principle-of-state.md` — "Pure set membership. The presence of the row IS the state" (where the general statement first appears).
* `gem/bsv-wallet/db/migrations/001_create_schema.rb` — `spendable` (`:158-162`), `inputs` (`:192-205`), `broadcasts` (`:96-125`).
* `gem/bsv-wallet/db/migrations/003_schema_constraints.rb` — `spendable.action_id` NOT NULL (`:104`).

## Unverified claims

None.
