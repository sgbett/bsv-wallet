# Plan: Restore spendable to pure set membership (#65)

## Context

PR #56 (migration 004) moved `derivation_prefix`, `derivation_suffix`, `sender_identity_key`, and `output_type` from `outputs` to `spendable`. This conflated two concerns: recording spending authority (derivation data) with declaring an output spendable (set membership). The auto-fund work (#61) exposed this: change outputs need derivation data recorded at signing time but should not become spendable until broadcast acceptance.

The fix: move the columns and constraints back to `outputs`. Restore `spendable` to `{id, output_id, action_id}`. The `change` flag is cosmetic (display metadata) — it goes on `output_details`, not in the enum.

## Design decisions

### Ternary enum on outputs

`output_type` enum: `root`, (future: `outbound` via #66). NULL = normal derived output.

Truth table:

| output_type | derivation required | derivation forbidden | spendable allowed |
|-------------|:---:|:---:|:---:|
| NULL (normal) | YES | | YES |
| root | | YES | YES |
| outbound (#66) | | YES | NO |

Three distinct constraint profiles. `change` is NOT in the enum — it has the same constraint profile as NULL (requires derivation, allows spendable). It's a display concern, not a structural one. It belongs on `output_details`.

### Constraints on outputs

```sql
-- Root outputs must NOT have derivation fields
CHECK (output_type != 'root' OR derivation_prefix IS NULL)
CHECK (output_type != 'root' OR derivation_suffix IS NULL)
CHECK (output_type != 'root' OR sender_identity_key IS NULL)

-- Non-root outputs (NULL type) must have derivation fields
CHECK (output_type IS NOT NULL OR derivation_prefix IS NOT NULL)
CHECK (output_type IS NOT NULL OR derivation_suffix IS NOT NULL)
CHECK (output_type IS NOT NULL OR sender_identity_key IS NOT NULL)
```

When `outbound` is added (#66), it gets the same "no derivation" treatment as root, plus a constraint preventing spendable rows.

### Change output lifecycle

No special treatment. Change outputs follow the same lifecycle as any other output:

- **Phase 2b** (`sign_action`): write Output row with derivation data. No Spendable row.
- **Phase 4** (broadcast acceptance or `no_send`): promote — add Spendable row.

This is identical to how caller outputs work today. No phantom UTXOs, no special BEEF chaining path. The `no_send` path promotes immediately (caller explicitly accepts the risk). The broadcast path promotes on acceptance.

### `output_details.change` flag

Cosmetic. Tells the UI "this output was change from a transaction you sent." Never indexed, never queried in the hot path. UTXO selection picks by satoshis and basket, never by change flag.

## Blast radius

60+ locations across 4 layers: migration, Store, Engine, specs. Wide but shallow — most changes are mechanical column reference moves.

## Files to modify

| File | Changes |
|------|---------|
| `db/migrations/004_schema_constraints.rb` | Keep derivation on outputs, add output_type + constraints to outputs, strip spendable back to thin, keep `change` on output_details |
| `db/migrations/005_add_change_to_output_details.rb` | DELETE — 004 no longer drops `change` from output_details |
| `postgres/store.rb` | promote_action, sign_action, resolve_inputs_for_signing, find_spendable, query_change_output_vouts |
| `interface/store.rb` | Update docs for sign_action, promote_action |
| `wallet/engine.rb` | auto_fund_action, build_funded_transaction |
| `postgres/constraints_spec.rb` | Constraint tests: spendable → outputs |
| `postgres/store_spec.rb` | Move derivation fields from Spendable.create to Output.create |
| `postgres/spendable_spec.rb` | Remove derivation/output_type from Spendable tests |
| `postgres/output_spec.rb` | Move output_type to Output creation |
| `postgres/migration_spec.rb` | Update enum location expectations |
| `wallet/engine_spec.rb` | Move derivation fields in fund_wallet helpers and output specs |
| `docs/reference/schema.md` | Reconcile with schema-constraints.md |
| `docs/reference/schema-constraints.md` | Merge into schema.md, then delete |

## Implementation steps

### Step 1: Migration 004 — reverse the column move

Database is rebuildable (no production data), so we edit in place.

**outputs section:** Remove the 3 `drop_column` lines (keep derivation columns from 001). Add `output_type` column. Add the 6 CHECK constraints (rewritten for root-only exclusion):

```ruby
# --- 5. outputs ---
# The immutable log. Derivation data lives here — it's a fact about the
# output, recorded when the key is derived. Spendable is pure membership.
alter_table(:outputs) do
  set_column_not_null :locking_script
  add_column :output_type, :output_type
  add_constraint(:satoshis_range)          { satoshis >= 0 }
  add_constraint(:vout_range)              { vout >= 0 }
  add_constraint(:locking_script_min)      { length(locking_script) >= 1 }
  # Root outputs use identity key directly — no derivation fields
  add_constraint(:root_no_prefix,    "output_type != 'root' OR derivation_prefix IS NULL")
  add_constraint(:root_no_suffix,    "output_type != 'root' OR derivation_suffix IS NULL")
  add_constraint(:root_no_sender,    "output_type != 'root' OR sender_identity_key IS NULL")
  # Derived outputs (NULL type) must have all derivation fields
  add_constraint(:derived_needs_prefix, 'output_type IS NOT NULL OR derivation_prefix IS NOT NULL')
  add_constraint(:derived_needs_suffix, 'output_type IS NOT NULL OR derivation_suffix IS NOT NULL')
  add_constraint(:derived_needs_sender, 'output_type IS NOT NULL OR sender_identity_key IS NOT NULL')
end
```

**spendable section:** Strip to thin membership:

```ruby
# --- 6. spendable ---
# Pure set membership — a row's existence IS the wallet.
alter_table(:spendable) do
  set_column_not_null :action_id
end
```

**output_details section:** Keep `change` column (remove the `drop_column :change` line). It's cosmetic metadata, not structural:

```ruby
# --- 7. output_details ---
alter_table(:output_details) do
  set_column_not_null :action_id
  # change column stays — cosmetic flag for display, not structural
end
```

**down block:** Mirror changes. Drop output_type + constraints from outputs. Spendable reverts action_id to nullable. Output_details re-drops change (to match 001 state? — actually 001 has change, so down is a no-op for output_details).

Wait — 001 creates output_details WITH `change` (it was in the original schema). 004 currently drops it. If we stop dropping it, the down migration for output_details just needs to revert `action_id` to nullable. No column changes.

### Step 2: Delete migration 005

`005_add_change_to_output_details.rb` re-adds `change` to output_details. Since 004 no longer drops it, 005 is unnecessary. Delete the file.

### Step 3: Store — `promote_action`

Derivation fields and `output_type` move from `Spendable.create` to `Output.create`. Spendable becomes thin:

```ruby
output = Output.create(
  action_id:           action_id,
  satoshis:            out[:satoshis],
  vout:                out[:vout],
  locking_script:      out[:locking_script],
  output_type:         out[:output_type],
  derivation_prefix:   out[:derivation_prefix],
  derivation_suffix:   out[:derivation_suffix],
  sender_identity_key: out[:sender_identity_key]
)

if wallet_owned
  Spendable.create(output_id: output.id, action_id: action_id)
end
```

### Step 4: Store — `sign_action` (change outputs)

Change outputs write Output rows with derivation data. NO Spendable rows — promotion happens later (Phase 4 or no_send).

The `change: true` flag goes on OutputDetail:

```ruby
change_outputs.each do |chg|
  output = Output.create(
    action_id:           action_id,
    satoshis:            chg[:satoshis],
    vout:                chg[:vout],
    locking_script:      chg[:locking_script],
    derivation_prefix:   chg[:derivation_prefix],
    derivation_suffix:   chg[:derivation_suffix],
    sender_identity_key: chg[:sender_identity_key]
  )
  OutputDetail.create(output_id: output.id, action_id: action_id, change: true)
end
```

No Spendable row. No output_type (NULL = normal derived output, which is what change is structurally).

### Step 5: Store — `resolve_inputs_for_signing`

Read derivation fields from `outputs` instead of `spendable`. Remove the `left_join(:spendable, ...)` entirely:

```ruby
rows = @db[:inputs]
  .join(:outputs, id: :output_id)
  .join(Sequel[:actions].as(:source_actions), id: Sequel[:outputs][:action_id])
  .where(Sequel[:inputs][:action_id] => action_id)
  .order(Sequel[:inputs][:vin])
  .select(
    Sequel[:inputs][:vin],
    Sequel[:inputs][:nsequence].as(:sequence),
    Sequel[:source_actions][:wtxid].as(:source_wtxid),
    Sequel[:outputs][:vout].as(:source_vout),
    Sequel[:outputs][:satoshis].as(:source_satoshis),
    Sequel[:outputs][:locking_script].as(:source_locking_script),
    Sequel[:outputs][:derivation_prefix],
    Sequel[:outputs][:derivation_suffix],
    Sequel[:outputs][:sender_identity_key]
  )
  .all
```

One fewer join. Simpler query. Faster.

### Step 6: Store — `find_spendable`

Read derivation fields from `output` instead of `spendable_entry`:

```ruby
candidates << {
  id:                  output.id,
  satoshis:            output.satoshis,
  vout:                output.vout,
  action_id:           output.action_id,
  locking_script:      output.locking_script,
  derivation_prefix:   output.derivation_prefix,
  derivation_suffix:   output.derivation_suffix,
  sender_identity_key: output.sender_identity_key
}
```

No need to touch `spendable_entry` at all.

### Step 7: Store — `query_change_output_vouts`

Query `output_details.change` (the cosmetic flag):

```ruby
def query_change_output_vouts(action_id:)
  Output.where(action_id: action_id)
        .where(
          OutputDetail.dataset
            .where(Sequel[:output_details][:output_id] => Sequel[:outputs][:id])
            .where(change: true)
            .select(1)
            .exists
        )
        .select_map(:vout)
end
```

This is actually the same query as the current PR #62 version. It was right before the enum distraction.

### Step 8: Engine — `auto_fund_action`

The key behavioral change. Change outputs follow the same promotion lifecycle as caller outputs:

**`sign_action`** writes Output rows (with derivation) + OutputDetail (with `change: true`). No Spendable.

**`no_send` path:** After sign_action, promote change outputs to spendable. Same as caller outputs — `promote_with_outputs` already handles this pattern. Need a `promote_change_outputs` method or extend the existing promote flow to include change outputs.

**Broadcast path:** After broadcast acceptance, promote change outputs alongside caller outputs. The data is on the Output row — promotion is just `Spendable.create(output_id:, action_id:)`.

Implementation: `sign_action` writes Output + OutputDetail for change. A new Store method `promote_change_to_spendable(action_id:)` queries outputs with `output_details.change = true` for the action and creates Spendable rows. Called from `auto_fund_action` in the no_send path and after broadcast acceptance.

### Step 9: Engine — `build_funded_transaction`

Remove `output_type` from change_output_specs (change is not a type, it's a flag). Derivation fields stay as-is.

### Step 10: Specs — mechanical updates

- Every `Spendable.create` with derivation fields → move to `Output.create`
- Every `Spendable.create` with `output_type:` → move to `Output.create`
- `Spendable.create` becomes just `(output_id:, action_id:)`
- Constraint specs test on `outputs` table, not `spendable`
- Auto-fund specs verify change outputs are NOT spendable until promotion

### Step 11: Documentation — reconcile schema docs

Merge `schema-constraints.md` into `schema.md`. One document, one truth:
- Derivation on outputs
- Spendable is thin `{id, output_id, action_id}`
- output_type enum on outputs: `root` (future: `outbound`)
- `change` flag on output_details (cosmetic)

Delete `schema-constraints.md`.

## Risk

- Surface area is wide (60+ locations) but changes are mechanical
- CI enforces green — nothing merges broken
- The constraint rework (root-only exclusion) is simpler than the original mutual-exclusivity pattern
- The `promote_change_to_spendable` method is new Store surface area, but minimal (query + insert)
