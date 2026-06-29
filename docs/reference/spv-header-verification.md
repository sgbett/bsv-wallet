# SPV header verification — the `spv_headers` trust model

How the wallet decides a merkle root is real. Settled in [ADR-032](../../.architecture/decisions/adrs/20260629_ADR-032-spv-header-trust-model.md) (HLR #335).

## The axis

BEEF verification (`Transaction::Tx#verify`) checks a merkle *path*, then asks a chain tracker "is this *root* valid at this height?". `config.trust_model` selects who answers:

| `trust_model` | Tracker | Answers root-for-height by… | Default |
|---|---|---|---|
| `:trusted_service` | `BSV::Network::ChainTracker` | fetching the root from a chain-query Service (WhatsOnChain) and **trusting it** | ✓ |
| `:spv_headers` | `BSV::Network::SpvHeaderChainTracker` | reading it from a **locally PoW-validated** header chain — no service trusted | opt-in |

Set via `BSV_WALLET_TRUST_MODEL=spv_headers` or `config.trust_model = :spv_headers`. Selected once at boot (`cli.rb`); `walletd` boots through the same seam.

## What `:spv_headers` does

Maintains a contiguous, proof-of-work-validated chain of 80-byte block headers anchored at a baked-in **checkpoint**, and answers only from it.

- **Validation rigour: PoW-at-stated-target + contiguity.** Each header must have valid proof-of-work against its *stated* compact target (`nBits`) and link (`prev_hash`) to its already-validated predecessor. The wallet does **not** recompute that the stated target is correct per the difficulty-adjustment algorithm (DAA) — see [the residual](#the-residual).
- **Fail-closed.** A height below the checkpoint, a header that fails PoW or linkage, a missing header, or a height the sync cannot reach all resolve to "not valid". Verification fails rather than falling back to service-trust.
- **Lazy sync, bounded.** On a miss the chain extends from the validated tip up to `height + 100` (the `+100` keeps the SDK coinbase-maturity check satisfied), one header per fetch (no bulk endpoint exists). A `MAX_SYNC_SPAN` cap refuses absurd heights before any fetch — the DoS bound.

## Structural validity (principle of state)

A header is "validated" iff its 80 bytes are present in `blocks.header` *and* it forms a PoW-valid chain back to the checkpoint — a property recomputable from the stored bytes. There is **no `validated` status column**; presence-and-linkage is the signal. The `header_root_match` CHECK ties the embedded merkle root to the `merkle_root` column so they cannot drift. Header writes are **append-or-reject** — a validated row is never downgraded to header-NULL nor overwritten by a competing header (preserving the evidence #245's reorg handling will need). See [`principle-of-state.md`](principle-of-state.md).

## The residual

`:spv_headers` is a large improvement over blind service-trust, **not** airtight against a fully-malicious *sole* service. Validating PoW at the *stated* target but not the target's correctness means a sole header source can serve a self-consistent **low-difficulty fork**: lower the stated target, cheaply mine valid-PoW-for-that-easy-target headers, present a fabricated root.

**On BSV this is materially worse than on BTC** — BSV's minority share of SHA256 hashrate lowers the cost of fabricating a target-consistent fork. The gate raises the bar well above blind trust but does not approach Nakamoto-security on BSV specifically. Closed later by full DAA validation, multi-service cross-check, or P2P header sourcing (all deferred; DAA/cumulative-work overlaps #245).

## Operational constraints

- **Refresh the checkpoint each release.** The shipped mainnet checkpoint (currently block 955000) must move toward the tip per release, or first-sync cost grows with the gap. It is a small, auditable trust root — `{height, 80-byte header}` — that self-verifies (`sha256d` of the header equals the known block hash).
- **Legacy imports below the checkpoint.** A proof at a height below the checkpoint fails closed. New wallets are unaffected; to import genuinely old UTXOs under `:spv_headers`, lower the checkpoint via the `config.spv_checkpoint` override (`{ height:, header: }`), or use `:trusted_service` for that import.
- **Imports are self-asserted, not a trust gap.** `import_utxo` concerns the wallet's *own* coins; its proof path does not run through `Tx#verify`, so even under `:spv_headers` an import's merkle root is taken from the service on faith. This is **not** the counterparty risk `:spv_headers` closes — a lying service gains nothing and cannot cause loss, only a brief belief in a coin the wallet cannot spend (rejected at broadcast; any onward BEEF is rejected by the recipient's own SPV). A consistency asterisk on the label, tracked as low-priority polish at #485.
- **Mainnet only (phase-1).** No testnet checkpoint ships (the testnet 20-minute special-difficulty rule is out of scope); `Checkpoints.for(:testnet)` raises.

## See also

- [ADR-032](../../.architecture/decisions/adrs/20260629_ADR-032-spv-header-trust-model.md) — the decision, alternatives, and the full residual analysis.
- [`principle-of-state.md`](principle-of-state.md) — structural validity, no status column.
- [`schema.md`](schema.md) — the `blocks.header` column and its CHECKs.
