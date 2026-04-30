# Interface Derivation from BRC-100

How each internal machinery interface was derived from the BRC-100 specification.

The BRC-100 spec defines the external contract between applications and wallets (28 methods, captured in `Interface::BRC100`). It says nothing about wallet internals. The four machinery interfaces below are architectural decompositions inferred from what the external contract requires.

---

## BroadcastQueue — direct derivation

**Source:** `createAction` and `signAction` options.

The `acceptDelayedBroadcast` parameter describes two distinct execution models in a single boolean:

- `true` — *"the transaction will be sent to the network by a background process"*
- `false` — *"the transaction will be broadcast to the network and any errors returned in result"*

The `sendWith` option adds batching: *"Sends a batch of actions previously created as `noSend` actions to the network; either synchronously if `acceptDelayedBroadcast` is true or by a background process."*

The `sendWithResults` return type carries per-transaction status values (`:unproven`, `:sending`, `:failed`) — these are broadcast lifecycle states, not transaction states.

The spec is describing a queue without using the word. The interface (`enqueue`, `enqueue_batch`, `status`, `process_pending`) falls out mechanically from these semantics.

**Confidence:** Direct — the spec describes the behaviour; the interface names it.

---

## UTXOPool — strong derivation

**Source:** The `noSend` / `noSendChange` / `sendWith` transaction chaining mechanism and `abortAction`.

The key passage on `noSendChange`: *"Valid when `noSend` is true. May contain `noSendChange` outpoints previously returned by prior `noSend` actions in the same batch of chained actions."*

This describes a multi-step construction flow: build transaction A (unsent), take its change outputs, feed them as inputs to transaction B (also unsent), then `sendWith` both. Change outputs from A must be reserved — a concurrent caller must not select the same UTXOs.

`abortAction` reinforces this: if a transaction-in-progress can be cancelled, whatever was reserved for it must be released back to the pool.

Additional signals:
- `listOutputs` return values include `spendable: true` — outputs have a lifecycle
- BRC-46 baskets: *"conceptual containers for grouping UTXOs"* — managed output organisation
- The `PoolDepletedError` (insufficient UTXOs for a requested amount)

The spec implies reservation semantics. The pool pattern (acquire/release/add/remove/balance) is an architectural choice for expressing them.

**Confidence:** Strong — reservation semantics are implicit in the chaining mechanism; the pool abstraction is an architectural choice.

---

## Store — obvious but unspecified

**Source:** Every stateful method in the BRC-100 interface.

`listActions`, `listOutputs`, `listCertificates`, `discoverByIdentityKey`, `discoverByAttributes` — all query persisted state with filters and pagination. `internalizeAction` explicitly stores incoming transactions. Labels, tags, baskets, and certificates are organisational metadata that must survive between calls.

BRC-100 doesn't discuss persistence. It's an interface spec — it defines the contract between application and wallet, not wallet internals. Any wallet implementation needs a store; the spec informed the shape of its methods (what's queryable, what filters exist) but not the decision to have one.

**Confidence:** Obvious — implied by statefulness, not prescribed by the spec.

---

## ProofStore — inferential

**Source:** Foundational requirements sections 6 (BRC-67/BRC-62) and the `trustSelf` option.

Section 6: *"Wallets should utilize BEEF when constructing, communicating, and validating transactions. BEEF supports streaming validation..."*

The `trustSelf` option: *"input transactions may omit supporting validity proof data for TXIDs known to this wallet"* — "known to this wallet" implies the wallet maintains a cache of validated proofs.

`getHeaderForHeight` returns 80-byte block headers. If the wallet serves these, it stores them.

Separating proof storage from the main Store was an architectural judgement, not a spec requirement. The reasoning: proof data has different characteristics — write-once, immutable (until reorg), potentially prunable, keyed by txid rather than queried with the rich filter patterns the main store needs. A single Store interface with proof methods would satisfy the spec equally well; the separation is a bet on different access patterns and lifecycle.

**Confidence:** Inferential — the spec establishes the need for proof data; separation from Store is an architectural call.

---

## Summary

| Component      | BRC-100 source                                                        | Derivation |
|----------------|-----------------------------------------------------------------------|------------|
| BroadcastQueue | `acceptDelayedBroadcast`, `noSend`, `sendWith`, `sendWithResults`     | Direct     |
| UTXOPool       | `noSend`/`noSendChange` chaining, `abortAction`, spendable outputs   | Strong     |
| Store          | Every `list*`/`query` method, `internalizeAction`, baskets/labels/tags | Obvious    |
| ProofStore     | BRC-67/62 sections, `trustSelf`, `getHeaderForHeight`                 | Inferential |
