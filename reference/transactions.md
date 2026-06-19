# Transaction egress: broadcast vs transmit

There are **two** ways a signed transaction leaves the wallet, and conflating
them is a recurring source of bugs (each "fix" to one wire shape silently broke
the other). They are different *processes* with different recipients, wire
formats, outcome taxonomies, and state. This document fixes the distinction.

| | **Broadcast** | **Transmit** |
|---|---|---|
| Recipient | the miner network (anonymous, fungible) | a *named* peer wallet (identity key) |
| Wire format | **Extended Format (EF)** | **Atomic BEEF (BRC-95)** |
| What the recipient does | consensus validation (scripts + fees) | SPV verification (BRC-67) |
| Verb | `Engine::Broadcast#submit` | `Engine::Transmission#transmit` *(not yet built)* |
| Outcome | MINED / REJECTED / DOUBLE_SPEND | DELIVERED / ACK'd / refused |
| Resolution | SSE + block-watch (global chain state) | peer internalize ACK (point-to-point) |
| Per-recipient memory | none — a tx is a tx | **BeefParty** — what has peer X already seen |
| Cardinality per action | 0..1 | 0..N (one per counterparty) |

## The distinction is the recipient's *job*, not its *knowledge*

The tempting wrong model is "a peer knows nothing so needs everything; a miner
has most of it so needs less." That is not the driver. The driver is **what the
recipient does with the transaction**:

- **A miner does consensus validation.** It checks scripts and fees, and
  confirms the inputs are unspent against its own UTXO/mempool state. For that
  it needs the *immediate* input scripts and amounts — **one level deep** — and
  **no** merkle proofs, because a miner does not re-verify history; it is the
  thing that establishes it. That is exactly what **EF** carries: the raw tx
  plus, for each input, the source satoshis and source locking script inlined.
  EF exists so the node need not do a UTXO lookup per input — supply the prevout
  data and it validates statelessly. A raw-tx submit fails with
  `'PreviousTx' not supplied`.

- **A receiving wallet does SPV.** It must prove to itself, trusting no one,
  that every ancestor was really mined. That requires the **full proven
  ancestry** back to anchors, carrying **merkle proofs (BUMPs)**. Even a peer
  that already knew every txid would still need the proofs to verify. That is
  **BEEF**.

So depth and proofs are fixed by the validation model, not by recipient
knowledge.

## Both formats are projections of one hydrated transaction

EF and BEEF are not separately constructed. Both derive from the same in-memory
`Transaction::Tx` whose inputs have `source_transaction` wired (the *hydrated*
object — see `Engine::Hydrator`):

- `to_ef_hex` → keep one level, drop proofs → **EF for a miner**
- `to_atomic_binary` → keep the full wired graph → **BEEF for a peer**

BEEF is a strict superset of EF for the subject transaction. This is why the
broadcast daemon can prime its cache with the BEEF the producer already built
for the caller's return value and simply call `to_ef` on it — no second
hydration (`Engine::Broadcast#hydrated_transaction_for`).

## Trimming is an orthogonal axis (BEEF only)

"How much does the recipient already hold?" *is* a real dimension — but it is
**orthogonal** to the format choice and applies only to BEEF. It is the
**trimming** optimisation: ancestors a counterparty already has are reduced to
TXID-only entries (`make_txid_only`), so the wire carries only what is new. The
SDK's `Transaction::BeefParty` is the per-counterparty bookkeeping layer for
this. It rides *on top of* BEEF and never applies to EF — EF is already minimal
for a miner's job, with nothing to trim against the miner's knowledge.

Trimming is the one place the "peer knows X, send less" instinct is correct.

## Two domains over one substrate

Broadcast and transmit are separate stateful *processes* (wallet side, per the
stateless→SDK / stateful→wallet axis in `state-boundaries.md`) sitting on a
shared *operational* substrate:

```
            Engine::Hydrator   ← shared: wtxid-keyed bytes cache → wired Transaction::Tx
             /            \
  Engine::Broadcast    Engine::Transmission   (not yet built)
   #submit  → EF→miner   #transmit → BEEF→peer
   resolve: SSE/blocks   resolve: peer ACK
   stateless-about-who   stateful-about-who (BeefParty, per counterparty)
```

The per-recipient-memory row is the deciding difference: broadcast is stateless
about *who* (a tx is global), transmission is stateful about *who* (BeefParty is
inherently per-counterparty). That state cannot be bolted onto `Engine::Broadcast`
without smuggling a foreign model in — hence a sibling domain, not a flag.

`Engine::Transmission` is thinner than it first looks: it is transport +
per-peer trimming + delivery-outcome, *on top of* the shared Hydrator. It is not
a fork of Broadcast.

A note on the verb: `transmit`, not `send` — `send` is poisoned by Ruby's
`Object#send`. `submit` stays as the inner HTTP verb of the broadcast subsystem.
`Broadcast` and `Transmission` are the domain nouns; `submit` and `transmit` are
their actions.

## Broadcast and transmit are parallel, not sequential

They are independent edges off the same action, not a pipeline. BEEF/SPV exists
precisely so a peer can verify an *unconfirmed-subject* transaction from its
ancestry proofs without waiting for the subject to mine — so a transmit need not
follow a broadcast (or vice versa). An action may be broadcast and never
transmitted (a self-spend), transmitted and never broadcast by us (the peer
broadcasts), both, or neither (a purely internal action). The trust/timing
stance — whether and when to transmit relative to broadcasting — is a
Transmission-domain decision, not an ordering baked into the action.

## Relationship to BRC-100

BRC-100 specifies the *interface* (`createAction` returns the BEEF,
`internalizeAction` consumes it) and is **deliberately silent on transport**. The
spec's model is "the wallet hands you the tx object; how it reaches the peer is
your concern." So the return-BEEF-and-let-the-caller-deliver path (the
`bin/send | bin/receive` pipe) **is** the BRC-100-compliant baseline, and it
remains the default. `Engine::Transmission` is an **original, beyond-spec
extension** — there is no reference implementation; the peer acceptance/rejection
taxonomy and delivery semantics are the wallet's to design. Conceptual lineage:
peer-to-peer / IP-to-IP direct payments (the whitepaper's "direct" channel).

A design constraint that follows: **delivery synchronicity is an invocation mode,
not a property of `transmit`.** v1 delivers synchronously because an inline caller
awaits a self-contained `transmit`; the same operation must be drivable
asynchronously by the daemon later. This mirrors `broadcast_intent`
(inline/delayed over one code path) — see `Engine::Broadcast`.

## Current state (2026-06)

The asymmetry is stark and is the historical root of the flip-flopping:

- **Broadcast (→ network) is a first-class process.** `Engine::Broadcast`, OMQ
  PULL sockets, SSE resolution, callback handlers, crash-recovery — the daemon is
  built around it. Both the inline and daemon paths now ship EF (#252 closed the
  daemon-side raw-hex gap).
- **Transmit (→ peer) is only a CLI pipe.** `Engine#send_payment` /
  `create_action` build the BEEF envelope; `bin/send | bin/receive` shuttle a
  JSON `{ beef, outputs, sender_identity_key }` blob over stdin/stdout
  (`bin/send` is deprecated in favour of `bin/create`). There is **no**
  transmissions table, **no** transport (identity-key → endpoint resolution),
  **no** daemon/API/0MQ delivery channel, and **no** delivery-outcome resolution.

A first-class Transmission domain — table (grain: action × counterparty),
transport, BeefParty trimming, delivery resolution, API/0MQ surface — is the
subject of a forthcoming HLR.

## The egress completeness check is a transmit precondition

`Engine::Hydrator#validate_for_handoff!` (the structural-only verify with
`TrustedSelfChainTracker`) answers exactly one question: *is this BEEF fit to
hand to a peer?* It is therefore a **Transmission precondition**, currently
living on the Action path because Transmission does not exist yet. When the
domain materialises, the check moves there. The wallet trusts its own persisted
proofs (validated against a real `Network::ChainTracker` at proof-arrival time),
so structural completeness — every input path terminates at a `merkle_path` or
wires through to one — is the only thing left to assert at egress. Failure means
an upstream proof-closure gap, not a chain-validity problem.

Note also that the check fails the **delivery**, not the wallet's state: the DB
transition has already committed atomically; the BEEF is a read-only projection
over committed state, so a failed projection raises to the caller without rolling
anything back (principle-of-state — `principle-of-state.md`).

## References

- Format specs: BRC-12 (Raw Transaction), BRC-62 (BEEF), BRC-74 (BUMP),
  BRC-95 (Atomic BEEF), BRC-67 (SPV). EF (Extended Format) inlines per-input
  source satoshis + locking script onto the raw tx; it is the ARC submission
  shape, not a peer-interchange format.
- `state-boundaries.md` — the stateless/stateful axis that puts both processes
  in the wallet.
- `send_or_nosend.md` — `noSend`/`sendWith` batching. This is a **Broadcast**
  concern, not Transmission: #192 builds a chain of transactions *locally*
  (spending not-yet-broadcast change) then flushes the batch to the **network**
  atomically. Its "chained-send" is intra-wallet UTXO chaining, distinct from the
  inter-wallet BEEF cascade that motivates transmission.
- #296 — BEEF chain integrity + hydration: extracts the shared `Engine::Hydrator`
  substrate both domains read.
- #192 — noSend/sendWith subsystem (Broadcast-domain extension). The only mechanic
  shared with Transmission is `knownTxids` trimming (BeefParty), which lives on the
  shared substrate, not in either process. The two domains stay separate; a future
  Transmission composes alongside #192's batch broadcast rather than absorbing it.
