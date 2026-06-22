# Resilience & Recovery

A wallet holds value, so the interesting failures are not "the feature didn't work" but "the process died at the worst possible moment" or "the network contradicted what we believed". This gem is built around the assumption that those things *will* happen, and most of its more unusual design choices are there to make them survivable.

This page draws together the resilience mechanisms that appear throughout the other concept pages and explains the recovery story: how a wallet can be rebuilt or reclaimed from the private key alone.

## Limp mode: protecting a draining wallet

A wallet whose balance falls too low is in a dangerous spot — it may not be able to pay fees, and continuing to spend can leave it stranded with locked inputs and no way out. **Limp mode** is a hard guard against that, owned by `Engine::Policy`:

<!-- generated from gem/bsv-wallet/lib/bsv/wallet/engine.rb#limp_mode? + #headroom -->
```ruby
def limp_mode? = @utxo_pool.balance < @limp_threshold
def headroom   = [@utxo_pool.balance - @limp_threshold, 0].max
```

When the balance is below `limp_threshold`, **all outbound operations are blocked** (`Policy#guard_balance!` raises `LimpModeError`). The wallet can still *receive* — that is precisely how you get it out of limp mode — but it will not initiate new spends.

- The default threshold is **50 000 satoshis**, configurable, with a **hard floor of 10 000** that the constructor refuses to go below (`LIMP_THRESHOLD_MIN`). You cannot accidentally disable the protection.
- There is also a **headroom check**: a spend is rejected if it *would* drop the projected balance below the threshold, not just if the wallet is already below it. The funding loop uses the pre-lock balance as its reference so the check stays accurate even after inputs are locked mid-transaction.
- Genuine bootstrap and reclaim paths — `import_wallet`, `import_utxo`, and `sweep` — set `@bypass_limp_mode` for the duration, because those are exactly the operations that *restore* or *rescue* a low wallet and must not be blocked by the guard they are trying to satisfy. `Policy` itself is stateless; the bypass flows in at call time, so the only place the bypass mutation lives is on `Engine`.

`LimpModeError` reports both the balance and the threshold, so an operator (or calling code) knows how much it needs to receive to recover.

## The crash-recovery invariant

The hardest moment in a wallet's life is broadcasting: there is a window between "we sent the transaction to the network" and "we recorded what happened" where a crash could lose track of an in-flight transaction. The wallet closes this window with a deliberately ordered write.

`submit` stamps `broadcast_at` **in a committed transaction before the network POST**:

<!-- generated from gem/bsv-wallet/lib/bsv/wallet/engine/broadcast.rb#submit -->
```ruby
def submit(action_id, action, started_at:)
  @store.mark_broadcast_attempted(action_id: action_id)  # commit broadcast_at
  response = @broadcaster.broadcast(action[:raw_tx], ...) # THEN hit the network
  ...
```

The consequence is that a crash mid-POST leaves the broadcast row in a **recognisable state**: `broadcast_at IS NOT NULL` but `tx_status IS NULL`. That is not an ambiguous "did it send or not?" — it is a specific marker the [daemon's](daemon.md) resolution loop knows how to resolve, by asking the network through `Broadcaster#get_tx_status` and recording whatever actually happened. The ordering trades a possible *duplicate* status query (harmless) for the impossibility of a *silently lost* broadcast (not harmless).

The complement is on the recording side: `record_broadcast_result` **writes the promotions row in the same database transaction** as it records an accepted status. Phase 4 promotion is atomic with the result it depends on, so a process cannot die between "the network accepted it" and "the outputs became spendable" and leave the two disagreeing. This is the same principle as [structural state](action-lifecycle.md): never let two facts that must agree live in separate, separately-committed places.

## Fail-closed verification

Every place the wallet consults the outside world to decide whether to trust something, it defaults to *distrust* on error:

- **SPV** (in `Engine::BeefImporter`) raises rather than admitting an unverified payment, and raises outright if no chain tracker is configured.
- **The chain tracker** returns `false` from `valid_root_for_height?` when a header lookup fails, rather than raising or guessing — an unprovable block is treated as invalid.
- **Egress validation** — `Engine::Transmission#transmit` parses the trimmed BEEF and runs `Hydrator#validate_for_handoff!(allow_txid_only: true)` before the row is recorded. The wallet refuses to ship a BEEF it cannot itself verify against its own stored proofs, raising `EgressBeefInvalidError` *before* the wire bytes ever leave the process. See [Transactions (reference) — Egress validation](../reference/transactions.md).

The bias is always toward refusing a good thing over accepting a bad thing. See [Transactions & BEEF](transactions-and-beef.md).

## Speculative promotion, and its unwind

The send path is optimistic: a `promotions` row is written on network *acceptance* without waiting for a mined proof, so payments can be chained at speed. The safety net is the **reject cascade** — if the network terminally rejects a broadcast, `reject_action` recursively unwinds the speculative promotion through any child actions that spent the now-invalid change. The cascade refuses to proceed (and rolls back loudly) if it would have to reject an *internal* action or one the network has already *accepted*, because at that point an automatic unwind would cause more harm than the rejection it is responding to. The full state machine is in [The Action Lifecycle](action-lifecycle.md).

## Defence in depth: database-level guards

The wallet's invariants are enforced first in application code and *again* in the schema, so that no code path — present or future, in this gem or a consumer reaching into the database — can violate them. Each guard mirrors an application rule (see [Persistence](persistence.md) for the schema):

| Invariant | Application rule | Database guard |
|-----------|------------------|----------------|
| Outbound outputs are never spendable | pool never selects them | `prevent_outbound_spendable` trigger forbids a `spendable` row for an outbound output |
| Received history is never deleted | `abort_action` refuses promoted outputs; `reject_action` refuses internal actions | `prevent_internal_action_delete` trigger blocks deleting an internal action with a `promotions` row |
| Outputs are immutable | no code mutates `outputs.action_id` | FK `ON DELETE RESTRICT` + `NOT NULL` on `outputs.action_id` |
| A broadcast row's intent tracks its action | set once, never changed | composite FK `broadcasts(action_id, intent) → actions(id, broadcast_intent)` with `ON UPDATE RESTRICT`, plus a `CHECK (intent != 'none')` |
| Promotions trace to accepted broadcasts | the application only writes a row on acceptance | composite FK `promotions_broadcast_status_fkey` plus the `auth_not_rejected` CHECK |

These are not redundant pedantry. They are the line that holds when the application logic has a bug: the database will raise a constraint violation rather than quietly corrupt the wallet's record of on-chain value.

## The reaper: cleaning up abandoned work

Not every action completes. A deferred action that is created but never signed keeps its inputs locked, which would slowly strand UTXOs. `Engine::Reaper` deletes actions whose age exceeds `BSV_WALLET_REAP_THRESHOLD_S` **unless they have a promotions row**. The criterion is deliberate: a promotions row means the action produced canonical value and must be kept; an unpromoted, unsigned, or unbroadcast action is exactly the abandoned work the reaper exists to clear, and deleting it releases its locked inputs back to the pool via cascade.

In production this is the **reaper fibre**: the daemon's `Scheduler` runs a 60-second discovery loop that pushes stale-action IDs onto `inproc://reaper.pull`, and `Engine::Reaper#pull!` consumes them. Calling `store.reap_stale_actions(threshold:)` from a script still works the same way and is the path the test suite uses; the daemon fibre simply automates it on a cadence.

## Recovery from the key alone

The deepest form of resilience is that the wallet's state is, in principle, reconstructible from the **private key plus the chain**. Three mechanisms make this real:

- **Rebuild from chain** — `import_wallet` and `import_utxo` discover and internalise the wallet's own UTXOs from the network, recording them as proven internal actions. A wallet that has lost its database but kept its WIF can repopulate.
- **Recoverable receive addresses** — the WBIKD scheme derives legacy receive addresses from the identity key and public on-chain coordinates, so `list_receive_addresses` and `scan_receive_addresses` can re-derive the set of outstanding addresses and find payments to them without any stored secret. `internalize_wbikd_utxo` then ingests each discovered UTXO and recycles the slot. See [Keys & Cryptography](keys-and-cryptography.md).
- **Reclaim to a bare key** — `sweep` consolidates everything to a *root* P2PKH address (`hash160(pubkey)`, not a derived one), so the funds land somewhere a plain private key can spend them with no derivation metadata at all. This is the ultimate exit: whatever state the wallet is in, the value can be swept back to the identity key and recovered.

Taken together, the rule is that **the key is the wallet**. Everything else — the database, the baskets, the action history — is a cache of state that can be rebuilt or bypassed, never the sole custodian of value.
