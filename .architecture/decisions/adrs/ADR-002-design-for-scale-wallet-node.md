# ADR-002: Design for Bitcoin SV scale — the wallet-node model

## Status

Accepted.

## Context

Bitcoin SV's thesis is unbounded on-chain throughput. A wallet built for occasional payments — the browser-resident, promise-returning model — is a client, not infrastructure, and cannot meet that. We are building a wallet meant to run as a persistent process and sustain high transaction rates.

The shape that follows is a *wallet node*. `walletd` hosts the wallet library — as Unicorn hosts a Rack app, hosting it rather than containing it — runs the background loops, and scales horizontally as multiple workers sharing one database, with contention resolved structurally (the single-spend `UNIQUE` constraint, not application locks). BRC-100's JSON interface is the human- and RPC-convenience layer, the way `bitcoin-cli` fronts `bitcoind`; the substantive path is binary, wallet to wallet.

## Decision Drivers

* BSV targets unbounded throughput; the wallet's data layer has to be able to match it.
* Wallets mostly talk to wallets (payments); blockchain fetch and broadcast are secondary.
* Bitcoin is deliberately lean and binary; an ABI-over-sockets path is the endgame.
* The structural costs taken elsewhere — immutability, partitioning, derived state, a tiered UTXO pool — need a justification, and this is it.

## Decision

Design for Bitcoin SV scale: millions of transactions per second as a design constraint, not occasional use.

* **Wallet-node model.** `walletd` is a persistent process that hosts the wallet, runs its background work, and scales horizontally across workers sharing one database; contention is resolved by the schema, not application-level locking.
* **JSON is the convenience skin; binary is the protocol.** BRC-100's JSON surface is RPC convenience; the scaling path is a binary ABI between wallet nodes.
* **This scale target is the justification the structural decisions cite.** Immutability (ADR-011), the outputs/spendable partition, derived state, and the tiered UTXO pool are each warranted by this target; absent it, several would be over-engineering.

## Alternatives Considered

### A. Design for ordinary wallet scale (browser / occasional use, JSON + promises)
Simpler, and adequate for a payments client — but it does not meet BSV's throughput thesis, and retrofitting scale into a client-shaped schema is a rebuild. **Rejected.**

### B. Build for current needs, optimise for scale later
The structural choices that buy scale must live in the schema from the start; bolting them on afterwards means re-deriving the data model. Here deferral is not cheaper, only later. **Rejected.**

## Consequences

### Positive
* The downstream structural decisions have one explicit justification to point at, rather than each re-arguing scale.
* Horizontal scaling falls out of a shared database with structural single-spend.
* The design is positioned for the binary-ABI endgame.

### Negative
* Front-loads complexity that is marginal at ordinary volumes — a deliberate, conscious bet.
* Commits to a heavier design than a payments client needs.

### Load-bearing
* This target is the assumption the structural ADRs rest on. Were it abandoned, those decisions — ADR-011 in particular — would be the ones to revisit.

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

This is the design's one large forward bet, made consciously. **Necessity** rides on the project's goal: targeting BSV's throughput is a stated aim, not a hypothetical, so necessity is high *given that aim* — and the honest move is to name it as the assumption everything else cites. **Complexity** is high, but concentrated here as the justification, which keeps the downstream ADRs pointing at one place rather than each re-arguing it. **Recommendation: ✅ Approve**, with the explicit note that this is the load-bearing scaling assumption and the structural ADRs are conditional on it. The over-engineering risk is real only if the scale goal is not — so it is the goal, not the structure, that must be kept honest.

## Validation

* `walletd` hosts the wallet and runs its background loops; multiple workers can share one database.
* Single-spend contention is resolved by a `UNIQUE` constraint, not application locks.
* The structural ADRs cite this target as their justification.

## References

* ADR-003 (principle of state) and ADR-011 (tempered immutability) — both rest on this target.
* `.architecture/reviews/wallet-node-architecture.md` — the wallet-node framing in full.
