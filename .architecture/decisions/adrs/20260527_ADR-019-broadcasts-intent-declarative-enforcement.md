# ADR-019: broadcasts-intent — keep a cross-table invariant in the database, declaratively

## Status

Accepted.

**Decided:** 2026-05-27 (commit `7803e85`, #221).

## Context

ADR-003 fixes the principle this ADR exemplifies: the database schema is the canonical source of truth, every state-changing operation moves the database atomically from one valid state to another, and invalid state is structurally impossible because the schema rejects it. The database enforcing valid state is not a choice — it is the foundation.

This ADR records one concrete invariant and how it is held.

The invariant: an `actions` row with `broadcast_intent = 'none'` — the transactions the wallet never broadcasts (internalize, import, wbikd, receipts) — must never own a row in the `broadcasts` table. A `broadcasts` row records an attempt to put a transaction on the network via ARC; an action that by design is never broadcast has nothing to record there. Allowing such a row would be exactly the kind of internally-contradictory state ADR-003 forbids — the action's own intent says "never broadcast" while a sibling row claims a broadcast lifecycle.

This is a *cross-table* rule. The condition lives on `actions` (`broadcast_intent`) but must constrain rows in `broadcasts`. A plain CHECK constraint cannot express it: a CHECK sees only the row being written, not another table. So the question is not *whether* the database enforces it — under ADR-003 it must — but *how* the database can be made to enforce a rule a single-row CHECK cannot reach.

Two routes keep enforcement in the database:

1. A **trigger** on `broadcasts` that looks up the parent action and rejects the INSERT when its `broadcast_intent = 'none'`. This is exactly what was first proposed — #198 (the constraint-gap analysis) lists it as gap 5, mirroring the existing `prevent_outbound_spendable` trigger.
2. **Denormalise** the parent's intent onto `broadcasts` so a declarative constraint *can* see it, then enforce with an FK and a CHECK — no procedural code.

The deciding force is scale (ADR-002). The `broadcasts` INSERT sits on the hot send path — it fires on every transaction the wallet broadcasts. A trigger runs `plpgsql` per affected row, and #221 records the design-discussion figure that a per-row trigger "limit[s] throughput to ~10k tx/s region". On the path the wallet must scale, taxing every send with a procedural lookup is the wrong trade when a purely declarative encoding is available.

## Decision Drivers

* **ADR-003 — the database enforces valid state, always.** The invariant must have a schema backstop; leaving it to application code is not on the table.
* **A single-row CHECK cannot express a cross-table rule.** Enforcement has to reach across `broadcasts` → `actions`, so a plain CHECK on `broadcasts` is insufficient on its own.
* **ADR-002 — the send path must scale.** The `broadcasts` INSERT is hot; a per-row trigger competes with the throughput target (~10k tx/s ceiling, #221). The cheapest mechanism that holds the rule wins.
* **A trigger and a denormalised declarative encoding are functionally equivalent here** — both keep enforcement in the database. The denormalised form costs no procedural code per write; the trigger does.

## Decision

Keep the invariant in the database, and encode it **declaratively** by denormalising the parent's intent onto `broadcasts`:

* `broadcasts.intent` (`broadcast_intent` ENUM, `NOT NULL`) carries a copy of the parent action's `broadcast_intent`, populated when the `broadcasts` row is created (`001_create_schema.rb:108`).
* A composite foreign key `broadcasts(action_id, intent) → actions(id, broadcast_intent)` ties the copy to the parent — the broadcast's `intent` *must* equal its action's `broadcast_intent`, or the FK rejects the row (`001_create_schema.rb:122-123`). This targets `UNIQUE(id, broadcast_intent)` on `actions` (`001_create_schema.rb:93`), the FK target added by the `broadcast → broadcast_intent` rename in #217.
* A CHECK `intent != 'none'` on `broadcasts` (`constraint(:intent_not_none, …)`, `001_create_schema.rb:124`) forbids the denormalised value being `'none'`.

Composed, the two are airtight: the FK forces `broadcasts.intent` to equal the parent's `broadcast_intent`; the CHECK forbids `intent = 'none'`; therefore a `broadcast_intent = 'none'` action can hold no `broadcasts` row at all — declaratively, with no trigger on the hot path.

A second invariant falls out of the same FK at no extra cost. With `on_update: :restrict` (`001_create_schema.rb:123`), any attempt to mutate `actions.broadcast_intent` while a `broadcasts` row exists is rejected — `actions.broadcast_intent` is effectively immutable for the life of a broadcast. One FK, two invariants, both held by the database.

This ADR is an **exemplar of ADR-003, not a competing meta-policy.** The principle being illustrated:

1. **The database enforces valid state — always.** That is ADR-003; it is not negotiable, and this invariant is no exception.
2. **When a plain declarative constraint cannot express a cross-table rule, the response is not to drop to unenforced application code** — that would break ADR-003. The response is to find a form in which the database *can* enforce it. Here, denormalising a column so a composite FK + CHECK can see the cross-table condition.
3. **The specific technique — denormalise + composite FK + CHECK — is an illustrative example, not the principle.** The principle is: enforcement stays in the database, and the mechanism is chosen with scale in mind (ADR-002). Here a declarative encoding was chosen over a functionally-equivalent trigger precisely because the trigger would tax the hot path.
4. **Application transactions still wrap multi-write transitions atomically (ADR-006), but they *serve* the constraints, they never *replace* them.** The code that creates a `broadcasts` row populates `intent` from the parent so the FK is satisfied; it does not "validate" the rule itself — the schema is the gate.

Triggers remain legitimate where a rule is non-declarable *and* off the hot path. They are not a competing rung in a hierarchy; they are simply another form of "enforcement stays in the database", chosen when no declarative form can express the rule and the path can afford the per-row cost. (See footnote.)

## Alternatives Considered

### A. A `BEFORE INSERT` trigger on `broadcasts` (the original #198 gap-5 proposal)
A `plpgsql` trigger looks up the parent action and rejects the INSERT when its `broadcast_intent = 'none'`, mirroring `prevent_outbound_spendable`.
**Pros:** keeps enforcement in the database; needs no extra column; expresses the cross-table check directly.
**Cons:** runs per affected row on the hot send path, competing with the throughput target — the ~10k tx/s ceiling cited in #221. Where a declarative encoding can hold the *same* rule with no procedural code per write, the trigger is strictly the more expensive of two functionally-equivalent options.
**Rejected** — not because triggers are illegitimate (two live triggers prove they aren't, see footnote), but because on this path a declarative form is available and cheaper. The denormalised FK + CHECK was chosen instead (#221).

### B. Enforce it in application code inside the broadcast transaction, with no schema backstop
Have `Store` simply refrain from inserting a `broadcasts` row for a `broadcast_intent = 'none'` action, relying on every write path going through that one method.
**Pros:** no schema change at all.
**Cons:** **this breaks ADR-003.** An invariant held only by application code, with no database backstop, is precisely the drift the principle of state exists to make impossible — a new write path that forgets the rule would persist contradictory state and the database would not stop it. This is a critical defect, not a legitimate option.
**Rejected** — categorically. ADR-003 is not a preference to be traded against convenience; the database must enforce the rule.

## Consequences

### Positive
* The invariant has a declarative schema backstop and costs nothing procedural on the hot send path — the database rejects a contradictory `broadcasts` row, and the send path pays no per-row trigger.
* A second invariant (`actions.broadcast_intent` immutable while a broadcast exists) comes free from the same FK's `on_update: :restrict`.
* The encoding cannot be forgotten by a new write path: any code inserting a `broadcasts` row must supply an `intent` the FK and CHECK accept, or the INSERT fails.

### Negative
* **Denormalisation carries a copied value.** `broadcasts.intent` duplicates the parent's `broadcast_intent`. The duplication is *constrained* — the composite FK guarantees the copy can never disagree with its source, so this is a denormalisation the schema keeps honest, not a drift risk. The cost is one extra column and the discipline of populating it at insert time.
* **The hot-path judgement rests on an estimate.** Choosing the declarative encoding over the trigger leans on the ~10k tx/s figure from a design discussion (#221), not a measured per-trigger benchmark on this schema. The conclusion (declarative beats trigger when both express the rule) holds regardless of the exact number, but the *urgency* of avoiding the trigger is calibrated to an estimate.

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

This is a textbook application of ADR-003 under ADR-002's scale constraint, and it adds no new machinery — one column, one composite FK, one CHECK, all declarative. The genuinely simpler-looking option (B, application-only) is the one rejected, and rightly: it would break the principle of state, which is the opposite of simpler. Between the two database-side options, the chosen denormalised encoding is *cheaper* than the trigger it replaced, so scale and simplicity pull the same way here rather than against each other — the rare case where the constraint-respecting choice is also the lighter one. The denormalised column is kept honest by the FK, so the usual drift objection to denormalisation does not bite. **Approve.**

## Validation

* A `broadcasts` row whose `intent` differs from its parent action's `broadcast_intent` is rejected by the composite FK (`001_create_schema.rb:122-123`).
* A `broadcasts` row with `intent = 'none'` is rejected by the `intent_not_none` CHECK (`001_create_schema.rb:124`); composed with the FK, no `broadcast_intent = 'none'` action can hold a `broadcasts` row.
* Updating `actions.broadcast_intent` while a `broadcasts` row references it is rejected by `on_update: :restrict` (`001_create_schema.rb:123`).
* These are Postgres-native constraints; their behaviour (composite FK, CHECK violation, RESTRICT on update) is verified against Postgres, not assumed from the SQLite translation (ADR-009).

## Footnote — triggers are still legitimate (off the hot path)

A trigger is the right form when a rule is *not* declaratively expressible **and** the guarded write is not throughput-critical. Two live triggers illustrate that DB-side enforcement takes whatever form fits — declarative where possible, a trigger where no declarative form can express the rule and the path can afford it. They are not a rung in a hierarchy; they are more examples of "enforcement stays in the database":

* **`prevent_outbound_spendable`** (`gem/bsv-wallet/db/migrations/003_schema_constraints.rb:108-125`) — a `BEFORE INSERT ON spendable` trigger rejecting a `spendable` row for an `output_type = 'outbound'` output. The condition is a cross-row check against `outputs`, which a CHECK on `spendable` cannot express.
* **`prevent_internal_action_delete`** (`gem/bsv-wallet/db/migrations/008_prevent_internal_action_delete.rb:28-45`) — a `BEFORE DELETE ON actions` trigger blocking deletion of a `broadcast_intent = 'none'` action that owns a `promoted` output. CHECKs never fire on DELETE, and the condition is a cross-table existence check — declaratively impossible on both counts.

Where broadcasts-intent *could* be made declarable (by denormalising), it was — precisely because its write is hot. These two cannot be made declarable, and their writes are not hot, so a trigger is the form that fits.

## References

* ADR-003 — schema as canonical state; this ADR is an exemplar of it (the database enforces valid state; application code serves the constraints, never replaces them).
* ADR-002 — design for BSV scale; the throughput target that makes a hot-path trigger the wrong trade.
* ADR-006 — one relational store, one ACID boundary; the atomic transition the broadcast insert participates in.
* ADR-009 — Postgres-native primitives; the composite FK / CHECK / ENUM / trigger features the schema enforces with.
* `gem/bsv-wallet/db/migrations/001_create_schema.rb` — `actions` `unique %i[id broadcast_intent]` (:93); `broadcasts.intent` column (:108), composite FK with `on_update: :restrict` (:122-123), `intent_not_none` CHECK (:124).
* `gem/bsv-wallet/db/migrations/003_schema_constraints.rb` (:108-125) — `prevent_outbound_spendable` trigger.
* `gem/bsv-wallet/db/migrations/008_prevent_internal_action_delete.rb` (:28-45) — `prevent_internal_action_delete` trigger.
* HLR #198 (constraint-gap analysis; gap 5 proposed the trigger), #221 (FK + CHECK chosen over the trigger; the ~10k tx/s ceiling; commit `7803e85`), #217 (`broadcast → broadcast_intent` rename adding the `UNIQUE(id, broadcast_intent)` FK target).

## Unverified claims

None. Every structural claim was read from the cited migration file or issue. Two notes against the drafting brief, both confirmed by source:

* The composite FK + CHECK + UNIQUE live in `001_create_schema.rb` (the schema was consolidated). #221 and #217 draft them as "migration 011" / "migration 007"; those numbers refer to pre-consolidation migrations that now live in `001`. The references cite the live locations.
* Issue #225 does not exist in this repository (`gh issue view 225` → "Could not resolve to an Issue"), so it carries no relevance to this decision.
