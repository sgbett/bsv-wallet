# ADR-005: Accounting ledger, not transaction DAG

## Status

Accepted.

**Decided:** 2026-05-05 (commit `d08edd3`, "feat: PostgreSQL schema, migration, and Sequel models", HLR #1) — the ledger model (outputs as ledger entries, `inputs` as debits, the DAG derivable but not the primary model) is fixed by the original schema; no adjacency-list or closure structures were ever introduced.

## Context

A wallet could model the full transaction DAG — every output traced back through its spending chain toward its origin. That is what a *node* needs: to decide a UTXO is valid, walk the graph. A wallet's question is different — "what can I spend, and what did I spend it on?" — which is double-entry bookkeeping, not graph traversal. And merkle proofs remove the need to walk at all: a proof shows a transaction is in a block, so each settled output stands as an independent fact. The "Back to Genesis" ancestry walk is unnecessary.

## Decision Drivers

* The wallet's queries are filtered aggregates ("balance of basket X", "my spendable outputs"), not ancestry walks.
* Merkle proofs make each settled output a standalone fact; the DAG need not be traversed to trust it.
* A node validates by walking the graph; a wallet accounts for its own slice of it.

## Decision

Model the wallet as an accounting ledger. Outputs are the ledger entries — credits created, debits consumed via `inputs`; an action is the event that creates and consumes them; balance is the sum of unspent credits. The transaction DAG is *derivable* — the edges exist as `outputs.action_id` (the creating action) and `inputs` (the consuming action), so a spending chain can be reconstructed if one ever needs auditing — but it is not the primary model, and nothing is optimised for traversing it. The schema is optimised for what BRC-100 actually asks: list the outputs in a basket, compute a balance, lock UTXOs for spending.

## Alternatives Considered

### A. Model the DAG explicitly (adjacency list / recursive CTEs)
**Rejected.** That is a node's concern. The wallet runs filtered aggregates, not graph walks, and merkle proofs remove the need to validate by ancestry.

### B. Transaction-centric model — the transaction as the primary entity
**Rejected.** In Bitcoin the UTXO is the ledger entry and the transaction is the transformation function. Outputs are the primary entity (ADR-004); actions are the events around them.

## Consequences

### Positive
* The common queries are filtered aggregates over small tables, not recursive walks.
* The DAG remains reconstructable from the `outputs.action_id` / `inputs` edges when genuinely needed.
* The model matches an SPV wallet's actual workload.

### Negative
* Auditing a full spending chain is a deliberate, occasional reconstruction, not a first-class operation.

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

Modelling the DAG would be over-engineering for a wallet — solving a node's problem the wallet doesn't have, at the cost of every common query. The ledger model is both simpler and faster for the real workload, with the graph still derivable for the rare audit. **Approve.**

## Validation

* The schema carries no adjacency-list or closure structures for transaction ancestry.
* Balance, basket listing, and coin selection are filtered aggregates.
* A spending chain can still be reconstructed from `outputs.action_id` and `inputs`.

## References

* ADR-004 — outputs as the primary entity (the ledger entries).
* ADR-003 — derived state.
* `reference/schema.md`.
