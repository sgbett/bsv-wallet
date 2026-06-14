# ADR-004: Outputs/spendable vertical partition, and the inputs table as the lock

## Status

Accepted.

## Context

The wallet's value lives in its outputs, and the outputs table is the hot path — coin selection scans it constantly. Loading every attribute onto that table (and indexing them) turns the hottest table into the bottleneck: wider rows, fewer per page, write latency on each index. At the same time, "can I spend this?" is asked far more often than "what are this output's display details?", and the two have very different access patterns.

So the output is not one row in one table. It is split: an immutable core, a tiny set that says what is spendable now, satellite tables for the rest, and a separate table for the spend relationship.

## Decision Drivers

* Coin selection is the hot path; its scan target must stay narrow (ADR-002).
* "Spendable now" is a small, high-churn working set; output history is large and cold.
* Single-spend must be guaranteed without an application-level lock.
* The spend relationship has its own attributes that belong to neither the output nor the action.

## Decision

**Partition the output vertically.** `outputs` is the immutable core (action, satoshis, vout, locking script, derivation, type). `spendable` is the UTXO set — pure set membership, `{id, output_id, action_id}`, no data columns. `output_details` and `output_baskets` hold display/application metadata and basket membership. The hot path scans the tiny `spendable` table and PK-joins back to `outputs` only for the data it needs. The shorthand: **outputs is the log; spendable is the wallet.**

**The `inputs` table is the lock.** Claiming an output to spend is an INSERT into `inputs`; `UNIQUE(output_id)` makes a double-spend structurally impossible. Concurrent claims resolve in PostgreSQL via `INSERT … ON CONFLICT (output_id) DO NOTHING RETURNING` — the loser's row simply isn't returned, and its transaction rolls back. No Ruby mutex, no `SELECT … FOR UPDATE`.

**Spendability is derived, not stored** (per ADR-003): an output is spendable iff a `spendable` row exists and no `inputs` row claims it. The presence/absence of rows *is* the state.

## Alternatives Considered

### A. One wide "kitchen-sink" outputs table
Every attribute and its indexes on one row. **Rejected** — it makes the hottest, most-scanned table the bottleneck and forces the hot path to drag data it never reads.

### B. A `spending_transaction_id` (or `spent_by`) FK on the output
Record the consuming transaction on the output itself. **Rejected** — a category error: *being consumed* is a property of the input relationship, not of the output, and it would be a mutable column on the immutable log. The `inputs` table also gives the relationship's own attributes (`vin`, `nsequence`, description) a home they otherwise lack.

### C. Application-level locking for single-spend (mutex / `SELECT … FOR UPDATE`)
**Rejected** — `UNIQUE(output_id)` + `ON CONFLICT` resolves contention structurally in the database, with recovery ergonomics identical to the UPDATE approach but yielding a proper `inputs` table as the by-product.

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

The partition is justified by the hot path (ADR-002): at small scale a wide table would serve, but the split is cheap and buys the log/wallet separation and structural single-spend at once. The inputs-as-lock is the elegant move — contention handled by a `UNIQUE` constraint rather than application code, which is strictly less to get wrong. **Approve.** The only thing to guard is keeping data columns *off* `spendable` (ADR-010) so the hot set stays tiny.

## Validation

* `outputs` carries no display/basket metadata; `spendable` is keys-only.
* Coin selection enters through `spendable`, PK-joining to `outputs`.
* Single-spend is enforced by `UNIQUE(inputs.output_id)`; spendability is read structurally, not from a flag.

## References

* ADR-003 — derived state (spendability is structural, not stored).
* ADR-002 — the scale target that makes the hot-path partition worth it.
* ADR-011 — outputs as the immutable log this partition produces.
* `reference/schema.md`.
