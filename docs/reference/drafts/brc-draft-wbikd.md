---
title: "BRC draft: WBIKD"
parent: Reference
nav_order: 15
---

# BRC-XXXX: Legacy Address Generation via Wallet Basket Locking

Simon Bettison (simon@bettison.org)

## Abstract

This proposal defines a method for generating legacy P2PKH receive addresses using only the primitives defined by the [BRC-100](../wallet/0100.md) wallet interface. A wallet creates pre-funded UTXO "slots" in a dedicated basket, locks each slot with a zero-output action to reserve an address, and derives the address deterministically using [BRC-42](../key-derivation/0042.md) key derivation. An on-chain OP_RETURN marker enables address recovery from the identity key alone, without requiring any specific storage implementation.

## Motivation

[BRC-29](../payments/0029.md) payments require both sender and recipient to have BRC-100 compliant wallets. The sender performs [BRC-42](../key-derivation/0042.md) key derivation, constructs the transaction, and delivers the [BEEF](../transactions/0095.md) directly to the recipient.

However, many BSV participants — exchanges, legacy wallets, and automated systems — cannot perform BRC-42 derivation or deliver BEEF. They need a plain P2PKH address string. The recipient's wallet must generate that address, monitor it for incoming funds, and internalize those funds when they arrive.

This specification addresses three problems:

1. **Address generation** — deriving unique P2PKH addresses from the wallet's identity key using only BRC-100 primitives
2. **Address tracking** — maintaining a list of outstanding addresses without introducing new storage structures
3. **Address recovery** — enabling fund recovery from the identity key alone when the wallet's local state is lost

## Specification

### Terminology

- **Slot** — a pre-funded UTXO held in a designated basket, serving as the basis for address derivation
- **Locking action** — a zero-output, non-broadcast action whose sole purpose is to claim a slot and establish derivation parameters
- **Slot basket** — a [BRC-99](../wallet/0099.md) protocol-reserved basket named `p wbikd` (Wallet Basket Identity Key Derivation)

### 1. Slot Creation

The wallet creates slot UTXOs by broadcasting a self-payment into the slot basket.

1. Generate a random derivation prefix and suffix<sup>[1](#footnote-1)</sup>
2. Derive a public key using [BRC-42](../key-derivation/0042.md) with `counterparty = "self"`, `protocolId = [2, prefix]`, `keyId = suffix`
3. Construct a [P2PKH](../scripts/0016.md) locking script from the derived public key
4. Create an action via [BRC-100 `createAction`](../wallet/0100.md) with:
   - One output locked to the derived script, assigned to basket `p wbikd`
   - A random satoshi amount (e.g., 100–1000 sats)
   - An OP_RETURN output containing a recovery marker (see §5)
5. Broadcast the transaction

The random satoshi amount ensures slot creation transactions are indistinguishable from normal wallet activity on-chain. Broadcasting is essential — it releases any change from the funding inputs back to the wallet's spendable set.

Multiple slots may be created in a single transaction by including multiple outputs assigned to the slot basket.

### 2. Address Generation

To generate a receive address, the wallet locks an available slot and derives a P2PKH address from deterministic parameters.

1. Query the slot basket for an available (unlocked) output using [BRC-100 `listOutputs`](../wallet/0100.md) with `basket = "p wbikd"`
2. If no slot is available, create one per §1
3. Lock the slot by creating a non-broadcast action (`broadcast = 'none'`,
   an internal-path action that never goes to ARC) with:
   - One input referencing the slot output
   - Zero outputs
   - Label `"wbikd"` attached to the action
4. Compute derivation parameters:
   - `derivationPrefix` — the transaction ID (display-order hex) of the slot's source transaction
   - `derivationSuffix` — the output index (vout) of the slot, encoded as a decimal string
5. Derive a public key using [BRC-42](../key-derivation/0042.md) with `counterparty = "self"`, `protocolId = [2, derivationPrefix]`, `keyId = derivationSuffix`
6. Compute the P2PKH address: `Base58Check(0x00 || HASH160(derivedPublicKey))`
7. Return the address string and derivation parameters to the caller

The derivation parameters are deterministic from on-chain data (transaction ID and output index of the slot). They do not depend on any wallet-internal identifiers.

### 3. Address Monitoring

Outstanding addresses are discoverable by querying the wallet's action list.

1. Query actions with label `"wbikd"` using [BRC-100 `listActions`](../wallet/0100.md) with `includeInputs = true`
2. Filter for actions with `internal` status (active locks — non-broadcast internal-path actions)
3. For each active lock, re-derive the address from the input's source transaction ID and output index per §2 steps 4–6
4. Check each address for unspent outputs using a UTXO lookup service

This monitoring can run as a periodic background task within the wallet's existing daemon infrastructure.

### 4. Fund Internalization and Slot Recycling

When funds are discovered at a monitored address:

1. Fetch the raw transaction from the network
2. Verify the output at the discovered vout is P2PKH locked to the expected derived public key
3. Record the output as spendable, associating it with the derivation parameters (`derivationPrefix`, `derivationSuffix`, counterparty `"self"`) so the wallet can derive the corresponding private key for spending
4. Tag the recorded output with `"wbikd"` for future sweep scanning (see §6)
5. Abort the locking action using [BRC-100 `abortAction`](../wallet/0100.md)

Aborting the locking action releases the slot output back to basket `p wbikd`, making it available for future address generation. The slot is recycled — no new funds need to be committed.

The recorded output is immediately spendable. The wallet derives the corresponding private key using the same [BRC-42](../key-derivation/0042.md) parameters that were used to derive the public key. How the wallet records the output — whether by constructing a BEEF envelope and calling `internalizeAction`, or via an internal import mechanism — is an implementation detail.

### 5. On-Chain Recovery Markers

Each slot creation transaction includes an OP_RETURN output containing a recovery marker. This enables address recovery from the identity key alone, without access to the wallet's local state.

The recovery marker is computed as:

```
marker = HMAC-SHA256(identityPrivateKey, satoshiAmount)
```

Where `satoshiAmount` is the decimal string representation of the slot output's satoshi value (e.g., `"537"`).

**Recovery procedure:**

1. For each candidate satoshi amount in the slot range (e.g., 100–1000):
   - Compute `expectedMarker = HMAC-SHA256(identityPrivateKey, amount)`
   - Scan the blockchain for OP_RETURN outputs containing `expectedMarker`
2. For each matching OP_RETURN, identify the sibling slot output in the same transaction
3. Derive the address using the slot's transaction ID and output index per §2
4. Check the derived address for unspent funds

The search space is bounded by the slot satoshi range. For a range of 100–1000, this requires 901 HMAC computations and corresponding OP_RETURN scans.

**Privacy properties:**

- The recovery marker is deterministic from the identity private key and the satoshi amount
- An observer who sees the OP_RETURN cannot link it to an identity public key without the private key
- An observer who knows both the slot transaction ID and output index cannot derive the receive address without the private key (BRC-42 with `counterparty = "self"` requires the private key for ECDH computation)

### 6. Sweep Scanning

Internalized outputs are tagged `"wbikd"` (§4 step 4). This enables periodic sweep scanning for additional payments to previously used addresses.

1. Query all outputs tagged `"wbikd"` using [BRC-100 `listOutputs`](../wallet/0100.md)
2. For each tagged output, re-derive the address from the stored `derivationPrefix` and `derivationSuffix`
3. Check each address for new unspent outputs not yet internalized

Sweep scanning addresses the case where a sender makes a second payment to a previously used address after the locking action has been aborted and the slot recycled. The `"wbikd"` tag on internalized outputs persists permanently in the wallet's output log, ensuring no address is forgotten.

### 7. Slot Lifecycle Summary

```
   [Create Slot]          Broadcast self-payment → slot output in basket "p wbikd"
        |                 OP_RETURN with recovery marker
        v
   [Generate Address]     Lock slot with zero-output non-broadcast action
        |                 Derive address from (slot txid, slot vout)
        v
   [Monitor]              Scan derived address for UTXOs
        |
        v
   [Internalize]          Import funds with derivation params, tag "wbikd"
        |
        v
   [Recycle Slot]         Abort locking action → slot returns to basket
        |
        v
   [Available]            Slot ready for next address generation
```

### 8. Security Considerations

**Address unlinkability:** Each slot produces a unique derived address. The derivation uses BRC-42 ECDH with `counterparty = "self"`, which requires the identity private key. Different slot transaction IDs and output indices produce unrelated addresses. An observer cannot link two generated addresses to each other or to the wallet's identity key.

**Slot transaction privacy:** Slot creation transactions are standard P2PKH self-payments with random amounts. They are indistinguishable from normal wallet activity on the blockchain.

**Recovery marker privacy:** The OP_RETURN recovery marker is an HMAC keyed by the identity private key. Without the key, an observer cannot determine which OP_RETURNs are recovery markers or which identity they belong to.

**Address reuse:** This specification does not prevent a sender from making multiple payments to the same address. The sweep scan mechanism (§6) ensures such payments can be discovered. However, address reuse reduces privacy for the sender — standard Bitcoin address hygiene applies.

**Concurrent slot locking:** The wallet must ensure that a slot output cannot be claimed by two locking actions simultaneously. BRC-100 wallets already enforce single-spend semantics on inputs — a given output can only be consumed by one action at a time. The implementation mechanism (database constraint, in-memory lock, etc.) is wallet-specific, but the invariant must hold.

## Implementations

This specification is designed to be implementable by any [BRC-100](../wallet/0100.md) compliant wallet. It uses only standard wallet primitives:

- `createAction` with baskets, labels, and the wallet's internal non-broadcast action mechanism
- `abortAction` for slot recycling
- `listActions` with label filtering and input inclusion
- `listOutputs` with basket and tag filtering
- [BRC-42](../key-derivation/0042.md) key derivation with `counterparty = "self"`
- [BRC-99](../wallet/0099.md) protocol-reserved basket naming (`p wbikd`)

No additional storage tables, indexes, or wallet extensions are required.

## References

- <a name="footnote-1">1</a>: The random derivation value for slot creation is independent of the address derivation parameters. Slot derivation values protect the slot's own P2PKH output. Address derivation parameters are determined by the slot's on-chain identity (transaction ID and output index).
- [BRC-29](../payments/0029.md): Simple Authenticated BSV P2PKH Payment Protocol
- [BRC-42](../key-derivation/0042.md): BSV Key Derivation Scheme (BKDS)
- [BRC-43](../key-derivation/0043.md): Security Levels, Protocol IDs, Key IDs and Counterparties
- [BRC-84](../key-derivation/0084.md): Linked Key Derivation Scheme
- [BRC-99](../wallet/0099.md): P Baskets — Allowing Future Wallet Basket and Digital Asset Permission Schemes
- [BRC-100](../wallet/0100.md): Unified, Vendor-Neutral, Unchanging, and Open BSV Blockchain Standard Wallet-to-Application Interface
