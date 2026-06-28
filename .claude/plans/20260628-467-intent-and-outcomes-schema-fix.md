# HLR #467 — Schema fix: drop `output_type`, state `spendable_intent` explicitly, structural root validation via per-wallet CHECK

**HLR:** #467
**Foundational docs:** `docs/reference/intent-and-outcomes.md` + `ADR-031`
**Related:** ADR-010 (banned the inference in code, encoded it structurally), HLR #60 (broader inference-site audit register), PR #466 (Phase 5, blocked on this), HLR #460 (BRC-29 strict alignment — separate concern)
**Branch:** `feat/467-intent-and-outcomes-schema-fix` (off `feat/433-phase-5-cli-catchup-and-send-beef`)
**PR target:** `feat/433-phase-5-cli-catchup-and-send-beef` (not master)

## Problem (summary)

`outputs.output_type` triples as kind tag, spendability discriminator, and inference target. The schema's `typed_no_*` constraints encode an inference rule structurally — the exact anti-pattern ADR-010 banned in code while baking it into the schema. PR #466's `send_beef_spec.rb` surfaced the consequence: BRC-29 outbound payments mis-classified as self-spendable.

The wallet's identity is pinned by the WIF at construction time; root P2PKH outputs are structurally identifiable from `locking_script = 1976a9{hash160(identity_pubkey)}88ac`. The kind doesn't need a stored marker — it's a fact derivable from the locking script bytes, and can be enforced by a per-wallet DB CHECK with the literal embedded at migration time.

## Approach (summary)

Drop `output_type`. Add `spendable_intent: enum('spendable', 'none')` as the explicitly stated intent. Encode root identification as a structural CHECK with a per-wallet literal (no functions on the hot path). Remove the five inference sites (`engine/action.rb:124`, `store.rb:198`, `store.rb:224`, `beef_importer.rb:329`, `brc100.rb#validate_output_ownership!`). Make every decision-maker (CLI commands, Engine internal methods, BRC-100 wrapper, TxBuilder) state `spendable_intent` explicitly. Mirror the DB CHECK at the Sequel model layer for clean app-level errors before the DB rejects.

## The valid permutations

Three independent properties of an `outputs` row:

| `root_pattern` (locking_script matches `1976a9{HASH}88ac`) | `controls_present` (derivation_prefix/suffix/sender_identity_key all set) | `spendable_intent` | Valid? | Why |
|---|---|---|---|---|
| T | F | `spendable` | ✅ | Root P2PKH we own (chain UTXO) |
| T | F | `none` | ❌ | Root-pattern locking → we own it; `none` contradicts |
| T | T | `spendable` | ❌ | Hash collision (~2⁻¹⁶⁰); reject as impossible-state |
| T | T | `none` | ❌ | Same — impossible-state insertion |
| F | F | `spendable` | ❌ | No way to spend (no controls, not root) |
| F | F | `none` | ✅ | Outbound base58 (no controls, no root match) |
| F | T | `spendable` | ✅ | BRC-42 self-payment / change |
| F | T | `none` | ✅ | BRC-29 outbound via derivation to counterparty |

Four valid, four invalid. Two schema constraints together enforce:

```ruby
# controls_all_or_nothing — derivation triple set together or absent together
constraint(
  :controls_all_or_nothing,
  '(derivation_prefix IS NULL AND derivation_suffix IS NULL AND sender_identity_key IS NULL) ' \
  'OR (derivation_prefix IS NOT NULL AND derivation_suffix IS NOT NULL AND sender_identity_key IS NOT NULL)'
)

# spendable_recoverable — the row encodes a recoverable spending key (or honestly admits none)
# Literal embedded at migration time from Migration.identity_pubkey_hash.
constraint(
  :spendable_recoverable,
  Sequel.lit(
    '(locking_script = ? AND derivation_prefix IS NULL AND spendable_intent = ?) ' \
    'OR (locking_script <> ? AND derivation_prefix IS NULL AND spendable_intent = ?) ' \
    'OR (locking_script <> ? AND derivation_prefix IS NOT NULL)',
    root_script_lit, 'spendable',
    root_script_lit, 'none',
    root_script_lit
  )
)
```

No functions on the hot path. Single literal byte comparison + null checks per insert.

## Commit cadence

**First commit:** this plan file + `docs/reference/intent-and-outcomes.md` + ADR-031 + ADR INDEX update. Title: `docs(plans): #467 — intent-and-outcomes schema fix`.

**Subsequent commits:** atomic units as the work surfaces them. The phases below organise the work; they are NOT a 1:1 commit map. A phase may yield one commit if the change is tight; it may yield several if the work has natural seams. The cadence follows the work, not the plan's section count. Each commit references `#467` in its subject.

---

## Phase 0 — Pre-flight

Drop and recreate every per-wallet test DB. The schema is changing structurally; stale migration state will fail.

```bash
for db in test alice bob carol sdk w1 w2 w3 w4 w5; do
  PGPASSWORD=postgres psql -h localhost -p 5433 -U postgres -c \
    "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'bsv_wallet_$db'"
  PGPASSWORD=postgres psql -h localhost -p 5433 -U postgres -c "DROP DATABASE IF EXISTS bsv_wallet_$db"
  PGPASSWORD=postgres psql -h localhost -p 5433 -U postgres -c "CREATE DATABASE bsv_wallet_$db"
done
```

## Phase 1 — Principle documentation (Commit 1)

**Deliverables:**

1. **This plan file** — saved to `.claude/plans/20260628-467-intent-and-outcomes-schema-fix.md`.

2. **`docs/reference/intent-and-outcomes.md`** — load-bearing principle doc:
   - Statement: intent stated explicitly; outcomes persisted as rows; never reverse-engineer intent from outcomes.
   - Derive vs infer terminology: forward (rules → facts → derived view) good; backward (outcome → guessed intent) bad.
   - The atomicity argument: state machine of valid intermediate states; multiple atomic transitions.
   - The outcome-row-deletion catastrophe: derivation must survive on the immutable log (`outputs`, not `spendable`).
   - Living register of intent points: `broadcast_intent` (settled), `spendable_intent` (this HLR), shape for additions.
   - The enum convention: enums over booleans, even for two values (extensibility + symmetry).
   - Cross-references: `principle-of-state.md`, `state-boundaries.md`, `core-vs-conformance.md`; ADR-003, ADR-010, ADR-031.

3. **`.architecture/decisions/adrs/20260628_ADR-031-intent-and-outcomes.md`** — captures why we articulated the principle now:
   - Two examples that surfaced it (`broadcast_intent` settled correctly; spendable-controls inference surfaced by `send_beef_spec.rb`).
   - ADR-010's blindspot: banned the inference in code, encoded it structurally via `typed_no_*`.
   - HLR #467 as the first principle-driven schema fix; HLR #60 as the living audit register.
   - Pragmatic Enforcer block: this is naming what we have been doing wrong, not adding speculation.

4. **`.architecture/decisions/adrs/INDEX.md`** — add ADR-031 entry.

**Verification:** cross-references resolve; British prose, no emoji.

---

## Phase 2 — Schema rework + migration plumbing (Commit 2)

**Deliverables:**

1. **`lib/bsv/wallet/migration.rb`** (new tiny module):
   ```ruby
   module BSV::Wallet::Migration
     class << self
       attr_accessor :identity_pubkey_hash
     end
   end
   ```
   Plus an `expected_root_script` helper that returns the 25-byte locking script bytes for the current `identity_pubkey_hash` — shared between migrations and the model validator.

2. **`Store#migrate!`** — set the hash before invoking Sequel migrator, reset after:
   ```ruby
   def migrate!
     BSV::Wallet::Migration.identity_pubkey_hash = key_deriver.identity_pubkey_hash
     Sequel::Migrator.run(@db, MIGRATIONS_DIR)
   ensure
     BSV::Wallet::Migration.identity_pubkey_hash = nil
   end
   ```

3. **`KeyDeriver#identity_pubkey_hash`** — verify the method exists; if not, add it (returns 20-byte binary `hash160(identity_pubkey_bytes)`).

4. **Amend `db/migrations/001_create_schema.rb`:**

   In the type-mapping constants block at the top:
   - Remove `c[:output_type] = postgres ? :output_type : :text`
   - Add `c[:spendable_intent] = postgres ? :spendable_intent : :text`

   In the `create_enum` declarations:
   - Remove `create_enum(:output_type, %w[root outbound])`
   - Add `create_enum(:spendable_intent, %w[spendable none])`

   In `create_table(:outputs)`:
   - Remove `column :output_type, c[:output_type]`
   - Add `column :spendable_intent, c[:spendable_intent], null: false`
   - Remove the six `typed_no_*` / `derived_needs_*` constraint declarations
   - Add `controls_all_or_nothing` constraint
   - Add `spendable_recoverable` constraint with per-wallet literal (see above)

   SQLite-only ENUM-equivalent CHECK:
   - Remove `output_type_values` constraint
   - Add `constraint(:spendable_intent_values, "spendable_intent IN ('spendable', 'none')") unless postgres`

5. **Amend `db/migrations/002_triggers.rb`:**
   - Rewrite `prevent_outbound_spendable` trigger: change `output_type = 'outbound'` check to `spendable_intent = 'none'`.
   - Keep the trigger as defence-in-depth for direct `spendable` inserts that bypass the application path. Follow-up issue tracks its eventual evaluation for removal.

6. **`models::Output`** — drop the `:output_type` column reference; add `:spendable_intent`. Verify existing scopes (`spendable`, etc.) are unaffected.

**Constraint-level spec coverage:** new spec exercises each of the 8 permutations against a real DB, confirming the 4 invalid combinations are rejected with the right constraint name. Postgres-targeted; SQLite differs slightly in error text — translate.

**Verification:**
- `bundle exec rspec spec/bsv` against Postgres against a fresh `bsv_wallet_test` DB — schema specs pass.
- `\d outputs` in psql shows the new column and the literal-bearing CHECK with the wallet's actual hash visible.

---

## Phase 3 — Sequel model validation (Commit 3)

**Deliverables:**

1. **`def validate`** on `models::Output` mirroring the DB CHECK logic:

   ```ruby
   class Output < Sequel::Model(:outputs)
     def validate
       super
       validate_controls_all_or_nothing
       validate_spendable_recoverable
     end

     private

     def validate_controls_all_or_nothing
       set_count = [derivation_prefix, derivation_suffix, sender_identity_key].count { |v| !v.nil? }
       return if [0, 3].include?(set_count)

       errors.add(:derivation_prefix,
                  'derivation_prefix/derivation_suffix/sender_identity_key must be all set or all absent')
     end

     def validate_spendable_recoverable
       expected = BSV::Wallet::Migration.expected_root_script
       root_match = locking_script == expected
       controls_set = !derivation_prefix.nil?

       valid = case [root_match, controls_set, spendable_intent.to_s]
               in [true, false, 'spendable'] | [false, false, 'none'] | [false, true, _]
                 true
               else
                 false
               end
       return if valid

       errors.add(:spendable_intent,
                  "invalid combination: root_match=#{root_match} controls=#{controls_set} intent=#{spendable_intent}")
     end
   end
   ```

2. **Store-boundary error translation** — wherever `models::Output.create` is called (Store insertion paths), rescue `Sequel::ValidationFailed` and raise `BSV::Wallet::InvalidParameterError` with the formatted error message. Single rescue covers the whole insertion path.

**Verification:**
- New spec `spec/bsv/wallet/store/models/output_spec.rb` exercising all 8 permutations against the model (no DB roundtrip required for the validation tests — model `valid?` returns false for the four invalid combinations).
- Existing Store specs still pass (with `spendable_intent` added to their output specs in Phase 5 if not in this phase).

---

## Phase 4 — Engine API + inference site removal (Commit 4)

**Deliverables:**

1. **`Engine::Action.canonical_outputs`** (`engine/action.rb:115-140`):
   - Drop `effective_type = out[:output_type] || (out[:derivation_prefix] ? nil : 'outbound')`.
   - Require `out[:spendable_intent]` — raise `InvalidParameterError` with a clean message if missing.
   - Pass `spendable_intent: out[:spendable_intent]` through to the row hash.
   - Drop the `output_type: effective_type` field from the emitted hash.

2. **`Store#do_create_action_outputs`** (`store.rb:185-205`):
   - Replace `wallet_owned = out[:derivation_prefix] || out[:output_type] == 'root'`
   - With `wallet_owned = out[:spendable_intent].to_s == 'spendable'`.
   - Spendable row creation continues to be gated on stated intent.

3. **`Store#promote_action_outputs`** (`store.rb:216-235`):
   - Replace the inference with `output.spendable_intent.to_s == 'spendable'`.
   - Drop the `change_output?` fallback (no longer needed — `spendable_intent` stated explicitly upstream covers change outputs).
   - Grep for any remaining callers of `change_output?`; if none, delete the method; if any, leave + add to the follow-up issue.

4. **`Engine::BeefImporter#resolve_internalize_output`** (`beef_importer.rb:317-330`):
   - Drop `spec[:output_type] = 'root' unless rem[:derivation_prefix]`.
   - Set `spec[:spendable_intent] = 'spendable'` for both `basket_insertion` and `wallet_payment` branches (all wallet-bound).

5. **`BRC100#validate_output_ownership!`** (`brc100.rb:455-477`):
   - Delete the entire method.
   - Delete callers' invocation of it.
   - The DB CHECK + model `validate` together replace it across all paths.

6. **`Store#sweepable_state`** (`store.rb:556-572`):
   - Replace `WHERE outputs.output_type IS NULL` with `WHERE outputs.derivation_prefix IS NOT NULL`.
   - Update the surrounding docstring's "Root outputs (output_type = 'root')" wording.

7. **`store/sweepable_state.rb`** docstring — same wording fix.

**Verification:** unit specs around the changed classes pass. Specs that construct fixture outputs may need `spendable_intent:` added — fixed mechanically here or in Phase 5.

---

## Phase 5 — Decision-makers state intent (Commit 5)

Every site that constructs an output spec for `engine.build_action` (or directly invokes `Engine::Action.canonical_outputs`) gets `spendable_intent:` set explicitly.

**CLI commands:**
- `send.rb` base58 path → `spendable_intent: 'none'`
- `send.rb` identity-key path → `spendable_intent: 'none'` (derivation columns retained as provenance, now harmless under the new CHECK)
- `receive.rb` envelope path → `spendable_intent: 'spendable'`
- `receive.rb` raw-BEEF path → `spendable_intent: 'spendable'`
- `import.rb` → flows through `engine.import_wallet` (verify intent set internally)
- `consolidate.rb` → flows through `engine.consolidate_step` (verify)
- `sweep.rb` → flows through `engine.sweep` (verify)

**Engine internal methods:**
- `Engine#send_payment` (`engine.rb:1042`): payment output `'none'`, change output (added by TxBuilder) `'spendable'`
- `Engine#consolidate_step`: consolidation output `'spendable'`
- `Engine#sweep`: outbound `'none'`
- `Engine#import_utxo`: self-payment output `'spendable'`
- `Engine#import_wallet`: forwards via `import_utxo`
- `Engine#internalize_wbikd_utxo`: `'spendable'`

**TxBuilder change output construction** (`engine/tx_builder.rb`):
- Change outputs are BRC-42 self-payments → `spendable_intent: 'spendable'`.

**BRC-100 wrapper** (`brc100.rb`):
- `createAction` outputs spec — translate from BRC-100 vocab to engine vocab with default `spendable_intent: 'spendable'` (the BRC-100 spec assumes self-owned outputs).
- Document this in the wrapper.

**Unit-spec updates included in this commit** for each touched class.

---

## Phase 6 — Spec sweep + integration + docs (Commit 6)

**Spec sweep:**
- Search for any remaining output-spec constructions in specs (`grep -rn "satoshis:.*locking_script:" gem/bsv-wallet/spec/`); add `spendable_intent:` to each. Estimate ~30-50 remaining sites after Phases 4-5.
- Delete specs that exercise dropped constraints (`typed_no_*`, `derived_needs_*`, `validate_output_ownership!`).
- Update `sweepable_state_spec` for new query semantics.

**Integration spec:**
- `spec/integration/send_beef_spec.rb`: `pending` → real `expect`. Sender funds drop by exactly `sats + fee`.

**Docs sweep:**
- `docs/reference/schema.md`: outputs section rewrite — drop `output_type`, add `spendable_intent`, document the per-wallet literal CHECK, document the model-mirror validation, cross-reference `intent-and-outcomes.md`.
- `lib/bsv/wallet/interface/store.rb`: docstring updates (lines 77, 130).
- Engine YARD comments referencing `output_type`: scan and update.
- `docs/reference/action-lifecycle.md`: scan for `output_type` references, update.

**CHANGELOG entry** (`gem/bsv-wallet/CHANGELOG.md`, unreleased section):

```
### Schema (breaking, pre-release)

- Removed `outputs.output_type` column. Spendability intent now expressed by
  new `outputs.spendable_intent` ENUM ('spendable' | 'none'). See HLR #467.
- Per-wallet DB CHECK on outputs enforces structural recoverability — the
  WIF-derived root P2PKH script is baked into the constraint at migration
  time. Spendable outputs must either carry derivation controls or match
  the root P2PKH pattern literally.
- Operators with pre-existing test DBs must DROP and recreate them.
```

---

## Phase 7 — Verification + push + PR

**Verification suite (run from `gem/bsv-wallet`):**

```bash
# Unit specs against Postgres (primary target)
BSV_WALLET_POSTGRES=postgres://postgres:postgres@localhost:5433/ \
  bundle exec rspec spec/bsv spec/bin spec/support

# Unit specs against SQLite (augmentation)
bundle exec rspec spec/bsv spec/bin spec/support

# Integration specs (with WIFs)
BSV_WALLET_WIF_SDK=... BSV_WALLET_WIF_ALICE=... BSV_WALLET_WIF_BOB=... \
BSV_WALLET_POSTGRES=postgres://postgres:postgres@localhost:5433/ \
  bundle exec rspec spec/integration/beef_egress_validity_spec.rb spec/integration/send_beef_spec.rb

# Lint
bundle exec rubocop
```

All must pass. Zero pending. Zero offences.

**Push + PR:**

```bash
git push -u origin feat/467-intent-and-outcomes-schema-fix
gh pr create \
  --base feat/433-phase-5-cli-catchup-and-send-beef \
  --title "fix(schema): #467 — drop output_type, spendable_intent explicit, structural root CHECK" \
  --body "<comprehensive body>"
```

PR body covers: problem, principle, fix shape, test results, breaking-change operator note, references.

---

## Risks and mitigations

| Risk | Mitigation |
|---|---|
| Per-wallet literal in CHECK differs across Postgres/SQLite | Sequel's `Sequel.blob(...)` abstracts; verify in Phase 2 against both engines. |
| `Migration.identity_pubkey_hash` global feels fragile | Set inside `Store#migrate!` and reset in `ensure`. Single-threaded migration runner. Documented in the migration file's preamble. |
| Removing `change_output?` breaks something | Phase 4 grep for all callers; defensive-keep if found. |
| Spec fixtures balloon in scope | Search-and-replace mostly mechanical; `spendable_intent:` field uniform across most call sites (`:spendable` for wallet-owned, `:none` for outbound). |
| BRC-100 wrapper makes wrong default assumption | BRC-100 spec assumes self-owned outputs; defaulting to `'spendable'` is correct. Document in the wrapper. |
| Operators don't know to drop+recreate test DBs | CHANGELOG entry + PR description make this explicit. CI runs against fresh DBs. |
| The 8-permutation constraint encoding is wrong | Phase 2 constraint-level spec; Phase 3 model spec — both exercise all 8 directly. |

---

## Open items (flag during execution)

1. **`change_output?` deletion confidence** — verify no other callers before deleting (Phase 4).
2. **`prevent_outbound_spendable` trigger continued role** — rewrite in this PR; evaluate removal in follow-up issue.
3. Follow-up issue to file alongside #467 (not part of it): *Post-#467 defence-in-depth audit: evaluate removal of `prevent_outbound_spendable` trigger; resolve `change_output?` fate if it survives #467 as defensive code.*

## Estimate

~7 hours focused work + ~30 min slop. Roughly:
- 45 min: Phase 1 (docs)
- 90 min: Phase 2 (schema)
- 45 min: Phase 3 (model validate)
- 60 min: Phase 4 (engine + inference removal)
- 75 min: Phase 5 (decision-makers)
- 120 min: Phase 6 (spec sweep + integration + docs)
- 30 min: Phase 7 (verification + PR)
