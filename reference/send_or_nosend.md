# send / noSend: batching and chained-send workflows

> **Status note (May 2026):** HLR #183 stripped the BRC-100 `noSend` /
> `noSendChange` / `sendWith` / `knownTxids` primitives from the base
> wallet's public API. The wallet retains the `'none'` value of the
> `broadcast_intent` enum, but only for **internal** non-network actions
> (incoming BEEF, imported root UTXOs, wbikd locks, `send_payment`
> returning BEEF). The chained-send subsystem that this document
> describes will be reintroduced under issue
> [#192](https://github.com/sgbett/bsv-wallet/issues/192) as a separate,
> persistent-batch-aware feature. Read this document as a description
> of "what the wallet *will* eventually support," not "what the wallet
> currently does."

Reference notes on the BRC-100 `noSend` / `sendWith` / `noSendChange` /
`acceptDelayedBroadcast` primitives — what each one means, how they combine,
how the reference TypeScript implementation realises them, and where the
current Ruby wallet sits relative to that model.

## The two concepts are orthogonal

The literature usually presents these together as "the noSend/sendWith
story". They are actually answers to two different questions, and the
BRC-100 ABI fuses them into the same option struct only because the call
that closes a chain is also the call that flushes the batch.

| Concept           | Question it answers                                                                              | Spec primitive                            |
|-------------------|--------------------------------------------------------------------------------------------------|-------------------------------------------|
| **Batching**      | "How do I submit *N* already-signed actions to the network as one unit?"                          | `sendWith: [txid, …]` on the final call   |
| **Chained-send**  | "How do I let action *N+1* spend the change of action *N* before *N* is on-chain?"                | `noSend: true` + `noSendChange` round-trip |

Every chained-send workflow ends in a batch (the final `sendWith`). A batch
can also be flat — *N* sibling transactions with no parent/child dependency.

The BSV Hub copy of the BRC-100 spec is the only place in the corpus where
the concept is named directly (the paragraph is in the hub gloss, not the
canonical `bitcoin-sv/BRCs` file):

> In current interoperable implementations, `createAction` is also used for
> wallet-managed batching and chained-send workflows such as `noSend`,
> `sendWith`, and change remixing. Implementers MUST therefore not assume
> that every valid `createAction` call explicitly carries one or more inputs
> or outputs in the request body.

That sentence sits on top of four ABI fields (`noSend`, `noSendChange`,
`sendWith`, `knownTxids`) plus the visible status enum (`nosend`,
`unprocessed`, `sending`, `unproven`).

## The four ABI primitives

From BRC-100 `createAction.options` (and the equivalent fields on
`signAction`):

- **`noSend: true`** — Build, sign, store, lock UTXOs, promote outputs into
  baskets — but do **not** hand the raw tx to ARC. The action's status
  becomes `nosend`. The change UTXOs that were just minted are not
  spendable by `listOutputs`; instead they are returned in the response as
  **`noSendChange: OutpointString[]`**.
- **`noSendChange: [outpoint, …]`** on the *next* `createAction` — "Here
  are change outpoints from a previous `noSend` action in the same batch;
  treat them as eligible inputs even though they are not yet on-chain."
  This is how a chain forms: tx *N+1* explicitly cites the change outpoints
  of tx *N*.
- **`sendWith: [txid, …]`** — On the call that finalises the batch, "also
  broadcast these previously-`noSend`'d siblings/ancestors." The wallet
  returns `sendWithResults: [{ txid, status }]` per companion with status
  drawn from `'unproven' | 'sending' | 'failed'`.
- **`knownTxids: [txid, …]`** + **`trustSelf: 'known'`** — Pruning hints
  for the SPV envelope: "don't bother including BUMPs or rawTxs for these
  ancestors, I already have them." This is the BEEF-side enabler that makes
  batching cheap when ancestor chains are long — exactly the use case BRC-96
  (BEEF V2 Txid-Only) was written for.

Orthogonal axis:

- **`acceptDelayedBroadcast: true`** (default) — once the batch is
  determined, hand off to the wallet's background daemon and return
  immediately. `false` — submit inline, surface any ARC error in the result.

The action status enum on the wallet's records is the visible state machine:

```
completed | unprocessed | sending | unproven | unsigned | nosend | nonfinal | failed
```

`nosend → sending → unproven → completed` is the chained-send happy path.

## The four-quadrant combination

`isNoSend` and `isSendWith` are independent booleans. All four combinations
are meaningful — verified against the reference implementation's branch:

| `isNoSend` | `isSendWith` | meaning                                                              |
|------------|--------------|----------------------------------------------------------------------|
| F          | F            | classic "create + broadcast one tx"                                  |
| F          | T            | "broadcast my new tx **plus** these N parked txids together" — flush |
| T          | F            | "park my new tx; I'll flush later" — start or extend a chain         |
| T          | T            | "park my new tx alongside these others as an explicit group"         |

## Reference implementation mechanics

`@bsv/wallet-toolbox` (the BSV Blockchain reference) realises the concept in
[`src/storage/methods/processAction.ts`](https://github.com/bsv-blockchain/wallet-toolbox/blob/master/src/storage/methods/processAction.ts)
and
[`src/signer/methods/createAction.ts`](https://github.com/bsv-blockchain/wallet-toolbox/blob/master/src/signer/methods/createAction.ts).
Three things are worth quoting directly:

### The batch is a persisted entity

```ts
const batch = txids.length > 1 ? randomBytesBase64(16) : undefined
// ...
await storage.updateProvenTxReq(readyToSendReqIds, { status: 'unsent', batch }, trx)
```

A random 16-byte id is stamped on every member of a multi-tx group in the
`provenTxReqs` table. The monitor daemon can then ship them as a unit and
recover atomically if it crashes mid-batch.

### isNoSend / isSendWith combine

```ts
if (args.isNoSend && !args.isSendWith) {
  logger?.log(`noSend txid ${req.txid}`)            // park it
} else {
  txidsOfReqsToShareWithWorld.push(req.txid)         // include in this batch
}
```

### isDelayed decides who ships the batch

```ts
if (isDelayed) {
  await storage.updateProvenTxReq(readyToSendReqIds, { status: 'unsent', batch }, trx)
  return { swr, ndr }                                // daemon picks up later
}
// otherwise synchronous:
const prtn = await storage.attemptToPostReqsToNetwork(readyToSendReqs, ...)
```

The wallet-toolbox Monitor daemon ("watches pending transactions,
rebroadcasts failures, handles chain reorganizations, and manages proof
acquisition") is what drives `status='unsent'` rows to completion.

## Transport layer (BRC-62 / BRC-95 / BRC-96)

A chained batch is only *possible* because the BEEF transport format
supports multi-transaction graphs:

- **BRC-62 BEEF** carries `nBUMPs + nTransactions` in topological order
  ("Parents… must occur before children"). Khan's algorithm is the
  reference sort.
- **BRC-95 Atomic BEEF** is the *single-subject* variant — used as the
  return value of one `createAction` (`tx: AtomicBEEF`).
- **BRC-96 BEEF V2 Txid-Only** lets a sender omit ancestors the receiver
  has already validated. The spec's motivation paragraph reads like a
  description of `knownTxids`:

  > "Consider when two parties cooperate over a short amount of time to
  > construct one or more transactions. Inputs may be added by either
  > party. … At each exchange of information along this process, one party
  > sends a BEEF to the other to validate the new inputs or transaction(s)
  > they originate."

  Without BRC-96, every step in a deep chained-send re-ships the whole
  ancestor graph.

## Adjacent specs that orbit the same problem

- **BRC-1** — pre-BRC-100 single-tx ancestor (no chaining option). The
  BRC-100 ABI is its explicit replacement.
- **BRC-29 "Simple Authenticated P2PKH Payment"** — earliest spec to
  acknowledge *application-level* batching: "Decide on the number of
  outputs (across one or multiple transactions) that will comprise the
  payment." All outputs in one payment share a `derivationPrefix`; each has
  its own `derivationSuffix`. `sendWith` is the protocol-level expression
  of this.
- **BRC-50 "Submitting Received Payments"** — explicit limit: "Only one
  transaction can be submitted per request." Incoming flow has no
  batching; outgoing does.
- **BRC-54 "Hybrid Payment Mode for DPP"** — *application-level* batching
  of a different shape: a payment "option" is a set of txs in AND-relation.
  The DPP `PaymentACK` returns a `transactions: [txid, …]` array. No
  `sendWith` primitive at the DPP layer; the wallet underneath must still
  flush them as one.
- **BRC-109 "IP-to-IP Note Settlement"** — formalises *broadcast pacing
  strategies* for many-independent-tx payments (`all_at_once | paced |
  bursts`, with `burst_size`, `min_spacing_ms`, etc.). Assumes independent
  notes (disjoint inputs, no chaining), so it sidesteps the chained-send
  problem entirely — but its pacing vocabulary is the closest the corpus
  comes to specifying *how* to actually ship a batch.
- **BRC-60** — philosophical counter-weight: argues long dependent chains
  are an anti-pattern and a single non-final tx + hash chain is preferred.
  Useful as a sanity check against treating chained-send as a goal in itself.
- **BRC-65 / BRC-46** — `labels` on actions and `baskets` on outputs are
  how callers later *find* the members of a logical batch. The batch id in
  wallet-toolbox is opaque internal plumbing; the user-visible grouping
  handle is a shared label.

## State in this codebase

> The detail below describes the pre-#183 state. After HLR #183 the base
> wallet no longer exposes `no_send`, `no_send_change`, `send_with`, or
> `known_txids` on the public BRC-100 surface, and the
> `Engine#process_send_with` helper has been removed. The
> `broadcast_intent` enum still has a `'none'` value, but it now marks
> internal non-network actions only (see `reference/schema.md` and
> `reference/schema-intent.md`). The `Action#derived_status` for those
> actions is `:internal`, not `:nosend`. The notes below are kept as
> the design study that will inform issue #192.

The pre-#183 Ruby implementation (`gem/bsv-wallet`) covered the primitives
but not the persistent batch:

- `Engine#create_action` accepted `no_send`, `no_send_change`, `send_with`,
  `known_txids` and the broadcast-mode resolution mirrored BRC-100:
  ```ruby
  def determine_broadcast(no_send, accept_delayed_broadcast)
    if no_send then :none
    elsif accept_delayed_broadcast then :delayed
    else :inline
    end
  end
  ```
- `process_send_with` inline-broadcast each companion by looking up its
  existing `actions` row + pre-staged `broadcasts` row. There was **no
  batch id** — companions were looked up by wtxid one at a time.
- The action status enum mapped to BRC-100: `Action#derived_status`
  returned `:nosend` when `broadcast == 'none'`.
- The OMQ-based `Engine::Broadcast` played the role of wallet-toolbox's
  Monitor daemon (still does, for the surviving send-path lifecycle):
  `pull!` consumes `pending_pushes` from a PULL socket, `reply!` answers
  REP for inline calls.
- The `noSendChange` round-trip worked (the engine returned change
  outpoints in the `:no_send_change` key) but the wallet didn't treat
  "this outpoint belongs to a pending noSend action" as a first-class
  concept on the spendable side — auto-funding via `inputs: nil` would
  not pick `noSendChange` UTXOs as inputs.

### Gap

The named missing piece is **the persistent batch entity**. wallet-toolbox
stamps `batch = randomBytesBase64(16)` on every member of a multi-tx group;
the daemon then drives the whole group through ARC together and can
detect/replay batch-level failures. The pre-#183 Ruby implementation
processed companions one by one inside the request that supplied
`sendWith`; #183 removed that helper, and the eventual #192 implementation
is expected to introduce the persistent batch as a proper subsystem.

For the wallet's scaling target the batch becomes load-bearing — it is the
unit ZeroMQ would shuttle around, and it is the failure-recovery boundary
the Monitor-equivalent daemon needs in order to safely replay
partially-broadcast groups.

## Sources

- [BRC-100 — canonical](https://github.com/bitcoin-sv/BRCs/blob/master/wallet/0100.md)
- [BRC-100 — BSV Hub gloss with the "batching and chained-send workflows" paragraph](https://hub.bsvblockchain.org/brc/wallet/0100)
- [BRC-1 Transaction Creation](https://bsv.brc.dev/wallet/0001)
- [BRC-62 BEEF](https://bsv.brc.dev/transactions/0062),
  [BRC-95 Atomic BEEF](https://bsv.brc.dev/transactions/0095),
  [BRC-96 BEEF V2 Txid-Only](https://bsv.brc.dev/transactions/0096)
- [BRC-109 IP-to-IP Note Settlement](https://bsv.brc.dev/wallet/0109)
- [BRC-60 Hash Chains over Dependent Transactions](https://bsv.brc.dev/state-machines/0060)
- [`@bsv/wallet-toolbox` repository](https://github.com/bsv-blockchain/wallet-toolbox) — reference implementation
- [wallet-toolbox `processAction.ts`](https://github.com/bsv-blockchain/wallet-toolbox/blob/master/src/storage/methods/processAction.ts) — `shareReqsWithWorld`, batch id assignment
- [wallet-toolbox `createAction.ts`](https://github.com/bsv-blockchain/wallet-toolbox/blob/master/src/signer/methods/createAction.ts) — `noSendChangeOutputVouts` plumbing
