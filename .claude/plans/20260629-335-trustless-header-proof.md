# Plan — HLR #335: Trustless proof via validated block headers (config-gated)

> Project plan for [HLR #335](https://github.com/sgbett/bsv-wallet/issues/335). Intended execution:
> `/do-hlr 335`, which commits this plan first, breaks it into sub-issues (`/plan:tasks`), then drives
> build → QA → security gate → PR. All changes via PR; never push to master.

## Context

Incoming-BEEF verification ultimately trusts a chain-query Service. On a cache miss,
`BSV::Network::ChainTracker#valid_root_for_height?` (chain_tracker.rb:29-58) fetches the merkle
root for a height from WhatsOnChain and **accepts it without proof-of-work validation**
(beef_importer.rb:187 is the sole consumer, via `subject_tx.verify`). We verify the merkle
*path* but never the *root* it commits to — the one remaining trust gap in the wallet's SPV story.

HLR #335 adds an **opt-in** trust model where the wallet maintains a PoW-validated header chain
anchored at a shipped checkpoint and answers root-for-height from headers it validated itself.
Default behaviour is unchanged.

## Decisions locked (planning session 2026-06-29)

- **Trust rigour**: PoW-at-stated-target + contiguity from a shipped checkpoint. *Documented
  residual*: a fully-malicious **sole** service could mine a low-difficulty fork — closed later by
  full-DAA / multi-source / P2P. This is a large improvement over blind service-trust, not yet
  airtight; state it plainly in docs and the ADR.
- **Header source**: phase-1 = service (validated), P2P deferred. Prefer the SDK Chaintracks client
  (`bsv-sdk: lib/bsv/network/protocols/chaintracks.rb`) for efficient range sync; fall back to the
  already-wired WoC `:get_block_header`. Validate regardless of source.
- **Anchor**: hardcoded recent checkpoint per network, config-overridable.
- **Scope**: verification path only. No money-model/balance gating.

## Approach

Selection happens at one seam (`cli.rb:124`) — `BSV::Wallet.config` is already in scope there, and
`TrustedSelfChainTracker` is the existing precedent for a per-trust-context tracker subclass. The
SDK supplies the 2-method `ChainTracker` duck type but **no header parser or PoW check** — that
primitive is the real new work.

**Components (files):**

1. **Schema — amend in place** `gem/bsv-wallet/db/migrations/001_create_schema.rb` (blocks, ~L82):
   add `column :header, c[:bytea]` (nullable) + `constraint(:header_length, 'header IS NULL OR
   length(header) = 80')`. Pre-release amend-in-place policy is explicit in the file header. Keep
   `merkle_root` as the indexed answer (extracted from `header`). Update `docs/reference/schema.md`.

2. **`BlockHeader` validator (new)** `gem/bsv-wallet/lib/bsv/network/block_header.rb`: parse 80 bytes
   → {version, prev_hash, merkle_root, time, bits, nonce}; `block_hash` = SHA256d (reuse SDK
   primitives — confirm `BSV::Primitives` hash entry point); `target_from_bits`; `valid_pow?`
   (hash_int ≤ target); `links_to?(parent)`. SRP value object. **White-hat review before merge.**

3. **`SpvHeaderChainTracker` (new)** `gem/bsv-wallet/lib/bsv/network/spv_header_chain_tracker.rb`
   `< BSV::Transaction::ChainTracker`. `initialize(store:, services:, checkpoint:)`.
   - `valid_root_for_height?(root, height)`: fail-closed if `height < checkpoint.height`; lazily
     `sync_to!(max(height+100, height))` — fetch headers from validated tip up to target, validate
     each (PoW + prev-linkage) and persist; any failure ⇒ stop + return false; then compare the
     stored header's merkle_root. (+100 satisfies the SDK coinbase-maturity check.)
   - `current_height`: validated tip. Sibling to `trusted_self_chain_tracker.rb`.

4. **Checkpoints (new)** `gem/bsv-wallet/lib/bsv/network/checkpoints.rb`: per-network shipped
   `{height, block_hash}` (auditable). Config-overridable.

5. **Config** `gem/bsv-wallet/lib/bsv/wallet/config.rb`: `attr_accessor :trust_model` (+ optional
   `:spv_checkpoint`), `BSV_WALLET_TRUST_MODEL` env, `self.parse_trust_model` mirroring
   `parse_network` (L91). Default `:trusted_service`.

6. **Wiring** `gem/bsv-wallet/lib/bsv/wallet/cli.rb:124`: `case BSV::Wallet.config.trust_model` →
   `SpvHeaderChainTracker.new(...)` vs `ChainTracker.new(...)`. Confirm `bin/walletd` needs nothing
   (daemon builds no BeefImporter).

7. **Store** `gem/bsv-wallet/lib/bsv/wallet/store.rb`: extend `record_block_header` to persist
   `header`; add validated-tip / contiguous-range reader + checkpoint seed. Keep `find_block`,
   `max_block_height`.

## Principle-of-state & #245 alignment

- **Structural validity, no status column**: a header is "validated" iff it's present and forms a
  PoW-valid chain back to the checkpoint — recomputable from stored bytes. No `validated` flag.
  `blocks` stays canonical *and* rebuildable (re-syncable from the checkpoint).
- **#245 (reorg) seam**: `header` yields prev_hash + bits, so cumulative work is derivable — #245
  adds fork-choice/competing-height handling (and may add a `chainwork` projection) without a schema
  redo. Phase-1 follows one contiguous chain; `UNIQUE(height)` means reorg = #245.

## Out of scope (state explicitly — no silent caps)

P2P header sourcing; money-model/balance gating; bloom-scan discovery; full BSV DAA validation
(residual documented); proofs **below** the checkpoint (fail-closed — mitigate via checkpoint depth
or override).

## Verification

- Unit (Postgres + SQLite): `block_header_spec` (valid / bad-PoW / bad-link / malformed / nBits
  vectors); `spv_header_chain_tracker_spec` (covers-height-via-sync, fail-closed on invalid/missing,
  rejects wrong root, coinbase-maturity depth); `config` trust_model parse; CLI tracker-selection.
- Integration (Postgres-primary): boot engine in `spv_headers` mode with a fixture checkpoint + a
  short chain of **real mainnet headers**, verify an incoming BEEF at a covered height passes and an
  invalid/short-of-height header fails closed. Fixtures deterministic (no `Date.now`/random).
- Manual: `BSV_WALLET_TRUST_MODEL=spv_headers bin/wallet` import a real BEEF — observe header sync +
  validation in logs; confirm default mode behaviour byte-for-byte unchanged.
- `cd gem/bsv-wallet && BSV_WALLET_POSTGRES=… bundle exec rspec` (+ SQLite run) and `bundle exec
  rubocop`.
- New ADR (next number) recording the trust-model toggle, option-1 rigour + residual, extending
  ADR-015 (chain-tracker-pivot).

## Execution

Run via `/do-hlr 335` (you-invoked) once you're happy with this plan. Its pre-flight will branch
`feat/335-<slug>` from master and commit this plan first; the validator's crypto/merkle surface will
trip `/do-hlr`'s conditional security gate, so the white-hat pass on `BlockHeader` happens
automatically. Subsystem-sized + multi-task → expect several sub-issues, each landing via its own PR.
