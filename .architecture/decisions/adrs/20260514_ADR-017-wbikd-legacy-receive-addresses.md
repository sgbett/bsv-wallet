# ADR-017: Legacy receive addresses via WBIKD, on existing machinery

## Status

Draft — the capability is implemented against the *draft* WBIKD BRC (`docs/reference/drafts/brc-draft-wbikd.md`, not yet a ratified standard); daemon automation of address scanning (HLR #114) is still pending.

**Decided:** 2026-05-14 (commit `b2fba01`, PR #109 — "feat: on-chain derivation params and OP_RETURN recovery markers (#108)"; HLR #108, WBIKD store-agnostic redesign) — the store-agnostic redesign that derives from on-chain txid/vout (not database integer IDs) and recovers via OP_RETURN markers, the design recorded here, superseding the original DB-ID derivation (HLR #102).

## Context

BRC-29 payments require both parties to run a BRC-100 wallet: the sender performs BRC-42 derivation, builds the transaction, and delivers BEEF directly. Many BSV participants — exchanges, legacy wallets, automated systems — cannot do any of that. They have only a plain P2PKH address string. To accept funds from them the wallet must generate a receive address, watch it for incoming UTXOs, and internalize what arrives.

The draft BRC `docs/reference/drafts/brc-draft-wbikd.md` (Wallet Basket Identity Key Derivation, "WBIKD") specifies how to do this using only BRC-100 primitives: a slot UTXO in a protocol-reserved basket, a zero-output locking action that reserves an address, BRC-42 derivation with `counterparty = "self"`, and an on-chain OP_RETURN marker for recovery. The question this ADR answers is how the wallet implements that capability — and, specifically, what the derivation parameters are made from, because that choice fixes whether funds can be recovered without the wallet's database.

This capability is **implemented** in `gem/bsv-wallet/lib/bsv/wallet/engine.rb` (`generate_receive_address`, `list_receive_addresses`, `scan_receive_addresses`, and the private `find_or_create_wbikd_slot`, `compute_wbikd_marker`, `internalize_wbikd_utxo`), covered by `spec/bsv/wallet/engine/wbikd_spec.rb`. The BRC it implements is a **draft**, authored here, not yet a ratified standard.

## Decision Drivers

* **No parallel subsystem.** A receive-address feature must not introduce its own tables, watchlist, or address registry. The wallet already has actions, inputs, baskets, labels, and tags; the watchlist should *be* the database (ADR-003).
* **On-chain recoverability.** If the database is lost but the identity key is retained, funds sent to a generated address must be recoverable. That forces the derivation parameters to be enumerable or discoverable from the chain, not random.
* **Store-agnostic portability.** The draft BRC is meant to be implementable by any BRC-100 wallet. Tying derivation to *our* schema's identifiers would make it un-portable (HLR #108).
* **Single-spend on a slot.** Two locking actions must never claim the same slot; the mechanism must rest on an invariant the schema already enforces.

## Decision

**Build WBIKD on the existing action/basket/derivation machinery — no new tables.** A slot is a pre-funded UTXO assigned to the BRC-99 protocol-reserved basket `p wbikd`. Generating an address locks one slot with a zero-output, `broadcast_intent = :none` locking action labelled `wbikd`; the outstanding-address list is just `list_actions(labels: ['wbikd'])` filtered to `:internal` status (active locks). Single-spend on a slot is the `UNIQUE(output_id)` lock on `inputs` (ADR-004) — a concurrent claim is caught and retried, not coordinated in Ruby.

**Derive the address from on-chain data: the slot's source transaction and output index.** `derivation_prefix` is the slot's source transaction display-order txid (a `dtxid`, 64-char hex); `derivation_suffix` is the slot's vout as a decimal string. BRC-42 derives the receive key with `protocol_id = [2, derivation_prefix]`, `key_id = derivation_suffix`, `counterparty = "self"`; the P2PKH address is `Base58Check(0x00 || HASH160(derivedPublicKey))`. These parameters depend only on the blockchain — no database identifier participates — so the same parameters re-derive the same address on any wallet (`engine.rb` `generate_receive_address`, `list_receive_addresses`; `wbikd_spec.rb` "produces a deterministic address from the same derivation params").

**Each slot-creation transaction carries an OP_RETURN recovery marker** `HMAC-SHA256(identityPrivateKey, satoshiAmountString)`, the slot output taking a random satoshi value in 100–1000 (`engine.rb` `compute_wbikd_marker`, `find_or_create_wbikd_slot`; `wbikd_spec.rb` "compute_wbikd_marker"). With the database gone, recovery enumerates the bounded satoshi range, recomputes each expected marker, scans the chain for matching OP_RETURNs, and from each matching transaction takes the sibling slot output's txid/vout to re-derive the address (draft BRC §5). The marker is keyed by the identity *private* key, so it leaks neither the identity nor the address to an observer.

**On receipt the slot is recycled.** `scan_receive_addresses` queries the network for UTXOs at each outstanding address; `internalize_wbikd_utxo` fetches the raw transaction, verifies the output is P2PKH locked to the expected derived key, records it spendable with the BRC-42 derivation parameters and a `wbikd` tag, best-effort links a merkle proof, then aborts the locking action — which releases the slot back to `p wbikd` for reuse. The `wbikd` tag persists on the immutable output row (ADR-010/011), so a later sweep can re-derive historical addresses and catch repeat payments after the lock is gone.

**Why the marker is a *recovery* aid, not a supersession signal.** The OP_RETURN exists to make a slot discoverable from the identity key alone (draft BRC §5). It is not a chain-published "this address is superseded" flag, and the implementation does not treat it as one. Repeat-payment handling is the sweep over `wbikd`-tagged outputs (§6), not the marker.

Slot derivation (the random `BSV::Wallet.random_derivation` prefix protecting the slot's *own* output, `wallet.rb`) is independent of address derivation (the txid/vout parameters). Conflating the two is the error footnote 1 of the draft warns against.

## Alternatives Considered

### A. Derive parameters from database integer IDs

The original design (HLR #102, merged): `derivation_prefix = base64(int64 action.id)`, `derivation_suffix = base64(int64 output.id)`. Enumerable for recovery — walk `action_id × output_id` and check each derived address.
**Pros:** recoverable by bounded enumeration; trivially deterministic; no OP_RETURN needed.
**Cons:** couples recovery to *this* schema's sequential `bigint` primary keys; a wallet on another store would have to maintain its own monotonic sequences to match; not expressible in the store-agnostic draft BRC.
**Rejected** — superseded by HLR #108. On-chain parameters (txid/vout) give the same recoverability without binding the scheme to our primary-key allocation, so the capability ports to any BRC-100 wallet. (The current code carries one stale docstring header asserting the old integer-ID rationale — tracked in #308 — but the code path derives from txid/vout.)

### B. A dedicated address / watchlist table

Track generated addresses and their derivation parameters in a purpose-built table.
**Pros:** an explicit, directly queryable list of outstanding addresses.
**Cons:** a parallel subsystem beside canonical state — exactly what ADR-003 forbids. The action/basket/label structure already expresses "outstanding address" (an `:internal` `wbikd`-labelled lock); a second store would be a projection that can drift.
**Rejected** — the database is the watchlist; outstanding addresses are a structural query, not a maintained list.

### C. Random (UUID) derivation parameters

Use random values for the prefix/suffix, as reference wallets do for ordinary derivation.
**Pros:** simplest to generate; no chain dependency.
**Cons:** destroys recoverability — 128-bit random space is not enumerable, so a lost database means lost funds with no recovery path.
**Rejected** — recoverability is a decision driver; random parameters forfeit it.

## Consequences

### Positive

* No new tables, indexes, or watchlist: the feature is BRC-100 primitives over canonical state (ADR-003). Outstanding addresses, recycling, and single-spend all fall out of existing structure.
* Recoverable from the identity key alone, with the chain — and the recovery scheme is store-agnostic, so the draft BRC is implementable by other wallets.
* The `wbikd` tag on the immutable output row keeps historical addresses sweepable after the lock is aborted and the slot recycled.

### Negative

* Recovery is an O(satoshi-range × chain-scan) enumeration, not a lookup — deliberately "security as an economic function": the cost scales with how many addresses were ever generated, justified only when the lost funds warrant it.
* Slot creation must broadcast (to release funding change back to spendable and to publish the OP_RETURN marker), so generating the *first* address depends on network acceptance — not a pure local operation.
* The locking action and recovery marker add an OP_RETURN and a zero-output internal action per slot; minor on-chain and bookkeeping overhead.
* WBIKD locks are a deletable `broadcast_intent = 'none'` action, distinct from received-UTXO history; migration 008's `prevent_internal_action_delete` trigger keys on *promoted outputs* precisely so these ephemeral locks stay deletable while history does not — an invariant that must be kept in mind when touching that trigger.

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

The feature reuses canonical machinery rather than standing up a parallel subsystem (the rejected Alternative B), which is the cheaper and safer design and aligns with ADR-003. The on-chain-parameter choice is not speculative: it replaces a shipped integer-ID design (Alternative A, HLR #102) that worked but bound recovery to this schema's keys; the redesign (HLR #108) buys store-agnostic portability at the cost of one OP_RETURN per slot — proportionate. The enumeration cost is honestly framed as economic, not hidden. The one untidy edge is a stale docstring header still asserting the superseded rationale; that is a doc bug to fix, not a design flaw. **Approve.**

## Validation

* `derivation_prefix` is the slot source `dtxid` (64-char hex) and `derivation_suffix` is the slot vout (decimal string); re-deriving from the returned parameters reproduces the same address (`wbikd_spec.rb`).
* Outstanding addresses are `:internal` `wbikd`-labelled locks; aborting a lock removes the address from `list_receive_addresses` and returns the slot to `p wbikd` (`wbikd_spec.rb` "excludes aborted actions", "recycles the slot back to basket p wbikd").
* Each slot-creation transaction carries an OP_RETURN `HMAC-SHA256(identity_private_key, satoshi_string)` marker; markers differ per amount and are deterministic per amount (`wbikd_spec.rb` "compute_wbikd_marker").
* No new table backs the feature; the watchlist is the action/basket/label structure (ADR-003).
* The `prevent_internal_action_delete` trigger leaves zero-output WBIKD locks deletable while protecting promoted-output history (migration 008).

## References

* `docs/reference/drafts/brc-draft-wbikd.md` — the draft BRC this implements (slot, locking action, OP_RETURN recovery marker, sweep).
* `gem/bsv-wallet/lib/bsv/wallet/engine.rb` — `generate_receive_address`, `list_receive_addresses`, `scan_receive_addresses`, `find_or_create_wbikd_slot`, `compute_wbikd_marker`, `internalize_wbikd_utxo`.
* `gem/bsv-wallet/spec/bsv/wallet/engine/wbikd_spec.rb` — behavioural coverage.
* `gem/bsv-wallet/db/migrations/008_prevent_internal_action_delete.rb` — the WBIKD-lock carve-out in the delete-guard trigger.
* ADR-003 — schema as canonical state; the watchlist is the database, not a parallel store.
* ADR-008 — binary internally, hex at boundaries (the `dtxid` derivation prefix is a boundary hex string; the identity key is the documented hex carve-out).
* ADR-010 — derivation data on the immutable `outputs` row; the `wbikd` tag survives spending for sweep.
* ADR-014 — import-as-rescue; sibling recoverability theme (funds recoverable from on-chain material, not solely from local state).
* HLR #102 — original WBIKD (database integer-ID derivation, merged). HLR #108 — store-agnostic redesign (on-chain txid/vout parameters + OP_RETURN recovery markers), the design recorded here.
