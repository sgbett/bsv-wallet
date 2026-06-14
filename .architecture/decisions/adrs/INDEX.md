# ADR index — by decision date

The ADRs in this directory are reconstructed decision records. **The filename number is an immutable ID, not a position in time** — ADR-019 was decided before ADR-018, ADR-021 before ADR-010, and so on. This index is the chronological view: each ADR ordered by its `**Decided:**` line (the date of its *latest* recorded decision).

Conventions in force (see `.claude/plans/20260614-adr-reorganisation.md`):

- **Numbers are stable IDs.** No renumbering in this pass; re-ordering by number is deferred to a later step now that every ADR is dated.
- **Same-time decisions** share one ADR, labelled (a)/(b)/(c) (e.g. ADR-004, ADR-008, ADR-013).
- **Different-time decisions** are split into one file per decision, sharing the parent number by slug (ADR-011 → delete / promotion; ADR-015 → pivot / egress).
- A changed decision is recorded as a **new** dated ADR that supersedes the old one; decisions are not edited in place (only corrections and the Status line).

| # | ADR | Decided | Status | Theme |
|---|-----|---------|--------|-------|
| 1 | [ADR-001](ADR-001-clean-room-schema-first.md) | 2026-04-30 | Accepted | Clean-room rebuild; the schema is the primary artefact |
| 2 | [ADR-002](ADR-002-design-for-scale-wallet-node.md) | 2026-05-05 | Accepted | Design for BSV scale; the wallet-node model |
| 3 | [ADR-003](ADR-003-schema-as-canonical-state.md) | 2026-05-05 | Accepted | Schema as canonical state (the principle of state) |
| 4 | [ADR-004](ADR-004-outputs-spendable-partition.md) | 2026-05-05 | Accepted | (a) outputs/spendable partition · (b) inputs-as-the-lock · (c) spendable-as-a-FK-row |
| 5 | [ADR-005](ADR-005-accounting-ledger-not-dag.md) | 2026-05-05 | Accepted | Accounting-ledger model, not a transaction DAG |
| 6 | [ADR-006](ADR-006-single-relational-store.md) | 2026-05-05 | Accepted | One relational store, one ACID boundary |
| 7 | [ADR-007](ADR-007-single-tenant-no-user-table.md) | 2026-05-05 | Accepted | Single-tenant engine, no user table |
| 8 | [ADR-008](ADR-008-binary-internal-hex-at-boundaries.md) | 2026-05-05 | Accepted | (a) binary internally, hex at boundaries · (b) identity-pubkey carve-out |
| 9 | [ADR-009](ADR-009-postgres-native-primitives.md) | 2026-05-05 | Accepted | Postgres-native primitives over a portable subset |
| 10 | [ADR-021](ADR-021-brc100-interface-design.md) | 2026-05-05 | Accepted | BRC-100 interface as a plain Ruby module over the schema |
| 11 | [ADR-010](ADR-010-derivation-placement-output-type.md) | 2026-05-06 | Accepted | Derivation data on outputs; the inference ban |
| 12 | [ADR-014](ADR-014-import-as-rescue-self-pay-derived.md) | 2026-05-06 | Accepted | output_type ENUM / root; import-as-rescue, self-pay to a derived address |
| 13 | [ADR-015 (pivot)](ADR-015-chain-tracker-pivot.md) | 2026-05-13 | Accepted | Chain-tracker pivot to the SDK's `Transaction::Tx#verify` |
| 14 | [ADR-017](ADR-017-wbikd-legacy-receive-addresses.md) | 2026-05-14 | Draft | Legacy receive addresses via WBIKD, on existing machinery |
| 15 | [ADR-012](ADR-012-store-abstraction.md) | 2026-05-23 | Accepted | Store abstraction over a relational floor |
| 16 | [ADR-016](ADR-016-walletd-daemon-omq-concurrency.md) | 2026-05-23 | Accepted | walletd daemon + ZeroMQ/OMQ concurrency |
| 17 | [ADR-011 (promotion)](ADR-011-post-broadcast-promotion.md) | 2026-05-27 | Accepted — promote-authorisation open (#307) | Post-broadcast promotion: a one-shot UPDATE on outputs |
| 18 | [ADR-013](ADR-013-auto-fund-create-action.md) | 2026-05-27 | Accepted | Auto-funding createAction (selection, fees, change) |
| 19 | [ADR-019](ADR-019-broadcasts-intent-declarative-enforcement.md) | 2026-05-27 | Accepted | broadcasts-intent: a cross-table invariant kept declarative in the schema |
| 20 | [ADR-011 (delete)](ADR-011-delete-unpromoted-outputs.md) | 2026-05-30 | Accepted | Failure-bounded DELETE of unpromoted outputs |
| 21 | [ADR-015 (egress)](ADR-015-egress-beef-validation.md) | 2026-06-10 | Accepted | Egress-BEEF validation — never ship an invalid BEEF |
| 22 | [ADR-018](ADR-018-stateless-sdk-stateful-wallet-boundary.md) | 2026-06-10 | Accepted | Stateless SDK / stateful wallet boundary |
| 23 | [ADR-022](ADR-022-state-as-a-fk-row.md) | 2026-06-10 | Accepted | State as a FK row (the general membership-row pattern) |
| 24 | [ADR-020](ADR-020-test-taxonomy.md) | 2026-06-14 | Draft | Test taxonomy — engine-intent vs store-invariant |
