# Store / walletd Boundary — Reactive Store, Proactive Daemon

**Date**: 2026-05-22
**Status**: Architectural principle (emerging from atomicity audit)

---

## The Principle

**The store is reactive.** It accepts atomic writes and answers queries. It does not initiate anything. It does not listen for messages. It does not reach out to other components. It does not orchestrate multi-step processes.

**walletd is proactive.** It observes state (discovery queries), coordinates work (omq messaging), handles network I/O, and delivers complete instructions to the store. All orchestration lives here.

The store is the vault. walletd is the nervous system. The vault doesn't make phone calls — the nervous system brings things to it.

---

## The Smell: Proactive Store Models

`Action#write!` is the canonical example of the boundary violation:

```ruby
def write!(response)
  data = response.data
  return unless data.is_a?(Hash) && data[:merkle_path] && data[:block_height]

  proof_store = BSV::Wallet::Store::ProofStore.new  # ← reaches out
  proof_id = proof_store.save_proof(wtxid: wtxid, proof: { ... })  # ← write 1
  update(tx_proof_id: proof_id)  # ← write 2, not in a transaction
end
```

Problems:
1. **Not atomic** — two writes without a transaction. Crash between them = orphaned proof, unlinked action.
2. **Store reaches out** — a model instantiates another store component. The data layer is doing orchestration.
3. **Coupled to network response shape** — a store model knows about `ProtocolResponse` data format.

---

## The Correct Flow

```
WRONG (proactive store):

  Services.fetch!(action)
    → network call
    → action.write!(response)
      → proof_store.save_proof(...)    ← store orchestrating
      → action.update(tx_proof_id:)   ← non-atomic

RIGHT (reactive store):

  walletd:  discovers action needs proof
  walletd:  → sends "fetch proof" to network service
  network:  → returns proof data to walletd
  walletd:  → store.link_proof_to_action(action_id:, proof_data:)  ← one atomic write
```

The store receives a complete, pre-digested instruction. One method call, one transaction, all-or-nothing. walletd did the coordination. The store just writes.

---

## What "Reactive" Means Concretely

A reactive store model:
- **Has** derived status methods (`derived_status`, `needs_push?`, `needs_fetch?`) — these are queries, not actions
- **Has** attribute accessors and associations
- **Does NOT** instantiate other store components
- **Does NOT** make network calls
- **Does NOT** perform multi-step writes without a transaction
- **Does NOT** know about response formats from external services

A reactive store method:
- Accepts complete data (not raw network responses)
- Wraps multi-table writes in a transaction
- Returns simple results (IDs, booleans, hashes)
- Has no side effects beyond the database

---

## What "Proactive" Means Concretely

walletd (the proactive layer):
- **Discovers** what needs doing (structural queries via store)
- **Coordinates** network calls (via Services/omq)
- **Transforms** network responses into store instructions
- **Delivers** atomic write instructions to the store
- **Sequences** multi-step workflows (fetch proof → link to action → update broadcast)

The proactive layer is where Pushable/Fetchable's `write!` logic should live — in walletd's task handlers, not in the models.

---

## The omq Wiring

With omq patterns, the flow becomes message-driven:

```
walletd reactor:
  ├── fiber: discovery loop
  │     └── PUSHes "proof-needed" messages for unproven actions
  │
  ├── fiber: network worker
  │     ├── PULLs "proof-needed"
  │     ├── calls Services.fetch
  │     └── PUSHes "proof-arrived" with proof data
  │
  └── fiber: store writer
        ├── PULLs "proof-arrived"
        └── store.link_proof_to_action(action_id, proof_data)  ← atomic
```

Each fiber does one thing. The store writer only writes. The network worker only fetches. The discovery loop only queries. Messages connect them. Crash any fiber — the others continue. Restart — discovery re-finds the work.

---

## Audit Checklist

For each store model, check:

- [ ] Does `write!` exist? What does it do?
- [ ] Does it instantiate other store components?
- [ ] Does it perform multiple writes? Are they in a transaction?
- [ ] Does it know about network response formats?
- [ ] Could the orchestration move to walletd?

Known models to audit:
- `Action` — `write!` creates TxProof + links to action (NOT atomic)
- `Broadcast` — `write!` updates broadcast columns from response
- Any store method that touches multiple tables

---

## The Bigger Pattern

This boundary maps to the declarative/imperative split discussed in the wallet-node-architecture review:

| | Store (reactive/declarative) | walletd (proactive/imperative) |
|---|---|---|
| **Does** | Atomic reads and writes | Coordination, sequencing, I/O |
| **Knows about** | Schema, constraints, queries | Network, messaging, workflows |
| **Initiates** | Nothing | Everything |
| **State** | Database (persistent, shared) | In-flight work (ephemeral, per-process) |
| **Fails** | Atomically (transaction rollback) | Gracefully (retry via rediscovery) |
| **Scales** | Connection pooling, read replicas | Ractors, PUSH/PULL fan-out |

The store is the thing you can trust. walletd is the thing that makes it useful.

---

**This document should be referenced when auditing store models and when designing walletd task handlers. The principle: if a store model is doing something other than reading or atomically writing, that logic belongs in walletd.**
