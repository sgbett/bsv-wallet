# CLI Utility Suite for BSV Wallet (#57)

## Context

Issue #57 requires two wallet instances operating independently in one test process. `Sequel::Model.db` is a global — no way around it without a major refactor. Solution: each wallet runs in its own OS process via standalone CLI tools. These tools also become the scripting/MCP surface later.

## Approach

Extract the common boot sequence from `bin/import_utxo` into a shared `CLI` module. Build three new tools (`send`, `receive`, `balance`) that each boot their own wallet process. An integration spec orchestrates them via `Open3`.

## Shared Boot Module

**File:** `gem/bsv-wallet/lib/bsv/wallet/cli.rb`

Module with three methods:
- `CLI.boot(wallet_name:, network:)` — connects DB, migrates, builds engine. Returns `{ engine:, key_deriver:, proof_store:, db:, identity_key:, private_key: }`
- `CLI.extract_wallet_name(argv)` — pops wallet name from ARGV if first arg looks like a name (not a flag/hex). Returns `[name_or_nil, remaining_args]`
- `CLI.env_fetch(base_name, wallet_name)` — resolves `WIF_ALICE` → `WIF` cascade

Not autoloaded from the main gem — bin scripts explicitly `require_relative '../lib/bsv/wallet/cli'`.

## CLI Tools

### `bin/balance` (new)
- `bin/balance [wallet] [--basket <name>]`
- Prints balance (integer sats) to stdout, detail to stderr
- Simplest tool — validates boot works

### `bin/send` (new)
- `bin/send [wallet] --to <identity_key_hex> --sats <amount> [--fee <amount>]`
- Selects first spendable output from 'default' basket
- Builds P2PKH payment + change, calls `create_action(no_send: true)`
- Writes binary BEEF to stdout, summary to stderr
- Default fee: 226 sats (1 sat/byte for standard P2PKH tx)

### `bin/receive` (new)
- `bin/receive [wallet] [--basket <name>]`
- Reads binary BEEF from stdin
- Scans outputs for P2PKH matching wallet's identity key
- Calls `internalize_action` with matching outputs
- Default basket: 'received'

### `bin/import_utxo` (refactor)
- Replace 40-line boot sequence with `CLI.boot`
- WhatsOnChain fetch logic stays in-tool (not shared)

## Integration Test

**File:** `gem/bsv-wallet/spec/integration/cli_spec.rb`

Uses `Open3.capture3` to run each tool in its own process:
1. `bin/balance alice` — verify funds
2. `bin/send alice --to <bob_key> --sats 500` — capture BEEF on stdout
3. `bin/receive bob` — pipe BEEF via stdin
4. `bin/balance bob --basket received` — verify receipt

Bob's identity key derived inline in the test from `WIF_BOB` (no DB needed).

Existing `on_chain_spec.rb` stays for in-process Engine testing.

## Implementation Order

1. `lib/bsv/wallet/cli.rb` — shared boot ✅
2. `bin/balance` — simplest, validates boot ✅
3. `bin/import_utxo` — refactor to use CLI.boot ✅
4. `bin/send` — create_action usage ✅
5. `bin/receive` — internalize_action usage ✅
6. `spec/integration/cli_spec.rb` — end-to-end test (written, not validated)
7. Update `.env.example` with wallet naming docs ✅

## Key Files

- `gem/bsv-wallet/lib/bsv/wallet/cli.rb` (create) ✅
- `gem/bsv-wallet/bin/balance` (create) ✅
- `gem/bsv-wallet/bin/send` (create) ✅
- `gem/bsv-wallet/bin/receive` (create) ✅
- `gem/bsv-wallet/bin/import_utxo` (modify) ✅
- `gem/bsv-wallet/spec/integration/cli_spec.rb` (create) ✅
- `gem/bsv-wallet/.env.example` (modify) ✅

## Verification

1. `ruby -c` syntax check all new files
2. `bundle exec rspec --exclude-pattern '**/integration/**'` — existing tests still pass
3. Manual: `bin/balance alice` boots and prints balance
4. Manual: `bin/send alice --to <key> --sats 500 | bin/receive bob` — pipeline works
5. With funded wallets: `bundle exec rspec --tag on_chain` — CLI spec passes

## What Remains

Validation — running the integration tests against real funded wallets to prove the full lifecycle works end-to-end. The CLI suite was built to surface bugs; the first round of testing surfaced schema issues that were fixed in PR #59 (issue #58). The next step is to re-run against the corrected schema.
