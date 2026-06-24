# BRC-100 conformance register

A living register of every BRC-100 concept and our stance on it. Companion to [`core-vs-conformance.md`](core-vs-conformance.md), which states the load-bearing principle this register applies. The register is the per-element classification; the principle is what governs each row.

Stance values:

- **Implemented (core)** — the concept maps to a wallet operation that lives in the Engine/Store. Native first-class behaviour.
- **Boundary-only** — the spec parameter or shape is accepted at `BSV::Wallet::BRC100`, translated or stubbed, and not propagated into the Engine.
- **Diverged** — we implement the concept but with semantics tuned to our single-tenant deployment. Spec contract honoured at the wire; internal behaviour differs from the spec's presumed reference model.
- **Deferred** — accepted at the boundary as a stub or no-op; full machinery not built. The path to implementation, if/when it becomes load-bearing, is recorded.
- **Amputated** — absent from the wallet entirely. The concept has no operational equivalent in our deployment model.

This document is intended to be edited as positions move between categories. A concept that starts deferred and is later built moves to implemented or boundary-only with the original entry preserved in the change log at the bottom.

## Cryptographic operations

| Method | Stance | Notes |
|---|---|---|
| `encrypt` / `decrypt` | Implemented (core) | Engine primitives over `@key_deriver` (AES-GCM symmetric, BRC-2). |
| `createHmac` / `verifyHmac` | Implemented (core) | Engine primitives over `@key_deriver` (BRC-56). |
| `createSignature` / `verifySignature` | Implemented (core) | Engine primitives over `@key_deriver` (BRC-3). |

These are the indivisible-verb 1:1 primitives ratified by ADR-026. Conformance wraps each in BRC-100 hash-vocabulary shape; the Engine speaks wallet vocab.

## Public keys and identity

| Method / param | Stance | Notes |
|---|---|---|
| `getPublicKey` | Implemented (core) | Engine `#get_public_key`. Identity-shaped pubkeys returned as hex (ADR-008); derived pubkeys returned as binary. |
| `protocolID` / `keyID` | Implemented (core) | BRC-43 derivation parameters. Pass through to `@key_deriver`. |
| `counterparty` (self / anyone / hex) | Implemented (core) | BRC-43 counterparty rules. Identity-shaped pubkey hex carve-out preserves the spec's wire form. |
| `forSelf` | Implemented (core) | Self-derivation flag. |
| `privileged` / `privilegedReason` | Deferred | Accepted at the boundary, no privilege escalation machinery (no permission UI to escalate through). When BRC-116 lands, becomes a permission check. |

## Certificates

| Method | Stance | Notes |
|---|---|---|
| `acquireCertificate` / `listCertificates` | Implemented (core) | Engine primitives; `certificates` and `certificate_fields` tables canonical (BRC-52 interchange in hex per ADR-008's identity-pubkey carve-out rationale). |
| `proveCertificate` | Implemented (core) | Engine primitive; selective field disclosure via BRC-52. |
| `relinquishCertificate` | Implemented (core) | Removes certificate from wallet's tracked set. |
| `discoverByIdentityKey` / `discoverByAttributes` | Implemented (core) | Engine primitives; remote certificate discovery via configured network services. |

## Key linkage revelation

| Method | Stance | Notes |
|---|---|---|
| `revealCounterpartyKeyLinkage` | Implemented (core) | BRC-69 method 1, BRC-72 protection. Engine primitive. |
| `revealSpecificKeyLinkage` | Implemented (core) | BRC-69 method 2, BRC-72 protection. Engine primitive. Includes BRC-97 proof-type for future ZKP schemes. |

## Action lifecycle

| Method | Stance | Notes |
|---|---|---|
| `createAction` | Implemented (core) | Engine `#build_action`. Funding strategy, fee model, change generation (ADR-013). Returns `signableTransaction` for deferred-sign path (ADR-024 forward direction). |
| `signAction` | Implemented (core) | Engine `#sign_action`. |
| `internalizeAction` | Implemented (core) | Engine `#internalize_action`. Both `wallet payment` (BRC-29) and `basket insertion` protocols. |
| `abortAction` | Implemented (core) | Failure-bounded delete of unpromoted outputs (ADR-011 delete). |
| `listActions` | Implemented (core) | Engine `#list_actions`. Status derived from structural state per principle-of-state. |
| `listOutputs` | Implemented (core) | Engine `#list_outputs`. Basket-scoped query, BRC-100 contract honoured at the wire (untracked outputs not surfaced). |
| `relinquishOutput` | Implemented (core) | Removes from `spendable`; output row preserved. |

### Action lifecycle parameters

| Parameter | Stance | Notes |
|---|---|---|
| `inputs` / `outputs` | Implemented (core) | Action construction. |
| `inputBEEF` | Implemented (core) | Ancestry import via `Engine::BeefImporter`. |
| `description` | Implemented (core) | `actions.description` column. |
| `labels` (on action) | Implemented (core) | `tx_labels` / `tx_labels_map` tables. |
| `tags` (on output) | Implemented (core) | `output_tags` / `output_tags_map` tables. |
| `basket` (per output) | Diverged | See "Basket semantics" below. |
| `customInstructions` (per output) | Implemented (core) | Column on `outputs`. |
| `outputDescription` (per output) | Implemented (core) | Column on `outputs`. |
| `knownTxids` | Implemented (core) | Ancestry import optimisation; the parameter name `txids` is BRC-100 spec vocabulary at the boundary, values are wire-order wtxids internally. |
| `noSend` / `sendWith` | Deferred | Engine decomposition precondition complete (ADR-024); restoration tracked by #192. The lifecycle exists structurally; the deferred-send orchestration on top is the missing piece. |
| `acceptDelayedBroadcast` | Implemented (core) | Maps to declarative broadcast intent (ADR-019). |
| `randomizeOutputs` | Implemented (core) | Boundary shuffle before signing. |
| `include` (`'locking scripts'` / `'entire transactions'`) | Implemented (core) | Result shape control for `listOutputs`. |
| `includeCustomInstructions` / `includeTags` / `includeLabels` | Implemented (core) | Result shape control flags. |

### Basket semantics — the divergence

The spec contract says: outputs created without `basket` are not surfaced by `listOutputs`. We honour this at the wire. Internally, however, every output is recorded in the `outputs` table; the `basket` column is a categorisation axis, not a tenancy axis. Multi-tenant wallets in the reference implementation use `basket` as a per-app sandbox key (with `userId` as the per-user partition). We have neither. For us, basket is what the application chose to name its outputs by, and the "untracked" behaviour is enforced as a query-time filter at the conformance layer, not as an absence in the storage layer.

This is a divergence in internal semantics with full external conformance.

## Chain queries

| Method | Stance | Notes |
|---|---|---|
| `getHeight` | Implemented (core) | Via configured chain tracker (ADR-015 pivot). |
| `getHeaderForHeight` | Implemented (core) | Same. |
| `getNetwork` | Implemented (core) | `'mainnet'` / `'testnet'` from wallet configuration. |
| `getVersion` | Implemented (core) | Wallet version reporting. |

## Authentication

| Method | Stance | Notes |
|---|---|---|
| `isAuthenticated` | Implemented (core), trivially | Always `true` for a constructed Engine — having the WIF is being authenticated. |
| `waitForAuthentication` | Implemented (core), trivially | Returns immediately. The BRC-100 reference assumes an authentication step where the wallet is unlocked by user action; we have no lock state, so the wait is a no-op. |

The spec's authentication model presupposes a lock-screen / unlock UI. We replace it with WIF-at-construction: if you constructed the Engine, you authenticated.

## Cross-cutting parameters

| Parameter | Stance | Notes |
|---|---|---|
| `originator` | Boundary-only | Accepted on every BRC-100 method, dropped at the boundary. Forward direction: DBAP-style permission tokens in admin baskets when implemented (originator ADR). |
| `seekPermission` | Boundary-only | Accepted, no-op'd. We have no permission UI to seek from. Will become meaningful when BRC-116 lands. |
| `OriginatorDomainNameString` validation | Boundary-only | Format validation at the conformance layer (FQDN shape) where present; no behavioural use. |
| Hash-vocabulary return shapes (`{ txid:, tx: }` etc.) | Boundary-only | Conformance translates wallet vocab returns into BRC-100 hash shapes. ADR-026 codifies this. |
| Spec-shape input validation | Boundary-only | Length limits, format constraints, reserved-name checks all enforced at the conformance layer. Engine assumes valid input. |
| `userId` (implied) | Amputated | No `users` table, no `user_id` column anywhere. Identity is the WIF (ADR-007). Forward direction: per-user databases (per-user-databases ADR). |

## Reserved names

BRC-100 reserves several name patterns. We enforce them at the conformance layer to prevent forward-incompatible adoption by application callers, even where we don't implement the corresponding machinery.

| Pattern | Concern | Stance |
|---|---|---|
| Basket names starting with `admin` (BRC-99) | Reserved for wallet-internal use (e.g. wallet-toolbox uses `admin basket-access` for DBAP tokens). | Boundary-only — reject from the public API. Reserved for future originator/DBAP work. |
| Basket name `default` | Historically used by some wallets for internal operations. | Boundary-only — reject from the public API. |
| Basket names starting with `p ` (BRC-99) | Reserved for future specially-permissioned baskets. | Boundary-only — reject from the public API. |
| Protocol IDs starting with `admin` (BRC-98) | Reserved for wallet-internal use. | Boundary-only — reject from the public API. |
| Protocol IDs starting with `p ` (BRC-98) | Reserved for future specially-permissioned protocols. | Boundary-only — reject from the public API. |
| Basket names trailing ` basket` | Redundant suffix. | Boundary-only — reject from the public API. |
| Protocol IDs trailing ` protocol` | Redundant suffix. | Boundary-only — reject from the public API. |

Tracked HLR: BRC-100 basket-name validation (this branch's spawned issue).

### Basket length limit — note a spec inconsistency

BRC-100 §"Rules for Basket Names" says basket names must be ≤ **400 characters**. The TS type `BasketStringUnder300Characters` used on every basket-bearing field says ≤ **300 characters**. The two are in tension within the spec itself.

We adopt **300** as the binding limit, on the grounds that the TS type is what conformant callers will validate their inputs against. The discrepancy is worth raising upstream against the BRCs repository at some point, but the practical position is unambiguous: 300 wins.

## Permission machinery (BRC-116)

| Concept | Stance | Notes |
|---|---|---|
| Per-originator basket access (DBAP) | Deferred | Direction recorded in the originator ADR: PushDrop tokens in an `admin basket-access` basket, mirroring wallet-toolbox. |
| Per-originator protocol access (DPACP) | Deferred | Same mechanism, `admin protocol-permission` basket. |
| Per-originator certificate access (DCAP) | Deferred | Same mechanism, `admin certificate-access` basket. |
| Per-originator spending authorisation (DSAP) | Deferred | Same mechanism, `admin spending-authorization` basket. |
| Grouped permission requests | Deferred | Surface added when DBAP lands. |
| Counterparty trust grants | Deferred | Surface added when DBAP lands. |
| `onXxxRequested` callbacks | Amputated | No permission UI. If a host UI ever wraps the wallet, it owns its own prompting; the wallet does not export callback hooks. |

## Application identity model

| Concept | Stance | Notes |
|---|---|---|
| App discovery / `manifest.json` interaction | Amputated | No multi-app surface. |
| Per-origin sandboxing | Amputated | No application boundary inside the wallet; the consumer is whoever holds the WIF. |
| Per-origin storage namespace | Amputated | One wallet's outputs are one wallet's outputs. No per-origin partition. |
| `displayOriginator` (UI hint) | Amputated | No UI. |

## How to read this register

When a BRC-100-shaped change arrives — a new method call from a consumer, a parameter we hadn't seen, a return shape mismatch — find the entry. If absent, add one. The register is the authoritative answer to "do we handle this, and how?" so that we don't re-derive the rationale every time it comes up.

When a deferred concept becomes load-bearing, move the entry to its new stance, link the implementation issue/ADR, and preserve the original rationale in a `<details>` block under the entry. This document is the trail of decisions, not a one-shot snapshot.

## Related

- [`core-vs-conformance.md`](core-vs-conformance.md) — the principle governing every classification here.
- ADR (this branch) — core-vs-conformance as a decision record.
- ADR-007 — single-tenant engine; one row in the "Amputated" column.
- ADR-021 — BRC-100 interface design; the conformance layer's shape.
- ADR-026 — Engine primitive surface; the boundary discipline at the primitive level.
- `docs/reference/external/BRC100.md` — the 28-method specification (in-tree copy).
- BRC-116 — the permission framework we currently defer (canonical at the [BRCs repository](https://github.com/bitcoin-sv/BRCs/blob/master/wallet/0116.md)).

## Change log

- *2026-06-24* — Initial register. All categorisations recorded against the wallet's state at this date; subsequent moves between stances will be logged here.
