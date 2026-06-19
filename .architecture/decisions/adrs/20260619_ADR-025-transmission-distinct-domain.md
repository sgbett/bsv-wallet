# ADR-025: Transmission is a distinct domain from Broadcast

## Status

Accepted. Tracked by Transmission HLR #385 (draft: `.claude/plans/20260619-transmission-hlr.md`).

**Decided:** 2026-06-19.

## Context

A signed transaction leaves the wallet two ways, and the wallet has only ever treated one of them as a domain. **Receiving** a peer's transaction is first-class — `Engine::BeefImporter` verifies, saves proofs, and promotes atomically. **Sending to a peer** is a CLI pipe: `Engine#send_payment` / `Hydrator#build_atomic_beef` build a BEEF envelope and `bin/send | bin/receive` shuttle it as JSON over stdin/stdout. There is no transmissions table, no transport, no per-counterparty state, no delivery resolution.

This ADR records *why the missing half is its own domain* rather than a method on the existing one — because the tempting move is to treat "send to a peer" as "broadcast, but to a wallet," and that instinct is exactly what has been biting.

The two paths look like one thing with a different recipient. They are not. **Broadcast** ships Extended Format (EF) to the miner network for consensus validation; **transmit** ships Atomic BEEF to a named peer for SPV. Because broadcast (→ miner) accreted all the process machinery — OMQ sockets, SSE resolution, crash-recovery — and transmit (→ peer) was treated as incidental, fixes aimed at one wire shape repeatedly broke the other (the EF-vs-raw daemon work and the BEEF-egress work kept colliding). The flip-flop is a symptom of an unnamed boundary.

`reference/transactions.md` carries the full technical framing (EF vs BEEF as projections of one hydrated transaction, trimming as an orthogonal axis). This ADR records the decision and the load-bearing reason.

## Decision Drivers

* **Stateless-about-who vs stateful-about-who.** A broadcast is global: a transaction is a transaction, the network is anonymous and fungible. A transmission is to a *named* counterparty and must remember, per peer, *what that peer has already seen* (BeefParty trimming). That per-recipient memory is the deciding difference — it cannot live in a domain whose whole shape assumes the recipient is anonymous.
* **Cardinality.** action → broadcast is 0..1; action → transmission is 0..N (one per counterparty). The natural grain of transmission state is (action × counterparty), which broadcast has no concept of.
* **Format is fixed by the recipient's job, not its knowledge.** EF is one-level-no-proofs because a miner does consensus validation; BEEF is full-proven-ancestry because a peer does SPV. The wire shape is a property of *what the recipient does*, so the two cannot share one "send" that picks a format by flag.
* **Concrete bug history.** The conflation already shipped breakage; this is evidence of need, not a hypothetical.
* **Principle of state.** Per-peer "what they've seen" is genuinely new persistent state the wallet has never held; it must be canonical and derived, which means a domain that owns it.

## Decision

**Establish `Engine::Transmission` as a distinct stateful domain — sibling to `Engine::Broadcast` and `Engine::TxProof` — sitting on the shared `Engine::Hydrator` substrate. Wallet-to-peer delivery is *not* a method or mode flag on `Engine::Broadcast`.**

* Verb is `transmit` (not `send` — `Object#send` collision); `submit` stays the inner ARC HTTP verb inside Broadcast. `Broadcast` and `Transmission` are the domain nouns.
* Per-counterparty state lives at grain (action × counterparty) in a `transmissions` table; delivery status is **derived** from structural facts (e.g. presence of an ack timestamp), never a status column (principle-of-state).
* `Hydrator#validate_for_handoff!` — already "is this BEEF fit to hand to a peer?" — is a **Transmission precondition** and relocates to this domain.
* Egress trimming (`replace_known_ancestors!` / `known_txids`), today misplaced in `BeefImporter` (ingress), relocates to Transmission, where the SDK's `Transaction::BeefParty` is adopted.

**Architectural Components Affected:**
* New `Engine::Transmission` + `Interface::Transmission`; new `transmissions` table + Store methods.
* `Engine::BeefImporter` — loses the egress-trim responsibility.
* `Engine::Hydrator` — `validate_for_handoff!` ownership moves to Transmission (the substrate stays shared).
* `Engine::Broadcast` — **unchanged** (the boundary is the point).

## Consequences

### Positive
* The flip-flop bug class is closed by construction: Broadcast and Transmission cannot share the wire-shape decision, so a fix to one cannot regress the other.
* Per-peer knowledge becomes first-class canonical state instead of an absent capability papered over by a CLI pipe.
* The egress contract gathers in one place (`validate_for_handoff!` + trimming), and `BeefImporter` narrows to pure ingress.
* The two domains share one substrate (`Engine::Hydrator`), so neither duplicates hydration.

### Negative / trade-offs
* A new domain for a capability that currently exists only as a CLI pipe — the machinery arrives ahead of a heavy production use. Mitigated by deliberately minimal v1 scope (caller-supplied endpoint, synchronous ACK) with transport-directory and async/daemon delivery explicitly deferred.
* The wallet gains its first per-counterparty persistent state — new schema surface and new failure modes (delivery, idempotent re-transmit) to design against principle-of-state.

### Neutral
* Naming, not behaviour, is the immediate deliverable; the existing send path keeps working until Transmission supersedes it.

## Alternatives Considered

### A. `Engine::Broadcast#transmit` (or a recipient-mode flag on Broadcast)
Add peer delivery as a second method/mode on the existing domain.
**Rejected** — it smuggles per-counterparty state (BeefParty) into a domain whose entire shape assumes an anonymous, fungible recipient. The wire-shape decision (EF vs BEEF) would then live in one place keyed by a flag, which is precisely the coupling that produced the flip-flop. The state model is foreign; bolting it on reintroduces the bug class.

### B. Leave transmit a CLI pipe
Keep `send_payment` + `bin/send | bin/receive`; do nothing.
**Rejected** — no canonical per-peer state, no trimming, no delivery resolution, and the receive/send asymmetry (and its bug class) persists. The capability stays unowned.

### C. Fold transmission into #192
Treat peer delivery as part of the noSend/sendWith subsystem.
**Rejected** — #192 is **Broadcast-domain** batching: it chains transactions locally then flushes the batch to the *network* atomically. Its "chained-send" is intra-wallet UTXO chaining, a different thing from inter-wallet BEEF delivery that merely shares the word "chain." Folding them re-conflates the very boundary this ADR draws. The only shared mechanic is `knownTxids`/BeefParty trimming, which lives on the shared substrate, owned by neither process.

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

**Proposed Decision:** "Wallet-to-peer delivery is a distinct domain `Engine::Transmission`, not a method on `Engine::Broadcast`."

**Necessity (8/10).** This is not a speculative future boundary — it is an *already-violated* one with a concrete bug history (the EF/BEEF flip-flop). The cost of waiting is continued regression whiplash every time either wire shape is touched. The decision is mostly an act of *naming* a boundary that the codebase has been paying to ignore.

**Complexity (4/10).** The decision itself adds little: a domain noun, a verb, and a clear "Broadcast is untouched" line. The *implementation* adds one table and a thin domain — but the genuinely heavy parts (identity→endpoint directory, async/daemon/resumable delivery) are explicitly deferred to a phase 2, and v1 is caller-supplied-endpoint + synchronous ACK. The risk to watch is the same one ADR-024 names: a phase-2 that ossifies into "someday," leaving a half-built domain.

**Simpler alternative considered:** Alternative A (a flag on Broadcast) is *simpler in lines* but not *simpler in model* — it imports per-counterparty state into a stateless-about-who domain, which is the expensive kind of complexity. Doing nothing (B) is simplest but leaves the bug class live. Neither is genuinely cheaper once the state model is accounted for.

**Recommendation:** ✅ Approve. **Pragmatic score:** Necessity 8 / Complexity 4 / **Ratio 0.5** (target < 1.5). The decision records a boundary that already exists in the problem domain; the cost is naming it and a deliberately minimal first slice.

## Relationship to BRC-100

BRC-100 specifies the *interface* — `createAction` returns the BEEF, `internalizeAction` consumes it — and is **deliberately silent on transport**. The compliant baseline is therefore "return the tx object; the caller delivers it" — exactly the `Engine#send_payment` + `bin/send | bin/receive` pipe, which **stays the default**. `Engine::Transmission` is an **original, beyond-spec extension**: there is no reference implementation to defer to, so the peer acceptance/rejection taxonomy and the delivery semantics are ours to design. (Conceptual lineage: peer-to-peer / IP-to-IP direct payments — the whitepaper's "direct" channel.) This raises, not lowers, the bar: novelty without a spec to lean on is exactly where rigour against principle-of-state and the broadcast precedent earns its keep.

**Delivery synchronicity is an invocation mode, not a property of `transmit`.** v1 ships synchronous delivery, but the synchronicity must come from an *inline caller awaiting a self-contained `transmit`* — never from `transmit` being intrinsically blocking. `transmit` is designed self-contained so the daemon can drive it asynchronously later; the inline synchronous call is one mode of invoking the same operation. This is the `broadcast_intent` inline/delayed model — the inline-equals-delayed robustness ADR-024/#183 preserved — applied to transmission. Building a synchronous-only `transmit` would forfeit that robustness and force a rewrite for the Phase-2 daemon path.

## Validation

* **Success test:** a `transmit → internalize` round-trip (Transmission → `BeefImporter`) is deterministic; per-peer trimming sends only what the counterparty lacks; delivery status is derived, not stored; `Engine::Broadcast` is unmodified.
* **The model is correct iff** a change to either wire shape (EF or BEEF) cannot, structurally, regress the other — because the decision is now owned by separate domains rather than one flag; and `transmit` can be invoked both inline (synchronous) and async (daemon) over one code path.

## References

* `reference/transactions.md` — broadcast vs transmit technical framing (the EF/BEEF distinction, trimming axis, two-domains-over-one-substrate).
* Transmission HLR — #385 (v1 scope, phasing, open forks); draft `.claude/plans/20260619-transmission-hlr.md`.
* ADR-018 — stateless SDK / stateful wallet; the axis this decision applies (broadcast stateless-about-who, transmission stateful-about-who).
* ADR-015 — egress BEEF validation; `validate_for_handoff!`, which relocates to Transmission as its precondition.
* ADR-024 — Engine decomposition; `Engine::Hydrator` is the shared substrate both domains read.
* #296 — BEEF chain integrity + hydration: extracts the wtxid-keyed Hydrator substrate (enabler, not blocker).
* #192 — noSend/sendWith (Broadcast-domain batching); kept separate, composed alongside later.
* SDK `Transaction::BeefParty` — per-counterparty trimming bookkeeping adopted by Transmission.
