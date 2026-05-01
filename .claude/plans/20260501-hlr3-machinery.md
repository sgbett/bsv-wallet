# Plan: HLR #3 — Machinery (UTXOPool, BroadcastQueue, ProofStore)

## Context

HLR #1 delivered models, HLR #2 delivered the Store. Three Layer 2a components remain: UTXOPool (thin delegation to Store), BroadcastQueue (ARC communication + broadcasts table), and ProofStore (tx_proofs + tx_reqs). The engine (HLR #4) needs all three.

**Source issue:** sgbett/bsv-wallet#3

---

## UTXOPool — `gem/bsv-wallet-postgres/lib/bsv/wallet/postgres/utxo_pool.rb`

The simplest component. Tier 1: pure delegation to Store.

```ruby
class UTXOPool
  include BSV::Wallet::Interface::UTXOPool

  def initialize(store:)
    @store = store
  end

  def select(satoshis:, exclude: [])
    candidates = @store.find_spendable(satoshis: satoshis, exclude: exclude)
    total = candidates.sum { |c| c[:satoshis] }
    raise BSV::Wallet::PoolDepletedError, 'default' if total < satoshis
    candidates
  end

  def release(outputs:)
    # No-op for tier 1 — CASCADE handles it
  end

  def balance
    Output.spendable.sum(:satoshis) || 0
  end
end
```

Three methods, trivial. `select` adds the `PoolDepletedError` check that the Store doesn't have (the Store returns whatever it finds, the pool enforces sufficiency). `balance` queries directly — no need to go through Store for a simple aggregate.

---

## BroadcastQueue — `gem/bsv-wallet-postgres/lib/bsv/wallet/postgres/broadcast_queue.rb`

Owns the broadcasts table and ARC communication. Accepts an ARC client (SDK protocol) at construction time.

### Constructor

```ruby
def initialize(db: nil, arc_client: nil)
  @db = db || BSV::Wallet::Postgres.db
  @arc_client = arc_client
end
```

The `arc_client` is optional — when nil, `submit(immediate: true)` will raise (no network available). This allows testing the database operations without a network connection.

### submit(action_id:, raw_tx:, immediate:)

1. Create broadcast record
2. If immediate AND arc_client available: post to ARC, update record with response, return result
3. If not immediate: return the record (worker will post later)

The post-to-ARC flow:
- Call `@arc_client.call(:broadcast, raw_tx)` — returns a Result
- Map the Result data to broadcast columns (tx_status, arc_status, block_hash, etc.)
- Binary fields (block_hash, merkle_path) need hex-to-binary conversion from the ARC JSON response
- Return a hash with :action_id, :tx_status, and any proof data

### handle_event(event)

Receives a parsed TransactionStatus hash (from callback or SSE). The event has binary txid (already decoded by the callback endpoint).

1. Look up action by txid: `Action.first(txid: Sequel.blob(event[:txid]))`
2. If no action found, return nil
3. Find or create broadcast record for that action
4. Update broadcast columns from the event
5. Return { action_id:, tx_status:, block_hash:, block_height:, merkle_path: }

The engine decides whether to promote based on the returned tx_status.

### process_pending(limit:)

Worker entry point. Finds broadcasts that were sent but have no terminal status:

```ruby
stale = Broadcast
  .where { broadcast_at !~ nil }
  .where(tx_status: [nil, 'UNKNOWN', 'RECEIVED', 'SENT_TO_NETWORK', 'ACCEPTED_BY_NETWORK'])
  .where { broadcast_at < Time.now - 30 }
  .limit(limit)
```

For each: call `@arc_client.call(:get_tx_status, txid:)`, update the broadcast record, collect results.

### status(action_id:)

Simple read: `Broadcast.first(action_id:)` → hash or nil.

### BroadcastCallback — Rack app

Separate file: `gem/bsv-wallet-postgres/lib/bsv/wallet/postgres/broadcast_callback.rb`

A Rack-compatible app that parses ARC TransactionStatus JSON POSTs and delegates to a BroadcastQueue instance.

```ruby
class BroadcastCallback
  def initialize(broadcast_queue:)
    @broadcast_queue = broadcast_queue
  end

  def call(env)
    request = Rack::Request.new(env)
    body = JSON.parse(request.body.read, symbolize_names: true)
    event = decode_event(body)
    @broadcast_queue.handle_event(event)
    [200, { 'content-type' => 'text/plain' }, ['OK']]
  end

  private

  def decode_event(body)
    {
      txid:          decode_hex(body[:txid]),
      tx_status:     body[:txStatus],
      status:        body[:status],
      block_hash:    decode_hex(body[:blockHash]),
      block_height:  body[:blockHeight],
      merkle_path:   body[:merklePath],  # keep as-is for now
      extra_info:    body[:extraInfo],
      competing_txs: body[:competingTxs]
    }
  end

  def decode_hex(hex)
    return unless hex
    [hex].pack('H*')
  end
end
```

---

## ProofStore — `gem/bsv-wallet-postgres/lib/bsv/wallet/postgres/proof_store.rb`

Owns tx_proofs and tx_reqs tables.

### save_proof(txid:, proof:)

Upsert — insert or update by txid:

```ruby
existing = TxProof.first(txid: Sequel.blob(txid))
if existing
  existing.update(proof_columns(proof))
  existing.id
else
  TxProof.create({ txid: txid }.merge(proof_columns(proof))).id
end
```

### find_proof(txid:)

`TxProof.first(txid: Sequel.blob(txid))` → hash or nil.

### proof_exists?(txid:)

`TxProof.where(txid: Sequel.blob(txid)).any?` — the trustSelf fast path.

### request_proof(txid:, raw_tx:, input_beef:)

Insert into tx_reqs. Idempotent — `insert_conflict(target: :txid)` ignores duplicates.

### process_pending(limit:)

Find tx_reqs with status 'unmined', poll ARC for each:
1. `@arc_client.call(:get_tx_status, txid:)`
2. If MINED: save_proof, update tx_req with tx_proof_id and status
3. If not: increment attempts
4. Return resolved proofs

Also accepts an arc_client at construction for the polling.

---

## Files to Create

```
gem/bsv-wallet-postgres/lib/bsv/wallet/postgres/
  utxo_pool.rb
  broadcast_queue.rb
  broadcast_callback.rb
  proof_store.rb

gem/bsv-wallet-postgres/spec/bsv/wallet/postgres/
  utxo_pool_spec.rb
  broadcast_queue_spec.rb
  broadcast_callback_spec.rb
  proof_store_spec.rb
```

Update `postgres.rb` autoloads to include UTXOPool, BroadcastQueue, BroadcastCallback, ProofStore.

---

## Testing approach

- **UTXOPool**: real PostgreSQL, create funded outputs, test select/release/balance
- **BroadcastQueue**: mock the arc_client (RSpec double), test database operations and the submit/handle_event/process_pending/status flows. No real network calls.
- **BroadcastCallback**: Rack::MockRequest to test the Rack app. Verify it parses JSON correctly and delegates to handle_event.
- **ProofStore**: real PostgreSQL, test save/find/exists/request/process_pending. Mock arc_client for process_pending.

---

## Verification

1. `bundle exec rspec` — all specs pass (existing 97 + new)
2. UTXOPool: select returns candidates, raises PoolDepletedError when insufficient
3. UTXOPool: balance reflects spendable outputs minus locked
4. BroadcastQueue: submit(immediate: false) creates record without posting
5. BroadcastQueue: submit(immediate: true) posts via arc_client and updates record
6. BroadcastQueue: handle_event updates broadcast, returns action_id for promotion
7. BroadcastCallback: Rack app parses ARC JSON, hex-decodes txid/block_hash
8. ProofStore: binary round-trip on txid, merkle_path, block_hash
9. ProofStore: proof_exists? returns true/false correctly
10. ProofStore: request_proof is idempotent (duplicate txid ignored)
