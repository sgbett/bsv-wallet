# ADR-028: Per-user databases as the multi-user isolation primitive

## Status

Accepted (forward direction). The single-user posture is in force today (ADR-007); this ADR commits to the multi-user shape we will adopt *when and if* multi-user support is added, so that no design decision taken between now and then forecloses it.

**Decided:** 2026-06-24 — the multi-user direction was sketched in the 2026-06-24 design conversation that prompted ADR-027. ADR-007 (2026-05-05) already established the current single-user shape; this ADR is its forward complement.

## Context

ADR-007 dropped the reference implementation's `users` table and `user_id` columns on the grounds that the wallet is a single-tenant engine. That decision committed in the negative: "the schema does not carry tenancy". It left positive in the open: "if we ever do support multiple users, *how* will we?"

The wallet-toolbox reference uses **per-row tenancy**: one database, many users, every data row carries `userId`, every query filters by it. The deployment is "cloud wallet service holds N users' data side by side". This shape works correctly when implemented carefully and works terribly when the careful implementation slips: a bug in a query author's WHERE clause leaks across tenants, and the leak is structurally unprovable to be absent.

Two more facts shape the alternative we want:

1. **The wallet targets the throughput scaling vision (ADR-002).** Per-row tenancy is a tax on every index, every constraint, every WHERE clause, every lock. The reference implementation's approach is incompatible with the throughput target even when it works.
2. **The core-vs-conformance principle (ADR-027)** treats multi-user support as an overlay above the wallet, not as a concern that should reshape the core. The wallet's data tables should look the same in single-user and multi-user deployments; what differs is what sits above them.

A trigger to record the forward direction *now* — even though no demand-pull exists for the work — is that any incremental schema decision we take in the meantime can either preserve or foreclose this path. Naming the path means new schema work can stay aligned without re-deriving it.

## Decision Drivers

* **Structural isolation beats discipline.** A bug that omits a `WHERE userId = ?` cannot leak across tenants when there is no cross-tenant data in the database the connection is attached to. This is enforced by structure, not by code review.
* **The core stays unchanged between single-user and multi-user.** Whatever the per-user database looks like today is what it looks like in multi-user mode. No schema migration on the per-user side. No application-code branch for tenancy. The Engine and Store are tenancy-naive at all times.
* **Throughput stays preserved per user.** Each user's database sees one user's load; the central database holds only what cannot survive being split (and the design pressure is to keep that to a minimum).
* **Postgres credential separation becomes available** as defence-in-depth above the structural isolation. Each per-user database can grant connection credentials only to that user's role, so a credential leak (or a privilege misconfiguration in `walletd`) cannot cross databases.
* **Cross-database queries are forbidden by structure.** Postgres cannot transparently `JOIN` across databases at the same instance; cross-DB operations must be application-orchestrated. This forces every centralised concern to justify its centralisation against an explicit composition cost, which keeps central minimal.

## Decision

**When multi-user support is added, it takes the form of one central database (`bsv_wallet`) plus one per-user database (`bsv_wallet_<name>`) per registered user. The central database holds the minimum state that cannot survive being split — by default, only the `users` table. Each per-user database is structurally identical to today's single-user database.**

The shape:

```
Postgres instance
├── bsv_wallet                       ← central (multi-user mode only)
│   └── users(user_id, identity_key, name, created_at, ...)
├── bsv_wallet_alice                 ← per-user (one database per registered user)
│   ├── actions, outputs, spendable, ...   ← identical to today's schema
│   └── (no users/origin/permission columns)
├── bsv_wallet_bob
│   └── ... (identical shape to alice's DB)
└── bsv_wallet_carol
    └── ...
```

The decision has five parts:

1. **Central schema is `bsv_wallet`; per-user schemas are `bsv_wallet_<name>`.** This extends the existing naming convention. Single-user deployments today use `bsv_wallet_<name>` directly; multi-user adds the central `bsv_wallet` alongside, without disturbing existing per-user databases.

2. **Central holds `users` only, by default.** Every table proposed for the central database must justify its centralisation against a specific operational case that cannot be served by querying per-user databases. The default rejection is the load-bearing constraint, not the default acceptance. The two example operations sketched during the 2026-06-24 conversation (aggregate balances, identity-key lookup) both survive cross-DB decomposition without needing additional centralised state.

3. **Per-user databases stay tenancy-naive.** No `user_id` column, no `originator` column, no permission overlay. ADR-007 holds; ADR-027 holds. A per-user database has no idea it is one of many. This means the wallet code that runs against a single-user database is bitwise the same wallet code that runs against a per-user database in multi-user mode.

4. **Cross-database operations are application-orchestrated, never transparent.** An "aggregate balances across users" report is one query against `bsv_wallet.users` followed by N queries against `bsv_wallet_<name>.outputs` reassembled in Ruby. This is acceptable because aggregate operations do not need high throughput per call; high-throughput operations stay within one per-user database by construction.

5. **Per-user Postgres credentials are a separable layer of defence in depth.** A future evolution gives each per-user database its own role/password (or other auth), enforced at the conformance/RPC layer when `walletd` services a multi-user request. This is not blocked by this ADR and not required for initial multi-user support; it is the defensive depth available above the structural isolation.

The migration story:

- **Adding multi-user to an existing single-user deployment:** create `bsv_wallet`, populate `users` with a row for the existing wallet's identity key, leave the existing `bsv_wallet_<name>` database untouched. No per-user-DB migration.
- **Adding a new user:** insert into `bsv_wallet.users`, create `bsv_wallet_<name>` with the same schema migrations the existing per-user DBs ran.
- **Removing a user:** delete from `bsv_wallet.users`, drop `bsv_wallet_<name>` (or archive it as a whole-DB unit). No per-user-row deletion across multiple shared tables.

The shape this ADR commits to is enabling, not blocking. Until multi-user is built, no code is added; until it is built, the constraint is "no design decision taken between now and then forecloses this shape".

## Alternatives Considered

### A. Per-row tenancy in a single shared database (the reference implementation's shape)

`userId` column on every data table, every query filters by it.

**Rejected.** The structural-isolation argument is the dispositive one: a bug that omits the WHERE filter leaks across tenants, and there is no structural defence. The reference implementation accepts this risk because it serves a hosted-cloud-wallet product where audit and code review carry it; we have neither the product shape nor the audit budget. Add the throughput tax (every index, every WHERE, every lock pays the tenancy cost) and the case for this shape collapses entirely.

### B. Per-row tenancy with Postgres Row-Level Security

Same as A but enforce the per-user filter via Postgres RLS policies.

**Rejected.** RLS reduces the "developer forgot the WHERE clause" failure mode but does not eliminate the throughput tax. The RLS predicate is still applied per query, the tenancy column is still in every index, and the additional planning overhead is non-trivial. We also still maintain a single point of catastrophic failure: misconfigured RLS or a superuser-equivalent connection bypasses the policy entirely.

### C. Per-schema isolation within one database (Postgres schemas, not databases)

One database, N schemas, one schema per user.

**Rejected.** Postgres schemas inside one database share the catalog, share the role permissions surface, share the connection pool. They reduce *some* of the bug-leakage risk (a schema-qualified query against the wrong schema would fail) but they do not give us the credential-separation defensive depth that per-database isolation does, and they do not give us the "drop the user means drop the database" operational cleanness. The marginal complexity benefit (one less Postgres instance command to provision a user) is small versus the loss of independent operational handling.

### D. Continue deferring the multi-user direction

Take no position on shape until demand arrives.

**Rejected.** Continued deferral is correct on the *implementation* axis (no code is added by this ADR), but is wrong on the *commitment* axis — incremental schema decisions made in the meantime can foreclose options. Naming the direction now costs nothing in implementation and prevents the case where a future incremental decision (a new column, a new table) lands in a shape that is awkward to subsequently partition.

## Consequences

### Positive

* **Structural isolation between users.** Cross-tenant leakage is structurally impossible: there is no other tenant's data in the database a given operation can reach. This is a strictly stronger guarantee than disciplined per-row filtering.
* **The single-user shape stays the multi-user shape.** No code branch, no schema migration, no tenancy-awareness in the Engine or Store. The wallet that runs in single-user mode is bitwise the same wallet that runs in multi-user mode; what differs is what sits above it.
* **Per-user throughput is preserved.** Each user's hot path queries hit a database the size of one user's data. The throughput vision (ADR-002) survives multi-user adoption.
* **Defensive depth available via per-user credentials.** Whether or not we deploy it initially, the option exists structurally — per-database credential separation is something Postgres natively supports, and we can add it as an overlay without reshaping the data model.
* **Operational simplicity.** Adding a user is creating a database; removing a user is dropping a database. Both are atomic Postgres operations with no row-level archeology.
* **The core stays the core (ADR-027).** Multi-user support is an overlay above the wallet; it does not reshape the wallet.

### Negative

* **Cross-DB operations cost a query per user.** Aggregate reports become "one query on `bsv_wallet.users` plus N queries on `bsv_wallet_<name>.<table>`" with reassembly in Ruby. This is the right trade because aggregate ops don't need high throughput; the price is paid in the cold path, not the hot one.
* **Migration coordination across N databases.** When the per-user schema evolves, every per-user database must run the migration. The Sequel migration model already supports per-database execution; the operational change is "run the migrations N times rather than once". For schema changes that must apply atomically across all users (uncommon), the per-user-DB shape makes this harder; this is the trade we accept for structural isolation.
* **Identity-key lookup goes through the central DB on cold path.** A per-user request that needs `users.identity_key` makes a central-DB query before reaching the per-user DB. This is a single-row fetch (fast inherently) and is cacheable per `walletd` instance (the identity key changes once per user, so a long-lived in-memory cache makes the central-DB call vanish after first warm-up). The hot path stays within the per-user DB.

## Implementation notes

This ADR adds no code. Until multi-user support is built (no demand-pull observed at 2026-06-24), no migrations run and no central database exists. The forward direction is a constraint on incremental decisions: schema changes that land between now and multi-user adoption must be compatible with the per-user-DB shape, which is automatic so long as they don't introduce centralisation assumptions (cross-tenant aggregates encoded in DDL, cross-user FK references, etc.).

When the work is scheduled (under a future HLR), the implementation outline is:

1. **Migration `bsv_wallet` schema** — `users(user_id, identity_key, name, created_at, ...)` and nothing else by default.
2. **`Fixtures` / configuration update** — registry mapping `name → identity_key` resolves against `bsv_wallet.users` when central is present, falls back to today's local-only resolution when absent.
3. **Per-user DB provisioning** — `CREATE DATABASE bsv_wallet_<name>`, run all per-user migrations against it.
4. **`walletd` request routing** — incoming requests resolve target user → target per-user DB connection. The per-user DB connection is the only thing the wallet code sees.
5. **Defensive depth (optional, follow-up):** per-user Postgres roles, request-time credential selection at the conformance layer.

Out of scope for this ADR but tracked elsewhere: the central database's role in BRC-100 originator support (whether DBAP tokens for cross-user permission grants live centrally), inter-user payment within one wallet instance, multi-instance `walletd` against the same central DB.

## References

* ADR-002 — design for scale; the throughput argument behind this isolation choice.
* ADR-003 — schema as canonical state; preserved per-user-DB by construction.
* ADR-007 — single-tenant engine, no user table; the retrospective complement of this ADR.
* ADR-027 — core wallet vs BRC-100 conformance; this ADR is one forward application of that principle.
* `docs/reference/core-vs-conformance.md` — the principle this ADR defers to.
* `docs/reference/schema.md` — the per-user schema definition that stays unchanged.
* HLR (future, not yet raised) — schedule of work to implement multi-user.
