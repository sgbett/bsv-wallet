# Chain Tracker Pivot — Replace Manual Ancestry Walking with SDK Verify

## Context

The SDK's `Transaction#verify(chain_tracker:)` implements a queue-based SPV ancestry walk: scripts, merkle proofs, fee adequacy — the full verification algorithm. The wallet reimplemented this same tree walk in `resolve_ancestor` / `build_atomic_beef` for BEEF construction, minus all verification. Meanwhile, incoming BEEFs (`internalizeAction`) are only structurally validated because the chain_tracker is nil.

This pivot:
- Builds a wallet-owned `ChainTracker` on the existing `blocks` table (DB + network write-through cache)
- Replaces `resolve_ancestor` with a trivial `wire_ancestor` (load-and-attach, no logic)
- Uses `Transaction#verify` for incoming SPV validation (replaces `validate_beef!` + `validate_fee_adequacy!`)
- Lets `Beef#merge_transaction` handle BEEF serialization from the wired graph

The result: the SDK owns the verification algorithm, the wallet owns the data sources, the chain_tracker bridges them.

### Recent PRs Accounted For

- **#80** — `blocks` table already exists (in `001_create_schema.rb`), Block model exists, ProofStore.save_proof internally calls `find_or_create_block`. Phase 1 is done.
- **#83/#78** — `BSV::Network::Services` routing layer merged. Chain_tracker uses it for network calls.
- **#90** — Pushable/Fetchable entity pattern. `tx_reqs` dropped. Proof acquisition via `Action#write!`. Block entity does NOT yet implement Fetchable — chain_tracker is the natural place to add this.
- **#72** — `send_payment` / `import_wallet` porcelain added. No BEEF changes. Transparent to this pivot.
- **#94** — Architecture framework. No code changes.
- **Current line numbers:** `build_atomic_beef` (968), `resolve_ancestor` (1000), `validate_beef!` (1108), `validate_fee_adequacy!` (1156), `auto_fund_action` (1451). Latest migration: `004_drop_tx_reqs.rb`.

---

## Phase 1: Prerequisite — ProofStore population at sign time

**Problem:** `handle_proof_from_broadcast` saves raw_tx to ProofStore only on inline broadcast acceptance. Delayed-broadcast transactions aren't in ProofStore until mined. The current `resolve_ancestor` has a fallback (action lookup + `resolve_inputs_for_signing`). The new `wire_ancestor` won't — it relies solely on ProofStore.

**Fix:** When an action is signed, also save `{raw_tx: raw_tx}` to ProofStore (no merkle_path yet — unconfirmed). This ensures any signed transaction is immediately available for BEEF construction.

**File:** `gem/bsv-wallet/lib/bsv/wallet/engine.rb`

Add after each `@store.sign_action` call:
```ruby
@proof_store.save_proof(wtxid: wtxid, proof: { raw_tx: raw_tx })
```

Idempotent (save_proof upserts). When merkle_path later arrives via broadcast response or `Action#write!` (Fetchable pattern from PR #90), the same wtxid gets updated.

---

## Phase 2: `BSV::Network::ChainTracker`

**New file:** `gem/bsv-wallet/lib/bsv/network/chain_tracker.rb`

```ruby
module BSV
  module Network
    class ChainTracker < BSV::Transaction::ChainTracker
      def initialize(db:, services:)
        @db = db
        @services = services
      end

      def valid_root_for_height?(root, height)
        # Fast path: local blocks table
        block = @db[:blocks].where(height: height).first
        if block
          return block[:merkle_root] == [root].pack('H*')
        end

        # Miss path: fetch header via Services routing layer
        result = @services.call(:get_block_header, height)
        return false unless result.respond_to?(:success?) && result.success?

        fetched_root = result.data['merkleroot'] || result.data['merkle_root']
        return false unless fetched_root

        # Write-through: persist for future lookups
        block_hash = result.data['hash'] || result.data['block_hash']
        persist_block(height: height, merkle_root: fetched_root, block_hash: block_hash)

        [fetched_root].pack('H*') == [root].pack('H*')
      rescue StandardError => e
        BSV.logger&.warn { "[ChainTracker] valid_root_for_height? error: #{e.message}" }
        false # fail closed
      end

      def current_height
        result = @services.call(:current_height)
        return result.data if result.respond_to?(:success?) && result.success?

        @db[:blocks].max(:height) || 0
      rescue StandardError
        @db[:blocks].max(:height) || 0
      end

      private

      def persist_block(height:, merkle_root:, block_hash:)
        root_bin = [merkle_root].pack('H*')
        hash_bin = block_hash ? [block_hash].pack('H*') : nil
        @db[:blocks].insert_conflict(target: :height).insert(
          height: height,
          merkle_root: Sequel.blob(root_bin),
          block_hash: hash_bin ? Sequel.blob(hash_bin) : nil
        )
      rescue Sequel::Error => e
        BSV.logger&.debug { "[ChainTracker] persist_block failed: #{e.message}" }
      end
    end
  end
end
```

**Key behaviors:**
- Inherits SDK's `BSV::Transaction::ChainTracker` — satisfies the duck type
- Namespace: `BSV::Network::` (network infrastructure, same pattern as `BSV::Network::Services`)
- Uses `:get_block_header` command via Services routing (supported by WoC, Chaintracks, JungleBus protocols)
- Write-through: successful fetch → `INSERT ... ON CONFLICT DO NOTHING`
- Fail closed: any error → `false` → verification fails
- Block headers are immutable — once persisted, never updated

**Future Fetchable alignment:** The Block model could later adopt the Fetchable pattern (PR #90) with `fetch_command: :get_block_header`. For now, the chain_tracker handles fetching directly — simpler, and the Fetchable pattern is designed for daemon-driven polling, not synchronous on-demand lookups.

---

## Phase 3: `wire_ancestor` (replaces `resolve_ancestor`)

**File:** `gem/bsv-wallet/lib/bsv/wallet/engine.rb`

Replace `resolve_ancestor` (line 1000) with:

```ruby
def wire_ancestor(wtxid, visited: Set.new)
  return if visited.include?(wtxid)
  visited.add(wtxid)

  proof = @proof_store.find_proof(wtxid: wtxid)
  return unless proof && proof[:raw_tx] && proof[:raw_tx].bytesize >= 10

  tx = BSV::Transaction::Transaction.from_binary(proof[:raw_tx])

  if proof[:merkle_path]
    tx.merkle_path = BSV::Transaction::MerklePath.from_binary(proof[:merkle_path]).first
    return tx  # Proven terminal — no need to recurse
  end

  # Unconfirmed: wire each input's source recursively
  tx.inputs.each do |input|
    ancestor = wire_ancestor(input.prev_wtxid, visited: visited)
    input.source_transaction = ancestor if ancestor
  end

  tx
end
```

**What's eliminated from `resolve_ancestor`:**
- No `@store.find_action(wtxid:)` lookup (line 1023 of current code)
- No `@store.resolve_inputs_for_signing(action_id:)` fallback (line 1024)
- No conditional branches for "action has inputs" vs "bare proofs from BEEF" (lines 1026-1039)
- Just: load from ProofStore → parse → if proven, stop; if not, recurse into inputs

---

## Phase 4: Rewrite `build_atomic_beef`

**File:** `gem/bsv-wallet/lib/bsv/wallet/engine.rb` (line 968)

```ruby
def build_atomic_beef(raw_tx, action_id)
  tx = BSV::Transaction::Transaction.from_binary(raw_tx)
  resolved_inputs = @store.resolve_inputs_for_signing(action_id: action_id)

  resolved_inputs.each_with_index do |resolved, idx|
    input = tx.inputs[idx]
    next unless input
    input.source_transaction = wire_ancestor(resolved[:source_wtxid])
  end

  beef = BSV::Transaction::Beef.new
  beef.merge_transaction(tx)
  beef.to_atomic_binary(tx.wtxid)
end
```

Structurally minimal change — swaps `resolve_ancestor` for `wire_ancestor`. SDK's `merge_transaction` recursively follows `source_transaction` links.

**No verify call on outgoing path.** We trust our own construction. Verification is for incoming untrusted data only. Add a comment at the call site explaining this decision — it's load-bearing and future maintainers need to understand the asymmetry.

---

## Phase 5: Rewrite `internalize_action` validation

**File:** `gem/bsv-wallet/lib/bsv/wallet/engine.rb`

Replace `validate_beef!` (line 1108) + `validate_fee_adequacy!` (line 1156) with:

```ruby
def verify_incoming_transaction!(subject_tx)
  raise BSV::Wallet::InvalidBeefError, 'chain_tracker required' unless @chain_tracker

  subject_tx.verify(chain_tracker: @chain_tracker)
rescue BSV::Transaction::VerificationError => e
  raise BSV::Wallet::InvalidBeefError, "SPV verification failed: #{e.message} (#{e.code})"
end
```

The `internalize_action` flow (line 231) becomes:
1. `parse_beef(tx)` — SDK auto-wires `source_transaction` links within the BEEF
2. `hydrate_known_sources!(subject_tx)` (if `trust_self == 'known'`) — for inputs whose `source_transaction` is nil (sender sent TXID-only entries), wire from local ProofStore via `wire_ancestor`
3. `verify_incoming_transaction!(subject_tx)` — SDK walks in-memory graph, validates scripts + merkle proofs + fee adequacy
4. `save_beef_proofs` — persist ancestor proofs BEFORE replacing known ancestors
5. `replace_known_ancestors!` (if `trust_self == 'known'`) — replaces known txs in BEEF list (runs after save so no proof data is lost; runs after verify so the graph was already validated)

**What Transaction#verify gives us (that we didn't have):**
- Script verification on every input
- Ancestry walk with per-ancestor merkle proof validation via chain_tracker
- Output ≤ input check (replaces `validate_fee_adequacy!`)
- Structured error codes (`:invalid_merkle_proof`, `:script_failure`, `:output_overflow`, `:missing_source`)

---

## Phase 6: Delete dead code

- `resolve_ancestor` (line 1000) — replaced by `wire_ancestor`
- `collect_input_ancestry` (line 942) — unused
- `validate_beef!` (line 1108) — replaced by `verify_incoming_transaction!`
- `validate_fee_adequacy!` (line 1156) — subsumed by Transaction#verify's `:output_overflow` check

---

## Error Propagation

| SDK raises | Wallet wraps as | Meaning |
|---|---|---|
| `:invalid_merkle_proof` | `InvalidBeefError` | Block header doesn't match |
| `:script_failure` | `InvalidBeefError` | Unlocking script fails execution |
| `:output_overflow` | `InvalidBeefError` | Outputs exceed inputs (no fee) |
| `:missing_source` | `InvalidBeefError` | Input ancestry incomplete |
| `:insufficient_fee` | `InvalidBeefError` | Below fee model (if fee_model: provided) |

Public API contract unchanged: callers catch `InvalidBeefError`.

---

## Testing Strategy

1. **BSV::Network::ChainTracker spec** (`gem/bsv-wallet/spec/bsv/network/chain_tracker_spec.rb`) — DB hit, DB miss + network fetch, write-through persistence, fail closed on error, current_height fallback
2. **wire_ancestor spec** (engine_spec.rb) — proven terminal, recursive unconfirmed, circular reference guard, missing proof returns nil
3. **verify_incoming_transaction! spec** (engine_spec.rb) — wraps VerificationError, raises when chain_tracker nil
4. **internalize_action** — update existing specs from mock chain_tracker expectations to full verify flow
5. **build_atomic_beef** — existing specs pass (wire_ancestor produces same graph for well-populated ProofStore)
6. **ProofStore at sign time** — verify save_proof called during sign path
7. **TXID-only + verify integration test** (Critical) — parse BEEF, call `replace_known_ancestors!` to convert known ancestors to TXID-only, then call `subject_tx.verify(chain_tracker:)` and confirm it succeeds. This validates the highest-risk assumption: that `make_txid_only` mutates the BEEF list without invalidating the in-memory `source_transaction` pointers wired by `from_binary`.

---

## Files

| File | Change |
|---|---|
| `gem/bsv-wallet/lib/bsv/network/chain_tracker.rb` | **New** — ChainTracker implementation |
| `gem/bsv-wallet/lib/bsv/wallet/engine.rb` | Add `wire_ancestor`, `verify_incoming_transaction!`; rewrite `build_atomic_beef`; add ProofStore save at sign time; delete `resolve_ancestor`, `collect_input_ancestry`, `validate_beef!`, `validate_fee_adequacy!` |
| `gem/bsv-wallet/spec/bsv/network/chain_tracker_spec.rb` | **New** — tests |
| `gem/bsv-wallet/spec/bsv/wallet/engine_spec.rb` | Update verification and BEEF tests |
| `docs/reference/schema.md` | Update to note chain_tracker role of blocks table |

---

## Sequencing

```
[Phase 1: ProofStore at sign time]  ← prerequisite fix, independent
         |
[Phase 2: BSV::Network::ChainTracker]  ← new file, uses existing blocks table
         |
[Phase 3: wire_ancestor]  ← replaces resolve_ancestor
         |
[Phase 4: build_atomic_beef rewrite]  ← uses wire_ancestor
         |
[Phase 5: internalize_action rewrite]  ← uses verify + chain_tracker
         |
[Phase 6: delete dead code]
```

---

## Verification

```bash
cd gem/bsv-wallet && bundle exec rspec
cd gem/bsv-wallet-postgres && bundle exec rspec
cd gem/bsv-wallet && bundle exec rubocop
```
