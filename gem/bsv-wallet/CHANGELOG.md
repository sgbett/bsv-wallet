# Changelog

## Unreleased

### Schema (breaking, pre-release)

- Removed `outputs.output_type` column. Spendability intent now expressed by
  new `outputs.spendable_intent` ENUM (`'spendable' | 'none'`). See HLR #467
  and `docs/reference/intent-and-outcomes.md`.
- Per-wallet DB CHECK on outputs enforces structural recoverability — the
  WIF-derived root P2PKH script is baked into the constraint at migration
  time. Spendable outputs must either carry derivation controls or match
  the root P2PKH pattern literally.
- `prevent_outbound_spendable` trigger removed; replaced declaratively via
  composite FK + CHECK on `spendable`. No triggers on the hot path
  (see `docs/reference/hot-path-design.md`).
- Operators with pre-existing test DBs must DROP and recreate them.

### Changed (breaking)

- **`list_actions` response shape: derived status `:nosend` renamed to
  `:internal`** (#195, part of HLR #183). Actions whose `broadcast` is
  `'none'` — incoming BEEF, imported root UTXOs, wbikd locks,
  `send_payment` — now report `status: :internal` in the `list_actions`
  response. The old `:nosend` value is no longer emitted. Callers reading
  `:status` from `list_actions` must update accordingly. Disambiguates
  the internal non-network lifecycle from BRC-100's chained-send
  `noSend` primitive, which is deferred to #192.

### Changed

- **Send-path output promotion restored to Phase 4** (#194, part of
  HLR #183). The send path (`broadcast IN ('delayed', 'inline')`) no
  longer promotes outputs to the canonical UTXO set at sign time.
  Outputs are persisted at sign time with `promoted = false`; the flag
  flips to `true` (and spendable rows are inserted) only when ARC
  returns an accepted status. The internal path
  (`broadcast == 'none'`) continues to promote synchronously inside
  `create_action`. The `outputs` table gains a `promoted` boolean
  column; existing rows backfill as `promoted = true`.
- **`outputs.action_id` FK is RESTRICT** (#189, part of HLR #183).
  Outputs cannot be orphaned by an action delete; cleanup paths
  (`abort_action`, `fail_broadcast_action`, reaper) clear dependent
  rows before the action delete.

### Removed (breaking)

- **BRC-100 chained-send API surface stripped** (#193, part of HLR #183).
  The `no_send_change`, `send_with`, and `known_txids` keyword arguments
  are no longer accepted on `create_action` / `sign_action`.
  `Engine#process_send_with` is removed. (`known_txids` is still
  accepted on `internalize_action`, where it serves the `trustSelf`
  SPV-pruning role and is unrelated to chained-send.) The chained-send
  subsystem (persistent batch entity, `noSend` chain extension,
  `sendWith` flushing) is deferred to issue #192. The `no_send` keyword
  remains on the public API and routes the action onto the internal
  path; the `no_send_change` key in the `create_action` result hash is
  also retained.

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
