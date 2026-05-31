# #126 e2e harness — session handoff (2026-05-30)

## TL;DR

- Phase 1 smoke runs clean end-to-end on chain (5 SDK→Wn fundings broadcast and mined).
- Phase 4 smoke partially works (5 Wn→SDK root sweeps mined) but the SDK self-sweep step exposes a wallet architectural gap: **the spendable set isn't filtered by "is this output's parent action actually on chain"**. As a result SDK's self-sweep picks no_send Phase 2 outputs as inputs, Teranode rejects.
- Branch `feat/126-e2e-on-chain-harness` has 4 uncommitted-but-working changes (rejection→fail_broadcast_action wiring, dedup, import_utxo idempotency, SDK self-sweep step). Do **not** discard.
- The wallet DBs are in a partially-consistent state. SDK has stuck actions referencing no_send orphans. Wn wallets are at terminal sweep state.

## Branch state

Branch: `feat/126-e2e-on-chain-harness`. Pushed to origin: yes.
Last pushed commit: `8106707 feat(engine): Engine#sweep + cleanup_spec terminal hop pays to root P2PKH`.

**Uncommitted changes** (in working tree):

```
M lib/bsv/wallet/engine.rb     — adds rejected?, wires fail_broadcast_action in both
                                  create_action + sign_action inline broadcast paths;
                                  adds dedup in import_wallet; adds idempotency check
                                  in import_utxo (find_action(wtxid:) shortcut);
                                  Phase 2 in import_utxo gets no_send: + accept_delayed_broadcast: kwargs
M spec/e2e/cleanup_spec.rb     — adds SDK self-sweep step (between Wn sweeps and import);
                                  changes import_wallet call to use include_unconfirmed: true
                                  and no_send: false (broadcast Phase 2)
```

Both changes pass `bundle exec rspec spec/bsv spec/bin` (802 examples 0 failures) and
`bundle exec rubocop`. They are correct in intent; commit before continuing if the next
session decides to push forward without further wallet design changes.

## What landed end-to-end

### Phase 1 smoke (setup_spec) — succeeded

Original SDK funding: `3e3e6afe9211bfea03f79e5dff8ae7053b7c37a8cc2944a75349dce0b21f2348:0` (100M sats, mined block 951148).

Diagnostic self-pay `8be3b74d…:0` (99,999,500 sats, mined 951310) — spent into the smoke; replaced the original UTXO. This was a probe we did before the proper Phase 1 to confirm the wallet builds consensus-valid txs.

Phase 1 broadcast 6 txs, all mined (block 951353):

| dtxid | role | status |
|---|---|---|
| `7fb47330…` | SDK import_utxo Phase 2 (BRC-42 self-payment, the wrapper around 8be3b74d) | mined |
| `cd85904a…` | SDK → W1 (10M) | mined |
| `608419e9…` | SDK → W2 (10M) | mined |
| `b5a3d5a2…` | SDK → W3 (10M) | mined |
| `8b4265e1…` | SDK → W4 (10M) | mined |
| `c57316ce…` | SDK → W5 (10M) | mined |

Per-wallet end state after Phase 1:
- W1..W5: 10,000,000 sats each as BRC-42 derived outputs (inbound from SDK)
- SDK: ~49,999,230 sats as 40 BRC-42 derived change outputs from the 5 sends, plus the wrapper

Total controlled: ~100M − 270 sats fees.

### Phase 4 smoke (cleanup_spec) — partially succeeded

Wn sweeps to SDK root: **5 txs broadcast, 4 mined, 1 mined-then-spent**.

| dtxid | from | to | result |
|---|---|---|---|
| `b47944ed…` | W1 | SDK root | mined 951357, then spent by SDK action #21 import-Phase 2 |
| `1d81328d…` | W2 | SDK root | mined 951357, unspent at SDK root |
| `9bfe63bb…` | W3 | SDK root | mined 951357, unspent at SDK root |
| `ec8d4040…` | W4 | SDK root | mined 951357, unspent at SDK root |
| `d2f05bab…` | W5 | SDK root | mined 951357, unspent at SDK root |

WoC `/unspent/all` at SDK root (`1rbsdkSoHtwuHHzW5KKBnMstN7Z7miZJ4`) right now:
- 4 confirmed outputs totalling 39,999,908 sats (all 4 mined at block 951357)
- The 5th (`b47944ed…`) was already spent by SDK action #21 (Phase 2 of importing `b47944ed`)

SDK self-sweep attempts: **2 broadcasts, both REJECTED by Teranode** with `PROCESSING (4): failed to validate transaction`:

| dtxid | action_id | input count | result |
|---|---|---|---|
| `026d92a7…` | #18 | 39 | REJECTED (sync inline broadcast — wallet did NOT know to abort, so action was left "promoted" in DB) |
| `de3a464f…` | #22 | unknown (similar) | REJECTED |

Root cause of the rejections: both self-sweep txs included SDK's no_send Phase 2 outputs as inputs — actions #9, #11, #13, #15 (created during earlier cleanup_spec attempts where `import_wallet` defaulted to `no_send: true`). Those Phase 2 txs never reached the chain, so the inputs they produced don't exist in Teranode's UTXO set.

## Database state right now

### SDK wallet DB (`bsv_wallet_sdk`)

```
actions:        21 rows
broadcasts:      8 rows
outputs:        58 rows
inputs:         52 rows
spendable:      52 rows
tx_proofs:      19 rows
truly_spendable: 0 outputs / 0 sats (after action #22's promote consumed everything)
```

**Action census** (`SELECT id, description, broadcast_intent, dtxid FROM actions ORDER BY id`):

```
 id | description         | broadcast_intent | dtxid
----+---------------------+------------------+------------------------------------------------------------------
  1 | imported UTXO       | none             | 8be3b74d26d6c74581d30681109eab5dd9d89e4b8d730b2286c1edcaa479b451  (Phase 1 import)
  2 | import self-payment | inline           | 7fb4733092a4b1f26f633fb94be0f53cc96926991e1008726ed49dc65b6f2c6e  (Phase 1 Phase 2 — MINED)
  3 | send 10000000 sats  | inline           | cd85904afd658be60cd4468f55960a8944939387c7f1040222c500e61e4c993b  (SDK→W1 — MINED)
  4 | send 10000000 sats  | inline           | 608419e9d9dabc4420f4141d450b3b8b75b70dc89b198ba5d5439f9834a244cc  (SDK→W2 — MINED)
  5 | send 10000000 sats  | inline           | b5a3d5a201c9503a901d70e71860f2648287106d906c04c29eb5501e3e799e58  (SDK→W3 — MINED)
  6 | send 10000000 sats  | inline           | 8b4265e1f3807f157915e50bd520bd7d9974bfa519dbd46bc88895b06d895b09  (SDK→W4 — MINED)
  7 | send 10000000 sats  | inline           | c57316ce6ddb5f862609394277ae9852d385b6cc8b5abfe570dd0919a63fd1f7  (SDK→W5 — MINED)
  8 | imported UTXO       | none             | ec8d40408e631db3...                                              (W4 sweep — Phase 4 import attempt #1, no_send)
  9 | import self-payment | none             | 1c18e1500b4b5aab...                                              (Phase 2 of #8 — NO_SEND, orphan)
 10 | imported UTXO       | none             | 9bfe63bb7c97b73f...                                              (W3 sweep — import attempt #1)
 11 | import self-payment | none             | 1ff27a4e27c60527...                                              (Phase 2 of #10 — NO_SEND, orphan)
 12 | imported UTXO       | none             | d2f05bab1f1a97e4...                                              (W5 sweep — import attempt #1)
 13 | import self-payment | none             | 208de934075ef581...                                              (Phase 2 of #12 — NO_SEND, orphan)
 14 | imported UTXO       | none             | 1d81328dd8890127...                                              (W2 sweep — import attempt #1)
 15 | import self-payment | none             | 74ed4ee1e1765859...                                              (Phase 2 of #14 — NO_SEND, orphan)
 16 | imported UTXO       | none             | NULL                                                             (orphan: action created, sign_action failed on duplicate-wtxid)
 17 | imported UTXO       | none             | NULL                                                             (same as #16 — earlier failed import)
 19 | imported UTXO       | none             | NULL                                                             (same — earlier failed import)
 20 | imported UTXO       | none             | b47944edd0e71faf...                                              (W1 sweep — import attempt #2, no_send)
 21 | import self-payment | inline           | d06534ac3c19eefa...                                              (Phase 2 of #20 — BROADCAST, SEEN_MULTIPLE_NODES)
 22 | sweep               | inline           | de3a464fba1cc0d4...                                              (SDK self-sweep — REJECTED by Teranode but wallet thinks it's promoted)
```

(Action #18 was manually SQL-deleted earlier in the session to release its 39 inputs.)

### Per-wallet (W1..W5) DBs

Each Wn has exactly 2 actions:

```
W1: #1 (phase 1 funding from SDK, dtxid=cd85904a — internalized BEEF)
    #2 (sweep, dtxid=b47944ed — broadcast, MINED, then spent by SDK)
W2: #1 (608419e9), #2 (1d81328d, mined, unspent at SDK root)
W3: #1 (b5a3d5a2), #2 (9bfe63bb, mined, unspent at SDK root)
W4: #1 (8b4265e1), #2 (ec8d4040, mined, unspent at SDK root)
W5: #1 (c57316ce), #2 (d2f05bab, mined, unspent at SDK root)
```

All Wn truly-spendable counts are 0 (each Wn's funding output is locked by its sweep action).

### Chain state at SDK root (`1rbsdkSoHtwuHHzW5KKBnMstN7Z7miZJ4`)

```
4 confirmed UTXOs, 39,999,908 sats total:
  ec8d4040…:0  =  9,999,977 sats  (block 951357)
  1d81328d…:0  =  9,999,977 sats  (block 951357)
  d2f05bab…:0  =  9,999,977 sats  (block 951357)
  9bfe63bb…:0  =  9,999,977 sats  (block 951357)
```

The 5th W→SDK sweep (`b47944ed`) was mined at 951357 but already spent by SDK's import-Phase-2 (`d06534ac`), which is currently in mempool (SEEN_MULTIPLE_NODES).

So SDK currently controls:
- ~40M sats at root P2PKH on chain (4 unspent UTXOs)
- ~10M sats at a fresh BRC-42 derived address on chain (the output of `d06534ac` — once that confirms)
- ~50M sats at BRC-42 derived addresses on chain (residual change from Phase 1 — wallet's DB carries derivation context but those outputs are wallet-orphan-ish because the wallet's spendable view is currently 0 due to action #22 promoting and locking everything)

## Architectural finding (the load-bearing one)

The wallet's 4-phase action lifecycle (lock / sign / broadcast / promote) handles two clean shapes:

1. **Inline broadcast + sync acceptance**: broadcast in Phase 3, promote in Phase 4. Wallet view matches chain.
2. **No_send (broadcast_intent='none')**: skip Phase 3, still promote in Phase 4. Wallet view is internal-only, intended for BEEF peer-to-peer where the recipient verifies the ancestor chain.

What's broken is the failure shape **plus** the unconditional Phase 4 promotion meaning:

- A no_send action's output goes into the spendable pool indistinguishable from an on-chain-confirmed output.
- `UTXOPool#largest` / `#smallest` etc. pick those orphans freely.
- Any subsequent broadcast that ends up consuming a no_send-parent output is dead on arrival at Teranode.

**The narrower interim fix** (proposed but not done):

> Filter spendable selection when building a broadcast tx: exclude outputs whose parent action has `broadcast_intent = 'none'` AND no `tx_proof_id` linked. The two conditions together mean "no chain reality."

That filter alone would have prevented the SDK self-sweep failures. It does not yet exist in the wallet code.

**Also missing**: async rejection cascade. When the daemon's poll loop discovers a previously-thought-OK tx is REJECTED, it should call `fail_broadcast_action` on the action and cascade to children. The interim sync-rejection→`fail_broadcast_action` wiring (now in `engine.rb`) only catches sync rejections; async ones still go undetected without the daemon.

## What's already wired in the uncommitted engine.rb

```ruby
# Engine constants
ACCEPTED_STATUSES = %w[SEEN_ON_NETWORK MINED ACCEPTED_BY_NETWORK IMMUTABLE].freeze
REJECTED_STATUSES = %w[REJECTED DOUBLE_SPEND_ATTEMPTED MALFORMED].freeze

# Engine#accepted?(broadcast_result)
#   true iff status is present and NOT in REJECTED_STATUSES
#   (Arcade's "submitted" → tx_status: "RECEIVED" via Services normalisation;
#   in-flight states like ANNOUNCED_TO_NETWORK / RECEIVED / etc. all count as accepted)

# Engine#rejected?(broadcast_result)   ← NEW
#   true iff status is present AND in REJECTED_STATUSES

# In Engine#create_action's inline-broadcast block:
if rejected?(broadcast_result)
  @store.fail_broadcast_action(action_id: ...)   # NEW — releases inputs, deletes action
elsif accepted?(broadcast_result)
  @store.promote_action_outputs(action_id: ...)
  handle_proof_from_broadcast(...)
end

# Engine#sign_action: same shape

# Engine#import_utxo: idempotency
#   short-circuits if @store.find_action(wtxid:) finds an existing action
#   prevents PG::UniqueViolation on actions_wtxid_index when re-importing

# Engine#import_wallet: dedup
#   reject duplicate (tx_hash, tx_pos) from provider response before iterating
#   defensive against mempool-race responses returning the same UTXO twice
```

## Test pass state

- `bundle exec rspec spec/bsv spec/bin` — 802 examples, 0 failures (against the uncommitted tree)
- `bundle exec rubocop` — clean
- `bundle exec rspec spec/e2e/setup_spec.rb` — last successful run completed Phase 1 fully on chain (commit `e14396e` working state). Re-running today would import the 4 unspent sweep UTXOs at SDK root and fund 4 of the 5 Wn (SDK only has ~40M left, not enough for 5×10M, even ignoring the 50M of derived-address residual).
- `bundle exec rspec spec/e2e/cleanup_spec.rb` — currently fails. SDK self-sweep keeps getting rejected by Teranode (PROCESSING 4) because it picks no_send orphan outputs as inputs.

## Possible next-session paths

In rough order of "least vs most aggressive":

1. **Just commit the safe wallet fixes and pause** (sync-rejection→fail_broadcast_action, dedup, import_utxo idempotency). These are correct architectural improvements regardless of #126. The cleanup_spec status would be "documented broken" against this branch.

2. **Implement the spendable-filter fix** in `UTXOPool#largest` / `#smallest` / `Models::Output.spendable`: only return outputs whose parent action has `broadcast_intent != 'none'` OR has a linked `tx_proof_id`. Smallish change; would unblock cleanup_spec on the current DB state without any chain action.

3. **Investigate the daemon's async rejection cascade**. Engine::Broadcast has a poll loop that fetches tx_status. When it sees REJECTED, it should cascade-fail through children. Probably not in scope for #126 alone.

4. **Test-state surgery**: manually delete the no_send Phase 2 orphan actions (#9, #11, #13, #15) and the NULL-wtxid orphans (#16, #17, #19, action #22), retry cleanup_spec. May or may not succeed depending on what else is broken.

5. **Wipe SDK's DB and rebuild from chain**: scan SDK root for the 4 unspent UTXOs (~40M), accept that the ~50M of derived-address change is orphaned (no derivation context after wipe), recover only ~40%. Reset-and-retry.

The 2 + 3 path is the architecturally correct answer. The 1 + 4 path gets you to "passes once" without solving the underlying gap.

## Sat budget situation

Started the session with ~100M on SDK funding. Currently controlled (across root + derived + in-flight):

```
On chain at SDK root:                            ~40M
In SDK mempool (action #21 Phase 2 output):      ~10M
On chain at SDK derived addresses (residual):    ~50M
─────────────────────────────────────────────────────
Total controllable from SDK WIF:                ~100M (minus ~1k sats fees)
```

If the wallet DBs are wiped, the derived-address portion (~50M) becomes orphaned — unrecoverable without the wallet's derivation prefix records. Either keep the DBs or accept the loss.

## Working tree commands to resume

```bash
cd /opt/ruby/bsv-wallet
git status                                       # confirm the 2 modified files are still there
cd gem/bsv-wallet
DATABASE_URL=postgres://postgres:postgres@localhost:5433/bsv_wallet_test \
  bundle exec rspec spec/bsv spec/bin            # should still be 802/0
bundle exec rubocop                              # should still be clean

# Inspect current DB state
PGPASSWORD=postgres psql -h localhost -p 5433 -U postgres -d bsv_wallet_sdk \
  -c "SELECT id, description, broadcast_intent, encode(reverse(wtxid),'hex') FROM actions ORDER BY id;"

# Inspect chain state at SDK root
curl -sS 'https://api.whatsonchain.com/v1/bsv/main/address/1rbsdkSoHtwuHHzW5KKBnMstN7Z7miZJ4/unspent/all' | head -c 600
```

## Files of interest

- `gem/bsv-wallet/lib/bsv/wallet/engine.rb` — Engine. Uncommitted changes here.
- `gem/bsv-wallet/lib/bsv/wallet/store.rb` — `abort_action` (refuses when broadcast row exists) and `fail_broadcast_action` (does the full unwind, but refuses if outputs are `promoted: true`).
- `gem/bsv-wallet/lib/bsv/wallet/store/utxo_pool.rb` — where the spendable-filter fix would land (the `largest` / `smallest` / `select` methods).
- `gem/bsv-wallet/lib/bsv/wallet/store/models/output.rb` — `dataset_module { def spendable ... }` is the filtering scope to extend.
- `gem/bsv-wallet/spec/e2e/cleanup_spec.rb` — uncommitted SDK self-sweep step + include_unconfirmed/no_send wiring.
- `gem/bsv-wallet/spec/e2e/setup_spec.rb` — committed at `e14396e`. Phase 1 demo path.

## SDK private key + derivation

- Root WIF: `BSV_WALLET_WIF_SDK` (from `~/.zprofile`)
- Root P2PKH address: `1rbsdkSoHtwuHHzW5KKBnMstN7Z7miZJ4`
- W1..W5 derived deterministically via `E2E::WalletDerivation.derive_by_name`
  (see `spec/e2e/support/wallet_derivation.rb` — child_bn = root_bn * (i+2) mod secp256k1_n)
