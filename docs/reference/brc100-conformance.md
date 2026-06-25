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

| BRC-100 method | Engine primitive | Stance | Notes |
|---|---|---|---|
| `encrypt` / `decrypt` | `engine.encrypt` / `engine.decrypt` | Implemented (core) | Over `@key_deriver` (AES-GCM symmetric, BRC-2). |
| `createHmac` / `verifyHmac` | `engine.create_hmac` / `engine.verify_hmac` | Implemented (core) | Over `@key_deriver` (BRC-56). |
| `createSignature` / `verifySignature` | `engine.create_signature` / `engine.verify_signature` | Implemented (core) | Over `@key_deriver` (BRC-3). |

These are the indivisible-verb 1:1 primitives ratified by ADR-026. Conformance wraps each in BRC-100 hash-vocabulary shape; the Engine speaks wallet vocab.

## Public keys and identity

| BRC-100 method / param | Engine primitive | Stance | Notes |
|---|---|---|---|
| `getPublicKey` | `engine.get_public_key` | Implemented (core) | Identity-shaped pubkeys returned as hex (ADR-008); derived pubkeys returned as binary. |
| `protocolID` / `keyID` | — (kwargs) | Implemented (core) | BRC-43 derivation parameters. Pass through to `@key_deriver`. |
| `counterparty` (self / anyone / hex) | — (kwarg) | Implemented (core) | BRC-43 counterparty rules. Identity-shaped pubkey hex carve-out preserves the spec's wire form. |
| `forSelf` | — (kwarg) | Implemented (core) | Self-derivation flag. |
| `privileged` / `privilegedReason` | — (kwarg) | Deferred | Accepted at the boundary, no privilege escalation machinery (no permission UI to escalate through). When BRC-116 lands, becomes a permission check. |

## Certificates

| BRC-100 method | Engine primitive | Stance | Notes |
|---|---|---|---|
| `acquireCertificate` | `engine.acquire_certificate` | Implemented (core) | `certificates` / `certificate_fields` tables canonical (BRC-52 interchange in hex per ADR-008's identity-pubkey carve-out rationale). |
| `listCertificates` | `engine.list_certificates` | Implemented (core) | Same. |
| `proveCertificate` | `engine.prove_certificate` | Implemented (core) | Selective field disclosure via BRC-52. |
| `relinquishCertificate` | `engine.relinquish_certificate` | Implemented (core) | Removes certificate from wallet's tracked set. |
| `discoverByIdentityKey` | `engine.discover_by_identity_key` | Implemented (core) | Remote certificate discovery via configured network services. |
| `discoverByAttributes` | `engine.discover_by_attributes` | Implemented (core) | Same. |

## Key linkage revelation

| BRC-100 method | Engine primitive | Stance | Notes |
|---|---|---|---|
| `revealCounterpartyKeyLinkage` | `engine.reveal_counterparty_key_linkage` | Implemented (core) | BRC-69 method 1, BRC-72 protection. |
| `revealSpecificKeyLinkage` | `engine.reveal_specific_key_linkage` | Implemented (core) | BRC-69 method 2, BRC-72 protection. Includes BRC-97 proof-type for future ZKP schemes. |

## Action lifecycle

| BRC-100 method | Engine primitive | Stance | Notes |
|---|---|---|---|
| `createAction` | **`engine.build_action`** | Implemented (core) | Naming divergence — see ["Engine primitive naming"](#engine-primitive-naming) below. Funding strategy, fee model, change generation (ADR-013). Returns `signableTransaction` for deferred-sign path (ADR-024 forward direction). |
| `signAction` | `engine.sign_action` | Implemented (core) | Spec-aligned. |
| `internalizeAction` | **`engine.import_beef`** | Implemented (core) | Naming divergence — see below. Both `wallet payment` (BRC-29) and `basket insertion` protocols. |
| `abortAction` | `engine.abort_action` | Implemented (core) | Failure-bounded delete of unpromoted outputs (ADR-011 delete). |
| `listActions` | `engine.list_actions` | Implemented (core) | Status derived from structural state per principle-of-state. |
| `listOutputs` | **`engine.spendable_outputs`** | Implemented (core), with [HLR #434 nil-basket affordance](#listoutputs-basket-nil-affordance-hlr-434) | Naming divergence — see below. Basket-scoped query at the wrapper; Engine primitive accepts basket-optional with `nil` = unbasketed. The wrapper *also* accepts `basket: nil` as an intentional divergence to surface the wallet's change pool to BRC-100 callers — see the [linked section](#listoutputs-basket-nil-affordance-hlr-434). |
| `relinquishOutput` | `engine.relinquish_output` | Implemented (core) | Removes from `spendable`; output row preserved. |

### Engine primitive naming

The default is: **Engine primitive == the Ruby-idiomatic snake_case of the BRC-100 camelCase spec name** — straightforward snake_case for verb-shaped names (`signAction` → `sign_action`, `getPublicKey` → `get_public_key`), and Ruby's predicate convention for `is_*`-shaped booleans (`isAuthenticated` → `authenticated?`, per the Authentication section below). 25 of the 28 primitives follow this rule directly. The three exceptions all share one rationale:

> **When the BRC-100 method name names a procedural verb or a metaphor, and the wallet's actual operation has a more direct name, the Engine primitive takes the direct name.**

The three divergences:

| BRC-100 | Engine | Rationale |
|---|---|---|
| `createAction` | `build_action` | "build" names what the wallet does — assemble a transaction with funding, fees, change. "create" is BRC-100 metaphor for "the action lifecycle entry point". |
| `internalizeAction` | `import_beef` | "import_beef" names the concrete operation — take a BEEF envelope, incorporate its outputs into the wallet. "internalize" is BRC-100 metaphor for "take this thing and consider it mine". |
| `listOutputs` | `spendable_outputs` | "spendable_outputs" IS the query — the UTXO set, optionally basket-filtered. "list" is BRC-100 procedural verb-stacking that has no parallel meaning in the wallet's vocabulary. |

The conformance layer (`BSV::Wallet::BRC100`) wraps each Engine primitive under the BRC-100 spec name and shape. Callers using BRC-100 see no divergence; consumers using Engine primitives directly (Engine::Batch, future #223 HTTP wrapper, future Engine::Transmission) see the wallet's own language.

This is ADR-026's "Engine speaks wallet vocab, BRC-100 wraps" principle applied at the *method-name* axis specifically — and ADR-026's primitive-surface decisions are the foundation; this register is the per-method record over time. The three divergences are recorded here, not in ADR-026, because they may grow or contract over time and ADRs are point-in-time decisions.

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

The spec contract says: outputs created without `basket` are not surfaced by `listOutputs`. We honour this at the wire. Internally, however, every output is recorded in the `outputs` table; basket membership (via the `output_baskets` JOIN, not as a column on `outputs`) is a categorisation axis, not a tenancy axis. Multi-tenant wallets in the reference implementation use `basket` as a per-app sandbox key (with `userId` as the per-user partition). We have neither. For us, basket is what the application chose to name its outputs by, and the "untracked" behaviour is enforced as a query-time filter at the conformance layer, not as an absence in the storage layer.

This is a divergence in internal semantics with full external conformance.

### `listOutputs basket: nil` affordance (HLR #434)

A second, more pointed divergence on this method: **`BSV::Wallet::BRC100#list_outputs` accepts `basket: nil` as a Ruby-side affordance** that routes to `engine.spendable_outputs(basket: nil)` — i.e. returns the wallet's unbasketed pool, which is where change outputs land in our model.

The spec gap that motivates this: BRC-100 requires `basket` on `listOutputs` and bans `'default'` as a basket name. Wallet-toolbox sidesteps the gap by routing change to a basket literally named `'default'` and surfacing it via `listOutputs(basket: 'default')` — undocumented behaviour that contradicts the spec's ban on the name. We don't do that — our change is genuinely unbasketed. The cost is that spec-conformant BRC-100 callers have no way to see change or the wallet's residual pool via `listOutputs` at all (it's visible via `listActions` and the `createAction` response, but not via the per-basket query). For a Ruby client that knows our internals, `basket: nil` closes this gap pragmatically.

**Invisible to TypeScript-conformant callers.** The TS type `BasketStringUnder300Characters` is non-nullable, so a TypeScript client constructing `listOutputs({ basket: null })` fails at type-check before reaching the wallet. The affordance affects only Ruby-side callers.

**Acceptance / behaviour:**

- `brc100.list_outputs(basket: nil)` returns the unbasketed spendable set, matching `engine.spendable_outputs(basket: nil)`.
- `brc100.list_outputs(basket: '')` and `brc100.list_outputs(basket: '   ')` continue to raise `ArgumentError` — only literal `nil` is the affordance.
- Return shape matches the BRC-100 hash: `{ total_outputs:, outputs: }`.

**Temporary by design.** The cleaner fix is upstream: BRC-100 deciding either (a) how change should be visible (per-basket return, named change basket, a new method, etc.) or (b) that it's correctly invisible and apps must track via `createAction` responses + `listActions`. Until upstream settles, this affordance lets the wallet remain usable for BRC-100 callers. **When upstream lands real semantics, remove this affordance.** The risk worth naming: the affordance solves immediate problems well enough that pressure to push upstream for proper resolution can ebb. The HLR captures this so future-us reads it back.

## Chain queries

| BRC-100 method | Engine primitive | Stance | Notes |
|---|---|---|---|
| `getHeight` | `engine.get_height` | Implemented (core) | Via configured chain tracker (ADR-015 pivot). |
| `getHeaderForHeight` | `engine.get_header_for_height` | Implemented (core) | Same. |
| `getNetwork` | `engine.get_network` | Implemented (core) | `'mainnet'` / `'testnet'` from wallet configuration. |
| `getVersion` | `engine.get_version` | Implemented (core) | Wallet version reporting. |

## Authentication

| BRC-100 method | Engine primitive | Stance | Notes |
|---|---|---|---|
| `isAuthenticated` | `engine.authenticated?` | Implemented (core), trivially | Ruby predicate convention (`?`-suffixed boolean) rather than `is_*` naming. Always `true` for a constructed Engine — having the WIF is being authenticated. |
| `waitForAuthentication` | `engine.wait_for_authentication` | Implemented (core), trivially | Returns immediately. The BRC-100 reference assumes an authentication step where the wallet is unlocked by user action; we have no lock state, so the wait is a no-op. |

The spec's authentication model presupposes a lock-screen / unlock UI. We replace it with WIF-at-construction: if you constructed the Engine, you authenticated. The `is_authenticated` → `authenticated?` shift is Ruby predicate idiom, not a vocabulary divergence — `is_` prefixes are foreign to Ruby in the same way that `_t` type suffixes are foreign to C++.

## Cross-cutting parameters

| Parameter | Stance | Notes |
|---|---|---|
| `originator` | Boundary-only | Accepted on every BRC-100 method, dropped at the boundary. Forward direction: DBAP-style permission tokens in admin baskets when implemented (originator ADR). |
| `seekPermission` | Boundary-only | Accepted, no-op'd. We have no permission UI to seek from. Will become meaningful when BRC-116 lands. |
| `OriginatorDomainNameString` validation | Boundary-only | Format validation at the conformance layer (FQDN shape) where present; no behavioural use. |
| Hash-vocabulary return shapes (`{ txid:, tx: }` etc.) | Boundary-only | Conformance translates wallet vocab returns into BRC-100 hash shapes. ADR-026 codifies this. |
| Spec-shape input validation | Tracked under HLR #428 | Length limits, format constraints, and reserved-name checks: conformance-layer enforcement is tracked by HLR #428 — not yet implemented. The DB-level CHECK on `baskets.name` currently rejects the literal `'default'` (the only reserved name with active CHECK coverage). Engine continues to assume valid input. |
| `userId` (implied) | Amputated | No `users` table, no `user_id` column anywhere. Identity is the WIF (ADR-007). Forward direction: per-user databases (per-user-databases ADR). |

## Reserved names

BRC-100 reserves several name patterns. We intend to enforce them at the conformance layer (tracked under HLR #428) so application callers cannot forward-incompatibly adopt the reserved namespace, even where the corresponding machinery isn't built yet. The schema-level CHECK on `baskets.name` already rejects the literal `'default'`; the comprehensive enforcement (the full table below, conformance-layer + schema) is HLR #428's scope.

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
- *2026-06-24* — Added "Engine primitive" column to the method tables. Recorded the three current name divergences (`createAction` → `build_action`, `internalizeAction` → `import_beef`, `listOutputs` → `spendable_outputs`) and the naming policy under which future divergences are evaluated. Same-day with the initial register because the divergences and the principle that explains them are co-discovered. (PRs #429 and #430 landed the prerequisite Engine surface changes — the `spendable_outputs` rename and `seek_permission:` residue removal respectively.)
- *2026-06-25* — Added the `listOutputs` `basket: nil` affordance (HLR #434) as an explicit, named divergence: BRC100 wrapper accepts `nil` and routes to `engine.spendable_outputs(basket: nil)`, surfacing the wallet's unbasketed pool (including change) to Ruby-side callers. Invisible to TypeScript-conformant callers (non-nullable TS type). Temporary by design — to be removed when BRC-100 settles change-pool visibility upstream.
