---
title: Hot-path design
parent: Reference
nav_order: 12
---

# Hot-path design — no triggers on per-row writes

A small operational rule that flows from [`principle-of-state.md`](principle-of-state.md) (the schema enforces, always) and the throughput target (ADR-002 — design for scale). Both routes are legitimate forms of "enforcement stays in the database"; the choice between them is settled by where the rule sits.

## Rule

> **No triggers on the hot path. Cross-table invariants that need schema enforcement on per-row writes are encoded declaratively — denormalise the parent's relevant column onto the child, then constrain with a composite FK + a single-row CHECK.**

The hot path is anywhere the wallet inserts at chain-speed: every `outputs` insert (one per output per action), every `spendable` insert (one per spendable output), every `broadcasts` insert (one per send-path action). A per-row `plpgsql` trigger on any of these taxes the path with a procedural lookup per write — #221 records the design-discussion ceiling of "~10k tx/s region" for per-row triggers, which the millions-of-tx/s target (ADR-002) forecloses.

A trigger and a declarative encoding are functionally equivalent for the rules they can both express. The declarative form costs no procedural code per write; the trigger costs `plpgsql` per affected row. When both work, declarative wins.

## The pattern

Three ingredients:

1. **Denormalise the parent's relevant column onto the child** so a single-row CHECK can see the cross-table condition.
2. **Composite FK from the child back to the parent on both columns** — the parent must expose a `UNIQUE(id, <denormalised_column>)` index as the FK target. The FK keeps the denormalised copy honest: it cannot disagree with its source, ever.
3. **CHECK on the child's denormalised column** to forbid the invariant-breaking values.

Composed, the FK forces the child's copy to equal the parent's value, and the CHECK forbids the disallowed values — so the parent cannot hold disallowed children, declaratively, with no trigger.

A second invariant often falls out for free. With `on_update: :restrict` on the composite FK, the parent's column becomes effectively immutable while a child row exists — any UPDATE on the parent's column is rejected by the FK. One FK, two invariants.

## Worked examples

### `broadcasts.intent` (settled, ADR-019)

The invariant: an `actions` row with `broadcast_intent = 'none'` (internal-path: internalize, import, wbikd, receipts) must never own a row in `broadcasts`. Internal-path actions never get broadcast; a `broadcasts` row for one would be a self-contradiction.

The encoding:

```ruby
# actions (parent): broadcast_intent ENUM, UNIQUE(id, broadcast_intent) for FK target
# broadcasts (child):
column :intent, broadcast_intent_type, null: false
foreign_key %i[action_id intent], :actions,
            key: %i[id broadcast_intent], on_update: :restrict
constraint :intent_not_none, "intent != 'none'"
```

The FK ties `broadcasts.intent` to the parent action's `broadcast_intent`; the CHECK forbids `intent = 'none'`. A `'none'` action cannot hold a `broadcasts` row by composition. `on_update: :restrict` additionally pins the parent's `broadcast_intent` for the broadcast's lifetime.

The original #198 gap-5 proposal was a `BEFORE INSERT` trigger on `broadcasts` mirroring `prevent_outbound_spendable`. Rejected on hot-path cost; the declarative form expresses the same rule for zero per-row overhead. Settled in PR #221, recorded in ADR-019.

### `spendable.spendable_intent` (HLR #467, this PR)

The invariant: an `outputs` row with `spendable_intent = 'none'` (an outbound payment we cannot spend) must never own a row in `spendable`. The spendable table is set membership over wallet-spendable outputs; an outbound output has no place in it.

The encoding mirrors the broadcasts pattern:

```ruby
# outputs (parent): spendable_intent ENUM, UNIQUE(id, spendable_intent) for FK target
# spendable (child):
column :spendable_intent, spendable_intent_type, null: false
foreign_key %i[output_id spendable_intent], :outputs,
            key: %i[id spendable_intent]
constraint :spendable_intent_must_be_spendable, "spendable_intent = 'spendable'"
```

This replaces the `prevent_outbound_spendable` trigger entirely. The trigger existed because no declarative form could express the cross-table rule under the old schema; once `spendable_intent` is denormalised onto `spendable`, the composite FK + CHECK pair holds the same rule with no procedural code. The trigger is dropped, not rewritten.

## When triggers ARE appropriate

Triggers stay legitimate where the rule is *non-declarable* (a plain CHECK cannot express it, no denormalisation reduces it to one) *and* the path is *off the hot path* (the per-row procedural cost does not matter at the rule's call frequency).

Examples that remain triggers in the schema:

- **`prevent_internal_action_delete`** — refuses `DELETE` on an internal action with a `promotions` row. Defence-in-depth against `reject_action` being called for internal-path actions; deletes are rare and off the chain-speed write path.
- **Cold-path consistency checks** generally — schema invariants enforced only during occasional batch operations, admin tasks, or destructive workflows.

A trigger on the hot path is the wrong tool when a denormalised composite FK + CHECK exists. A trigger off the hot path, holding a rule no declarative form can express, is the right tool.

## Test for new cross-table invariants

When a new cross-table rule arrives at the schema, walk the filter:

1. **Is the rule expressible as a single-row CHECK?** Yes → CHECK on the child, no trigger needed.
2. **Can the parent's relevant column be denormalised onto the child to make the rule a single-row CHECK?** Yes → composite FK + CHECK; the FK keeps the copy honest. The cost is one extra column.
3. **Does the rule live on the hot path?** Yes and 1+2 don't reduce it → re-examine; a trigger here forecloses scale. No → a trigger is acceptable; the per-row cost does not matter.
4. **Is the rule non-declarable and on the hot path?** This combination signals the schema is wrong-shaped for the rule. The fix is to reshape the schema (a new column, a new table, a new constraint target) until the rule reduces; not to ship a trigger that taxes every write.

## Related

- [`intent-and-outcomes.md`](intent-and-outcomes.md) — the principle that produces most of these cross-table invariants in the first place. Intent is stated on the parent, denormalised onto the child, and constrained declaratively here.
- [`principle-of-state.md`](principle-of-state.md) — the schema enforces, always. This document is the operational rule for *how* it enforces on the hot path.
- [`schema.md`](schema.md) — the table-by-table reference; the worked examples above link to their schema definitions.
- ADR-002 — design for scale; the throughput argument behind the hot-path rule.
- ADR-003 — schema as canonical state; the principle this is operationalising.
- ADR-019 — `broadcast_intent` as the canonical worked example.
- ADR-031 — names the intent-and-outcomes principle this rule supports.
- HLR #467 — the second worked example (`spendable_intent`), which drops `prevent_outbound_spendable` declaratively.
