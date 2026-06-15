# ADR-020: Test taxonomy — engine-intent vs store-invariant

## Status

Draft — the taxonomy is decided; the test-suite split it prescribes (HLR #64) is not yet complete.

**Decided:** 2026-05-05 (HLR #64, "Testing strategy — separate engine intent tests from store data-invariant tests") — dated to when the taxonomy was decided, i.e. when #64 was raised, not to the later write-up. The test-suite reorganisation it prescribes (#64) is still open, hence Draft.

## Context

The schema is the canonical source of truth (ADR-003): invalid state is structurally impossible because the schema's constraints reject it. That principle splits the wallet's testable surface in two. One half is *behaviour* — given a request, does the wallet decide and orchestrate correctly? The other half is *enforcement* — given an attempt to write bad data, does the schema actually reject it? These are different assertions about different layers, and a test suite that conflates them tests neither cleanly.

The conflation is concrete, not hypothetical. The original `engine_spec.rb` grew to thousands of lines mixing both kinds: it reached into the store to verify row states *and* constructed raw database fixtures to drive engine behaviour, while living in the unit tree yet requiring PostgreSQL (HLR #64). Two further forces sharpen the boundary now. First, the database posture has settled: Postgres is the production target and SQLite is a convenience for fast logic-only specs (CLAUDE.md, "Database & Wallet Configuration"; ADR-009). A test that asserts a CHECK violation only means something on the backend that *has* the CHECK. Second, the store is becoming a pluggable abstraction (ADR-012), so "does the schema reject this?" is a question that must be pinned to a specific backend, not assumed to hold everywhere.

## Decision Drivers

* The two assertion kinds — *the wallet decides correctly* vs *the schema rejects invalid state* — exercise different layers and belong in different files (HLR #64).
* Postgres is primary; SQLite is augmentation. Postgres-specific enforcement (CHECK, ENUM, RESTRICT FK, the `prevent_outbound_spendable` trigger) must have a spec that runs against Postgres, because SQLite carries those rules only by translation and would not surface a regression (ADR-009; CLAUDE.md, "Conventions").
* Store-invariant tests are how ADR-003 is *checked*, not merely asserted in prose — they prove the constraints are load-bearing.

## Decision

Split tests by **what they assert**:

* **Engine-intent tests** verify orchestration and behaviour — that the wallet decides correctly. "I asked to send 500 sats; did I get back a valid action with the right shape?" They live under `spec/bsv/wallet/engine/` and exercise the public `Engine` surface (`action_spec.rb`, `broadcast_spec.rb`, `consolidation_spec.rb`, and the rest). They use synthetic funding fixtures (`fund_wallet`) and placeholder scripts, because the assertion is about the *decision*, not the bytes.
* **Store-invariant tests** verify that the schema rejects invalid state — they are negative tests against the constraints themselves. Every CHECK, NOT NULL, UNIQUE, RESTRICT FK, ENUM rejection, and trigger from the migrations is exercised in `spec/bsv/wallet/store/constraints_spec.rb`, with the model and persistence layers covered alongside it under `spec/bsv/wallet/store/`. These assert ADR-003 holds.

Concretely:

* **Store-invariant tests are tagged `:postgres` and skip on SQLite.** `constraints_spec.rb` is `RSpec.describe 'Schema constraints', :postgres, :store`; the store shared context skips `:postgres`-tagged examples unless the backend is Postgres. The header records why: SQLite's `ALTER TABLE` cannot reliably add CHECK constraints, so on SQLite these rules are enforced at the application layer and the *database* enforces them only on Postgres. The negative test therefore only has meaning against Postgres.
* **The `prevent_outbound_spendable` trigger is a store-invariant test, not application logic.** An attempt to insert a `spendable` row for an `outbound` output is rejected by the database (`/spendable row forbidden for outbound output/`), and that rejection is what the test asserts.
* **Backend selection is by `BSV_WALLET_POSTGRES`, deliberately independent of `DATABASE_URL`.** Set → Postgres at `<base>/bsv_wallet_test`; unset → in-memory SQLite. The helper ignores `DATABASE_URL` so an operator's working database never silently hijacks the spec run (CLAUDE.md, "Conventions").
* **Both backends run in CI, in one matrix job.** The `test` job (Ruby 3.3 / 3.4 / 4.0) runs `bundle exec rspec` twice: once for SQLite, once with `BSV_WALLET_POSTGRES` set. Unit specs run on both; the `:postgres`-tagged store-invariant specs are exercised on the Postgres pass.
* **Integration and e2e are excluded from the unit run.** `.rspec` carries `--exclude-pattern "spec/{e2e,integration}/**/*_spec.rb"`, so a bare run is unit-only. Integration specs (`spec/integration/`) run in a separate Postgres-only CI job with per-wallet databases; e2e is the on-chain workload.
* **Aspirational: mock locking scripts (OP_1 / OP_TRUE) so engine-intent tests assert decisions, not bytes.** Engine specs already use sentinel scripts in places (`porcelain_spec.rb` uses `OP_1 OP_2 OP_3` as a distinctive sentinel; BEEF-verification specs use OP_1 ancestors). The stated intent is to make this systematic — a script mock that keeps intent tests off real-key cryptography — but it is not yet uniformly applied across the engine tree.

**Commands run from the gem directory.** Every `bundle` / `rspec` / `rubocop` invocation is from `gem/bsv-wallet/`, not the repo root; spec paths like `spec/bsv` only resolve there, and the repo root carries a different Gemfile (CLAUDE.md, "Running Specs").

This taxonomy is orthogonal to the unit/integration/e2e layering, not a replacement for it. A store-invariant test is a unit test that happens to require Postgres; an engine-intent test is a unit test of orchestration. The layering says *how much of the system* a spec boots; the taxonomy says *what kind of claim* it makes.

## Alternatives Considered

### A. One blended suite (the original `engine_spec.rb`)
Test behaviour and data invariants together, reaching into the store from engine specs.
**Pros:** fewer files; a single place to look for "what does this operation do?".
**Cons:** the file that requires Postgres but lives in the unit tree; intent assertions tangled with row-state assertions; the precise failure HLR #64 was raised to fix.
**Rejected** — the two assertion kinds exercise different layers and must be separable to be legible.

### B. SQLite as the default test backend, Postgres as the augmentation
Run the suite on SQLite by default and add Postgres coverage on top (the earlier posture; HLR #123, *Run engine specs against SQLite*).
**Pros:** no database service needed for the common case; fastest local loop.
**Cons:** Postgres-specific enforcement (CHECK, ENUM, RESTRICT, the trigger) regresses silently, because SQLite carries those rules only by translation and a SQLite-default run never asserts them on the engine that actually has them.
**Rejected — superseded.** The posture was flipped to Postgres-primary / SQLite-augmentation (HLR #228, *Flip integration specs to Postgres-default*; recorded in CLAUDE.md). SQLite remains a convenience for logic-only specs, not the default arbiter of correctness.

### C. Run store-invariant tests on SQLite too (drop the `:postgres` tag)
Assert the constraints against both backends.
**Pros:** uniform expectations across backends.
**Cons:** SQLite cannot reliably express the constraints under test (`ALTER TABLE` + CHECK); the tests would fail or assert a translated approximation, telling us nothing about the production constraint.
**Rejected** — a negative test for a constraint only means something on the backend that has it; the `:postgres` skip is correct.

## Consequences

### Positive

* Each spec makes one kind of claim, against the layer that owns it: engine-intent against orchestration, store-invariant against the schema. ADR-003 is *checked*, not just stated.
* Postgres-specific enforcement cannot silently regress — it has a spec that runs against Postgres in CI.
* Engine-intent tests stay fast and backend-agnostic; they assert decisions, freeing them from real-key cryptography where the script mock applies.
* The SQLite convenience survives without becoming a correctness blind spot: the matrix runs both, and the `:postgres` skip marks exactly what SQLite can't carry.

### Negative

* **Store-invariant tests don't run on the SQLite pass** — by design (they skip), so the fast local loop does not exercise constraint rejection. Accepted: those constraints are a Postgres concern, and CI's Postgres pass covers them.
* **Two backends in CI** roughly double the matrix's spec time. Accepted as the cost of proving SQLite still works without trusting it for enforcement.
* **The OP_1 / OP_TRUE script-mock intent is partial.** Engine specs use sentinel scripts in places but not uniformly; until it is systematic, some intent tests carry more cryptographic machinery than the taxonomy wants.
* **The unit/integration boundary in the engine tree is still imperfect.** Engine-intent specs hit PostgreSQL via synthetic `fund_wallet` rows — neither pure unit nor full integration. The split into `engine/` and `store/` is the structural step; a cleaner store/engine separation (HLR #64's open question) would let intent tests run without a store at all.

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

This taxonomy is a response to an observed failure (a multi-thousand-line spec conflating two assertion kinds, in the unit tree yet needing Postgres), not a speculative structure. The split is descriptive — it names what the specs already are and puts them in the right files — and it makes ADR-003 falsifiable by giving the constraints a negative-test home. The Postgres-primary posture is the correct, already-settled call; the `:postgres` skip is the minimum mechanism that keeps the SQLite convenience honest. The one piece of forward-looking ambition, the script mock, is flagged as aspirational rather than asserted as done. **Approve.**

## Validation

* `spec/bsv/wallet/store/constraints_spec.rb` is `RSpec.describe 'Schema constraints', :postgres, :store`; the store shared context skips `:postgres` examples unless `STORE_DATABASE_TYPE == :postgres`.
* The `prevent_outbound_spendable` rule is exercised as a store-invariant test (insert of a `spendable` row for an `outbound` output is rejected by the database).
* Engine-intent specs live under `spec/bsv/wallet/engine/`, exercise the public `Engine` surface, and use synthetic `fund_wallet` fixtures.
* Backend selection branches on `BSV_WALLET_POSTGRES` and ignores `DATABASE_URL` (store shared context; CLAUDE.md).
* CI's `test` job runs `bundle exec rspec` for both SQLite and Postgres across Ruby 3.3 / 3.4 / 4.0; `.rspec` excludes `spec/{e2e,integration}`; integration runs in a separate Postgres-only job.

## References

* ADR-003 — schema as canonical state; store-invariant tests are how this principle is checked.
* ADR-006 — single relational store; the one ACID boundary these tests run against.
* ADR-009 — Postgres-native primitives; the strongest tie — Postgres-specific behaviour is tested against Postgres, not assumed from SQLite.
* ADR-012 — store abstraction; the backend boundary the taxonomy tests across.
* HLR #64 (open) — separate engine-intent tests from store-invariant tests (the originating force).
* HLR #228 (closed) — flip to Postgres-default / SQLite-augmentation. HLR #123 (closed, superseded) — the earlier SQLite-default posture.
* CLAUDE.md — "Running Specs", "Database & Wallet Configuration", "Conventions".
