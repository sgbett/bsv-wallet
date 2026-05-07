# CLI Plumbing Tools & Engine Validation (#57)

## Context

The wallet's `create_action` is a low-level BRC-100 primitive — the caller provides fully-specified inputs and outputs. UTXO selection, fee calculation, and script construction are application-layer responsibilities. The current `bin/send` does all of this inline, making it hard to test individual steps and impossible to compose.

We need Unix-style plumbing tools that each do one thing, compose via pipes, and exercise the engine's machinery. We also need engine validation to catch logic errors (like marking someone else's output as spendable) before they hit the database.

Two inference bugs were already fixed this session. This plan builds on that.

## Output Convention

All tools share a common output pattern:

- **stdout piped**: binary output (for composition)
- **stdout TTY**: hex output (human-readable)
- `-b` flag: force binary to TTY
- `-o <file>`: write to file instead of stdout
- Machine-readable data to stdout, human summaries to stderr

Add `CLI::Output` module to `cli.rb` with `write_binary(data, opts)` and `write_json(hash, opts)`.

## Foundation Changes

### 1. `cli.rb` — expose utxo_pool, add Output module

- Pull `UTXOPool.new(store: store)` into a local variable
- Add `utxo_pool: utxo_pool` to the boot return hash
- Add `CLI::Output` module with TTY-aware binary/hex/JSON writing

### 2. Rename `bin/import_utxo` to `bin/import_root_utxo`

File rename only. Update internal usage strings. No logic changes.

## Plumbing Tools

### 3. `bin/list_outputs`

Detailed spendable output listing. Goes beyond `balance` to show IDs, vout, scripts, baskets.

```
bin/list_outputs [wallet] [--basket <name>] [--limit <n>] [--scripts]
```
- Stdout: JSON
- Engine method: `list_outputs`

### 4. `bin/select_utxos`

Select UTXOs for a target amount. Does NOT lock them.

```
bin/select_utxos [wallet] --sats <amount>
```
- Stdout: JSON array of `{id, satoshis, vout}`
- Uses: `ctx[:utxo_pool].select(satoshis:)`

### 5. `bin/derive`

Generate derivation prefix/suffix for a counterparty payment.

```
bin/derive [wallet] --counterparty <identity_key_hex> [--prefix <str>] [--suffix <str>]
```
- Stdout: two lines — `prefix\nsuffix`
- Defaults: prefix = `SecureRandom.uuid`, suffix = `'1'`
- Verifies derivation works via `key_deriver.derive_public_key`

### 6. `bin/lock`

Construct a P2PKH locking script from identity key + optional derivation.

```
bin/lock --to <identity_key_hex>                              # root-key P2PKH
bin/lock [wallet] --to <key> --prefix <p> --suffix <s>        # derived P2PKH (BRC-42)
```
- Stdin: optionally reads prefix/suffix (two lines) if not via flags
- Stdout: locking script (binary when piped, hex when TTY)
- Root-key path: no wallet boot needed, just `hash160(pubkey_bytes)` + `p2pkh_lock`
- Derived path: needs wallet boot for ECDH, uses `key_deriver.derive_public_key(for_self: true)`

### 7. `bin/create_action`

Raw `Engine#create_action` wrapper. Caller provides fully-specified JSON.

```
echo '{"inputs":[...], "outputs":[...]}' | bin/create_action [wallet] --description "..." [--no-send] [--label ...]
```
- Stdin: JSON with inputs/outputs
- Stdout: BEEF (binary/hex per convention)
- Converts hex locking_script values to binary before passing to engine

### 8. `bin/internalize`

Raw `Engine#internalize_action` wrapper.

```
bin/send alice ... | bin/internalize bob --description "received" --output "0:basket:received"
```
- Stdin: BEEF binary
- `--output` specs: `<vout>:<protocol>:<basket>` (repeatable)
- Engine method: `internalize_action`

## Porcelain Upgrades

### 9. `bin/send` — upgrade

Currently does everything inline. Upgrade to use `UTXOPool#select` for multi-UTXO selection and simple fee estimation (`inputs * 148 + outputs * 34 + 10`).

Keep as a porcelain tool — internally composes the plumbing steps but doesn't shell out to them.

### 10. `bin/receive` — rename from current, minor cleanup

The existing receive tool is fine for root-key P2PKH scanning. Add `output_type: 'root'` to the internalized output spec so the Store correctly marks ownership.

## Engine Validation

### 11. `validate_output_ownership!` in Engine

Add validation in `create_action` after building outputs:
- If `output_type: 'root'` — verify locking script is P2PKH to the identity key
- If `output_type: 'change'` — verify locking script is P2PKH (trust caller on which key)
- Reject `output_type` on non-P2PKH scripts

Location: `engine.rb`, new private method called before `promote_with_outputs`.

## Implementation Order

```
Phase 1: Foundation (no dependencies)
  1. cli.rb — Output module + utxo_pool in boot context
  2. Rename import_utxo → import_root_utxo

Phase 2: Read-only plumbing
  3. bin/list_outputs
  4. bin/select_utxos

Phase 3: Derivation & script plumbing
  5. bin/derive
  6. bin/lock

Phase 4: Action plumbing
  7. bin/create_action
  8. bin/internalize

Phase 5: Validation
  9. validate_output_ownership! in Engine

Phase 6: Porcelain
  10. Upgrade bin/send
  11. Update bin/receive
```

## Files

| File | Action |
|------|--------|
| `gem/bsv-wallet/lib/bsv/wallet/cli.rb` | Modify — Output module, utxo_pool |
| `gem/bsv-wallet/bin/import_utxo` | Rename → `import_root_utxo` |
| `gem/bsv-wallet/bin/list_outputs` | Create |
| `gem/bsv-wallet/bin/select_utxos` | Create |
| `gem/bsv-wallet/bin/derive` | Create |
| `gem/bsv-wallet/bin/lock` | Create |
| `gem/bsv-wallet/bin/create_action` | Create |
| `gem/bsv-wallet/bin/internalize` | Create |
| `gem/bsv-wallet/bin/send` | Modify |
| `gem/bsv-wallet/bin/receive` | Modify |
| `gem/bsv-wallet/lib/bsv/wallet/engine.rb` | Modify — validation |
| `gem/bsv-wallet/spec/integration/cli_spec.rb` | Modify |

## Verification

After each phase, verify with the real funded wallet:

```bash
# Phase 1: import still works
bin/import_root_utxo alice <txid> 0

# Phase 2: queries work
bin/list_outputs alice --basket default
bin/select_utxos alice --sats 500

# Phase 3: derivation + scripts work  
bin/derive alice --counterparty <bob_key>
bin/lock --to <bob_key> | xxd    # should show 76 a9 14 ... 88 ac

# Phase 4: raw action pipeline works
bin/select_utxos alice --sats 500 → feed IDs into create_action JSON
echo '<json>' | bin/create_action alice --description "test" | bin/internalize bob --description "rx" --output "0:basket:received"

# Phase 6: porcelain still works  
bin/send alice --to <bob_key> --sats 500 | bin/receive bob
bin/balance alice && bin/balance bob --basket received
```
