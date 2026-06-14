# ADR raft — catalogue & provisional order

Purpose: identify the architectural decisions made during the clean-room redesign and
the sessions that followed, so the reasoning is extracted into ADRs rather than left
buried in transcripts. Source: nine schema/design transcripts (mined 2026-06-12), the
GitHub HLR/PR record, this session's findings, the `/tmp` distillations, and the
`reference/` docs.

Filtering rule (don't overegg): an ADR is warranted when the decision is **stable**,
**non-obvious**, and has **its own alternatives**. Being already written in CLAUDE.md or
`reference/` is **not** grounds to skip — `reference/` (esp. `schema-intent.md`) became a
stopgap home for decisions, written as *what was done* rather than *what was decided, why,
and against which alternatives*; the ADR **supersedes/absorbs** that material. Genuine
**SKIP** is only for trivial decisions; **FOLD** rolls a sub-decision into a parent ADR.
Exception: genuinely *normative living* docs (`principle-of-state.md`, `state-boundaries.md`)
keep a `reference/` home *alongside* their ADR — the ADR is the frozen decision, the
reference doc the living statement (the ADR-003 split). `schema-intent.md` is
decisions-as-description and is to be **absorbed** across the raft.

ADR numbers follow rough decision/dependency order — roots first — not strict creation order (reslotted 2026-06-13 so clean-room and scale lead). The decision tree is the spine; cross-references link siblings, and the exact order of the *later* decisions matters less than getting the early ones right.

## Reference docs disposition (2026-06-13)

`reference/` is not one thing. Only the decision-as-description doc gets absorbed; the rest stay.
- **Plain reference — stays, no ADR:** `schema.md` (living schema description), `BRC100.md` (replicates the online spec), `sse.md` (Arcade SSE explainer), `transactions.md` (WIP), `raw-tx.md` (pure reference), `brc-draft-wbikd.md` (draft BRC proposal), `arcade-api-1.json` (API spec).
- **Normative living principle — reference home *plus* ADR (the ADR-003 split):** `principle-of-state.md` (↔ ADR-003), `state-boundaries.md` (↔ ADR-018).
- **Decision-as-description — absorb into ADRs:** `schema-intent.md`. `send_or_nosend.md` — category TBD (likely decision-flavoured; relates to noSend/#192).

## Decision tree (spine)

```
(roots, ~same moment, May 2026)
  clean-room / schema-first  ──┐  drivers: TS port was a reverse-engineered guess
  design for BSV scale       ──┤             with JSON blobs; the JS schema felt like
   (→ "wallet-node")           │             an afterthought, not the data lynchpin
                               ├─► vertical partition (outputs=log / spendable=wallet)
                               │     └─► outputs immutability ─► [promotion tempering]
  derived-state / principle of state  ── independent; "at any scale, on correctness"
```

## Tier A — already underway

| # | ADR | Verdict | Status | Notes |
|---|-----|---------|--------|-------|
| 001→003 | **The Principle of State (derived state)** | KEEP — **narrow it** | in PR #306 | Shed immutability (→011), the partition/scale/clean-room context (→their own), and the alternatives that belong elsewhere (C/D/E/F/G/I). Keep: derived-not-stored (no `status`, no `spendable` bool; alts A status-enum, B spendable-bool), atomic transitions, constraints-as-enforcement ("DB is the last line of defence"). |
| 002→011 | **Post-broadcast promotion & the scalability-tempered outputs-immutability invariant** | KEEP | in flight; #307 re-scoped | Thesis: *immutability serves scalability, not purity* — deviations are judged against the vacuum/partition purpose. **Two accepted deviations:** (1) UPDATE — the `promoted` flip (#194), HOT/self-pruning, internal outputs born-promoted; (2) DELETE — reject/abort/reap (#189), **failure-rate-bounded, not throughput-bounded** (high-frequency spent-delete designed out: spent outputs stay in the log, only the `spendable` row is deleted). Neither was vacuum-analysed at decision time; this ADR supplies it. Watch-items: keep `promoted` **unindexed**; consider `fillfactor < 100` on `outputs`; monitor `n_dead_tup`. Drift-guard split to A3. Sources: HLR #183/#197/#189/#194 (distilled this session). |
| A3→019 | **Constraint-enforcement hierarchy: declarative (FK/CHECK) > trigger > app-atomic** | KEEP (linked to 011) | Rule: prefer declarative; fall back to a trigger only when not declaratively expressible; on **hot paths** even a trigger is too costly (~10k tx/s ceiling, #221) → consciously app-enforce + transaction-atomic. Worked examples: **broadcasts-intent** (no `broadcasts` row when `broadcast_intent='none'`) → composite FK + `CHECK(intent!='none')`, chosen over the #198 trigger on throughput (#221); **promote-authorisation** (`promoted ⟹ accepted/internal`) → **app-enforced + atomic** in `record_broadcast_result` (NOT trigger: hot path; NOT declarable: mutable `tx_status` + disjunctive internal path + no cross-table CHECK; NOT a marker: duplicates `tx_status`). `promoted` stays a boolean. Triggers NOT banned (`prevent_outbound_spendable`, `prevent_internal_action_delete` — declarative-impossible, non-hot). Substantive open Q: authorising set `ACCEPTED` (strict) vs `!REJECTED` (optimistic + `reject_action` compensate; current). Source: #198/#221/#217/#240 (distilled this session). |

## Tier B — foundational roots (high value; currently only in transcripts/reviews)

| # | ADR (provisional) | Verdict | Source |
|---|------|---------|--------|
| B1 | **Clean-room redesign, schema-first** — rebuild rather than port; the schema is the lynchpin, not a byproduct of code | KEEP | `20260501_clean-room` :147-196,427-441; `20260501_brc100-impl` (clean break to fresh repo, #9) |
| B2 | **Design for BSV scale / the "wallet-node" north star** — millions-tx/s target drives partition, immutability, concurrency; walletd hosts the wallet (Unicorn model), ABI-over-sockets is the protocol, JSON BRC-100 is the RPC skin | KEEP (formalise) | `clean-room` :1264-1426; `chain-tracker` :6100-6234; `.architecture/reviews/wallet-node-architecture.md`; memory `project_scaling_vision` |

## Tier C — the schema spine (buried in the clean-room transcript)

| # | ADR (provisional) | Verdict | Source |
|---|------|---------|--------|
| C1 | **Outputs/spendable vertical partition** — "outputs is the log, spendable is the wallet"; the `inputs` table IS the lock (`UNIQUE(output_id)` + `ON CONFLICT`, not a `spentBy` FK) | KEEP | `clean-room` :266-376,517-684,1374-1426 |
| C2 | **Accounting ledger, not transaction DAG** — wallet models its slice (double-entry), merkle proofs collapse the DAG; not graph traversal | KEEP | `clean-room` :173-264 |
| C3 | **Single relational store / one ACID boundary** — proofs not split to a separate backend (FK can't span stores; BEEF needs them; proofs assembled in place) | KEEP | `clean-room` :838-871; this session (proof co-location) |
| C4 | **Single-tenant engine / no user table** — identity is a construction parameter; multi-tenancy is a layer above | KEEP | `clean-room` :1427-1563; `schema-constraints` :114-211 |
| C5 | **Binary-internal / hex-at-boundaries** (+ pubkey-hex carve-out) | KEEP — supersedes the CLAUDE.md convention | The *intent*: binary is the internal form, hex only where a spec mandates it; identity-pubkey hex is the carve-out. CLAUDE.md keeps the terse rule. `clean-room` :1049-1174; HLR #44/#52/#300 |
| C6 | **Postgres-native primitives over a portable subset** | KEEP — **absorbs `schema-intent.md`** | bytea / ENUM / CHECK / partial indexes / `ON CONFLICT` / partitioning chosen deliberately, not a portable subset. `reference/schema-intent.md`'s decision content folds in here over the raft |
| — | `actions`/`tx_proofs` naming; UUIDv7 `reference`; nullability/anti-denormalisation | SKIP/FOLD | Minor; fold into C1 or `schema-intent.md` |
| — | default = absence-of-a-row (baskets) | FOLD → 001 | Same absence-encodes-default pattern as derived-state |

## Tier D — schema specifics (derivation placement)

| # | ADR (provisional) | Verdict | Source |
|---|------|---------|--------|
| D1 | **Derivation placement & `output_type`** — derivation data lives on `outputs`; `spendable` is keys-only; the derivation-on-`spendable` experiment (PR #59) was reverted (#65/#66); `output_type` ENUM (root/outbound) + typed-vs-derived CHECK pairs + `prevent_outbound_spendable` trigger; "wallet decides, constraints enforce" (no inference in code, HLR #60) | KEEP | `schema-constraints` :729-790,973-1015; `import-utxo` :693-728,953-984; memory `project_spendable_purity`; HLR #65/#66/#60 |
| — | broadcasts as its own table (lifecycle decoupled from actions) | FOLD → 002 | `clean-room` :2624-2696; HLR #182/#190 |

## Tier E — persistence / store architecture (second wave)

| # | ADR (provisional) | Verdict | Source |
|---|------|---------|--------|
| E1 | **Store abstraction** — SQLite default *in the core gem* (relational floor, not file/KV); Postgres as optional override; namespace = abstraction hierarchy; per-model DB binding (drop global `Sequel::Model.db`); shared orchestration / thin adapter; gem-presence auto-discovery; later Postgres-gem consolidation | KEEP (one ADR, folds the sub-decisions) | `20260516_sqlite-postgres`; HLR #116/#117/#119/#120/#134; memory `project_store_consolidation`, `project_physical_logical_models` |
| — | Postgres-primary / SQLite-augmentation testing posture | FOLD → H2 | CLAUDE.md + HLR #228/#123 |
| — | Store owns atomicity / models are data not behaviour | FOLD → 001 or E1 | brc100-impl #7; HLR #143 |

## Tier F — funding / lifecycle

| # | ADR (provisional) | Verdict | Source |
|---|------|---------|--------|
| F1 | **Auto-fund createAction** — inline auto-funding (tri-state `inputs`: nil/[]/[…]); fee+change delegated to SDK; "split eagerness" (lock inputs early/reversible, write change atomically at Phase 2b); single change output v1, UTXOPool fanout deferred | KEEP | `20260505_auto-fund`; HLR #61/#199/#68 |
| F2 | **Import as rescue, self-pay to derived** — `import_utxo` is recovery-only; self-pays to a BRC-42 derived address so every spendable UTXO is derived; `internalize_action` must yield a spendable output or fail loudly | KEEP | `import-utxo` :1079-1187,953-1024 |
| — | UTXOPool tiers (select→pre-split→TxCache) | FOLD → B2 or F1 | memory `project_utxo_pool_evolution`; brc100-impl #4 |

## Tier G — network / concurrency (second wave; some already in review docs)

| # | ADR (provisional) | Verdict | Source |
|---|------|---------|--------|
| G1 | **Chain-tracker pivot** — SDK `Transaction#verify` replaces hand-rolled ancestry walking; `ChainTracker` as DB↔network write-through cache; verify-incoming-only trust asymmetry | KEEP | `chain-tracker` :232-330,83-100; HLR #95; `.architecture/reviews/chain-tracker-pivot.md` |
| G2 | **walletd daemon & OMQ concurrency** — ZeroMQ-direct (no abstract scheduler); idempotent stateless tasks (query-is-job-queue); 3-channel taxonomy; framework owns the clock, tasks own retry | KEEP | `chain-tracker` :5513-5996; HLR #156/#128; memory `project_background_processing` |
| G3 | **Network Services routing layer** — provider fallback, normalise-at-boundary, graceful degradation (NB: memory says belongs in SDK namespace — flag) | KEEP | `20260510_services`; HLR #77/#81; memory `project_network_services` |
| G4 | **WBIKD legacy receive addresses** — derived from existing action/basket machinery; on-chain-recoverable derivation (integer-ID → txid/vout + OP_RETURN marker supersession) | KEEP | `chain-tracker` :4645-4773; HLR #102/#108; memory `feedback_wbikd_derivation_recoverability` |
| — | Recursive BEEF ancestry / hydration primitive | DEFER | HLR #296 open; ADR when it lands |
| — | Pushable/Fetchable entity-driven network pattern | FOLD → G2/G3 | HLR #82 |
| G5 | **Stateless-SDK / stateful-wallet boundary** | KEEP | ADR records the boundary *decision*; `state-boundaries.md` stays as the living statement (ADR-003 split). brc100-impl #5 (drop ARC facade); HLR #302 |

## Tier H — interface / testing

| # | ADR (provisional) | Verdict | Source |
|---|------|---------|--------|
| H1 | **BRC-100 interface design** — plain Ruby module (no ported type system); synchronous methods, async is infrastructure; schema is canon, BRC-100 is the presentation layer | KEEP | `brc100-impl` :194-412,766-794 |
| H2 | **Test taxonomy** — engine-intent tests vs store-invariant tests; SQLite-default / Postgres-augmentation; OP_1 mocking principle (still aspirational) | KEEP | `20260505_ci` :767-775; HLR #64 (open) |

## Writing order (reslotted 2026-06-13 — decision order, roots first)

Authoritative numbering (supersedes the provisional B/C/… labels in the tier tables above):

1. **ADR-001 — clean-room / schema-first** — drafted ✓
2. **ADR-002 — design for BSV scale / wallet-node** — drafted ✓
3. **ADR-003 — principle of state (derived-state)** — reslotted from 001; *narrowing pass still pending* (shed immutability → ADR-011, redistribute alternatives → 004–010)
4. **ADR-004 — outputs/spendable partition (+ inputs-as-lock)**
5. **ADR-005 — accounting ledger, not DAG**
6. **ADR-006 — single relational store / one ACID boundary**
7. **ADR-007 — single-tenant / no user table**
8. **ADR-008 — binary-internal / hex-at-boundaries**
9. **ADR-009 — Postgres-native primitives**
10. **ADR-010 — derivation placement / output_type**
11. **ADR-011 — post-broadcast promotion & tempered immutability** — drafted ✓ (last in the spine, per its later decision)

Second wave (012+, rough order): store abstraction (E1) · auto-fund + import (F1/F2) · chain-tracker (G1) · services (G3) · daemon/OMQ (G2) · WBIKD (G4) · enforcement hierarchy (A3) · test taxonomy (H2) · BRC-100 interface (H1).

Core spine = 001–011. Second wave is lower-urgency; several have partial homes (reviews/CLAUDE.md).

## Open questions / resolutions (updated 2026-06-13)
- **Drift-guard → RESOLVED into A3.** `promoted ⟹ accepted/internal` is **app-enforced + transaction-atomic** (`record_broadcast_result`): a trigger is too costly on the hot path (~10k tx/s, #221) and the broadcasts-intent FK trick doesn't fit (mutable target, disjunctive path, no cross-table CHECK). `promoted` stays a boolean — no structural/marker rework. Remaining substantive Q: authorising set `ACCEPTED` vs `!REJECTED`.
- **Abort-DELETE: RESOLVED — accepted as deviation #2, no change.** The DELETE (reject/abort/reap of *unpromoted* outputs) is failure-rate-bounded → vacuum-neutral; it stays. NOT switched to orphans — speculative-output orphans were *proposed and rejected as janky* (`:1861`); delete-on-failure is the accepted model. No restructuring, no sub-issue. (Corrects an earlier mis-call that read `:1841` *spent*-output orphans as a precedent for *speculative*-output orphans.)
- **C3 vs E1: RESOLVED.** No contradiction — "one ACID boundary" = one store instance; "pluggable" = which relational engine. Both ADRs phrase it consistently.
- **G3 Services namespace: STILL OPEN.** May belong in the SDK; user figuring it out. Do not write G3 until resolved.
- **`send_or_nosend.md`: category TBD** (plain reference vs decision-as-description).
