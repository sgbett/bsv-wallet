# Transactions, BEEF & SPV

A wallet that does not run a full node still has to answer one hard question about every payment it receives: *is this real?* This gem answers it with **SPV** (Simplified Payment Verification) over **BEEF** envelopes, and it does so **fail-closed** — if it cannot prove a payment, it rejects it.

This page covers how outgoing transactions are packaged, how incoming ones are verified, the `trustSelf` optimisation, and the byte-order convention that runs through the whole data model. For the broadcast-versus-transmit distinction — the two ways a signed transaction leaves the wallet — see [Transactions (reference)](../reference/transactions.md).

## BEEF: shipping a transaction with its evidence

A bare transaction is not independently verifiable — you cannot tell whether its inputs existed or were already spent. **BEEF** (Background Evaluation Extended Format, BRC-62) solves this by bundling a transaction together with its **ancestry**: the chain of parent transactions and the merkle proofs that anchor them to mined blocks. The proofs ride on the bundle as **BUMPs** (BSV Unified Merkle Path, BRC-74). **Atomic BEEF** (BRC-95) is the single-subject form the wallet produces for one action.

With a BEEF envelope, a recipient can verify a payment entirely from the bundle plus block headers — no mempool lookups, no trusted third party for the transaction graph itself. This is what makes a server-side SPV wallet practical.

## Outgoing: building Atomic BEEF

When an action is built, `Engine::Hydrator#build_atomic_beef` walks the ancestor graph and assembles the raw transaction together with the proofs of its ancestry into a `BSV::Transaction::Beef` bundle. That bundle is what `build_action` returns as the `atomic_beef:` field (translated to `tx:` at the BRC-100 wrap layer) — ready to hand to the counterparty so they can verify and internalise it. The wallet stores the proofs it knows (`save_beef_proofs`) so it can reconstruct ancestry for future sends without re-fetching.

Hydration is wtxid-cached. A shared `Engine::HydratedTxCache` sits between `Hydrator` (deep BEEF walks) and `Engine::Broadcast` (Extended Format parent reads at submit time), so a transaction warmed by one path is visible to the other. The cache is bounded and monotonically enriched, configured by `BSV_WALLET_TX_CACHE_SIZE`.

The two-step model — Hydrator owns the egress walk, BeefImporter owns the ingress — keeps the directions one-way and decoupled. The shared substrate is the cache, not a back-edge.

## Incoming: parse, then verify, then trust

Receiving is `internalize_action(tx:, outputs:, …)`, routed through `Engine::BeefImporter`. The order of operations is the important part:

1. **Parse.** `parse_beef` decodes the envelope into a `Beef` bundle and locates the *subject* transaction. A bundle with no transactions, or one whose subject is missing, is rejected as `InvalidBeefError` before any trust is extended.
2. **Verify.** `verify_incoming_transaction!` calls the SDK's `subject_tx.verify(chain_tracker:)`, which performs full SPV: it checks every merkle proof against the block headers the chain tracker supplies and confirms the script evaluation. Any `VerificationError` is wrapped as `InvalidBeefError` with the SDK's error code — the payment does not enter the wallet.
3. **Record.** Only verified outputs are internalised. The output specs carry the BRC-42 derivation parameters (`derivation_prefix`, `derivation_suffix`, `sender_identity_key`) needed to later *spend* them, and a `basket insertion` protocol places them in the chosen basket. The proofs are saved so the received outputs are themselves provable when re-spent.

The internalised action is `broadcast_intent: 'none'` — an [internal action](action-lifecycle.md) — and its outputs are promoted in the same transaction as the ancestor proofs are saved, because the payment has already been proven against the chain.

!!! note "Fail-closed by construction"
    There is no "accept unverified" path. If no chain tracker is configured, verification raises rather than waving the payment through. The wallet would rather refuse a real payment than admit a fake one.

## `trustSelf`: not re-proving what you already know

When two parties transact repeatedly, the sender's BEEF will keep including ancestors the recipient *already has proofs for*. Re-shipping and re-verifying them is wasted work. The `trustSelf: 'known'` option optimises this in both directions:

- **Sending** — `Hydrator#replace_known_ancestors!` rewrites the BEEF so that ancestors the recipient is known to hold become **TXID-only entries**: a reference rather than the full transaction and proof. The envelope shrinks to just the novel part of the graph.
- **Receiving** — `Hydrator#hydrate_known_sources!` fills those TXID-only entries back in from the wallet's own stored transactions before verification, so SPV still runs over a complete graph.

The trust is bounded and explicit: only ancestors the wallet itself already holds are elided, and they are rehydrated from local truth, not taken on faith from the sender.

The same trim mechanism, layered on top with per-counterparty accounting, is what [Transmission](transmission.md) uses to ship each peer only the parts of the ancestor graph they have not already seen.

## The chain tracker

SPV needs block headers, and fetching them per verification would be slow and fragile. `Network::ChainTracker` is a **write-through cache**: it answers `valid_root_for_height?` and `current_height` from a local `blocks` table, fetching and persisting headers through `Network::Services` on a miss. It subclasses the SDK's `ChainTracker` so it drops straight into `Transaction#verify`.

Critically, it **fails closed**: if a header lookup errors, the tracker returns `false` (root invalid) rather than raising or guessing. A verification that cannot obtain a header fails, which is the safe direction.

For *egress* validation only — when the wallet is checking the BEEF it is about to hand to a peer — `TrustedSelfChainTracker` is used instead. It returns `true` for all header lookups because the wallet's own proofs were validated against real headers at import time; the chain has already been consulted. Using the trusted tracker here is what lets `Hydrator#validate_for_handoff!` enforce *structural* completeness (every input resolvable in the bundle, every proof anchored, the subject not demoted) without re-running header verification on data the wallet itself authored. It is never used for incoming peer data.

## Byte order: wire vs display

Bitcoin has a long-standing trap: transaction and block hashes are shown to humans in the *reverse* of their internal byte order. This wallet handles it with a single firm convention:

- **Wire order is what gets stored.** It is the raw output of SHA-256d (`SHA-256(SHA-256(bytes))`) — the bytes as they appear in serialised transactions and on the wire. `wtxid`, `merkle_root`, and block hashes live in the database as those raw bytes (`bytea` / `blob`).
- **Display order (reversed hex) appears only at the boundaries** — when logging, emitting JSON, talking to a provider that expects display txids, or ingesting from the chain tracker.

The two names the wallet uses for these:

- **`wtxid`** — 32-byte binary, wire order. Method params, variables, hash keys, database columns.
- **`dtxid`** — 64-char hex string, display order. JSON, logs, CLI output, external APIs.

You will see `.reverse.unpack1('H*')` (and its refinement form `String#to_dtxid` from `lib/bsv/wallet/txid.rb`) at exactly those boundaries — for example, turning a stored `wtxid` into a `dtxid` for a status query — and nowhere else. Keeping the canonical form in storage means joins, uniqueness constraints, and comparisons all operate on one representation; the reversal is a presentation concern pushed to the edges.

Why this matters in practice: the raw SHA-256d output is *not* "little-endian" in any meaningful sense — endianness is a property of multi-byte integers, and a 32-byte hash is not an integer. The reversal between wire and display is a historical Bitcoin convention, not a CPU-architecture artefact. Both representations are 32 bytes of the same hash material; only the order on the page differs.

## Related BRCs

- **BRC-12** — Raw Transaction format. The serialisation underneath everything.
- **BRC-62** — BEEF (Background Evaluation Extended Format). Bundles a transaction with its ancestry.
- **BRC-67** — Simplified Payment Verification. The verification model the wallet implements.
- **BRC-74** — BUMP (BSV Unified Merkle Path). The proof format carried inside BEEF.
- **BRC-95** — Atomic BEEF. The single-subject form the wallet produces.

Test vectors for these formats live in the BRC repositories themselves — `brc-12`, `brc-62`, `brc-74`, `brc-95` directories under [bsv-blockchain/BRCs](https://github.com/bsv-blockchain/BRCs). The wallet's parser/verifier passes those test suites; if you're writing an alternative implementation or a peer, the vectors are the conformance gate.

## Related

- [Transactions (reference)](../reference/transactions.md) — the canonical broadcast/transmit distinction, ACK contract, error taxonomy.
- [Action lifecycle](action-lifecycle.md) — how an internalised BEEF becomes an `:internal` action with promoted outputs.
- [Transmission](transmission.md) — wallet-to-peer BEEF delivery, which uses the same Atomic BEEF format with per-peer trim.
- [Schema](../reference/schema.md) — `actions.raw_tx`, `tx_proofs`, `blocks` table reference.
