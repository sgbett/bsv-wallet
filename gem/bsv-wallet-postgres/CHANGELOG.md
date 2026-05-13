# Changelog

## [0.100.0] - 2026-05-13

First release of the PostgreSQL adapter for the Ruby BRC-100 wallet.

### Added
- **Schema** — actions, outputs, inputs, spendable, baskets, labels, tags, certificates, tx_proofs, blocks, broadcasts
- **Store** — full BRC-100 action lifecycle: create, sign, promote, abort, reap, list, query
- **ProofStore** — merkle proof persistence with block normalization
- **UTXOPool** — UTXO selection with sizing strategy and limp mode
- **BroadcastQueue** — broadcast lifecycle management
- **Pushable/Fetchable** — Broadcast and Action adopt entity-driven network interaction
- **Migrations** — sequential schema migrations with constraint enforcement
- **Database trigger** — prevents outbound outputs from entering the spendable set

### Changed
- **blocks table** — normalized from tx_proofs; stores block headers independently
- **tx_reqs removed** — replaced by structural queries via Fetchable pattern

## [0.1.0] - 2026-05-01

### Added

- Initial 17-table PostgreSQL schema migration
- Sequel models for all wallet tables
- Connection management module
