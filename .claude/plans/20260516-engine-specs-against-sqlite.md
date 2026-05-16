# Engine Specs Against SQLite — Plan

**Issue:** #123
**Branch:** `feat/123-engine-specs-against-sqlite`
**Date:** 2026-05-16

## Overview

The engine spec suite previously ran exclusively against Postgres because that was the first Store implementation. Now that the default SQLite store exists (#116) and shared `Store::Base` orchestration (#120) confirms the engine logic is backend-agnostic, the engine specs move to SQLite — the wallet gem's actual default store.

The wallet gem stands on its own. SQLite is the implementation, and the wallet gem's spec suite is fully self-contained around it. No Postgres references, no backend parameterisation, no cross-backend coupling.

## Scope

Five spec files needed updating, plus the spec_helper and a stray comment:

| File | Change |
|---|---|
| `spec/bsv/wallet/engine/shared_context.rb` | Collapse to SQLite-only setup; reuse the wallet gem's existing `STORE_DB` |
| `spec/bsv/wallet/engine_spec.rb` | 3 direct model references switch from `BSV::Wallet::Postgres::Store::*` to `BSV::Wallet::Store::*`; drop the `if:` guard |
| `spec/bsv/wallet/engine/{limp_mode,porcelain,wbikd}_spec.rb` | Drop the `if:` guard |
| `spec/spec_helper.rb` | Remove the conditional truncate that existed for the Postgres path |
| `spec/bsv/network/chain_tracker_spec.rb` | Reword a stale comment that mentioned Postgres |
| `gem/bsv-wallet/Gemfile` | Update comment — bsv-wallet-postgres is now only for the on-chain integration test |

## Design

The engine specs piggyback on the wallet gem's existing `store/shared_context.rb`:

```ruby
require 'bsv-wallet'
require_relative '../store/shared_context'
```

That context already:
- Sets up an in-memory SQLite database (`STORE_DB`)
- Runs the wallet gem's migrations
- Binds `BSV::Wallet::Store::*` models to that database
- Wraps each example in a `transaction(rollback: :always)` for isolation

The engine `shared_context` then exposes services via `BSV::Wallet::Store.bootstrap(db: STORE_DB)` (introduced in #117 for the CLI auto-discovery path; also a clean factory for tests):

```ruby
let(:engine_services) { BSV::Wallet::Store.bootstrap(db: STORE_DB) }
let(:store)           { engine_services[:store] }
let(:utxo_pool)       { engine_services[:utxo_pool] }
let(:proof_store)     { engine_services[:proof_store] }
let(:broadcast_queue) { engine_services[:broadcast_queue] }
```

A few engine_spec.rb examples reach around the Store interface to verify implementation details (direct row delete to simulate the reaper; raw column read to check `tx_proof_id`). Those reference the model classes directly:

```ruby
BSV::Wallet::Store::Action.where(id: action[:id]).delete
BSV::Wallet::Store::Action.first(wtxid: Sequel.blob(...))
BSV::Wallet::Store::BroadcastQueue.new(services: services)
```

No abstraction, no indirection — the wallet gem is SQLite.

## Acceptance criteria (from issue #123)

- [x] Engine spec runs to green against SQLite
- [x] No duplication of test bodies
- [x] CI runs the wallet suite against SQLite
- [x] No new ARC mocking or fixtures required
- [x] Default local-dev backend is SQLite

## Verification

```bash
cd gem/bsv-wallet && bundle exec rspec
cd gem/bsv-wallet && bundle exec rubocop
```

637 examples, 0 failures. Rubocop clean.

## What's NOT here

- **No backend parameterisation.** The wallet gem's specs don't know about other backends. They test the default SQLite implementation, end to end.
- **No Postgres references in the wallet gem's spec tree.** The bsv-wallet-postgres gem has its own spec suite covering its concerns.
- **No "canary" step.** The wallet gem is a self-contained library; CI for it tests what it ships.

## Sequencing

1. #116 — Default SQLite store ✅
2. #119 — Restructure Postgres to match ✅
3. #120 — Extract shared orchestration ✅
4. #117 — Auto-discovery wiring ✅
5. **#123 — Engine specs against SQLite** ← this plan
