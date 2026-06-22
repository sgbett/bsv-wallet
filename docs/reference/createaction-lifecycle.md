# The action lifecycle — state-machine reference

> Canonical reference for the wallet's **action model**: the states an action can occupy, the legal atomic transitions between them, who is responsible for each, and what enforces each invariant. It is the **dynamic** complement to [`state-representations.md`](state-representations.md) (the *static* per-schema-element conformance register, #348): that document grades each column/row's representation class; this one traces how an action *moves* through states over time. Both are concrete implementations of [`principle-of-state.md`](principle-of-state.md). Maintained under #350.
>
> (Filename is historical — `createAction` is the dominant entry point, but the machine spans the whole action lifecycle: `createAction` / `signAction` / `internalizeAction` / broadcast / promote / reject / abort / reap.)

**Verified against** migrations `001`–`003` and `lib/` on 2026-06-17. The schema is consolidated: the pre-production practice is to edit migrations directly and wipe-and-re-migrate, so the former `001`–`012` history is folded into `001_create_schema.rb` (tables + the `promotions` gate), `002_action_id_cascade.rb` (denormalised `action_id` FKs + `spendable→promotions`), and `003_schema_constraints.rb` (CHECKs + the two triggers).

**The wallet derives lifecycle state; it never stores it.** There is no `status` column anywhere (the only one the schema ever had, `tx_reqs.status`, was deleted). This is stricter than the BRC-100 reference SDKs, which persist tx/output status as columns — see `project_brc100_reference_stores_status`.

---

## 1. States — each a structural predicate

A state is *read* from structure, never stored. The class column links to `state-representations.md`'s A–F taxonomy.

| State | Predicate (how it is read) | Class |
|-------|----------------------------|-------|
| **created** | `actions` row exists; `wtxid IS NULL` | A |
| **funded** (inputs locked) | `EXISTS(inputs WHERE action_id = …)`; a *single* output's lock = `EXISTS(inputs WHERE output_id = …)` | A |
| **signed** | `wtxid IS NOT NULL` (≡ `raw_tx IS NOT NULL`, by the `wtxid_raw_tx_parity` CHECK) | B |
| **staged** (deferred-signable) | signed via `stage_action`; pending outputs written; **no** `promotions` row; a `signableTransaction` handle returned to the caller | A/B |
| **broadcasting** | `EXISTS(broadcasts WHERE action_id = …)`; `broadcast_at` NULL = queued, set = submitted; `tx_status` mirrors ARC | A + D |
| **promoted** (canonical) | `EXISTS(promotions WHERE action_id = …)`; wallet-owned outputs now carry `spendable` rows | A |
| **proven / settled** | `actions.tx_proof_id` set **and** the joined `tx_proofs` row carries `merkle_path` + `block_id` | A + value |
| **rejected** | `promotions` deleted (cascades `spendable` out); `broadcasts.tx_status ∈ {REJECTED, DOUBLE_SPEND_ATTEMPTED}` | — |
| **aborted** | `actions` row deleted (cascades `inputs` / `outputs` / `spendable`) | — |
| **reaped** | a stale *signed-but-unpromoted* action deleted by the reaper | — |

Canonical queries: *spent?* → `NOT EXISTS(inputs WHERE output_id)`; *promoted?* → `EXISTS(promotions)`; *signed?* → `wtxid IS NOT NULL`; *proven?* → `tx_proof_id` join. Status is always a membership test or a join, never a column.

---

## 2. The atomic units

The lifecycle advances **only** through these `Store` methods, each its own `@db.transaction` (so each is one valid→valid transition):

| Unit | Writes (one transaction) |
|------|--------------------------|
| `create_action` | `actions` row (+ initial `lock_inputs_atomic?` when given inputs) |
| `lock_inputs` | `inputs` rows (all-or-nothing) |
| `sign_action` | `wtxid`+`raw_tx`, `broadcasts` row (if intent ≠ none), pending + change `outputs` |
| `stage_action` | `wtxid`+`raw_tx`, pending `outputs` (deferred path; no broadcast row) |
| `save_proof` | `tx_proofs` upsert (raw_tx, and merkle material when present) |
| `promote_action` | `promotions` (intent=none) + `outputs` + `spendable` (internal path) |
| `promote_action_outputs` | `promotions` (send) + `spendable` for existing wallet-owned outputs |
| `promote_change_to_spendable` | `spendable` for change outputs |
| `record_broadcast_result` | `broadcasts.tx_status` **+ `promote_action_outputs` in the same transaction** when non-rejected |
| `mark_broadcast_attempted` / `clear_broadcast_attempted` | `broadcast_at` set / cleared |
| `reject_action` | `DELETE promotions` (cascades `spendable`) + `broadcasts → REJECTED` |
| `abort_action` | `DELETE actions` (cascades inputs/outputs/spendable) |
| `reap_stale_actions` | `DELETE` stale signed-unpromoted actions |

---

## 3. The four lifecycle paths

Ordered atomic units per path (the non-atomic gaps between them are where crash-recovery matters — see §5):

1. **Deferred / signable** (`sign_and_process: false`): `create_action` → `lock_inputs` (caller inputs) → `stage_action` → `save_proof` → return signable handle. Promotion deferred to a later `signAction`.
2. **Internal `no_send`** (`broadcast_intent = none`): `create_action` → funding loop (`lock_inputs ×N`) → `sign_action` → `save_proof` → `promote_action` → `promote_change_to_spendable`. Promotes synchronously; never broadcasts.
3. **Broadcast-inline**: …→ `sign_action` (writes `broadcasts`, `broadcast_at` NULL) → `save_proof` → broadcast worker `submit` → on 202, `record_broadcast_result` (status **+ atomic promotion**).
4. **Broadcast-delayed**: identical through `save_proof`; the daemon's `pending_submissions` loop then drives `submit` → resolve → atomic promotion. The post-`sign_action` `broadcasts` row *is* the designed steady state.

---

## 4. Responsibility (post-#291 decomposition)

`Engine::Action` owns the **sequence**; the machinery lives in collaborators (ADR-024; extractions #323/#336/#343):

- **`FundingStrategy`** — input acquisition (select + the retried `lock_inputs`).
- **`TxBuilder`** — construction, fee fixpoint, change derivation, signing (`build` / `build_change` / `apply_spends`); store-free.
- **`Hydrator`** — egress BEEF assembly + handoff validation (`build_atomic_beef`, `wire_ancestor`, `validate_for_handoff!`); store-reading.
- **`Broadcast`** worker + `Scheduler` loops — `submit` / resolve / the atomic promote-on-accept; the daemon's discovery loops.
- **`Store`** — *every* atomic mutation above. Application code orchestrates; the Store (and the schema) enforce.

---

## 5. The validation matrix — invariant → enforcement

The heart of the model. Each invariant is classified **✓ DB-constrained** / **⚠ app-enforced (justified)** / **✗ unguarded (tracked)** — mirroring `state-representations.md`'s "zero class-F" discipline. The target is **zero *unnamed* gaps**: every ⚠ a conscious, justified exception; every ✗ closed or ticketed.

| Invariant | Enforcement | Class | Ref |
|-----------|-------------|-------|-----|
| An output is locked at most once (single-spend) | `inputs UNIQUE(output_id)` | ✓ | ADR-004 |
| `signed ⟺ has raw_tx` | `actions.wtxid_raw_tx_parity` CHECK | ✓ | |
| `broadcast_intent` immutable while a broadcast exists | `broadcasts (action_id,intent) → actions(id,broadcast_intent) ON UPDATE RESTRICT` | ✓ | ADR-019 |
| No broadcast row for an internal action | `broadcasts` CHECK `intent != 'none'` + the composite FK | ✓ | ADR-019 |
| Promotion path: internal ⟺ no status, send ⟺ status | `promotions.promo_path` CHECK | ✓ | ADR-023 |
| A send promotion exists only while its broadcast is non-rejected | `promotions (action_id,authorising_status) → broadcasts(action_id,tx_status) ON UPDATE CASCADE` + `auth_not_rejected` CHECK | ✓ | ADR-023 |
| A UTXO (`spendable`) cannot exist without promotion authorisation | `spendable.action_id → promotions ON DELETE CASCADE` | ✓ | ADR-022/004 |
| An outbound output is never spendable | `prevent_outbound_spendable` BEFORE-INSERT trigger | ✓ | |
| An internal promoted action cannot be deleted (protects received UTXO history) | `prevent_internal_action_delete` BEFORE-DELETE trigger | ✓ | |
| A merkle path requires block context (no proof without a root) | `tx_proofs.path_requires_block` CHECK | ✓ | |
| One broadcast per action | `broadcasts UNIQUE(action_id)` | ✓ | |
| **When** to promote (optimistic: as soon as ARC is non-rejected; `reject_action` compensates if it later flips) | `record_broadcast_result` *decides*; the FK above gates *validity* | ⚠ | ADR-023 |
| Promote-authorisation was a hot-path trigger candidate — rejected (~10k tx/s ceiling) and converted to the row+FK above | row-as-fact instead of trigger | ✓ (now) | ADR-023, supersedes ADR-011 |
| Pre-`sign_action` crash releases locked inputs | reaper predicate **excludes** `wtxid IS NULL` | **✗** | #326 |
| The reaper actually runs | `reap_stale_actions` is **defined but unscheduled** | **✗** | #325 |
| Internal `no_send` signed-but-unpromoted gets completed/reclaimed | none (reaper excludes `intent='none'`; no broadcast row ⇒ no discovery) | **✗** | #327 |
| Internal `no_send` caller-outputs-and-change promote atomically | `promote_action` + `promote_change_to_spendable` are separate transactions | ⚠/✗ | #328 |

The ✓ rows are the load-bearing result: the lifecycle's correctness invariants are overwhelmingly schema-enforced. The residue is the **liveness/cleanup** class (the ✗ rows), all tracked under #324 — see §6.

---

## 6. Crash-recovery / liveness

Correctness (no *invalid* state) is DB-constrained per §5; the open work is **liveness** — that a crash mid-sequence leaves a *valid* state something eventually completes or reclaims. Summary:

- **Send paths (3, 4) are well-covered post-sign**: the `broadcasts` + `broadcast_at` + `tx_status` state machine plus the *atomic* `record_broadcast_result` promotion form a correct, re-entrant recovery chain.
- **Exposure** concentrates in (a) the **pre-sign window** (`wtxid IS NULL`, inputs locked — across all paths) and (b) the **internal `no_send`** synchronous promotion (no asynchronous backstop).

Full per-gap analysis and remediation live in umbrella **#324** (#325 wire the reaper · #326 pre-sign reclaim · #327 internal backstop · #328 partial-promotion atomicity · #329 audit the remaining flows). Those issues are the convergence work that turns the ✗ rows above into ✓.

---

## 7. Relationship to the rest of the model

- [`state-representations.md`](state-representations.md) / #348 — **static** sibling (per-element representation classes). This doc is the **dynamic** (state/transition) view; neither subsumes the other.
- [`principle-of-state.md`](principle-of-state.md) — the aspiration both implement.
- [`state-boundaries.md`](state-boundaries.md) — where state lives (SDK vs wallet).
- **#324** — the liveness convergence tranche (closes the ✗ rows).
- **#60** — wallet decides, constraints enforce (the broader eliminate-inference goal).
- ADR-003 (schema-as-canonical-state), ADR-004 (outputs/spendable/inputs-as-lock), ADR-019 (declarative enforcement), ADR-022 (state-as-a-FK-row), ADR-023 (promotion-as-a-row).

---

## 8. Open items (for #350)

- **Completeness check** (probe): confirm every `store.rb` `@db.transaction` appears as a transition here, and every lifecycle-touching element in `state-representations.md` is reflected — so the matrix is provably exhaustive, not silently partial.
- **`actions.outgoing`** is being dropped (#349, migration `013`, in flight on the #348 branch). When it lands, it leaves the model entirely (it was never lifecycle state — a query-filter attribute).
- **Filename**: historical `createaction-lifecycle.md`; an `action-lifecycle.md` rename would match the broadened scope (optional, low priority).
- The ✗ rows are not yet closed — they are tracked, not resolved. This doc is the *target*; #324 is the path.
