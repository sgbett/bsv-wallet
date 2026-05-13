# Plan: Layer 2 — Pushable/Fetchable Entity Pattern

## Context

Layer 1 (`BSV::Network::Services`) handles routing, fallback, rate limiting. Layer 2 connects wallet database entities to the network. Through design discussion, we established:

1. **No separate service objects.** The database entities (Broadcast, Action) ARE the things that need network interaction. A `BroadcastRequest` alongside `Broadcast` is redundant — the Broadcast model itself declares its network capability.

2. **Two capabilities: Pushable and Fetchable.** Wallet entities either push data to the chain (broadcast) or pull data from the chain (proofs, transactions, UTXOs). The entity declares what command to call and what to do with the result.

3. **The query IS the job queue.** `tx_reqs` is a job queue wearing a data model's clothes. "Needs a proof" is derivable from structural state (`tx_proof_id IS NULL AND wtxid IS NOT NULL`). No separate job table needed.

4. **The entity controls the write.** The porcelain calls `entity.write!(response)` on success. The entity knows how to map network response fields to its own columns.

**Implements:** sgbett/bsv-wallet#77 (layer 2)
**Branch:** `feat/77-network-services-architecture`

## Design

### Pushable / Fetchable

Two modules that entities include to declare network capabilities:

```ruby
module BSV::Wallet::Pushable
  # What command to call
  def push_command     # e.g. :broadcast
  # What to send
  def push_payload     # e.g. action.raw_tx
  # What to do with the response
  def write!(response) # update columns from response.data
  # Is this entity in a state that needs pushing?
  def needs_push?      # e.g. broadcast_at.nil? || stale?
end

module BSV::Wallet::Fetchable
  # What command to call
  def fetch_command     # e.g. :get_tx_status
  # What args to pass
  def fetch_args        # e.g. { txid: dtxid }
  # What to do with the response
  def write!(response)  # update columns from response.data
  # Is this entity in a state that needs fetching?
  def needs_fetch?      # e.g. tx_proof_id.nil?
end
```

### Porcelain Operations

`Network::Services` gains two high-level operations (or these live alongside it):

```ruby
# Push an entity's data to the network
services.push!(entity)
  # → entity.push_command, entity.push_payload
  # → services.call(command, payload)
  # → entity.write!(response) on success

# Fetch data from the network for an entity
services.fetch!(entity)
  # → entity.fetch_command, entity.fetch_args
  # → services.call(command, **args)
  # → entity.write!(response) on success
```

Both handle errors consistently — log, increment retry state if applicable, don't raise.

### Entity Implementations

**Broadcast** (Pushable — initial broadcast):
```ruby
class Broadcast < Sequel::Model
  include BSV::Wallet::Pushable

  def push_command = :broadcast
  def push_payload = action.raw_tx
  def needs_push? = broadcast_at.nil?

  def write!(response)
    update(
      broadcast_at: Time.now,
      tx_status:    response.data[:tx_status],
      arc_status:   response.data[:status],
      block_hash:   response.data[:block_hash],
      block_height: response.data[:block_height],
      merkle_path:  response.data[:merkle_path],
      extra_info:   response.data[:extra_info]
    )
  end
end
```

**Broadcast** (Fetchable — status polling):
```ruby
# Same model, also fetchable for status updates
include BSV::Wallet::Fetchable

def fetch_command = :get_tx_status
def fetch_args = { txid: action.dtxid }
def needs_fetch?
  broadcast_at &&
    !TERMINAL_STATUSES.include?(tx_status) &&
    broadcast_at < Time.now - 30
end

# write! handles both push and fetch responses — same shape
```

**Action** (Fetchable — proof acquisition):
```ruby
# Actions that need proofs
def fetch_command = :get_tx_status  # or :get_merkle_path
def fetch_args = { txid: dtxid }
def needs_fetch?
  outgoing && wtxid && tx_proof_id.nil?
end

def write!(response)
  # Create proof from response, link to self
end
```

**Block** (Fetchable — block header cache for chain tracker):
```ruby
include BSV::Wallet::Fetchable

def fetch_command = :get_block_header
def fetch_args = { height: height }
def needs_fetch?
  merkle_root.nil?  # or block_hash.nil?
end

def write!(response)
  update(
    merkle_root: response.data[:merkle_root],
    block_hash:  response.data[:block_hash]
  )
end
```

The chain tracker calls `valid_root(root, height)`. If the block isn't cached, it creates a Block row and fetches it. The Block entity is the cache — Fetchable fills it from the network.

### Daemon

Thin loop, no business logic:

```ruby
loop do
  # Push pending broadcasts
  Broadcast.where(needs_push_condition).each do |b|
    services.push!(b)
  end

  # Fetch status for stale broadcasts
  Broadcast.where(needs_fetch_condition).each do |b|
    services.fetch!(b)
  end

  # Fetch proofs for unproven actions
  Action.where(needs_proof_condition).each do |a|
    services.fetch!(a)
  end

  sleep interval
end
```

### tx_reqs Elimination

`tx_reqs` columns and their replacements:

| tx_reqs column | Replacement |
|----------------|-------------|
| `wtxid` | `actions.wtxid` (already exists) |
| `status` | Derived: `tx_proof_id IS NULL` = needs proof |
| `attempts` | Add `proof_attempts` to actions, or derive from `updated_at` |
| `raw_tx` | `actions.raw_tx` (already exists) |
| `input_beef` | Not currently used by process_pending |
| `notified`, `notify`, `batch`, `history` | Unused — speculative columns from TS schema |

Migration: drop `tx_reqs` table, add `proof_attempts` column to actions if needed.

## Implementation Sequence

### Phase 1: Pushable/Fetchable modules + porcelain
- New: `gem/bsv-wallet/lib/bsv/wallet/pushable.rb`
- New: `gem/bsv-wallet/lib/bsv/wallet/fetchable.rb`
- Modify: `gem/bsv-wallet/lib/bsv/network/services.rb` — add `push!`/`fetch!`
- Specs for the modules and porcelain operations

### Phase 2: Broadcast adopts Pushable + Fetchable
- Modify: `gem/bsv-wallet-postgres/lib/bsv/wallet/postgres/broadcast.rb`
- Modify: `gem/bsv-wallet-postgres/lib/bsv/wallet/postgres/broadcast_queue.rb` — simplify to use push!/fetch!
- Update specs

### Phase 3: Action adopts Fetchable (proof acquisition)
- Modify: `gem/bsv-wallet-postgres/lib/bsv/wallet/postgres/action.rb` — or a concern module
- ProofStore's `process_pending` simplified or eliminated
- Update specs

### Phase 4: Remove tx_reqs
- Migration: drop tx_reqs table
- Remove: `gem/bsv-wallet-postgres/lib/bsv/wallet/postgres/tx_req.rb`
- Remove: ProofStore's `request_proof` / `process_pending` (replaced by Action fetchable)
- Update specs

### Phase 5: Wire into Engine + CLI
- Engine uses services.push!/fetch! instead of broadcast_queue/proof_store network methods
- CLI constructs Services, passes to Engine
- ArcAdapter removed (Services handles routing)

## Key Files

- `gem/bsv-wallet-postgres/lib/bsv/wallet/postgres/broadcast.rb` — gains Pushable + Fetchable
- `gem/bsv-wallet-postgres/lib/bsv/wallet/postgres/broadcast_queue.rb` — simplified
- `gem/bsv-wallet-postgres/lib/bsv/wallet/postgres/proof_store.rb` — process_pending simplified
- `gem/bsv-wallet-postgres/lib/bsv/wallet/postgres/action.rb` — gains Fetchable for proofs
- `gem/bsv-wallet/lib/bsv/network/services.rb` — gains push!/fetch!
- `gem/bsv-wallet-postgres/db/migrations/` — drop tx_reqs

## Open Considerations

**Fetch for non-existent rows:** Fetchable assumes a row exists to call `fetch!` on. Three cases:
1. Row exists, needs updating (Broadcast status poll) — straightforward
2. Row exists, needs related data (Action needs proof) — `write!` creates the related record
3. Row doesn't exist yet (Block for unknown height) — caller creates the row first, then fetches

Case-by-case for now. The Fetchable contract is flexible — `write!` handles whatever the entity needs. No single pattern forced.

## Verification

1. `cd gem/bsv-wallet && bundle exec rspec` — all wallet specs pass
2. `cd gem/bsv-wallet-postgres && bundle exec rspec` — all postgres specs pass
3. `cd gem/bsv-wallet && bundle exec rubocop` — clean
4. Integration specs pass (`source ~/.zprofile && bundle exec rspec --tag on_chain`)
5. Broadcast lifecycle works: submit → poll → status updates → proof linked
