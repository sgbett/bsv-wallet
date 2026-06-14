# ADR reorganisation plan (2026-06-14)

Tracked as HLR #317.

## Why

The 21 ADRs were *reconstructed* from history and reslotted by **topic**, not time. Consequences:

- Numbering is meaningful for ~001–005, then arbitrary; ADR-011 (recent) sits mid-list.
- The genre is inconsistent: 001–005 read like a chronological log; 006–021 are retrospective rationale narratives (current decision + embedded history); 022+ would be a log again.
- Some documents **combine distinct decisions** made at different times (ADR-011 is the clearest), which a true ADR never does.
- **ADR-019 is wrong** — it presents enforcement as a three-way "hierarchy", contradicting ADR-003.

Two facts make a clean fix tractable: external references to the ADRs are **thin** (one inline link + a couple of directory pointers), and dating each ADR by its **latest recorded decision** resolves the ordering ambiguity. Together these give a clear path to **re-ordering** the set — but that is a step *after* the content is fixed. **No renumbering for now** (it is deferred, not ruled out).

## Settled conventions

### Nomenclature (the keystone)
- **Several decisions made at the *same* time → one ADR, the individual decisions labelled (a)/(b)/(c).**
- **Decisions made at *different* times → split: one ADR file per decision.** For now a combined file keeps its number and splits by slug — e.g. `ADR-011-combined-decision.md` → `ADR-011-decision-one.md`, `ADR-011-decision-two.md`. Final numbers/order are assigned in the later re-ordering pass.

### Ordering
- Each ADR is dated by its **latest recorded decision** (tied to a PR / transcript / commit; approximate is fine — not to the minute).
- A dedicated **`.architecture/decisions/adrs/INDEX.md`** lists the set sorted by that date (with status and theme).
- **Numbers are stable for this pass — no renumbering now.** Once every ADR is dated and the splits exist, re-ordering (which *may* renumber) becomes feasible precisely because external refs are thin and the dates resolve order. That re-ordering is a **separate, later step.**

### Evolving a decision (forward process)
- A changed decision → a **new ADR** (dated now) that summarises the prior decision(s) + links them, and flips the old one's **Status → "Superseded by ADR-N"**.
- Never edit a *decision* in place — only corrections and the Status line.
- ADR-018 is the exemplar: it explicitly supersedes its old Alternative B.

### Enforcement model (clarifies ADR-003; resolves the ADR-019 problem)
- The **database enforces valid state — not a choice** (ADR-003: "invalid state is structurally impossible").
- Enforcement is done **in the database**, and the mechanism is chosen **with performance/scaling in mind** (ADR-002). The *specific technique is illustrative, not the principle* — e.g. broadcasts-intent (#221 / `7803e85`) denormalised a column so a composite FK + CHECK could enforce a cross-table rule declaratively, rather than pay a per-row trigger on the hot path.
- **Application transactions serve constraints** (atomic multi-write so the DB's constraints hold together); they never *replace* them.
- An invariant enforced in app code with **no DB backstop explicitly breaks ADR-003** — a critical error, not a tier. (promote-authorisation is exactly this; tracked in #307.)

## Per-ADR actions

> Every ADR — including the "keep as-is" set — gets a `Decided:` date in this pass.

### Split (different times → one file per decision)
- **ADR-011** → (a) the **DELETE** deviation (cascade / `reject_action`; agreed → rolled back → re-agreed) and (b) the **promote / UPDATE** flip (came later). Both reference ADR-004's immutability principle; immutability itself lives in 004. The promote half is the open defect → #307.
- **ADR-015** → (a) the **SDK-verify pivot + `ChainTracker` write-through cache** (the bug-fix and the solid wrap) and (b) **egress-BEEF validation / `TrustedSelfChainTracker`** (much later — the "wallet was emitting invalid BEEF" fix).

### Label (a)/(b)/(c) — several decisions, same time, one ADR
- **ADR-004** → (a) vertical partitioning [scale enabler], (b) inputs-as-the-lock, (c) spendable-as-a-FK-row.
- **ADR-008** → (a) binary-internal, (b) identity-pubkey carve-out (#300 *rediscovered* (b)).
- **ADR-013** → (1) `nil`-vs-`[]` calling, (2) input-selection, (3) schema implementation, (4) change-derivation.

### Move / rewrite
- **ADR-010** → move the `root` / `output_type` enum content to **ADR-014**; keep derivation-placement + the inference-ban.
- **ADR-014** → state the actual decision clearly; absorb the root enum from 010 (dated to when that happened); reflect that import is now canonically BRC-42, send-or-nosend to facilitate testing.

### Reframe
- **ADR-019** → collapse to the **broadcasts-intent decision** only — a cross-table invariant enforced in the database, with scale in mind (the denormalise + composite FK + CHECK technique was chosen over a hot-path trigger). Dated 2026-05-27 / `7803e85` (#221). It **exemplifies** ADR-003; it does not define a "hierarchy of choices." Promote-authorisation **leaves 019 entirely** (→ promote ADR / #307). The two `prevent_*` triggers become a footnote.

### Status → Draft (decided, not fully implemented)
- **ADR-020** (test taxonomy), **ADR-017** (WBIKD).

### New ADR
- **"State as a FK row"** — emerged *later* as a general principle out of ADR-004(c); its own dated ADR, referencing 004(c).

### Keep as-is (single decisions) — still dated
- 001, 002 (holistic / early), 003, 005, 006, 007, 009, 012, 016 (ZeroMQ is the broad call), 018 (textbook supersession), 021.

## Mechanics
- Add a `Decided:` line (date + source PR/commit) to **every** ADR.
- Build **`.architecture/decisions/adrs/INDEX.md`** — the set sorted by `Decided:`, carrying date, status, and theme.
- No renumbering in this pass.

## Open / parked
- **Promote decision** → #307 (the app-enforcement-without-backstop defect). Fix per 019's brief: enforce it in the database, or restructure so the DB can hold it. A parallel discussion will land into #307.

## Execution method
- **Do not edit the existing ADRs.** For each ADR that needs writing / splitting / reframing, instruct a **sub-agent to author a *new* ADR via the `/create-adr` skill**, briefed with what we now know the content should be.
- Give each sub-agent the **research pointers** for its ADR — the transcripts, memory files, PRs, issues, and plans it can search — and make explicit that the ADR records a **point-in-time decision and may not match the current codebase**.
- **Cross-check every sub-agent's output** against the sources before accepting it — confirm it captured the decision faithfully and invented nothing.

## Sequence (later)
1. ADR-019 reframe (broadcasts-intent exemplar; promote exits).
2. Splits: 011 (delete vs promote), 015 (pivot+cache vs egress-validation).
3. Labels: 004, 008, 013.
4. Move/rewrite: 010 root-enum → 014; 014 clarity + BRC-42 / send-nosend.
5. Status → Draft: 020, 017.
6. New ADR: "state as a FK row".
7. `Decided:` dates on every ADR + `INDEX.md`.
8. **Then** the separate re-ordering pass (may renumber — now feasible).
