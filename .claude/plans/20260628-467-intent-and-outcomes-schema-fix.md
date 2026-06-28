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

## Phase 1 — Foundational documentation

**Deliverables:**

1. **This plan file** — saved to `.claude/plans/20260628-467-intent-and-outcomes-schema-fix.md`.

2. **`docs/reference/intent-and-outcomes.md`** — load-bearing principle doc:
   - Statement: intent stated explicitly; outcomes persisted as rows; never reverse-engineer intent from outcomes.
   - Derive vs infer terminology: forward (rules → facts → derived view) good; backward (outcome → guessed intent) bad.
   - The atomicity argument: state machine of valid intermediate states; multiple atomic transitions.
   - The outcome-row-deletion catastrophe: derivation must survive on the immutable log (`outputs`, not `spendable`).
   - Living register of intent points: `broadcast_intent` (settled), `spendable_intent` (this HLR), shape for additions.
   - The enum convention: enums over booleans, even for two values (extensibility + symmetry).
   - Intent-placement rule: intent on the grain at which it varies (per-action → on actions; per-output → on outputs).
   - Per-wallet CHECK literal mechanism (mirrored from schema.md for discoverability).
   - Threat-model note (hash literal in schema is public; the wallet's root P2PKH address is public on chain).
   - WIF-rotation note (per-wallet CHECK literal tied to WIF for the wallet's lifetime; rotation = new wallet).
   - BRC-100 alignment note (the principle aligns with spec but isn't spec-mandated).
   - Cross-references: `principle-of-state.md`, `state-boundaries.md`, `core-vs-conformance.md`, `hot-path-design.md`; ADR-003, ADR-010, ADR-031.

3. **`docs/reference/hot-path-design.md`** (NEW) — declarative-beats-trigger principle:
   - Rule: no triggers on the hot path (output insert, spendable insert, broadcast row, etc.).
   - The composite FK + CHECK pattern as the canonical declarative shape (`broadcasts` is the worked example).
   - When triggers are appropriate (cold-path consistency checks; never per-row-on-write).
   - Cross-reference to `intent-and-outcomes.md` and ADR-019.

4. **`CLAUDE.md`** — one-line addition pointing fresh agents at `hot-path-design.md`. Caught by every spawned agent on every session.

5. **`.architecture/decisions/adrs/20260628_ADR-031-intent-and-outcomes.md`** — captures why we articulated the principle now:
   - Two examples that surfaced it (`broadcast_intent` settled correctly; spendable-controls inference surfaced by `send_beef_spec.rb`).
   - ADR-010's blindspot: banned the inference in code, encoded it structurally via `typed_no_*`.
   - HLR #467 as the first principle-driven schema fix; HLR #60 as the living audit register.
   - Pragmatic Enforcer block: this is naming what we have been doing wrong, not adding speculation.

6. **`.architecture/decisions/adrs/INDEX.md`** — add ADR-031 entry.

**Verification:** cross-references resolve; British prose, no emoji.

**Independent of code** — can run in parallel to Phase 2.

---

## Phase 2 — Schema rework + migration plumbing

**Deliverables:**

1. **`lib/bsv/wallet/migration.rb`** (new tiny module):
   ```ruby
   module BSV::Wallet::Migration
     class << self
       attr_accessor :identity_pubkey_hash
     end

     def self.expected_root_script
       raise 'identity_pubkey_hash not set — Store#migrate! must populate before any migration runs' unless identity_pubkey_hash
       BSV::Script::Script.p2pkh_lock(identity_pubkey_hash).to_binary
     end
   end
   ```
   The literal is built via `BSV::Script::Script.p2pkh_lock(...).to_binary` — single source of truth (SDK). Not hand-rolled `\x76\xa9\x14...\x88\xac`.

2. **`Store.new(identity_pubkey_hash:, ...)`** — accept the hash as a constructor parameter, store on instance. **`Store#migrate!`** populates `Migration.identity_pubkey_hash` from instance before invoking Sequel migrator, resets in `ensure`:
   ```ruby
   def initialize(url:, identity_pubkey_hash: nil, ...)
     @identity_pubkey_hash = identity_pubkey_hash
     # ...
   end

   def migrate!
     BSV::Wallet::Migration.identity_pubkey_hash = @identity_pubkey_hash
     # set Output model's class accessor too, for runtime validation
     models::Output.expected_root_script = BSV::Wallet::Migration.expected_root_script
     Sequel::Migrator.run(@db, MIGRATIONS_DIR)
   ensure
     BSV::Wallet::Migration.identity_pubkey_hash = nil
   end
   ```
   `cli.rb` boot ordering: construct `KeyDeriver` first; then `Store.new(identity_pubkey_hash: kd.identity_pubkey_hash, ...)`; then `store.migrate!`. Spec helper (`shared_context.rb`) constructs a deterministic test hash (e.g. `"\x00" * 20` or hash of a fixture WIF) and passes via `Store.new`.

3. **`KeyDeriver#identity_pubkey_hash`** — confirmed missing today; add as memoised reader on `KeyDeriver` (follows existing pattern of `identity_key` / `identity_key_bytes`). Returns 20-byte binary `hash160(identity_key_bytes)`. Refactor inline `hash160(identity_key_bytes)` callsites (`brc100.rb:470`, `engine.rb:728`) to use it — single source of truth.

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

   Add a unique index on `outputs(id, spendable_intent)` — needed as the composite FK target for the spendable denormalisation (below).

   In `create_table(:spendable)`:
   - Add `column :spendable_intent, c[:spendable_intent], null: false`
   - Add composite FK: `foreign_key %i[output_id spendable_intent], :outputs, key: %i[id spendable_intent]`
   - Add CHECK: `constraint(:spendable_intent_must_be_spendable, "spendable_intent = 'spendable'")`
   - This is the declarative replacement for the dropped `prevent_outbound_spendable` trigger. Mirrors the `broadcasts.intent` composite FK pattern.

   SQLite-only ENUM-equivalent CHECK:
   - Remove `output_type_values` constraint
   - Add `constraint(:spendable_intent_values, "spendable_intent IN ('spendable', 'none')") unless postgres`

   Preamble comment block on the `spendable_recoverable` constraint explaining: (a) the literal is the WIF-derived root P2PKH script populated by `Migration.identity_pubkey_hash`, (b) the literal is wallet-specific — cross-wallet schema dumps will differ, (c) the hash is public information (root P2PKH address).

5. **Amend `db/migrations/002_triggers.rb`:**
   - **Drop `prevent_outbound_spendable` trigger entirely.** The composite FK + CHECK on `spendable` (step 4 above) replaces it declaratively. **No trigger on the hot path.** This resolves the open follow-up item.

6. **`models::Output`** — drop the `:output_type` column reference; add `:spendable_intent`. Add class-level accessor `expected_root_script` (set by `Store#migrate!`). Verify existing scopes (`spendable`, etc.) are unaffected.

7. **`Store#verify_schema!`** — reads the `spendable_recoverable` CHECK definition from `pg_constraint` (or SQLite equivalent), asserts the literal matches the current `identity_pubkey_hash`. Called at boot. Catches schema drift, restore-to-wrong-DB, WIF mismatch. Raises `BSV::Wallet::SchemaIntegrityError` on mismatch.

**Constraint-level spec coverage:**
- 8-permutation table-driven matrix (Postgres + SQLite); each invalid row asserts the *expected* constraint name in the error
- Direct `INSERT INTO spendable` for an output whose `spendable_intent='none'` → composite-FK violation (proves the declarative replacement works without a trigger)
- Cross-backend constraint-name parity check
- `\d+ outputs` literal verification (psql)
- Migration round-trip determinism (dump → drop → re-migrate → diff → byte-identical)
- Wrong-wallet detection (migrate alice's DB; attempt bob-root-shape insert; rejected)
- `Store#verify_schema!` on a manually-corrupted CHECK literal raises cleanly

**Verification:**
- `bundle exec rspec spec/bsv` against Postgres against a fresh `bsv_wallet_test` DB — schema specs pass.
- `\d outputs` in psql shows the new column and the literal-bearing CHECK with the wallet's actual hash visible.

---

## Phase 3 — Sequel model validation (app-layer mirror)

**Deliverables:**

1. **`def validate`** on `models::Output` mirroring the DB CHECK logic. Reads expected script from the class accessor set by `Store#migrate!` (NOT from `Migration.identity_pubkey_hash` global, which is reset after migration). Flat conditional, not `case/in` (no codebase precedent for pattern matching; flat is searchable and matches every other validator):

   ```ruby
   class Output < Sequel::Model
     class << self
       attr_accessor :expected_root_script
     end

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
       root_match   = locking_script == self.class.expected_root_script
       controls_set = !derivation_prefix.nil?
       intent       = spendable_intent.to_s

       valid =
         (root_match  && !controls_set && intent == 'spendable') ||
         (!root_match && !controls_set && intent == 'none')      ||
         (!root_match && controls_set)
       return if valid

       errors.add(:spendable_intent,
                  "invalid combination (HLR #467 / intent-and-outcomes.md): " \
                  "root_match=#{root_match} controls=#{controls_set} intent=#{intent}")
     end
   end
   ```

2. **Store-boundary error translation** — wherever `models::Output.create` is called (Store insertion paths), rescue `Sequel::ValidationFailed` and raise `BSV::Wallet::InvalidParameterError` with the formatted error message. Single rescue covers the whole insertion path.

**Verification:**
- New spec `spec/bsv/wallet/store/models/output_spec.rb` exercising all 8 permutations against the model via `valid?` / `errors[:spendable_intent]` (no DB roundtrip required for the validation tests).
- Existing Store specs still pass (with `spendable_intent` added to their output specs in Phase 5).

---

## Phase 4 — Engine API + inference removal + Engine→BRC-100 inversion fix + identity_pubkey_hash accessor

**Deliverables:**

**Inference site removal:**

1. **`Engine::Action.canonical_outputs`** (`engine/action.rb:115-140`):
   - Drop `effective_type = out[:output_type] || (out[:derivation_prefix] ? nil : 'outbound')`.
   - Require `out[:spendable_intent]` — raise `InvalidParameterError` with message that references HLR #467 / `intent-and-outcomes.md` as context anchor.
   - Pass `spendable_intent: out[:spendable_intent]` through to the row hash.
   - Drop the `output_type: effective_type` field from the emitted hash.

2. **`Store#do_create_action_outputs`** (`store.rb:185-205`):
   - Replace `wallet_owned = out[:derivation_prefix] || out[:output_type] == 'root'`
   - With `wallet_owned = out[:spendable_intent].to_s == 'spendable'`.

3. **`Store#promote_action_outputs`** (`store.rb:216-235`):
   - Replace the inference with `output.spendable_intent.to_s == 'spendable'`.
   - Drop the `change_output?` fallback (covered by stated intent).
   - **Delete `change_output?` method entirely** (confirmed dead after this commit — single caller is the one being removed). No follow-up.

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

**Engine→BRC-100 inversion fix (pre-existing architectural defect — violates ADR-026 / ADR-027):**

8. **`Engine#send_payment`** (`engine.rb:1042`): reshape to call `engine.build_action` directly with engine-vocab output spec (drop the `brc100.create_action(...)` detour). The wallet-vocab method no longer reaches outward into the conformance wrapper.

9. **`Engine#sweep`**: same — call `engine.build_action` directly.

10. **`Engine#consolidate_step`**: same.

**`KeyDeriver#identity_pubkey_hash` accessor (and its consumers):**

11. **`KeyDeriver#identity_pubkey_hash`** — confirmed missing today. Add as memoised reader on `KeyDeriver` (binary, 20 bytes, `hash160(identity_key_bytes)`). Follows the existing pattern of `identity_key` (hex) and `identity_key_bytes` (binary).

12. **Refactor inline `hash160(identity_key_bytes)` callsites** to use the new accessor:
    - `brc100.rb:470` (inside `validate_output_ownership!` which is being deleted — moot)
    - `engine.rb:728` (the wallet's own-root-hash derivation)
    - Grep for any other inline `hash160(...)` of the wallet's own identity key and migrate

**YARD updates in this commit (not deferred to Phase 6):**

13. **`lib/bsv/wallet/interface/store.rb`** (lines 77, 130): drop `:output_type` from output-spec docstrings; add `:spendable_intent` (required); link to `intent-and-outcomes.md`.
14. **Engine YARD comments referencing `output_type`** — scan changed classes, update in same commit.

**Spec coverage:**

- "No-inference-remaining" canary spec — grep-equivalent at test level; fails loudly if a 6th inference site sneaks in
- `Engine#send_payment` end-to-end integration spec confirming outbound output gets `spendable_intent: 'none'`
- `KeyDeriver#identity_pubkey_hash` unit spec (round-trip, memoisation, 20-byte assertion)

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
- `createAction` outputs spec — translate from BRC-100 vocab to engine vocab with default `spendable_intent: 'spendable'` (BRC-100 spec assumes self-owned outputs).
- Accept explicit `spendable: Int8` from BRC-100 spec input if present, translate: `false → 'none'`, `true|absent → 'spendable'`.
- Document this in the wrapper YARD.

**Unit-spec updates included in this commit** for each touched class.

---

## Phase 6 — Spec sweep + integration + docs (Commit 6)

**Spec sweep:**
- Search for any remaining output-spec constructions in specs (`grep -rn "satoshis:.*locking_script:" gem/bsv-wallet/spec/`); add `spendable_intent:` to each. Estimate ~30-50 remaining sites after Phases 4-5.
- Delete specs that exercise dropped constraints (`typed_no_*`, `derived_needs_*`, `validate_output_ownership!`).
- Update `sweepable_state_spec` for new query semantics.

**Integration spec:**
- `spec/integration/send_beef_spec.rb`: `pending` → real `expect`. Sender funds drop by exactly `sats + fee` (tightened from `<=` to `==` or `be_within(fee_tolerance).of` — catches both over- and under-debiting regressions).
- Table-driven 8-permutation matrix spec (one data table, drivers for DB CHECK + model validate + engine surface). Eliminates 3-way drift risk.
- `Store#verify_schema!` integration spec (schema-drift assertion).
- `Migration.identity_pubkey_hash` lifecycle spec (set during migrate, nil after `ensure` runs in both success and failure paths).
- Cross-wallet contamination spec (boot wallet A in process, then wallet B; legitimate root output on B succeeds — confirms per-instance threading).
- Hot-path microbenchmark for `spendable_recoverable` CHECK (confirm constant-folded; no measurable insert-time regression).

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
| `Migration.identity_pubkey_hash` global pattern | Per-instance threading via `Store.new(identity_pubkey_hash:)` and class accessor `Output.expected_root_script` (set at boot). Global is only used at migration-emit time, reset in `ensure`. Cross-wallet contamination spec validates the threading. |
| Cross-wallet schema dump divergence | Each wallet's `pg_dump` shows its own hash literal in the CHECK. Documented in `docs/reference/schema.md` and `intent-and-outcomes.md` as by-design per ADR-028 (multi-user). |
| Schema drift / restore-to-wrong-DB | `Store#verify_schema!` at boot reads the CHECK literal, asserts it matches the current `identity_pubkey_hash`, raises on mismatch. |
| Spec fixtures balloon in scope | Table-driven matrix for the 8 permutations; mechanical `spendable_intent:` addition for other fixtures (uniform across most call sites). |
| BRC-100 wrapper default assumption | Inversion fix removes Engine→BRC-100 detour for `send_payment`/`sweep`/`consolidate_step`; wrapper default `'spendable'` only fires for genuine BRC-100 callers (spec-self-owned). |
| Operators don't know to drop+recreate test DBs | CHANGELOG entry + PR description make this explicit. CI runs against fresh DBs. |
| The 8-permutation constraint encoding is wrong | Phase 2 constraint-level spec; Phase 3 model spec — both exercise all 8 directly via the same data table. |
| `controls_all_or_nothing` redundancy with `spendable_recoverable` | Kept separately for distinct error messages (controls partial vs root-shape inconsistent). Trivial cost; real diagnostic value. |

---

## Resolved during this PR (no follow-ups)

- ✅ Trigger removal — `prevent_outbound_spendable` dropped entirely in Phase 2; declarative composite FK + CHECK replaces it.
- ✅ `change_output?` deletion — confirmed dead, deleted in Phase 4.
- ✅ BRC-100 wrapper default leak — addressed by the Engine→BRC-100 inversion fix (Phase 4).
- ✅ `KeyDeriver#identity_pubkey_hash` accessor — added in Phase 4.

## Estimate

~7 hours focused work + ~30 min slop. Roughly:
- 45 min: Phase 1 (docs)
- 90 min: Phase 2 (schema)
- 45 min: Phase 3 (model validate)
- 60 min: Phase 4 (engine + inference removal)
- 75 min: Phase 5 (decision-makers)
- 120 min: Phase 6 (spec sweep + integration + docs)
- 30 min: Phase 7 (verification + PR)
