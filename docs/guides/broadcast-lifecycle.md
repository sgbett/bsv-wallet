---
title: Broadcast lifecycle
parent: Guides
nav_order: 2
---

# Broadcast Lifecycle

How an action goes from "create" to a confirmed, spendable output. This is
the subtle core of the wallet — action creation is a four-phase state
machine, and output promotion is speculative. Understanding it explains why
outputs become spendable when they do, and what happens when the network
later disagrees.

(The BRC-100 method `engine.brc100.create_action` delegates to the Engine's
`build_action` primitive, which drives the four phases below.)

## The four phases of action creation

```
Phase 1            Phase 2          Phase 3          Phase 4
lock inputs   ->   fund        ->   broadcast   ->   promote outputs
(atomic)           (funding loop)   (inline/queued)  (on ARC accept)
```

1. **Lock inputs.** Resolve the initial input set (caller-supplied, or
   wallet-selected for the output total) and insert the action row plus the
   input rows in one atomic `Store#create_action`. The `inputs.output_id`
   UNIQUE constraint is the lock.
2. **Fund.** The funding loop templates the transaction, computes the exact
   fee, and either returns a finished transaction or a shortfall. On a
   shortfall (for wallet-selected inputs) it tops up via further selection
   and re-evaluates; caller-supplied shortfalls raise
   `InsufficientFundsError` immediately.
3. **Broadcast.** Either inline (synchronous) or queued for the daemon — see
   below.
4. **Promote outputs.** Insert a `promotions` row for the action (gated on
   the ARC response) and insert `spendable` rows for its owned outputs.
   Promotion is a row, not a flag (ADR-023, promotion-as-a-row).

## Funding: fees and change

Fees default to **100 sat/KB** (`SatoshisPerKilobyte`, configurable via
`BSV_WALLET_FEE_RATE_SATS_PER_KB`). The funding loop is careful for one
specific reason: the SDK's `Transaction#fee` silently drops all change when
funds are insufficient, which would mask a shortfall. So the wallet computes
the fee against the *templated* transaction itself and compares it to
`total_input_satoshis - sum(caller_outputs)`. Only when the surplus exceeds
the required fee does it distribute change — randomly across change outputs
for privacy — and any change output whose share rounds to zero is dropped.

The build order matters: template -> fee check -> distribute change ->
shuffle -> sign. Templates precede the fee because size estimation needs
them; the shuffle precedes signing because the sighash commits to final
output positions.

## Inline versus delayed broadcast

| Mode | What happens | When |
|---|---|---|
| **Inline** | Synchronous POST to ARC; the response gates promotion immediately | `accept_delayed_broadcast: false` |
| **Delayed** | A `broadcasts` row is queued; the daemon pushes it later | default |

A delayed broadcast lands nothing until `walletd` is running — see
[Operating the Daemon](operating-the-daemon.md).

## Transmission is parallel to broadcast (not a phase of it)

Broadcast and transmit are independent edges off the same action, not a
pipeline. Broadcast hands a transaction (Extended Format) to a miner;
transmit hands an Atomic BEEF to a named peer for SPV verification. An
action may broadcast and never transmit, transmit and never broadcast, both,
or neither — see [reference/transactions.md](../reference/transactions.md)
for the canonical distinction.

In **v1, transmission runs inline / synchronous from the engine call.** When
you invoke `engine.transmission.transmit(endpoint:, ...)`, the caller awaits
the HTTP POST + ACK validation; the deferred caller-driven path
(`endpoint: nil`) returns the BEEF immediately and leaves you to deliver it.
A daemon-driven async path is Phase 2 — same code shape, different
invocation mode, mirroring the broadcast inline/delayed split. The `walletd`
daemon does **not** drive transmission today.

## Speculative promotion

The wallet promotes outputs optimistically on *any non-rejected* ARC status,
so a chain of dependent spends unblocks immediately rather than waiting for
confirmation. The status taxonomy (defined in `BSV::Wallet::ArcStatus`):

- **Accepted** — `SEEN_ON_NETWORK`, `SEEN_MULTIPLE_NODES`,
  `ACCEPTED_BY_NETWORK`, `MINED`, `IMMUTABLE`
- **Rejected** — `REJECTED`, `DOUBLE_SPEND_ATTEMPTED`
- **In-flight** — anything else; treated as not-yet-rejected, so the wallet
  promotes and trusts the poll loop to resolve it.

If the network later rejects a transaction, `reject_action` runs a forward
cascade that unwinds the promoted descendants. In-flight is deliberately
*not* treated as rejected.

## Crash-recovery invariants

The code pairs writes into single transactions specifically so that any
crash leaves a *recoverable* intermediate state:

- `broadcast_at` is stamped in a committed transaction **before** the
  network POST, so a crash mid-POST leaves a recognisable
  `broadcast_at NOT NULL, tx_status NULL` state the poll loop resolves via a
  `GET /tx`.
- Output promotion happens in the **same transaction** as recording the
  broadcast result, closing the gap where a process could die between
  recording status and promoting.
- A reaper reclaims abandoned signed actions — but only those with no
  promoted output. Anything that reached the canonical UTXO set is
  protected.

## SPV is asymmetric

- **Incoming** transactions get full SPV verification:
  `Transaction#verify(chain_tracker:)` checks scripts, merkle proofs, and
  fee adequacy. A chain tracker is required.
- **Outgoing** BEEF is built from the wallet's own proof store with no
  verification — verification is for incoming, untrusted data only.
