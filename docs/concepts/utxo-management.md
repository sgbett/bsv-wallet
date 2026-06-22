# UTXO Management

A wallet that sends often lives or dies by how it manages its UTXO set. This gem treats the spendable set as something to be actively *shaped* — kept at a healthy count, split for parallelism, replenished as it drains, and consolidated when it fragments. This page covers selection, locking, change generation, the pool-growth strategy, and the consolidation and sweep operations.

## Selection and locking are separate

A subtle but important separation: the **pool recommends, the store locks.**

`UTXOPool#select(satoshis:)` returns candidate outputs sufficient to cover a target value, but those candidates are *not* reserved by the act of selecting them. The actual claim happens in `Engine::FundingStrategy` (Phase 1), which inserts a row into the `inputs` table for each chosen output through `Store#lock_inputs`. That table has a `UNIQUE` constraint on `output_id`, so the database itself enforces single-spend: if two actions race for the same UTXO, one insert wins and the other fails. There is no application-level "reserved" flag that a crash could leave dangling — the lock and the spend intent are the same row.

This is why `UTXOPool#release` is a no-op for the database-backed tiers: there is nothing to release, because selecting never reserved anything. An aborted action's `inputs` rows are removed by `ON DELETE CASCADE`, which frees the outputs automatically.

## Three tiers of pool

`Interface::UTXOPool` defines one contract with three intended implementations, trading simplicity for throughput:

| Tier | Strategy | Hot path | Status |
|------|----------|----------|--------|
| **1 — default** | Delegates to `Store#find_spendable`: a database query on every call. | One SQL query per selection. | Shipped — `Store::UTXOPool`. |
| **2 — pre-split** | Selects from a dedicated basket of pre-sized outputs. | A scoped database query with less contention. | Interface-defined; implementation deferred. |
| **3 — TxCache** | Dequeues from a pre-warmed in-memory queue; the dequeue *is* the reservation. | Pure memory, no per-call SQL. | Interface-defined; implementation deferred. |

The shipped concrete class, `Store::UTXOPool`, is the Tier 1 implementation. The tiering exists so that a deployment can move up to pre-split baskets or an in-memory cache *without changing the Engine* — the selection strategy is an injected collaborator behind a fixed interface. Tiers 2 and 3 are sketched against the same contract; no benchmark figures are claimed for either until they ship.

## Baskets

Outputs are organised into **baskets** — named groups with an optional replenishment policy (`target_count`, `target_value`). The `default` basket is implicit: an output with no `output_baskets` row belongs to it. Named baskets are how the wallet keeps purpose-specific outputs apart — most notably the `'p wbikd'` basket of pre-funded receive slots (see [Keys & Cryptography](keys-and-cryptography.md)).

`list_outputs(basket:)` and `balance` queries are basket-scoped, so an application can carve its funds into pools with different policies.

## The spendable set

"Spendable" has a precise structural definition (`Output.spendable`): an output that has a row in the `spendable` table **and** is not claimed by any row in the `inputs` table. The `spendable` table is the wallet's UTXO set; the `inputs` table is the set of claims against it. An output is spendable exactly when it is in the first and absent from the second. Outbound outputs (paid away to someone else) are forbidden a `spendable` row by a database trigger, so they can never be selected by mistake.

## The funding loop

`build_action` does not ask the caller to pre-compute fees or change. It runs a **funding loop** in `Engine::FundingStrategy` that converges on a balanced transaction by collaborating with `Engine::TxBuilder`:

1. `TxBuilder#build_change` templates the transaction with the currently locked inputs, the caller's outputs, and the right number of change outputs. It attaches P2PKH unlocking-script *templates* so the fee can be estimated accurately without signing.
2. The fee is computed by the wallet's single shared `fee_model` — `SatoshisPerKilobyte` defaulting to **100 satoshis per kilobyte**, overridable via `BSV_WALLET_FEE_RATE_SATS_PER_KB` so that `estimate_sweep_fee` can never drift from what is actually charged.
3. If the required fee exceeds the available surplus (inputs minus caller outputs, with change still at zero), the loop reports the **shortfall** and selects further inputs to cover it — excluding those already locked, and re-numbering `vin` contiguously.
4. Locking the top-up inputs is contention-checked: `Store#lock_inputs` returns how many rows it actually locked, and anything less than the batch size means a concurrent action took one, so the whole batch rolls back and FundingStrategy retries (bounded by `MAX_LOCK_RETRIES = 5`) before raising `InsufficientFundsError` rather than building an inconsistent transaction.

The loop bounds its own iterations (`max(spendable_count + 1, 2)`) so it can never spin. If the caller supplied their own inputs, there is no top-up — a shortfall is an immediate `InsufficientFundsError`.

## Change sizing: growing the pool

When the wallet generates change, it does not produce a single change output. It asks `change_output_count` how many to create, using a formula that actively grows the spendable set toward a healthy size:

```
target  = min(max_utxo_count, balance / min_utxo_sats)
deficit = target - spendable_count
result  = clamp(deficit, 1, max_change_per_tx)
```

With the defaults (`max_utxo_count: 500`, `min_utxo_sats: 1000`, `max_change_per_tx: 8`): the wallet aims for up to 500 spendable outputs (but never so many that the average dips below 1000 sats), creates enough change outputs each transaction to close the gap, always makes at least one (the remainder has to go somewhere), and never makes more than eight in a single transaction (so no one transaction bloats). A wallet that starts with one big output naturally fans out into a workable pool over its first several payments.

The remaining value is then **distributed across those change outputs randomly** (a Benford-style split, performed by the SDK's `change_distribution: :random`), and the output order is **shuffled** after fee distribution. Both are privacy measures: equal or predictably-ordered change outputs leak information about which output is change and how the wallet works. Change outputs whose share rounds to zero are dropped.

Change is paid to **BRC-42 self-derived** P2PKH addresses (`protocol_id: [2, prefix], key_id: suffix, counterparty: 'self'`), so even the wallet's own change uses fresh keys.

## Consolidation

Over time a spending wallet accumulates dust — many small outputs that are expensive to spend. `consolidate_step(target_inputs: 20)` folds the dustier tail back together: it consumes the `target_inputs` smallest spendable outputs plus the single largest as an anchor, and produces one BRC-42 self-derived output. It is a `no_send` (internal) action, so it commits synchronously without a broadcast. The `bin/consolidate` tool loops it until the wallet holds fewer than `target_inputs` spendable outputs.

This is the inverse of change sizing: sizing fans a wallet *out* toward a healthy count; consolidation pulls a *fragmented* wallet back in.

## Sweep

`sweep(recipient:)` builds a single transaction that consumes **every** spendable output and pays the lot (less fee) to the recipient's **root** P2PKH address — `hash160(recipient_pubkey)`, deliberately *not* a BRC-42 derived address. The point of a sweep is recoverability: the funds land somewhere a bare private key can reclaim them with no derivation metadata. This is the mechanism behind sweeping a wallet back to its SDK identity key, and `sweep_to_root` / `estimate_sweep_fee` support the same operation. See [Resilience & Recovery](resilience-and-recovery.md) for why this matters.
