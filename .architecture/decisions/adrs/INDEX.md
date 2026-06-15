# ADR index — by decision date

The ADRs in this directory are reconstructed decision records. **The filename number is an immutable ID, not a position in time** — ADR-019 was decided before ADR-018, ADR-021 before ADR-010, and so on. This index is the chronological view: each ADR ordered by its `**Decided:**` line (the date of its *latest* recorded decision).

Conventions in force (see `.claude/plans/20260614-adr-reorganisation.md`):

- **Numbers are stable IDs.** No renumbering in this pass; re-ordering by number is deferred to a later step now that every ADR is dated.
- **Filenames are date-prefixed** — `YYYYMMDD_ADR-NNN-slug.md`, so the directory lists chronologically while `ADR-NNN` stays the immutable ID. The date is the ADR's **authoring** date going forward (ADRs begin as Draft, written at decision time); the reconstructed ADR-001..024 raft was backdated to each decision's date — a one-off exception, since those decisions predated their write-up — not the forward rule. Split ADRs (011, 015) carry distinct prefixes for their two (decision) dates.
- **Same-time decisions** share one ADR, labelled (a)/(b)/(c) (e.g. ADR-004, ADR-008, ADR-013).
- **Different-time decisions** are split into one file per decision, sharing the parent number by slug (ADR-011 → delete / promotion; ADR-015 → pivot / egress).
- A changed decision is recorded as a **new** dated ADR that supersedes the old one; decisions are not edited in place (only corrections and the Status line).

| # | ADR | Decided | Status | Theme |
|---|-----|---------|--------|-------|
| 1 | [ADR-001](20260430_ADR-001-clean-room-schema-first.md) | 2026-04-30 | Accepted | Clean-room rebuild; the schema is the primary artefact |
| 2 | [ADR-002](20260505_ADR-002-design-for-scale-wallet-node.md) | 2026-05-05 | Accepted | Design for BSV scale; the wallet-node model |
| 3 | [ADR-003](20260505_ADR-003-schema-as-canonical-state.md) | 2026-05-05 | Accepted | Schema as canonical state (the principle of state) |
| 4 | [ADR-004](20260505_ADR-004-outputs-spendable-partition.md) | 2026-05-05 | Accepted | (a) outputs/spendable partition · (b) inputs-as-the-lock · (c) spendable-as-a-FK-row |
| 5 | [ADR-005](20260505_ADR-005-accounting-ledger-not-dag.md) | 2026-05-05 | Accepted | Accounting-ledger model, not a transaction DAG |
| 6 | [ADR-006](20260505_ADR-006-single-relational-store.md) | 2026-05-05 | Accepted | One relational store, one ACID boundary |
| 7 | [ADR-007](20260505_ADR-007-single-tenant-no-user-table.md) | 2026-05-05 | Accepted | Single-tenant engine, no user table |
| 8 | [ADR-008](20260505_ADR-008-binary-internal-hex-at-boundaries.md) | 2026-05-05 | Accepted | (a) binary internally, hex at boundaries · (b) identity-pubkey carve-out |
| 9 | [ADR-009](20260505_ADR-009-postgres-native-primitives.md) | 2026-05-05 | Accepted | Postgres-native primitives over a portable subset |
| 10 | [ADR-021](20260505_ADR-021-brc100-interface-design.md) | 2026-05-05 | Accepted | BRC-100 interface as a plain Ruby module over the schema |
| 11 | [ADR-020](20260505_ADR-020-test-taxonomy.md) | 2026-05-05 | Draft | Test taxonomy — engine-intent vs store-invariant |
| 12 | [ADR-010](20260506_ADR-010-derivation-placement-output-type.md) | 2026-05-06 | Accepted | Derivation data on outputs; the inference ban |
| 13 | [ADR-014](20260506_ADR-014-import-as-rescue-self-pay-derived.md) | 2026-05-06 | Accepted | output_type ENUM / root; import-as-rescue, self-pay to a derived address |
| 14 | [ADR-015 (pivot)](20260513_ADR-015-chain-tracker-pivot.md) | 2026-05-13 | Accepted | Chain-tracker pivot to the SDK's `Transaction::Tx#verify` |
| 15 | [ADR-017](20260514_ADR-017-wbikd-legacy-receive-addresses.md) | 2026-05-14 | Draft | Legacy receive addresses via WBIKD, on existing machinery |
| 16 | [ADR-012](20260523_ADR-012-store-abstraction.md) | 2026-05-23 | Accepted | Store abstraction over a relational floor |
| 17 | [ADR-016](20260523_ADR-016-walletd-daemon-omq-concurrency.md) | 2026-05-23 | Accepted | walletd daemon + ZeroMQ/OMQ concurrency |
| 18 | [ADR-011 (promotion)](20260527_ADR-011-post-broadcast-promotion.md) | 2026-05-27 | Superseded by ADR-023 | Post-broadcast promotion: a one-shot UPDATE on outputs |
| 19 | [ADR-013](20260527_ADR-013-auto-fund-create-action.md) | 2026-05-27 | Accepted | Auto-funding createAction (selection, fees, change) |
| 20 | [ADR-019](20260527_ADR-019-broadcasts-intent-declarative-enforcement.md) | 2026-05-27 | Accepted | broadcasts-intent: a cross-table invariant kept declarative in the schema |
| 21 | [ADR-011 (delete)](20260530_ADR-011-delete-unpromoted-outputs.md) | 2026-05-30 | Accepted | Failure-bounded DELETE of unpromoted outputs |
| 22 | [ADR-024](20260607_ADR-024-engine-decomposition-deferred-sends.md) | 2026-06-07 | Accepted | Decompose the Engine — precondition for restoring the deferred sends (#291) |
| 23 | [ADR-015 (egress)](20260610_ADR-015-egress-beef-validation.md) | 2026-06-10 | Accepted | Egress-BEEF validation — never ship an invalid BEEF |
| 24 | [ADR-018](20260610_ADR-018-stateless-sdk-stateful-wallet-boundary.md) | 2026-06-10 | Accepted | Stateless SDK / stateful wallet boundary |
| 25 | [ADR-022](20260610_ADR-022-state-as-a-fk-row.md) | 2026-06-10 | Accepted | State as a FK row (the general membership-row pattern) |
| 26 | [ADR-023](20260615_ADR-023-promotion-as-a-row.md) | 2026-06-15 | Accepted | Promotion is a row, not a column (supersedes ADR-011 promotion) |
