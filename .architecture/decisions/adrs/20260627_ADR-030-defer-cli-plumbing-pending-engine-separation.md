# ADR-030: Defer CLI plumbing verbs until the engine separates action creation from publication

## Status

Accepted.

## Context

The HLR #433 plan (native porcelain CLI) introduced a Git-style porcelain/plumbing/operational split, with the plumbing layer comprising four verbs: `build`, `sign`, `broadcast`, `transmit`. The architecture review of the plan (`20260627_feature-native-porcelain-cli`) raised plumbing as a YAGNI candidate (Pragmatic Enforcer position); we overrode that recommendation on the strength of "BSV protocol distinction at verb level" and proceeded.

Phase 2 (PR #456) attempted to extract `engine.broadcast_action(reference:, intent:)` as the engine-side primitive the CLI `broadcast` verb would wrap. Copilot review immediately surfaced that `dispatch_broadcast` requires a `broadcasts` row that doesn't exist for actions created via `no_send: true` (broadcast_intent='none'). The "fix" would have been a state-transition primitive that updates `actions.broadcast_intent` and inserts a `broadcasts` row atomically.

Deeper analysis exposed a structural conflation in the engine. The action lifecycle has four notional stages:

1. **Build** — assemble inputs/outputs/lock_time/version
2. **Sign** — apply unlocking scripts
3. **Persist** — commit signing artifacts to the `actions` table
4. **Publish** — dispatch to ARC inline, or queue via `broadcasts` row for daemon

The engine collapses stages 3 and 4. `build_action(no_send: false)` and `sign_action` both terminate by calling `dispatch_broadcast` at their tail; `Store#sign_action` inserts the `broadcasts` row inside the same DB transaction as the signing artifacts. There is no engine operation that takes a persisted action and publishes it separately.

The deferred-signing path (`build_action(sign_and_process: false)`) persists an intermediate state via `Store#stage_action`: the `actions.raw_tx` column holds **unsigned bytes** and `actions.wtxid` holds the hash of those unsigned bytes — a placeholder that does not match the wtxid the action will have once signed. The schema's `wtxid_raw_tx_parity` constraint is satisfied (both columns are non-NULL), but the persisted wtxid lies about the transaction's identity. The engine relies on the orchestrating layer to call `sign_action` within a controlled flow, overwriting the staged wtxid before any consumer treats it as authoritative.

This works inside the engine, where the orchestration is enforced by API discipline within a single process. It does **not** work for stateless CLI invocations: a CLI plumbing pipeline `wallet build` → exit → `wallet sign` persists the half-done staged state across process boundaries. Per the principle of state (ADR-003), every committed state should be a valid wallet state. A staged action with a placeholder wtxid is in-flight, not a state the wallet would honestly claim. The schema permits it because intermediate-state holding has no other home today.

The verb survival table is the test:

| Verb | Atomic at engine? | Survives without engine extension |
|------|-------------------|-----------------------------------|
| balance / list | yes (read-only) | ✓ |
| send | yes (build+sign+publish, all-or-nothing) | ✓ |
| receive | yes (`import_beef` atomic) | ✓ |
| import | per-UTXO atomic (each `import_utxo` is one transition) | ✓ |
| sweep / consolidate | yes | ✓ |
| reject | yes (abort transition on pending action) | ✓ |
| transmit | yes (operates on committed action's BEEF; no state transition) | ✓ |
| build / sign / broadcast | **NO** (leave or read intermediate state across CLI invocations) | ✗ |

Every porcelain and operational verb operates atomically per CLI invocation. Only the plumbing verbs break the model.

The engine extension needed to make plumbing honest — separable persisted intermediate states without polluting the canonical `actions` table — is exactly the work HLR #192 (`noSend` / `sendWith` reservation flow) sets out. #192 introduces in-engine reservation holding for staged-but-not-published actions, keyed by reference, with explicit promotion or expiry. That same primitive provides the home for CLI-plumbing's intermediate state.

In other words: the plumbing CLI verbs and the BRC-100 batching feature (`noSend`/`sendWith`) require the same underlying engine work. We had already deferred #192 from #433; we did not initially recognise that we had also implicitly deferred the plumbing layer with it.

## Decision

1. **Defer plumbing CLI verbs.** `build`, `sign`, and `broadcast` are removed from the #433 scope. They return as a follow-up once HLR #192's reservation flow lands and the engine supports separable persisted intermediate states. The plumbing-as-CLI mental model is honest only after that work.

2. **Reclassify `transmit` as operational.** Transmission operates on a fully-committed action's BEEF and represents a distinct domain (BEEF→peer vs BEEF→miner per ADR-025). It does not share the create+publish conflation; it does not require intermediate-state holding. It belongs alongside `sweep` and `consolidate` as a single-purpose verb against a completed action.

3. **Close PR #456 (`engine.broadcast_action`).** The method as designed only worked for the retry case (action already had a `broadcasts` row). The retry case is a different primitive entirely — it operates on a `broadcasts` row, not on an action — and is tracked as a follow-up issue against the broadcast surface, not the action surface.

4. **Document the engine's create+publish bundling as a structural property.** Future contributors who think to add `wallet publish` or extract a publish step must know that the current engine bundles persistence with publication by design, and that separating them is engine work, not CLI work.

5. **Plan reshape.** #433's six phases collapse to five: Phase 1 (DONE, dispatcher + balance + list, PR #454) stays; Phase 2 becomes porcelain `send` + `receive`; Phase 3 becomes porcelain `import` + `reject` + operational `sweep` + `consolidate` (with `import_wallet(basket:)` engine surface); Phase 4 becomes operational `transmit` (with `transmit_action` engine wrapper + egress hardening); Phase 5 is the spec rewrite.

## Consequences

- **CLI surface shrinks from 12 verbs to 9.** Porcelain (6: `balance`, `list`, `send`, `receive`, `import`, `reject`); operational (3: `sweep`, `consolidate`, `transmit`). No plumbing layer.
- **Engine surface additions shrink from 3 to 2.** `broadcast_action` removed entirely; `transmit_action(reference:, target:, ...)` and `import_wallet(basket:)` remain.
- **`send` remains the canonical create+publish verb.** Operators who want to build a transaction and broadcast it use `wallet send`. The fact that this is one atomic operation is the engine's structural decision, surfaced honestly in the CLI vocabulary.
- **Failed-broadcast retry becomes a separate primitive.** When a manual retry surface is added, it operates against the `broadcasts` row (not the action) — likely `wallet retry-broadcast <action_reference>` or similar — with semantics that reflect the publication lifecycle's distinct existence.
- **The architecture review's plumbing-cut recommendation is vindicated.** We arrived at the same conclusion via engineering necessity rather than YAGNI hand-waving. The review record stays as a snapshot of the team's input at the time; this ADR records the reversal and its rationale.
- **HLR #192's scope expands implicitly.** When #192 lands, it unblocks both BRC-100 batching AND CLI-plumbing. The plumbing follow-up issue can reference #192 as its prerequisite.
- **The verb naming for the eventual plumbing layer is undetermined.** `build`/`sign`/`broadcast` was the original placeholder set. During the discussion that produced this ADR, `publish` surfaced as a more honest label for the publication stage that `build_action` and `sign_action` collapse into their tails. Neither is the final answer. The verb decomposition follows from #192's design choice about where intermediate state lives — actions table with a discriminator column, separate reservations table, in-memory engine state keyed by reference, something else. Each design implies a different CLI boundary and therefore a different verb set. The plumbing layer cannot be designed in isolation from that choice; trying to lock the verb names now would prejudge the design.
- **The CLI abstraction made an engine-design question visible.** Attempting to expose plumbing verbs forced the question "where would the intermediate state for a multi-step action lifecycle be persisted?" — a question the engine has been quietly sidestepping because in-engine orchestration kept the staged state implicit. The CLI doesn't have that orchestration luxury; the question becomes mandatory. That mandatory framing is itself useful: it surfaces what #192 will actually need to decide.

## References

- [ADR-003 — Schema as canonical state](20260505_ADR-003-schema-as-canonical-state.md) — the principle this ADR applies
- [ADR-025 — Transmission distinct domain](20260619_ADR-025-transmission-distinct-domain.md) — why `transmit` is its own concern
- [ADR-027 — Core vs BRC-100 conformance](20260624_ADR-027-core-vs-brc100-conformance.md) — the broader axis #433's split sits on
- HLR #433 — native porcelain CLI (parent)
- HLR #192 — `noSend` / `sendWith` reservation flow (unblocks the plumbing follow-up)
- PR #454 — Phase 1 dispatcher (merged)
- PR #456 — Phase 2 `engine.broadcast_action` (closed; superseded by this ADR)
- Architecture review `20260627_feature-native-porcelain-cli` — Pragmatic Enforcer flagged plumbing as speculative; this ADR records the reversal
- `.claude/plans/20260626-native-porcelain-cli.md` — plan, updated in lockstep with this ADR
