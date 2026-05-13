# Changelog

## [0.100.0] - 2026-05-13

First release of the Ruby BRC-100 wallet — ground-up implementation.

### Added
- **BRC-100 Engine** — full transaction lifecycle: createAction, signAction, internalizeAction, abortAction, listActions, listOutputs, relinquishOutput
- **Key derivation** — BRC-42 ECDH key derivation, BRC-43 symmetric encryption, HMAC, ECDSA sign/verify
- **Certificates** — BRC-52 identity certificates with field-level encryption and selective revelation
- **Auto-funded transactions** — UTXO selection, fee estimation, change outputs with split-eagerness
- **SPV verification** — incoming BEEF validated via SDK `Transaction#verify` with chain tracker
- **BSV::Network::ChainTracker** — write-through block header cache (DB + network services)
- **BSV::Network::Services** — porcelain routing layer with fallback, rate limiting, response normalization
- **Pushable/Fetchable modules** — entity-driven network interaction for broadcast and proof lifecycle
- **Daemon** — background polling loop driving push!/fetch! on unresolved entities
- **UTXOPool** — sizing strategy with limp mode safety threshold
- **Porcelain CLI** — bin/create, bin/receive, bin/import, bin/send_payment
- **wtxid/dtxid convention** — binary wire-order internally, display hex at boundaries

## [0.1.0] - 2026-04-24

### Added

- BRC-100 wallet interface module (`BSV::Wallet`)
- Gem scaffolding
