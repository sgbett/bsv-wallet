# ADR-029: Originator deferral and DBAP direction

## Status

Accepted.

**Decided:** 2026-06-24 — the deferral has been in force since the beginning of the rebuild (`originator` has never reached the Engine); the recent reaffirmation is ADR-026 (engine primitive granularity, 2026-06-19) which codified it for the primitive surface. This ADR records the deferral as an explicit decision and commits the forward direction (DBAP via PushDrop admin baskets) so a future implementer doesn't re-derive it.

## Context

BRC-100 carries `originator: OriginatorDomainNameString` on every method. The parameter identifies which application is asking the wallet to do something; the spec's design intent is that the wallet uses it to gate permission decisions per application (BRC-116).

Our wallet has accepted `originator` at the BRC-100 boundary throughout the rebuild and has never propagated it into the Engine. Until 2026-06-24, this was an instinctive deferral with no recorded rationale; ADR-026 explicitly named it ("`originator:` does not propagate into Engine") as a consequence of the Engine speaking wallet vocabulary rather than BRC-100 vocabulary. ADR-027 (this branch) generalises the principle further.

What ADR-027 does not record is the **forward direction** — when originator support is eventually implemented (for full BRC-100 / BRC-116 conformance, or to host application clients on a daemon), what shape will that take? Without a forward commitment, a future implementer faces the same question we faced in early 2026: "should originator become a column on `outputs`/`actions`?", "should it become a permissions table?", "should each application get its own basket namespace?". Each of these is a reasonable-sounding question with a wrong answer, and the right answer (PushDrop tokens in admin baskets) is not obvious unless one has read the wallet-toolbox reference and understood its layering.

The wallet-toolbox reference implements BRC-116 permission machinery as **on-chain PushDrop UTXOs** stored in special `admin <category>-<action>` baskets within the user's own wallet. A `DBAP` (Domain Basket Access Protocol) token is a wallet output; its PushDrop script encodes `(originator, basketName)` and asserts "this originator is allowed to access this basket for this user". The same pattern handles protocol access (`DPACP`), certificate access (`DCAP`), and spending authorisation (`DSAP`), each in its own admin basket. Permission revocation is spending the token. Permission expiry is encoded in the PushDrop.

This shape has properties that align with our existing principles. Permissions are wallet outputs — they obey principle-of-state (schema is canon: the basket and its output ARE the permission record). Permissions are on-chain (provenance, audit trail, portability). Permissions are revoked the same way any wallet output is removed (spending). And, most importantly, permissions live as an **overlay** above the data tables (`outputs`, `actions`) rather than as columns within them — preserving the core-vs-conformance boundary that ADR-027 ratifies.

## Decision Drivers

* **Core-vs-conformance preservation (ADR-027).** Originator is application-interface vocabulary. Whatever mechanism we adopt must not push it into the data tables (`outputs.originator`, `actions.originator`, etc.) — that would be the textbook denormalisation failure (the user's "database 101" framing during the 2026-06-24 conversation). The DBAP shape satisfies this: the permission token is a regular wallet output; originator is content of the PushDrop script, not a column on `outputs`.
* **Throughput preservation (ADR-002).** A permissions overlay that interposes on every BRC-100 call adds latency to the hot path. Two postures defend the budget: (a) the permission check itself, when implemented, is a single output lookup keyed by `(admin_basket, originator)` rather than a join across data tables; (b) until implemented, every BRC-100 call costs zero permission work.
* **Principle-of-state alignment (ADR-003).** A permissions table beside the wallet's data tables is a second source of truth. Permissions-as-wallet-outputs is *the same* source of truth as everything else: the schema, projected through the admin basket.
* **Portability and audit.** On-chain permission tokens give every grant a transaction history. A wallet exported (or recovered from BRC-65 backup) carries its permission state intact.
* **Reference-implementation alignment.** Conforming to the BRC-100/116 wallet-toolbox pattern means application clients designed for that ecosystem find the mechanism they expect, even though our Ruby implementation is independent. This serves the interoperability goal of BRC-100 (HLR #28, ADR-021).
* **Cost is modest.** PushDrop tokens are 1-sat outputs of ~few-hundred-byte scripts. At BSV fee rates (100 sats/kb), each grant costs sub-penny. Grants are rare events (once per user-app-permission); the cost does not register against the throughput budget.

## Decision

**When originator support is implemented, it takes the shape of BRC-116-aligned PushDrop permission tokens stored in admin baskets within the wallet, mirroring the wallet-toolbox reference. Originator does not become a column on any data table.**

The shape:

1. **`BSV::Wallet::BRC100` (the conformance layer) becomes a permissions-aware wrapper.** It receives `originator` on every method, looks up the permission token for `(originator, requested-resource)` in the appropriate admin basket, and either proceeds, prompts (if a UI is wired up), or returns an authorisation error. The Engine remains originator-naive; the conformance layer interposes the check.

2. **Admin baskets are reserved by BRC-99 and enforced at the conformance boundary today.** The reserved-name validation (basket-name HLR on this branch) already prevents application callers from claiming `admin basket-access`, `admin protocol-permission`, `admin certificate-access`, or `admin spending-authorization`. The names are protected forward-compatibly so this ADR's direction can land without a collision migration.

3. **Permission tokens are PushDrop outputs.** Granting a permission is a wallet operation that creates a 1-sat output in the appropriate admin basket with a PushDrop script encoding the permission fields (originator, basketName for DBAP; originator+protocol for DPACP; etc., per BRC-116). Revoking is spending the output. Expiry is enforced at lookup time against an `expiry` field in the script.

4. **Four token types, four admin baskets:**
   - `admin basket-access` — DBAP tokens (basket access per originator).
   - `admin protocol-permission` — DPACP tokens (protocol use per originator + counterparty + security level).
   - `admin certificate-access` — DCAP tokens (certificate verification per originator).
   - `admin spending-authorization` — DSAP tokens (spending limits per originator).

5. **Permission lookup is a single basket query.** Given `(originator, requested-resource)`, the conformance layer queries the appropriate admin basket via the existing `list_outputs` machinery, filtering on tag or script content. This is the same hot-path machinery the rest of the wallet uses; no new query infrastructure.

6. **`seekPermission` semantics under DBAP.** When `seekPermission: false` is supplied and no token is found, the conformance layer raises an immediate authorisation error — the caller has signalled that prompting is off the table, so the wallet's response is the rejection. When `seekPermission: true` is supplied and no token is found, the conformance layer raises an "authorisation needed" error that a host UI can catch and translate into a prompt; the host then grants the token via the normal create-action flow and the caller retries. The wallet itself does not own a prompt UI — the `seekPermission` return path is the seam where a host UI plugs in.

7. **Single-user deployments accept originator without effect** until BRC-116 is implemented. The conformance layer accepts and drops `originator` as today; the admin baskets are reserved but empty; existing callers continue to work. Originator support, when implemented, is additive — no breaking change.

## Dependencies

**PushDrop support in `bsv-ruby-sdk`.** The implementation depends on PushDrop locking/unlocking script construction and parsing being available in the SDK. This is the gating dependency for the implementation HLR; until PushDrop ships in the SDK, the implementation cannot land. The deferral position of this ADR is unaffected by the dependency — we are committing direction, not scheduling implementation. When the work is scheduled, the HLR should verify PushDrop availability and surface any upstream work needed against `bsv-ruby-sdk`.

## Alternatives Considered

### A. Originator as a column on data tables

Add `originator` to `outputs`, `actions`, or both; partition queries by it; enforce per-originator access at the DB level.

**Rejected.** This is the textbook denormalisation failure (the user's "database 101" framing in the 2026-06-24 discussion). Originator is permissions vocabulary; the data tables are not permissions tables. Putting originator on the data tables conflates two axes the wallet-toolbox correctly keeps orthogonal: `userId` is the storage partition (we collapse this to per-DB by ADR-028's direction); `originator` is a runtime permission filter, never a partition. Denormalising permissions into data tables would also break the core-vs-conformance boundary (ADR-027) by pushing BRC-100 vocabulary into the core.

### B. Permissions table (relational overlay)

Add a `permissions(originator, resource_type, resource_name, granted_at, expires_at, revoked_at, ...)` table beside the data tables; conformance layer queries it on every BRC-100 call.

**Rejected as the chosen direction**, though it is structurally acceptable. This shape would work — it preserves the core-vs-conformance boundary (permissions live in an overlay, not in `outputs`), and it would be simpler to implement than PushDrop tokens. Two reasons it is not the chosen direction:

1. **Loss of on-chain provenance.** Wallet-toolbox-shape DBAP tokens are durable across wallet export/import (BRC-65 backup) and carry a per-grant transaction history. A relational permissions table has no such property — restoring a wallet from chain alone loses the permissions state.
2. **Loss of BRC-116 interoperability.** Application clients expecting BRC-100/116 compliance assume the permission record can be inspected as wallet outputs (via `listOutputs` against admin baskets). A relational alternative would diverge from this assumption silently.

The DBAP shape's on-chain cost is small enough that the durability and interoperability gains dominate. If the cost ever became material at scale (it won't, at the grant-frequency expected), a later ADR could switch to relational without disturbing the data tables.

### C. Per-originator basket namespaces

Give each originator its own private basket namespace — `<originator>:flowers` is a distinct resource from another originator's `<other>:flowers`. No permission tokens; access is implicit by namespace ownership.

**Rejected.** This is the "iframe semantics" model the user proposed during the 2026-06-24 conversation as an intuition check. It is internally consistent but it loses the BRC-100 design goal of *shared resources with permissioned overlay*: in BRC-100, two apps can be granted access to the same basket by the user (the principal), enabling sharing across apps the user trusts. Per-originator namespacing forecloses that. It also conflicts with BRC-99's reserved-name rules (which presume a single basket namespace per user) and would require structural divergence from BRC-100 with no compensating benefit.

### D. Implement BRC-116 permission UI in the wallet

Build a prompt mechanism into the wallet so it can ask the principal "App X wants Y; allow?" when no token is found.

**Rejected at this layer.** The wallet is a library and daemon, not a UI host. If a host product wraps it (a desktop wallet UI, a browser-extension wallet, a server with an admin web UI), the host owns prompting. The wallet exposes the `seekPermission: true` failure mode and the grant API (create-action with the admin basket as destination); the host wires its own UI to those. Trying to own prompts inside the wallet would either build a stub UI that wallpapers something a host must provide anyway, or push concerns into the wallet that belong with whoever owns the user relationship.

### E. Continue deferring with no forward direction

Leave the question "how will originator be implemented" unanswered.

**Rejected.** Continued *implementation* deferral is correct (no work is scheduled by this ADR). Continued *direction* deferral is wrong — the basket-name reservation work (HLR on this branch) makes claims about reserved names like `admin basket-access` that only make sense if the eventual implementation puts permissions in those baskets. Naming the direction now keeps the reservation work coherent and prevents a future implementer from concluding "the reservations don't make sense, let's drop them" between now and the implementation.

## Consequences

### Positive

* **The Engine stays originator-naive forever.** No primitive surface changes, no Store schema changes, no migration when BRC-116 lands. The conformance layer wraps; the core continues unchanged.
* **Permissions are first-class wallet artefacts.** They participate in the wallet's principle-of-state, its backup model, its audit trail. There is no shadow state beside the wallet.
* **BRC-116 interoperability is preserved.** Application clients designed against the wallet-toolbox model will find the mechanism they expect (admin baskets, DBAP tokens, BRC-99 reserved names).
* **The basket-name reservation HLR is grounded.** Reserving `admin*` and `default` and `p ` at the conformance layer today protects the namespace the eventual implementation needs. The reservation work is not speculative — it has a recorded forward use.
* **Cost is modest.** PushDrop tokens are 1-sat outputs; grants are rare events. At scale the budget impact is negligible.
* **Single-user deployments are unaffected until the implementation lands.** Today's behaviour (accept originator, drop it) is exactly what single-user mode wants. Multi-application deployments adopt the machinery additively.

### Negative

* **PushDrop dependency on the SDK.** Implementation is gated on PushDrop support in `bsv-ruby-sdk`. If that work is not scheduled when the wallet needs originator, the implementation HLR will need to schedule it upstream first.
* **On-chain cost per grant.** Each permission grant is a transaction (1-sat output, some BEEF overhead). At expected grant frequencies (once per user-app-permission, rare events) this is sub-penny and ignorable, but at hypothetical pathological grant rates it would matter. The mechanism is appropriate for the expected use; a relational fallback is structurally available if reality differs.
* **Grant operations require funding.** Granting a permission requires the wallet to spend a small amount of its own balance to construct the token output. This is an operational consideration — a freshly-created wallet with zero balance cannot grant permissions until it has at least the dust-output minimum plus fees. Not a blocker, but worth surfacing at implementation time.

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

This ADR commits direction without scheduling implementation, which is the right shape for forward-looking architectural decisions. The alternative (B) would be simpler to implement but loses two structural properties (on-chain provenance, BRC-116 interoperability) that are hard to add back later. The chosen direction defers cost (no code today) while preserving the option's value (full BRC-116 compliance via wallet-toolbox-shape DBAP) and constraining incremental decisions (the basket-name reservations land coherently). No abstractions are built; no code is added; the constraint is "don't foreclose this shape". **Approve.**

## Validation

The deferral is validated continuously by the wallet's structure:

* `BSV::Wallet::Engine` and its primitive surface contain no `originator` parameter.
* The Store schema contains no `originator` column on any table.
* `BSV::Wallet::BRC100` is the conformance-boundary entry point where the BRC-100 `originator` kwarg is accepted from callers; it does not propagate to the Engine. Other Ruby files may *mention* `originator` (interface contracts, tests, docs), but only the conformance wrapper acts on it.

The forward direction will be validated when the implementation lands:

* Permission tokens reside in admin baskets via `Engine#build_action` (no special create path).
* Permission lookup is implemented via `Engine#list_outputs` against admin baskets (no separate query layer).
* The Engine's primitive surface does not grow an `originator` parameter as part of the implementation work.

## Implementation notes

This ADR adds no code. When the implementation work is scheduled:

1. **HLR raises the work** with PushDrop SDK dependency verification as the gating step.
2. **`BSV::Wallet::BRC100` grows a `PermissionsCheck` collaborator** that resolves `(originator, resource)` against the appropriate admin basket via `engine.list_outputs(basket: 'admin basket-access', ...)`.
3. **Grant/revoke operations are surface added to the conformance layer** (BRC-100 spec does not name them explicitly, but `WalletPermissionsManager` in wallet-toolbox provides the precedent surface).
4. **`seekPermission`** semantics become live: `false` returns an authorisation error on missing token; `true` returns an "authorization needed" error that a host UI can catch and translate into a prompt.

The wallet-toolbox source (`WalletPermissionsManager.ts`, `BASKET_MAP` constants) is the reference for the field encoding in each PushDrop script type (`DBAP`, `DPACP`, `DCAP`, `DSAP`). BRC-116 is the specification.

## References

* ADR-002 — design for scale; the throughput preservation argument behind keeping originator out of the data path.
* ADR-003 — schema as canonical state; preserved by permissions-as-outputs.
* ADR-007 — single-tenant engine; complementary deferral (users).
* ADR-026 — Engine primitive granularity; codified "originator does not propagate into Engine" at the primitive surface.
* ADR-027 — core wallet vs BRC-100 conformance; this ADR is one forward application of that principle.
* ADR-028 — per-user databases; complementary multi-user direction (users), where originator and user are kept orthogonal.
* `docs/reference/core-vs-conformance.md` — the principle this ADR defers to.
* `docs/reference/brc100-conformance.md` — the per-concept register; "originator" entry refers here.
* BRC-99 — reserved basket names (admin, default, p prefix); enforced today, used by this ADR's direction.
* BRC-98 — reserved protocol IDs (admin, p prefix); enforced today.
* BRC-116 — the permission framework whose implementation direction this ADR commits.
* Wallet-toolbox `WalletPermissionsManager.ts` — the reference implementation of DBAP / DPACP / DCAP / DSAP tokens in admin baskets.
* HLR (this branch) — basket-name validation; reserves the namespace this ADR's direction uses.
* HLR (future, not yet raised) — schedule of work to implement originator/BRC-116 support.
