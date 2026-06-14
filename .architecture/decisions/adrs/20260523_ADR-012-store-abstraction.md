# ADR-012: Store abstraction over a relational floor

## Status

Accepted.

**Decided:** 2026-05-23 (commit `c17f5da`, PR #142 — "consolidate Postgres store into main wallet gem (#134)"; HLR #134) — the two-gem split (SQLite store + `bsv-wallet-postgres`) was collapsed into one store with a `database_type` branch and per-backend adapters, the abstraction this ADR records. The `Store#connect` factory landed earlier at PR #116 (`10d238f`, 2026-05-16).

## Context

The wallet persists everything behind one relational store, one ACID boundary (ADR-006), and that store leans on Postgres-native primitives — `bytea`, ENUM, CHECK, partial indexes, `INSERT … ON CONFLICT`, partitioning, triggers (ADR-009). PostgreSQL is the production target. But the unit suite needs a backend that boots in-process, with no server to provision, so logic-only specs run fast and a fresh checkout has something to run against before anyone installs Postgres.

The question this ADR answers is the shape of that abstraction: what backs the store when Postgres is not configured, how a backend is selected, and how the SDK-level control the schema needs survives behind the abstraction. The boundary in ADR-006 — *one* ACID boundary — settles that there is a single store instance; it does not settle *which* relational engine backs it.

The wallet once carried two gems for this: a SQLite store and a separate `bsv-wallet-postgres`. An audit found the Postgres gem differed from the SQLite one in only three substantive places — input-lock result interpretation, `competing_txs` array coercion, and connection setup — with every model, every Store method, and every collaborator identical logic in a parallel namespace.

## Decision Drivers

* The store needs a relational floor — foreign keys and transactions — not a file or key-value store; ADR-006 already excludes non-relational backends.
* The unit suite needs an in-process backend with no server dependency, and a fresh checkout needs a default that works before Postgres is installed.
* The schema's integrity guarantees are Postgres-native (ADR-009); the abstraction must not flatten them to a portable subset.
* Two near-identical store gems are duplication, not separation — the divergence is three small points, not two implementations.

## Decision

**Abstract persistence behind a single relational `Store`, with a relational floor as the default backend and PostgreSQL as the production target / opt-in override.**

* **`BSV::Wallet::Store` is an abstract base; `Store::SQLite` and `Store::Postgres` are thin adapters.** Nearly all behaviour — every Sequel model, every lifecycle and query method, the transaction boundaries — lives on the base. The adapters carry only what genuinely differs: `configure_db` (SQLite sets `journal_mode`/`foreign_keys` PRAGMAs; Postgres loads the `pg_enum`, `pg_array`, `pg_json` extensions) and `try_lock_input` (SQLite re-queries because `INSERT … ON CONFLICT` returns a rowid even on `DO NOTHING`; Postgres trusts the nil-on-`DO NOTHING` return). A single `@db.database_type == :postgres` branch in the base handles the third difference, `competing_txs` coercion (`Sequel.pg_array` vs `JSON.generate`).

* **The backend is selected by URL scheme.** `Store.connect(url)` returns a `Postgres` instance when the URL begins `postgres`, otherwise `SQLite`. The configured database URL therefore picks the engine: `DATABASE_URL` (end-user mode) or a per-wallet URL derived from `BSV_WALLET_POSTGRES` (dev/test mode) selects Postgres; with neither set, `CLI.boot` falls back to a SQLite file at `~/.bsv-wallet/<name>.db`.

* **The relational floor is bundled; Postgres is opt-in by gem presence.** `sqlite3` is a hard gem dependency, so the floor is always available — a fresh install runs. `pg` is *not* a runtime dependency; `Store::Postgres` requires it lazily and, on `LoadError`, raises a directive to add `gem 'pg'` to the Gemfile. The operator opts into Postgres by installing the driver and pointing the URL at it.

* **Models bind per store instance, not by leaning on the process-global `Sequel::Model.db`.** `Store#initialize` does set `Sequel::Model.db` — but only so model class bodies can resolve *a* connection during autoload-time schema introspection (Sequel reads column metadata when a model class is first evaluated). The store the wallet actually queries through is established by `bind_models!`, run after `migrate!`, which rebinds every model's dataset to that instance's `@db` (`klass.dataset = @db[klass.table_name]`). The global is an autoload bootstrap, not the query path. Each bin/ tool and the daemon run one wallet per OS process, so this is sufficient; nothing relies on two live stores sharing `Sequel::Model.db` within one process.

* **The store layer uses Sequel, not ActiveRecord.** The wallet wants direct SQL control — high-throughput UTXO selection, precise queries, a schema designed from relational first principles — where ActiveRecord's conventions would fight the schema rather than serve it. The ORM stays thin: Sequel datasets express the queries, they do not hide them.

* **One gem, not two.** The separate `bsv-wallet-postgres` gem is consolidated into the core; the base-plus-two-adapters form above *is* that consolidation. There is no longer a parallel namespace to keep in step.

The abstraction is a relational floor with a production override — not a portability layer. SQLite carries the Postgres-native features by translation (ENUM → CHECK, and so on) and is a logic-only convenience, never the production target. It does not flatten the schema to a portable subset (ADR-009); the testing posture that keeps Postgres-specific behaviour honest — Postgres-primary, SQLite-augmentation — is ADR-020's concern, not this one.

## Alternatives Considered

### A. One backend only — Postgres everywhere, no SQLite

**Pros:** a single code path; no translation layer; the production engine is the only engine, so nothing can pass on SQLite and regress on Postgres.
**Cons:** every unit-spec run, and every fresh checkout, needs a Postgres server provisioned before anything boots; the fast logic-only suite loses its in-process backend.
**Rejected** — the in-process floor is worth the thin adapter split; the regression risk it introduces is bounded by testing posture (ADR-020), not by dropping the floor.

### B. Make the store backend-agnostic by writing to a portable SQL subset

**Pros:** one schema, no per-backend branches, trivially swappable engine.
**Cons:** forgoes the Postgres-native features the integrity guarantees rest on — exactly ADR-009's rejected path. The abstraction would buy portability the product does not need at the cost of the structural guarantees it does.
**Rejected** — abstract behind a thin adapter, not by levelling down the schema.

### C. Keep two store gems (`bsv-wallet` + `bsv-wallet-postgres`)

**Pros:** each gem self-contained; Postgres users need not carry SQLite, and the reverse.
**Cons:** the two diverge in three small places and are otherwise identical — every model and Store method duplicated across namespaces, kept in step by hand. Duplication, not separation.
**Rejected** — consolidate to base-plus-adapters; the differences are override points, not a second implementation.

### D. A non-relational backend for some tables (per ADR-006's split temptation)

**Rejected in ADR-006.** A foreign key cannot span stores and an atomic transition cannot straddle them; the floor must be relational. Recorded here only to mark that "which engine" is downstream of "must be relational", already settled.

## Consequences

### Positive

* A fresh checkout runs unit specs immediately on the bundled SQLite floor, with no server to provision; Postgres is one URL and one `gem 'pg'` away.
* One store, one ACID boundary (ADR-006), backed by either engine without changing the call sites — adapters absorb the difference.
* The Postgres-native schema is intact behind the abstraction; SQLite translates, it does not flatten (ADR-009).
* One gem, not two — no parallel namespace to keep synchronised.

### Negative

* SQLite is a translated convenience that must keep pace with the Postgres-native constraints; behaviour that only Postgres enforces (CHECK violations, ENUM rejection, RESTRICT FK semantics, the outbound trigger) can pass on SQLite and regress unless verified against Postgres — the test-posture obligation discharged by ADR-020.
* The adapter split is a small standing cost: three difference points (`configure_db`, `try_lock_input`, the `competing_txs` branch) that any new backend-sensitive behaviour must consciously place on the base or in an adapter.

### Watch-items

* **New backend divergence belongs at the existing seams.** If a fourth Postgres/SQLite difference appears, it goes in `configure_db`, `try_lock_input`, or a `database_type` branch — not a widening adapter. A growing adapter is the signal the abstraction is leaking.
* **The process-global `Sequel::Model.db` stays an autoload bootstrap.** `bind_models!` is the query-path binding; relying on the global for the live store, or running two stores in one process, breaks the "one wallet per process" assumption that makes the global safe.
* **`pg` stays out of the gemspec.** Promoting it to a runtime dependency would force the driver on every install and erode the "SQLite floor, Postgres opt-in" shape.

## Pragmatic Enforcer Analysis

**Reviewer:** Pragmatic Enforcer. **Mode:** Balanced.

The abstraction is thin and earns its place: a single base class with two small adapters, selected by URL, is the minimum that gives an in-process unit-spec floor without forfeiting the production engine's native features. Consolidating the two gems removes duplication rather than adding a layer — the difference was three points, not two implementations, so the parallel namespace was pure overhead. The one real risk — SQLite silently diverging from Postgres-enforced behaviour — is not denied but pushed to where it can be caught (ADR-020's posture), which is the correct division. No speculative pluggability: there is no third backend on the horizon and the seams are sized for the two that exist. **Approve.**

## Validation

* `Store.connect` returns `Store::Postgres` for a `postgres` URL and `Store::SQLite` otherwise.
* `Store::SQLite` and `Store::Postgres` override only `configure_db` and `try_lock_input`; all lifecycle/query methods live on the base.
* `sqlite3` is a runtime dependency; `pg` is not — `Store::Postgres` raises an add-`gem 'pg'` directive on a missing driver.
* `bind_models!` rebinds every model's dataset to the store instance's `@db` after `migrate!`.
* There is one gem (`gem/bsv-wallet`); no separate `bsv-wallet-postgres`.

## References

* ADR-006 — one relational store, one ACID boundary (one store *instance*; this ADR is which engine backs it).
* ADR-009 — Postgres-native primitives (the abstraction must not flatten them; SQLite translates).
* ADR-003 — the Store owns atomicity; every multi-write method here wraps `@db.transaction`.
* ADR-020 — test taxonomy (the Postgres-primary / SQLite-augmentation posture that keeps the translated floor honest).
* `gem/bsv-wallet/lib/bsv/wallet/store.rb` — `connect` factory, `bind_models!`, the `database_type` branch.
* `gem/bsv-wallet/lib/bsv/wallet/store/sqlite.rb`, `store/postgres.rb` — the two adapters.
* `gem/bsv-wallet/lib/bsv/wallet/cli.rb` — `boot`, `default_sqlite_url`, the one-wallet-per-process note.
* HLR #116, #117, #119, #120, #134 — store-abstraction and gem-consolidation work.
