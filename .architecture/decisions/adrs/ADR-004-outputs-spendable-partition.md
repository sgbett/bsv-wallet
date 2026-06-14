# ADR-004: Outputs/spendable vertical partition, inputs-as-the-lock, and spendable-as-a-FK-row

## Status

Accepted.

**Decided:** 2026-05-05 (commit `d08edd3`, "feat: PostgreSQL schema, migration, and Sequel models", HLR #1) — the original Postgres schema that first established the `outputs`/`spendable` split, `UNIQUE(inputs.output_id)`, and the keys-only `spendable` set. The three sub-decisions below were made together as one schema shape; the current migration (`gem/bsv-wallet/db/migrations/001_create_schema.rb`) is a restored, SQLite-guarded translation of that same original.

## Context

The wallet's value lives in its outputs, and the outputs table is the hot path — coin selection scans it constantly. Loading every attribute onto that table (and indexing them) turns the hottest table into the bottleneck: wider rows, fewer per page, write latency on each index. At the same time, "can I spend this?" is asked far more often than "what are this output's display details?", and the two have very different access patterns.

So the output is not one row in one table. Three decisions were taken together to shape it: split the output's data vertically, make the *presence of a row* the spend rather than a status flag, and make spendability *pure set membership* in its own table. They are distinct decisions — they could in principle have been taken apart — but they were taken at one sitting as a single schema design, so they live in one ADR, labelled (a)/(b)/(c) below.

(Note on terminology: "partition" / "vertical partitioning" throughout means splitting one logical row's columns across several tables. It does **not** mean Postgres declarative `PARTITION BY`, which is a separate, future scaling step.)

## Decision Drivers

* Coin selection is the hot path; its scan target must stay narrow (ADR-002).
* "Spendable now" is a small, high-churn working set; output history is large and cold.
* Single-spend must be guaranteed without an application-level lock.
* The spend relationship has its own attributes that belong to neither the output nor the action.
* Spendability is a derived fact (ADR-003) and must not be a stored flag that can drift.

## Decision

### (a) Vertical partitioning of the output

Split the output's data across tables rather than carry it on one wide row. `outputs` is the immutable core — only the fields coin selection and reconstruction need: `action_id`, `satoshis`, `vout`, `locking_script`, and the derivation data (`sender_identity_key`, `derivation_prefix`, `derivation_suffix`). Display/application metadata (`output_details`) and basket membership (`output_baskets`) live in satellite tables, each a `UNIQUE`-keyed `output_id` row. The hot path scans the tiny working set (b/c) and PK-joins back to `outputs` only for the data it actually reads. The justification is scale: at small scale a wide table would serve, but the split keeps the hot table narrow and is what later lets `outputs` be an archivable immutable log (ADR-011). The shorthand: **outputs is the log.**

* `outputs` — `gem/bsv-wallet/db/migrations/001_create_schema.rb:142-155`; `sender_identity_key`/`derivation_prefix`/`derivation_suffix` at `:150-152`; `UNIQUE(action_id, vout)` at `:154`.
* `output_details` — `:165-177` (`output_id` UNIQUE at `:168`).
* `output_baskets` — `:180-189` (`output_id` UNIQUE at `:183`).

### (b) Inputs-as-the-lock

Single-spend is enforced *structurally*, by the `inputs` table itself, not by a status flag on the output. Claiming an output to spend is an `INSERT` into `inputs`; the presence of an `inputs` row referencing an output **is** the spend. `UNIQUE(inputs.output_id)` makes a second claim impossible. Concurrent claims resolve in PostgreSQL via `INSERT … ON CONFLICT (output_id) DO NOTHING RETURNING` — the loser's row simply isn't returned and its transaction rolls back, a deterministic loser-rolls-back with no Ruby mutex and no `SELECT … FOR UPDATE`. The `inputs` table also gives the spend relationship its own home for its own attributes (`vin`, `nsequence`, `description`).

* `inputs` table — `gem/bsv-wallet/db/migrations/001_create_schema.rb:192-205`; `output_id` FK `null: false` at `:196`; `unique :output_id` at `:203`; relationship attributes `vin`/`nsequence`/`description` at `:197-199`; `unique [action_id, vin]` at `:204`.
* The UNIQUE-constraint-as-lock framing is stated as a Decision Driver in ADR-003 (`ADR-003-schema-as-canonical-state.md:17`).

### (c) Spendable-as-a-FK-row

Spendability is pure set membership in a dedicated `spendable` table: an output is spendable iff a `spendable` row references it. No boolean column, no enum, no flag anywhere. The row's *existence* is the entire statement "this output is available to spend"; the table carries no data columns of its own beyond its key and the FK (`{id, output_id}`, with a denormalised `action_id` CASCADE key added later for reaper cleanup). Combined with (b): an output is concretely spendable iff a `spendable` row exists for it and no `inputs` row claims it.

This is the concrete decision for the spendable set specifically. (The broader principle — "represent state as the presence of a FK row" generally — was generalised out of this later and is recorded in its own ADR; it is *not* this decision.)

* `spendable` table — `gem/bsv-wallet/db/migrations/001_create_schema.rb:158-162`: `output_id` FK `null: false, unique: true` at `:161`; no data columns.
* Spendability-as-set-membership (no boolean) is stated in ADR-003 (`ADR-003-schema-as-canonical-state.md:29`, `:45-49`) and in `reference/principle-of-state.md`.

## Alternatives Considered

### A. One wide "kitchen-sink" outputs table (rejects (a))
Every attribute and its indexes on one row. **Rejected** — it makes the hottest, most-scanned table the bottleneck and forces the hot path to drag data it never reads.

### B. A `spending_transaction_id` (or `spent_by`) FK on the output (rejects (b))
Record the consuming transaction on the output itself. **Rejected** — a category error: *being consumed* is a property of the input relationship, not of the output, and it would be a mutable column on the immutable log. The `inputs` table also gives the relationship's own attributes a home they otherwise lack.

### C. Application-level locking for single-spend (mutex / `SELECT … FOR UPDATE`) (rejects (b))
**Rejected** — `UNIQUE(output_id)` + `ON CONFLICT` resolves contention structurally in the database, with recovery ergonomics identical to the UPDATE approach but yielding a proper `inputs` table as the by-product.

### D. A `spendable` boolean column on the output (rejects (c))
Carry spendability as a flag on the output row. **Rejected** — this is the predecessor's "four fields that must agree" failure mode (ADR-003): a stored flag drifts from structural truth. Spendability is set membership, derived from the presence/absence of rows.

### E. Data columns on the `spendable` row (rejects (c)'s purity)
Hang derivation or display data on the `spendable` row. **Rejected** — set membership and data are different facts that change at different times (auto-fund must record derivation at signing without yet declaring the output spendable). Derivation data belongs on `outputs`; `spendable` stays keys-only.

## Consequences

### Positive
* Coin selection scans a tiny set and joins for data only as needed.
* Double-spend is impossible by construction, with no application lock.
* The spend relationship's attributes have a home.
* The split is what makes `outputs` an archivable immutable log (ADR-011) — the log/wallet separation and the contention reduction were the same decision.

### Negative
* More tables; reads join across the partition.

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

The partition (a) is justified by the hot path (ADR-002): at small scale a wide table would serve, but the split is cheap and buys the log/wallet separation and structural single-spend at once. The inputs-as-lock (b) is the elegant move — contention handled by a `UNIQUE` constraint rather than application code, which is strictly less to get wrong. Spendable-as-a-FK-row (c) is the derived-state principle (ADR-003) applied to the UTXO set: a fact represented as a row's existence cannot drift the way a boolean can. **Approve.** The standing guard is keeping data columns *off* `spendable` (ADR-010) so the hot set stays tiny and (c) stays pure.

## Validation

* `outputs` carries no display/basket metadata; `spendable` is keys-only.
* Coin selection enters through `spendable`, PK-joining to `outputs`.
* Single-spend is enforced by `UNIQUE(inputs.output_id)`; spendability is read structurally, not from a flag.

## References

* ADR-003 — derived state (spendability is structural, not stored; the UNIQUE-as-lock driver).
* ADR-002 — the scale target that makes the hot-path partition worth it.
* ADR-010 — derivation on `outputs`; keeping data off `spendable`.
* ADR-011 — outputs as the immutable log this partition produces.
* `reference/principle-of-state.md` — the living statement of derived state and set-membership spendability.
* `reference/schema-intent.md` — per-primitive schema rationale.
* `gem/bsv-wallet/db/migrations/001_create_schema.rb` — the `outputs`, `spendable`, and `inputs` tables.

## Unverified claims

None.
