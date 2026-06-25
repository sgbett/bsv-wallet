# BSV Wallet — Project Instructions

## Language Convention

**Code identifiers** — American English. Method names, classes, schema columns, ENUM values, file names, constants. This is the only hard constraint: the BRC-100 spec defines `internalizeAction`, `randomizeOutputs`, etc., and mixing British Ruby identifiers (`internalise_action`) with American spec names creates confusion about which convention applies where.

Examples: `internalize`, `randomize`, `behavior`, `color`, `organization`, `optimize`, `summarize`, `favor`, `center`.

**Free prose** — author's voice (British for this author, per the global preference). CLAUDE.md, `docs/reference/`, READMEs, HLR bodies, PR descriptions, commit message bodies, RSpec `it` descriptions, RDoc/YARD comments, code comments. No translation required. Visual jar between a British comment and an American identifier in the same file is acceptable.

This narrows an earlier rule that demanded American everywhere. The identifier rationale (spec consistency) still holds; extending it to prose was a friction cost without a corresponding benefit.

## Transaction ID Convention: wtxid / dtxid

Two representations, one simple rule:

- **Binary** (Ruby internals, database, wire format): `wtxid` — wire-order, raw SHA256d, 32 bytes
- **String** (JSON, logs, CLI, external APIs): `dtxid` — display-order hex, 64 characters

No exceptions. If it's binary, it's `wtxid`. If it's a string, it's `dtxid`.

### Naming

| Name | Format | When |
|------|--------|------|
| `wtxid` | 32-byte binary, wire order | Method params, variables, hash keys, database columns |
| `dtxid` | 64-char hex string, display order | ARC API calls, JSON responses, logs, CLI output |
| `txid` | Varies | BRC-100 spec names only (`known_txids:`, return key `:txid`) — boundary comment required |

### BRC-100 spec names

Where a specification requires `txid` (e.g., `known_txids:` parameter, `:txid` return key), keep the spec name. Add a boundary comment. The value is a wire-order wtxid — the key name is the spec's label, not a byte-order indicator.

### SDK API names

Third-party conventions stay as-is: `PathElement#txid` (boolean flag), `txOrId` (TSC field). These are not our naming to change.

### Source

`Transaction::Tx#wtxid` returns wire order (SDK v0.17.0+). `Transaction::Tx#txid` returns display order — a convenience method, never used in the data path. The `BSV::Wallet::Txid` refinement provides `String#to_dtxid` (wtxid binary → dtxid hex) — the wallet's single home for the conversion; activate it per file with `using BSV::Wallet::Txid`.

## Transaction Class Convention: `Transaction::Tx` in prose

A transaction is an abstract entity with several representations: bytes on the wire, a row in `actions`, a BEEF bundle, a Ruby `Transaction::Tx` instance. The English word and the Ruby class are not interchangeable.

In prose, comments, YARD tags, and spec descriptions:

- **`Transaction::Tx`** names the Ruby class or its instances. Use this whenever the meaning is "the class instance specifically". The `BSV::` prefix is redundant for the audience — gem consumers read `Namespace::Class` instinctively.
- **`transaction`** (lowercase) is the English noun for the abstract entity. Use this when the representation doesn't matter, or when several representations are in play.
- **`Tx`** bare is reserved for Ruby code at call sites (where `BSV::Transaction::Tx` resolves it fully). In prose it reads as an alien identifier.

### Examples

| Reads | Means |
|-------|-------|
| "the cached `Transaction::Tx`" | Ruby instance, fully hydrated |
| "`Transaction::Tx#verify` walks via `input.source_transaction`" | Class method reference |
| "the transaction is rejected at broadcast time" | The abstract entity at any stage |
| "atomic BEEF carries the transaction graph" | Abstract entity, multi-representation |

### Source

Settled in PR #304 (the SDK 0.24.0 rename migration), after the initial mechanical sweep left awkward forms like `+Tx#verify+` and "the cached Transaction" in comments. `Transaction::Tx` for class references and lowercase `transaction` for the abstract noun resolves both.

## Public Key Convention: identity hex, derived binary

Pubkeys split into two classes with different representation rules. Identity-shaped pubkeys (the BRC interchange identifiers) are a deliberate carve-out from the binary-internal principle that applies to txids/scripts/hashes — they stay hex throughout. Derived/transient pubkeys (BRC-42 outputs) follow the principle as written and stay binary. New code that "fixes" identity-shaped pubkeys to binary is reversing a settled decision; new code that surfaces derived pubkeys as hex inside the data path is doing unnecessary conversion.

### Identity-shaped pubkeys — hex

Stable identifiers that cross BRC boundaries as JSON: the wallet's own identity, BRC-43 counterparty references, BRC-29 sender_identity_key, BRC-52 certificate fields. Hex storage, hex on the wire, hex internally for the dominant boundary-crossing path.

- **`KeyDeriver#identity_key`** — hex (66-char compressed). The BRC-100 `getPublicKey` emission value.
- **`KeyDeriver#identity_key_bytes`** — 33-byte binary. The accessor for crypto-op consumers (`hash160`, ECDH input). Never round-trip `identity_key` through `[hex].pack('H*')` — call `identity_key_bytes` instead.
- **`KeyDeriver` counterparty params** — hex (`'self'`, `'anyone'`, or hex public key), per BRC-43.
- **`outputs.sender_identity_key`** column — `:text`. BRC-29 interchange identifier.
- **`certificates.{certifier, subject, verifier, signature}` + `certificate_fields.{value, master_key}`** — `:text`. BRC-52 interchange.

### Derived / transient pubkeys — binary

Outputs of BRC-42 derivation, fed directly into the next crypto operation — a `hash160` to produce a locking script, an ECDH input to derive a symmetric key. These never cross a BRC boundary *as themselves*; they're intermediates within one operation.

- **`KeyDeriver#derive_public_key`** — returns 33-byte binary.
- **`Engine#get_public_key(identity_key: false, …)`** — returns 33-byte binary.

If/when these need to cross a JSON boundary (a future BRC-100 binding — issues #180, #223), conversion to hex happens at that emit point, the same way `dtxid` conversion happens at the txid boundary. Internally they stay binary.

### Why identity pubkeys are hex (and txids aren't)

These four supports explain the identity-pubkey carve-out specifically. Derived pubkeys don't need supports — they're binary because they go straight from `derive_public_key` into the next crypto op.

1. **The internal canonical form isn't bytes — it's a `PublicKey` object** (curve point). Hex and binary are both serializations of that. The wallet operates on `PublicKey` instances; it rarely manipulates identity pubkey bytes directly.
2. **Identity pubkeys are protocol identifiers, not binary content.** Txids get hashed, recomputed from raw tx, and indexed by structural bytes (wire order has meaning). Identity pubkeys flow through unchanged as identity tokens — bytes have no structural meaning beyond serialising the point.
3. **Identity pubkeys cross BRC boundaries more often than txids.** Every BRC-100 method takes or returns one (`identity_key`, `counterparty`, `subject`, `certifier`, `verifier`). BRC-29 and BRC-52 also specify hex at the wire. Hex storage moves conversion off the boundary-heavy path.
4. **The binary-internal principle itself carves out spec-mandated hex.** Convert to hex *only* where the spec explicitly says hex string — identity pubkey BRC fields meet that test directly. Txids are an exception in the *other* direction (binary even though `TXIDHexString` is BRC-canonical) precisely because txid bytes have structural meaning that identity pubkey bytes don't.

### Source

The reasoning is recorded in `project_pubkey_hex_exception` (memory). The decision was made at PR #18, cemented by HLR #28 (BRC-100 SDK alignment), and formalised in HLR #300 after the audit recovered the trace.

## Load-bearing Principles

Two design principles shape the wallet from the outside in. Both are documented in `docs/reference/`; the canonical wording lives there, this section is the at-a-glance summary for coding sessions. New behaviour that contradicts either is almost certainly wrong.

### Principle of state

> The database schema is the canonical source of truth for what is valid. All state-changing operations mutate the database atomically from one valid state to another. Invalid state is structurally impossible because the schema's constraints will reject it.

Practical consequences when working on this codebase:

- **Application code orchestrates; the schema enforces.** If you're writing application code that "validates" state, ask whether the schema could enforce the same invariant. If yes, lift it to the schema.
- **Multi-write operations belong in one `db.transaction` block.** If not, you're leaking the possibility of an intermediate invalid state.
- **Status is never stored.** Derived properties (action status, output spendability) are computed from structural state at read time. There is no `status` column to drift.
- **Caches are projections over canonical state, never beside it.** If deleting the cache and rebuilding from DB doesn't reproduce identical behaviour, the cache holds state that should be in the database.

Full statement, manifestations, and follow-ups: `docs/reference/principle-of-state.md`.

### Stateless vs stateful (SDK / wallet)

> Stateless behaviour belongs in the SDK. Stateful behaviour belongs in the wallet. SDK is operations, wallet is processes — same principle viewed from the temporal axis.

Practical consequences when designing new surface area:

- **Ask: does this need to remember anything between calls?** Yes → wallet. No → SDK. There is no half-stateful SDK feature that works after restart; the choice is wallet or broken.
- **The SDK has no database, no daemon, no clock-spanning state.** A stateful "feature" added there either secretly relies on the caller to persist (caller is the wallet) or silently loses information on restart.
- **The boundary is bidirectional and reviewable.** Surface area has moved both ways during the rebuild (BRC-100 interface + ProtoWallet ceded SDK → wallet). Future moves pass the same test in either direction.

Full statement and worked examples: `docs/reference/state-boundaries.md`.

## Database & Wallet Configuration

This is a **Postgres-based** wallet. SQLite exists as a convenience for fast logic-only specs that don't depend on DB invariants — it is not the production target.

The schema chooses Postgres-native features deliberately: `bytea` for everything hash-shaped, native `uuid` for `actions.reference`, ENUM types (`broadcast_intent`), CHECK constraints, RESTRICT FK semantics. See `docs/reference/schema.md` for the table-by-table reference, and `.architecture/decisions/adrs/20260505_ADR-009-postgres-native-primitives.md` for the per-primitive rationale.

### Migration discipline — pre-release

The schema lives in **`001_create_schema.rb`** (structure: every table with its columns, inline CHECKs, NOT NULLs, single-table FKs and indexes) and **`002_triggers.rb`** (behavioural guards: BEFORE-row triggers and their PG functions that can't sit inside CREATE TABLE because they reference other tables).

During pre-release development, schema changes amend these two files in place — no new migrations. The migration sequence is design documentation, not operational history; a reader should derive the full intended schema from 001 + 002 without piecing it together across follow-up files. The "hash trick" (`c[:type]` map at the top of 001) handles Postgres/SQLite divergence inline. Once a release ships and there are deployed wallets to forward-compat against, additive migrations begin at 003.

### Configuration model — no mystery

There are two audiences for wallet configuration, with different env-var conventions. Don't mix them up.

#### End-user mode (someone who installed the gem)

A single wallet, a single database. The end user sets one variable:

- **`DATABASE_URL`** — full Postgres URL (e.g. `postgres://user:pass@host:5432/my_wallet`), or any Sequel-compatible URL. The end user doesn't care about per-wallet derivation; they have one wallet.
- If `DATABASE_URL` is unset, `CLI.boot` falls back to SQLite at `~/.bsv-wallet/<name>.db` (or `default.db` for unnamed).

This is what README, install docs, and end-user-facing copy should foreground. End users **don't need to know about** `BSV_WALLET_POSTGRES` or `BSV_WALLET_WIF_<NAME>` — those are dev/test scaffolding.

#### Dev/test mode (this repo — what we use)

Multiple named wallets sharing one Postgres server. Resolution goes through **`BSV::Wallet::Fixtures`** — a registry block that maps each name to a WIF + database_url. The gem ships a default `config/fixtures.rb` that reads shell ENV vars and is auto-loaded when no user override exists, so the existing shell-env-driven convention (`~/.zshenv` locally, GitHub secrets in CI) still "just works".

Standard registered wallets:

- `alice`, `bob`, `carol` — integration specs
- `sdk` — e2e harness funder
- `w1`..`w5` — e2e wallet fleet (WIFs derived at runtime from `:sdk`)
- `test` — unit-spec DB (no WIF; specs generate their own keys)

ENV vars consumed by the default fixtures file:

- **`BSV_WALLET_POSTGRES`** — base URL (e.g. `postgres://postgres:postgres@localhost:5433/`). Per-wallet DB derives as `<base>/bsv_wallet_<name>`.
- **`BSV_WALLET_WIF_<NAME>`** — WIF per named wallet (e.g. `BSV_WALLET_WIF_ALICE`).
- **`DATABASE_URL_<NAME>`** (rare override) — pin a specific wallet to a non-standard URL.

`BSV_WALLET_POSTGRES` unset → unit specs fall back to in-memory SQLite (the SQLite-augmentation path). CLI tools that need a real wallet require it set.

Override the gem default by writing `~/.bsv-wallet/fixtures.rb` (or setting `BSV_WALLET_FIXTURES=<path>`). The user file fully replaces — register every wallet you want available. The e2e harness registers `w1`..`w5` at runtime via the same `Fixtures.configure` block.

### Conventions

- When the user says "the database" or "the wallet" without qualifying, assume Postgres in dev/test mode.
- Unit spec helper branches on `BSV_WALLET_POSTGRES`: unset → in-memory SQLite, set → `<base>/bsv_wallet_test`. The helper **ignores `DATABASE_URL`** — keeps an operator's working end-user `DATABASE_URL` from silently hijacking the spec run. Both backends run in CI (matrix job).
- Integration specs require **both** `BSV_WALLET_POSTGRES` and `BSV_WALLET_WIF_ALICE/BOB/CAROL` (each WIF funded with ≥ 1m sats on chain).
- E2E specs use the `sdk` wallet (`BSV_WALLET_WIF_SDK` + `<base>/bsv_wallet_sdk`) plus the `w1`..`w5` derived fleet for the multi-wallet harness.
- Postgres-specific behavior (CHECK violations, ENUM rejections, RESTRICT FK semantics, the `prevent_outbound_spendable` trigger) MUST have a spec that runs against Postgres — SQLite carries those via translation and won't surface a regression.
- New DB-touching test helpers must read the configured DB URL, never hardcode `sqlite://`.

## Running Specs

Specs must run from the gem directory, not the repo root.

```bash
# Wallet unit specs (Postgres — primary target)
cd gem/bsv-wallet && BSV_WALLET_POSTGRES=postgres://postgres:postgres@localhost:5433/ bundle exec rspec spec/bsv spec/bin

# Wallet unit specs against SQLite (augmentation — proves SQLite still works)
cd gem/bsv-wallet && bundle exec rspec spec/bsv spec/bin

# Wallet integration specs (require BSV_WALLET_POSTGRES + BSV_WALLET_WIF_ALICE/BOB/CAROL, each WIF funded with >= 1m sats)
cd gem/bsv-wallet && bundle exec rspec spec/integration

# All wallet specs (unit + integration)
cd gem/bsv-wallet && bundle exec rspec

# RuboCop
cd gem/bsv-wallet && bundle exec rubocop
```

## Architecture Framework

The `.architecture/` directory contains the AI Software Architect framework:

- **`members.yml`** — architecture team roster (10 specialists)
- **`principles.md`** — architectural principles governing design decisions
- **`decisions/adrs/`** — Architectural Decision Records
- **`reviews/`** — architecture reviews and system analyses
- **`config.yml`** — framework configuration

Commands: `architecture-status`, `create-adr`, `specialist-review`, `architecture-review`, `list-members`
