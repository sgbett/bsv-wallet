# Initial System Analysis

**Project**: bsv-wallet
**Date**: 2026-05-13
**Analysis Type**: Initial Setup Assessment
**Analysts**: Dr. Elena Vasquez (Systems Architect), James Thornton (BSV Domain Expert), Nadia Okafor (Security Specialist), Viktor Petrov (Performance Expert), Aisha Rahman (Maintainability Expert), Sam Oduya (Pragmatic Enforcer), Marcus Johnson (Ruby Expert), Dr. Lin Wei (Database Architect), Dr. Kenji Nakamura (Cryptography Reviewer)

---

## Executive Summary

The bsv-wallet project is a ground-up Ruby implementation of the BRC-100 wallet specification. It ships as two gems in a monorepo: `bsv-wallet` (core interfaces, engine, CLI) and `bsv-wallet-postgres` (Sequel/PostgreSQL persistence adapter). The architecture follows a four-layer SOA -- operational systems, services (component + atomic), BRC-100 business process, and consumer -- with dependency injection enabling testability without a database. The project is approximately 4,900 lines of library code and 8,000 lines of specs, developed by a solo developer.

The system is in an active growth phase. The core transaction lifecycle (create, sign, broadcast, promote) is operational, including auto-funded payments, BEEF envelope construction, and a recently shipped Pushable/Fetchable entity-driven network interaction layer with a Daemon polling loop. The schema has evolved through four migrations, with the latest removing the `tx_reqs` table in favor of structural-state-driven queries -- a sign of architectural maturity. Key derivation (BRC-42/43), cryptographic operations, and certificate management are implemented at the engine level.

Overall, the architecture is well-designed for its maturity stage. The interface-driven separation between core and postgres gems is a genuine strength, as is the constraint-driven PostgreSQL schema. The primary concern is the 1,700-line Engine class, which handles transaction construction, BEEF assembly, merkle path normalization, and ancestor resolution alongside its orchestration duties. This is the most likely source of future maintenance friction. The Pushable/Fetchable pattern and Services routing layer show good architectural direction, but several BRC-100 methods remain stubbed (`get_height`, `get_header_for_height`, `discover_by_attributes`).

**Overall Assessment**: Good

**Key Findings**:
- Engine.rb (1,708 lines) conflates orchestration with transaction mechanics -- extractable concerns include BEEF construction, transaction building, and merkle path normalization
- Constraint-driven schema with derived status is a genuine architectural strength that eliminates entire categories of state-management bugs
- Test-to-code ratio is healthy (1.6:1) with good coverage of the persistence layer, but integration test paths for the Daemon and Pushable/Fetchable lifecycle are nascent
- Certificate issuance protocol (`:issuance`) raises `UnsupportedActionError` -- a known gap with external-facing implications
- The auto-fund flow has a theoretical TOCTOU window between `enforce_headroom!` and the actual UTXO lock

**Critical Recommendations**:
- Extract transaction construction, BEEF assembly, and merkle path normalization from Engine into focused helper classes
- Add integration specs covering the Daemon polling lifecycle end-to-end through Pushable/Fetchable entities

---

## System Overview

### Project Information

**Primary Language(s)**: Ruby (3.0 -- 3.4 matrix in CI)

**Frameworks**: Sequel (ORM), custom SOA framework (no web framework -- library gem)

**Architecture Style**: Four-layer SOA with interface-driven dependency injection

**Deployment**: Library gems (consumed by host applications); CLI tools for direct operation

**Team Size**: 1 developer

**Project Age**: Active development (~3 months of focused work, based on commit history)

### Technology Stack

**Backend**:
- Ruby 3.x (tested across 3.0--3.4)
- bsv-sdk (BSV primitives: keys, scripts, transactions, ARC protocol)
- Sequel ORM (database access, migrations)
- pg gem (PostgreSQL driver)

**Database**:
- PostgreSQL 16 (primary persistence)
- 16 tables (blocks, tx_proofs, actions, broadcasts, baskets, outputs, spendable, output_details, output_baskets, inputs, labels, action_labels, tags, output_tags, certificates, certificate_fields, settings)
- tx_reqs table dropped in migration 004

**Infrastructure**:
- GitHub Actions CI (Ruby 3.0--3.4 matrix)
- PostgreSQL service container in CI
- Codecov coverage reporting (on Ruby 3.4)
- RuboCop linting
- Integration test suite with on-chain transactions (separate CI job, secrets-gated)

### Project Structure

```
/opt/ruby/bsv-wallet/
├── gem/
│   ├── bsv-wallet/                    # Core gem (zero DB dependencies)
│   │   ├── lib/bsv/
│   │   │   ├── wallet/
│   │   │   │   ├── engine.rb          # Layer 3 — BRC-100 orchestration (1,708 LOC)
│   │   │   │   ├── key_deriver.rb     # BRC-42/43 key derivation (492 LOC)
│   │   │   │   ├── interface/         # Abstract contracts (Store, UTXOPool, etc.)
│   │   │   │   ├── pushable.rb        # Network push mixin
│   │   │   │   ├── fetchable.rb       # Network fetch mixin
│   │   │   │   ├── daemon.rb          # Background polling loop
│   │   │   │   ├── cli.rb            # Shared CLI boot/output
│   │   │   │   └── errors.rb         # Wallet-specific error classes
│   │   │   └── network/
│   │   │       └── services.rb        # Provider routing layer (311 LOC)
│   │   └── spec/                      # ~5,000 LOC specs
│   │
│   └── bsv-wallet-postgres/          # PostgreSQL adapter gem
│       ├── lib/bsv/wallet/postgres/
│       │   ├── store.rb              # Interface::Store implementation (580 LOC)
│       │   ├── broadcast_queue.rb    # Interface::BroadcastQueue implementation
│       │   ├── utxo_pool.rb          # Tier 1 UTXO pool
│       │   ├── proof_store.rb        # Merkle proof manager
│       │   ├── action.rb, broadcast.rb, output.rb, ...  # Sequel models
│       │   └── ...
│       ├── db/migrations/            # 4 migration files
│       └── spec/                     # ~3,000 LOC specs
│
├── .architecture/                     # Architecture framework
├── .claude/                           # AI assistant configuration
├── .github/workflows/                 # CI configuration
├── DESIGN.md                          # Architecture and design document
└── reference/                         # BRC-100 spec reference
```

**Key Observations**:
- Clean split between core (interfaces + orchestration) and adapter (PostgreSQL implementation) follows dependency inversion
- Engine.rb at 1,708 lines is the largest file by a significant margin -- the next largest library file (key_deriver.rb) is 492 lines
- Engine spec (2,743 lines) is the largest test file, reflecting the engine's scope
- Models are thin (most < 400 LOC) with behavior pushed to the Store component

---

## Individual Member Analyses

### Dr. Elena Vasquez - Systems Architect

**Perspective**: Evaluates whether the system's layers and boundaries serve its evolution. Focuses on interface stability and dependency direction.

#### Current State Assessment

The four-layer SOA (operational, services, BRC-100, consumer) is well-articulated in both documentation and code. The dependency direction is correct: the core gem defines interfaces, the postgres gem implements them. Engine receives Layer 2a components at construction time via dependency injection, enabling full unit testing with in-memory doubles.

The interface modules (`Interface::Store`, `Interface::UTXOPool`, `Interface::BroadcastQueue`, `Interface::ProofStore`) define clear contracts with `NotImplementedError` defaults. The postgres implementations faithfully implement these contracts and return plain hashes -- no Sequel::Model objects leak through the boundary.

The recent Pushable/Fetchable layer is architecturally sound. Entities own their network interaction semantics (what command to call, what payload to send, how to write the response). Services routes and retries; it does not map fields. The Daemon accepts callable query objects rather than importing models, keeping the wallet gem free of postgres dependencies.

#### Strengths Identified

1. **Interface-driven gem separation**: The two-gem structure with abstract interfaces is a genuine dependency inversion. Someone could implement `Interface::Store` against SQLite, Redis, or in-memory hashes without touching the core gem. The in-memory store used in engine specs proves this works.

2. **Dependency injection without a DI framework**: Engine takes all its components via constructor args. No service locator, no global registry. Clean and testable.

3. **Entity-driven network interaction**: The Pushable/Fetchable pattern distributes network knowledge to the entities that need it. This avoids a centralized "manager" that needs to understand every entity type.

#### Concerns Raised

1. **Engine is doing too much** (Impact: High)
   - **Issue**: Engine.rb handles BRC-100 orchestration, transaction construction (build_transaction, build_funded_transaction), BEEF assembly (build_atomic_beef, resolve_ancestor), merkle path normalization (normalize_merkle_path, normalize_tsc_merkle_path), input resolution (build_inputs, derive_signing_key), and output building (build_outputs, resolve_locking_script). These are Layer 2 concerns mixed into Layer 3.
   - **Why It Matters**: At 1,708 lines, it is the highest-coupling point in the system. Adding new functionality (e.g., multi-input auto-fund, output grouping) requires modifying the file that orchestrates everything else. The surface area for introducing regressions is large.
   - **Recommendation**: Extract TransactionBuilder, BeefAssembler, and MerklePathNormalizer as Layer 2a helpers. Engine delegates to them. Each has focused specs.

2. **Services is in the wrong namespace** (Impact: Medium)
   - **Issue**: `BSV::Network::Services` lives in the wallet gem but acts as a general-purpose provider routing layer. The project memory notes this: "BSV::Network::Services belongs in SDK, current BSV::Wallet::Services is wrong namespace."
   - **Why It Matters**: If other consumers (non-wallet) want provider routing, they must depend on the wallet gem. This is an inverted dependency.
   - **Recommendation**: This is a known deferred item. When the SDK interface settles, move Services to the SDK gem. Until then, the cost of the wrong namespace is low.

3. **Circular potential in Broadcast/Action Fetchable** (Impact: Low)
   - **Issue**: Both `Broadcast` and `Action` implement Fetchable for `:get_tx_status`. The Daemon queries for each separately (`stale_fetches` and `pending_proofs`). The difference is in lifecycle: Broadcast tracks broadcast status, Action acquires proofs. But both fetch from the same ARC endpoint.
   - **Why It Matters**: A single ARC response could satisfy both entities' needs, but they poll independently, doubling network calls.
   - **Recommendation**: Consider whether one entity should handle both concerns, or whether the sibling memo in Services can bridge them (it already caches get_tx sibling data for get_merkle_path).

#### Initial Recommendations

1. **Extract transaction construction from Engine** (Priority: Important, Effort: Medium)
   - **What**: Create `TransactionBuilder` and `BeefAssembler` classes that Engine delegates to
   - **Why**: Reduces Engine to pure orchestration, improves testability of transaction mechanics in isolation
   - **How**: Move `build_transaction`, `build_funded_transaction`, `build_inputs`, `build_outputs`, `resolve_locking_script`, `resolve_unlocking_script`, `derive_signing_key`, `find_caller_input`, `apply_spends` to TransactionBuilder. Move `build_atomic_beef`, `resolve_ancestor`, `collect_input_ancestry` to BeefAssembler. Move `normalize_merkle_path`, `normalize_tsc_merkle_path` to MerklePathNormalizer.

---

### James Thornton - BSV Domain Expert

**Perspective**: Guards specification fidelity. Every architectural decision is evaluated against what BRC-100 requires and what the BSV protocol permits.

#### Current State Assessment

The wallet implements the full BRC-100 method surface (28 methods). The four-phase action lifecycle (lock, sign, broadcast, promote) correctly maps the spec's transaction semantics. Derived status from structural state avoids the common trap of status columns that drift from reality.

The `noSend`/`sendWith` chaining mechanism is implemented. Auto-funded actions with UTXO selection, fee computation (100 sats/kb via SDK), and Benford-distributed change outputs handle the common payment case. BEEF construction includes recursive ancestor resolution with proper handling of mined (BUMP) vs unconfirmed (raw_tx chain) ancestors.

The `trustSelf` parameter is implemented via `replace_known_ancestors!` which substitutes known transactions with TXID-only BEEF entries. Fee adequacy validation (BRC-67: inputs must exceed outputs) is present.

#### Strengths Identified

1. **Phase model maps spec precisely**: The create/sign/promote lifecycle mirrors BRC-100's execution model. Deferred signing (unlocking_script_length without unlocking_script) correctly returns a signable_transaction reference, and sign_action completes it.

2. **Binary-first data handling**: The wtxid/dtxid convention is consistently applied. Binary internally, hex at boundaries. Database bytea columns, binary wire format throughout. This eliminates double-memory overhead and encode/decode cycles.

3. **Change output distribution**: The `change_output_count` formula grows the UTXO pool toward a configurable target, capped per transaction. The SDK's `distribute_change` with `:random` mode provides Benford-style privacy. This is a thoughtful design that balances UTXO management with privacy.

#### Concerns Raised

1. **Three stubbed BRC-100 methods** (Impact: Medium)
   - **Issue**: `get_height` and `get_header_for_height` raise `UnsupportedActionError`. `discover_by_attributes` returns empty results. Certificate issuance (`:issuance` protocol) raises `UnsupportedActionError`.
   - **Why It Matters**: These are spec-mandated methods. A consumer expecting full BRC-100 compliance will hit runtime errors. `get_height` in particular is needed for chain tracking and SPV validation.
   - **Recommendation**: `get_height` and `get_header_for_height` can delegate to the network provider (WhatsOnChain already serves these). Certificate issuance is a larger concern that requires protocol implementation. Document which methods are stub vs implemented.

2. **Limp mode bypassed for import** (Impact: Low)
   - **Issue**: `import_utxo` sets `@bypass_limp_mode = true` as an instance variable flag. This is a boolean flag on a shared object -- if Engine is ever used concurrently (e.g., in a multi-threaded web server), this is a race condition.
   - **Why It Matters**: Currently fine for single-threaded CLI usage. Would be a problem in a multi-tenant server context.
   - **Recommendation**: Pass a `bypass_limp:` keyword through create_action instead of mutating shared state. Or use a thread-local.

3. **Fee estimate assumes 1 input** (Impact: Low)
   - **Issue**: The auto-fund flow estimates fees assuming 1 input (`10 + 148 + ((outputs.length + estimated_change_count) * 34)`). The comment says extra inputs contribute more satoshis than they cost in fees (true), but the estimate could undercount in edge cases with many small UTXOs.
   - **Why It Matters**: The SDK computes the real fee regardless, so this is only about whether `enforce_headroom!` rejects valid transactions prematurely.
   - **Recommendation**: Acceptable for now. If small-UTXO scenarios arise, adjust the estimate.

#### Initial Recommendations

1. **Implement get_height via network provider** (Priority: Important, Effort: Small)
   - **What**: Route `get_height` through Services to WhatsOnChain's chain info endpoint
   - **Why**: Required for chain tracking and any consumer expecting BRC-100 completeness
   - **How**: Add `:get_height` to WhatsOnChain provider, delegate from Engine

---

### Nadia Okafor - Security Specialist

**Perspective**: Treats every external input as hostile and every key operation as a potential leak. Reviews for timing attacks, key exposure, and injection vectors.

#### Current State Assessment

The wallet handles private keys, constructs Bitcoin transactions, and validates incoming BEEF data from untrusted sources. Key operations delegate to the SDK's cryptographic primitives -- no hand-rolled crypto. HMAC verification uses constant-time comparison (`secure_compare`). Binary data stays binary to avoid encoding-related injection vectors.

The `internalize_action` flow validates BEEF structure, verifies merkle paths against a chain tracker (when available), and checks fee adequacy before accepting incoming transactions. The `trustSelf` mechanism replaces known ancestors -- this is trust boundary management.

#### Strengths Identified

1. **No hand-rolled cryptography**: All ECDSA, ECDH, AES-256-GCM, and HMAC operations delegate to the SDK. The wallet handles key derivation parameters but never manipulates raw elliptic curve points.

2. **Constant-time HMAC comparison**: `secure_compare` does byte-by-byte XOR with a single result check -- proper timing attack mitigation.

3. **Database-enforced single-spend**: `INSERT ON CONFLICT` on `inputs.output_id` is the single-spend enforcement mechanism. This is atomic at the PostgreSQL level -- no application-level race condition can double-spend.

#### Concerns Raised

1. **Root private key in memory** (Impact: Medium)
   - **Issue**: `KeyDeriver` holds the root private key as a long-lived object. The CLI boot loads it from a WIF environment variable and keeps it in the engine for the process lifetime.
   - **Why It Matters**: Any memory dump, core dump, or process inspection exposes the master key. There is no mechanism to zeroize key material after use.
   - **Recommendation**: This is inherent to Ruby's GC-managed memory model -- there is no safe way to zeroize a Ruby string (the GC may have copies). Documented risk. In production, consider HSM integration via a KeyDeriver adapter that delegates signing to hardware.

2. **WIF from environment variable** (Impact: Medium)
   - **Issue**: The private key is loaded from `ENV['WIF']` or `ENV['WIF_ALICE']`. Environment variables are visible via `/proc/PID/environ` on Linux and may appear in process listings, shell history, or CI logs.
   - **Why It Matters**: In production deployments, environment variables are a weak secret transport mechanism.
   - **Recommendation**: For production: support loading WIF from a file (mode 0600) or a secret manager. For development: the current approach is adequate.

3. **No input validation on locking_script sizes** (Impact: Low)
   - **Issue**: `resolve_locking_script` accepts arbitrary-length binary data. A malicious caller could pass a multi-megabyte locking script, inflating transaction size and database storage.
   - **Why It Matters**: The SDK likely has its own limits during transaction construction, but there is no early rejection at the wallet boundary.
   - **Recommendation**: Add a size check on locking scripts at the engine boundary. BRC-100 doesn't specify a maximum, but a practical limit (e.g., 10KB) prevents abuse.

4. **No BEEF size validation** (Impact: Low)
   - **Issue**: `internalize_action` calls `parse_beef(tx)` on the incoming data without a size check. A multi-gigabyte BEEF payload would be parsed into memory.
   - **Why It Matters**: Denial of service vector when accepting transactions from untrusted sources.
   - **Recommendation**: Add a maximum BEEF size check before parsing (e.g., 10MB).

#### Initial Recommendations

1. **Document key material lifecycle** (Priority: Important, Effort: Small)
   - **What**: Document that the root key lives in process memory for the process lifetime, and outline HSM integration path
   - **Why**: Makes the security posture explicit for production deployment decisions
   - **How**: Add a "Key Material" section to DESIGN.md

---

### Viktor Petrov - Performance Expert

**Perspective**: Asks "what happens at 10x scale?" for every design. Focuses on database round-trips, memory allocation, and algorithmic complexity.

#### Current State Assessment

The hot path for transaction creation involves: UTXO selection (1 query), action creation (1 transaction with inserts), input resolution (1 join query), transaction construction (in-memory), signing (in-memory), and promotion (1 transaction with inserts). This is 3-4 database round-trips per transaction -- reasonable.

The spendable table (~28 bytes/row) is a clever performance optimization. It separates the "what can I spend?" question from the full output data, keeping the UTXO set scanning fast. PostgreSQL buffer cache should hold this table permanently for any reasonable wallet size.

BEEF construction calls `resolve_ancestor` recursively, hitting ProofStore for each ancestor. For deep chains of unconfirmed transactions, this is O(n) in chain depth with one database query per level.

#### Strengths Identified

1. **Spendable table as a hot-set index**: The minimal spendable table is a PK-join away from full output data. This is the right design for the scan-heavy, write-light UTXO selection workload.

2. **Three-tier UTXOPool design**: The interface supports progression from database queries (Tier 1) to in-memory queues (Tier 3) without changing the Engine. The current Tier 1 implementation is adequate for early use.

3. **N+1-aware query patterns**: `query_actions` and `query_outputs` use Sequel's join and subquery patterns rather than loading associations individually. The `include_*` flags avoid loading data that is not requested.

#### Concerns Raised

1. **Recursive ancestor resolution is O(depth * queries)** (Impact: Medium)
   - **Issue**: `resolve_ancestor` calls `@proof_store.find_proof(wtxid:)` and `@store.find_action(wtxid:)` for each level of the ancestry tree. For a chain of 10 unconfirmed transactions, this is ~20 queries.
   - **Why It Matters**: BEEF construction is on the critical path of `create_action` when returning `atomic_beef`. Deep unconfirmed chains are common during batch operations.
   - **Recommendation**: Batch-load proofs for all ancestors in a single query before recursing. Or cache resolved ancestors in the BeefAssembler for the duration of a single create_action call.

2. **find_or_create_labels/tags are N+1** (Impact: Low)
   - **Issue**: `find_or_create_labels` and `find_or_create_tags` iterate and issue SELECT + optional INSERT for each name individually.
   - **Why It Matters**: Labels and tags are typically few per action (1-3), so the impact is small. At scale with many labels, this becomes noticeable.
   - **Recommendation**: Batch with `INSERT ON CONFLICT ... RETURNING id` for all names in one statement. Low priority.

3. **change_output_count calls balance and spendable_count** (Impact: Low)
   - **Issue**: `change_output_count` calls `balance` (SUM query) and `spendable_count` (COUNT query) -- two queries. These are called during `auto_fund_action`, which also calls `select` (a third query on the same table).
   - **Why It Matters**: Three queries on the spendable/output join before the action is even created. The queries are cheap (spendable is tiny), but unnecessary.
   - **Recommendation**: Compute change_output_count from the candidates returned by select, or cache balance/count as part of select's result.

#### Initial Recommendations

1. **Batch ancestor proof resolution** (Priority: Important, Effort: Medium)
   - **What**: Collect all ancestor wtxids from transaction inputs, batch-load their proofs in one query, then build the tree
   - **Why**: Reduces BEEF construction from O(depth) queries to O(1)
   - **How**: Add `ProofStore#find_proofs(wtxids:)` batch method. Use it in a `BatchAncestorResolver`.

---

### Aisha Rahman - Maintainability Expert

**Perspective**: Evaluates whether a newcomer could understand, modify, and extend the code with confidence. Favors clarity over cleverness.

#### Current State Assessment

The codebase is well-documented. DESIGN.md provides a comprehensive architecture overview that accurately reflects the code. CLAUDE.md captures conventions (wtxid/dtxid, American English, running specs). The interface modules have YARD documentation explaining the contract and expected behavior.

The test suite has a healthy ratio (8,000 spec lines : 4,900 code lines). Engine specs cover the BRC-100 methods comprehensively. Postgres specs cover models, constraints, and store operations. The shared context pattern in engine specs enables focused test files for porcelain and limp mode.

Code style is consistent: frozen_string_literal everywhere, meaningful variable names, explicit keyword arguments, no metaprogramming tricks.

#### Strengths Identified

1. **DESIGN.md is accurate and detailed**: Unlike many architecture docs, this one matches the code. The four-layer diagram, phase lifecycle, and interface derivation from BRC-100 are all reflected in the implementation.

2. **Plain-hash interface boundary**: All Store/ProofStore methods return hashes, not Sequel models. This makes specs fast (mock with hashes) and prevents ORM leakage. The `action_to_hash` and `output_to_hash` methods enforce this consistently.

3. **Convention documentation is actionable**: The wtxid/dtxid convention, running specs instructions, and American English mandate in CLAUDE.md are specific enough to follow without guessing.

#### Concerns Raised

1. **Engine private methods are undiscoverable** (Impact: Medium)
   - **Issue**: Engine has 40+ private methods spanning transaction construction, BEEF assembly, validation, and key derivation. The private section is longer than many entire classes. A developer looking for "how does merkle path normalization work?" must scan 1,000 lines of private methods.
   - **Why It Matters**: Private methods in a single large file create a discovery problem. They are not indexed by module structure, not loadable in isolation, and not individually testable without `send`.
   - **Recommendation**: The extraction recommended by Dr. Vasquez directly addresses this -- smaller classes with public interfaces are self-documenting.

2. **Spec file for Engine is 2,743 lines** (Impact: Medium)
   - **Issue**: `engine_spec.rb` is the largest file in the project. While some specs have been extracted to porcelain_spec.rb and limp_mode_spec.rb, the core file still covers create_action, sign_action, abort_action, internalize_action, list_actions, list_outputs, and all cryptographic/certificate operations.
   - **Why It Matters**: Large spec files are hard to navigate and slow to run. When a spec fails, finding the relevant context requires significant scrolling.
   - **Recommendation**: Continue the extraction pattern already started. Split engine_spec.rb into per-method-group spec files (e.g., engine/create_action_spec.rb, engine/internalize_action_spec.rb, engine/crypto_spec.rb).

3. **No inline code comments in complex flows** (Impact: Low)
   - **Issue**: Some complex flows like `build_funded_transaction` have excellent step-by-step comments (A through J). Others, like `query_actions` and `resolve_inputs_for_signing`, have minimal inline documentation.
   - **Why It Matters**: The commented flows are significantly easier to follow. Inconsistency creates uncertainty about whether uncommented code is simple-enough-to-not-need-comments or just missing documentation.
   - **Recommendation**: Adopt the A-through-J commenting pattern for all multi-step Store methods.

#### Initial Recommendations

1. **Split engine_spec.rb into domain-grouped files** (Priority: Important, Effort: Small)
   - **What**: Extract create_action, internalize_action, and crypto specs into separate files following the existing porcelain_spec.rb pattern
   - **Why**: Improves spec navigation and enables targeted test runs during development
   - **How**: Create engine/create_action_spec.rb, engine/internalize_spec.rb, engine/crypto_spec.rb, engine/certificate_spec.rb using the existing shared_context.rb

---

### Sam Oduya - Pragmatic Enforcer

**Perspective**: Challenges every abstraction with "do we need this today?" Protects against speculative design and premature optimization.

#### Current State Assessment

The project demonstrates strong YAGNI discipline overall. The three-tier UTXOPool is defined as an interface, but only Tier 1 is implemented. The ProofStore is a separate interface but backed by the same PostgreSQL database. The BroadcastQueue has three delivery mechanisms in the design doc but only implements synchronous and callback. These are all appropriate: the interfaces preserve optionality without implementing complexity.

The recent tx_reqs table removal (migration 004) shows the team actively removing speculative infrastructure. The Pushable/Fetchable pattern replaced what would have been a separate proof-harvesting job queue.

#### Strengths Identified

1. **Interfaces without premature implementation**: Tier 2 and Tier 3 UTXOPool are designed but not built. The interface is ready; the implementation will come when needed. This is the right level of forward thinking.

2. **Active removal of unused infrastructure**: Dropping tx_reqs demonstrates willingness to delete code that was speculatively built. This is rare and valuable.

3. **Porcelain methods are thin**: `send_payment` and `import_wallet` are thin wrappers over `create_action` and `import_utxo`. They add convenience without adding abstraction layers.

#### Concerns Raised

1. **Output type inference in promote_with_outputs** (Impact: Medium)
   - **Issue**: `promote_with_outputs` infers `output_type: 'outbound'` when no derivation data is present (`effective_type = out[:output_type] || (out[:derivation_prefix] ? nil : 'outbound')`). This inference from field absence is fragile -- it couples the meaning of "no derivation fields" to "payment to someone else."
   - **Why It Matters**: Future output types that legitimately have no derivation (e.g., OP_RETURN data carriers) would be misclassified as outbound.
   - **Recommendation**: Require callers to explicitly set output_type rather than inferring it. The engine knows whether an output is a payment -- it should say so.

2. **Daemon interval is sleep-based** (Impact: Low)
   - **Issue**: The Daemon uses `sleep @interval` between polling cycles. This is simple but means the daemon is unresponsive to signals during sleep. A 30-second interval means up to 30 seconds of latency for new work.
   - **Why It Matters**: Acceptable for current use. If lower latency is needed, a condition variable or IO.select-based approach would be more responsive.
   - **Recommendation**: Leave as-is. The Daemon is explicitly designed as a polling loop. If event-driven processing is needed, SSE integration (Phase 3 in the design doc) is the right solution, not optimizing the poll interval.

#### Initial Recommendations

1. **Make output_type explicit in all create_action callers** (Priority: Nice-to-Have, Effort: Small)
   - **What**: Require output_type to be set explicitly rather than inferred from derivation field presence
   - **Why**: Eliminates a coupling between field presence and semantic meaning
   - **How**: Add validation that rejects outputs without explicit output_type when derivation fields are also absent

---

### Marcus Johnson - Ruby Expert

**Perspective**: Ensures Ruby code is idiomatic and leverages the language's strengths. Watches for anti-patterns from other languages leaking in.

#### Current State Assessment

The code is idiomatic Ruby. Frozen string literals are universal. Keyword arguments are used consistently (no positional argument ambiguity). Module composition (Pushable, Fetchable, DisplayTxid) follows Ruby conventions. Error handling uses the exception hierarchy properly -- custom errors inherit from a base, carry domain data (required/available sats, balance/threshold).

The Sequel usage is clean: models are thin, migrations are declarative, and the Store uses raw datasets (`@db[:inputs]`) where joins are needed rather than fighting the ORM.

#### Strengths Identified

1. **Keyword arguments everywhere**: Every public method uses keyword args. This makes call sites self-documenting and prevents positional arg ordering bugs -- important for a wallet where passing the wrong amount to the wrong parameter is catastrophic.

2. **Module composition for cross-cutting concerns**: Pushable and Fetchable are mixins that add network interaction capability without inheritance. DisplayTxid adds `dtxid` to any model with a `wtxid` column. This is Ruby's strength -- composition over inheritance.

3. **Autoload for lazy loading**: Interface modules use `autoload` for deferred loading. This keeps startup fast and avoids loading unused code paths.

#### Concerns Raised

1. **Mixed hash key conventions in normalize_broadcast_response** (Impact: Low)
   - **Issue**: `normalize_broadcast_response` handles both string and symbol keys from external APIs (`'txid'`, `:txid`, `'txStatus'`, `:txStatus`). The `extract` helper iterates over possible key names. This is defensive but verbose.
   - **Why It Matters**: Each new API response format requires adding more key variants to the extraction list.
   - **Recommendation**: Normalize keys once at the ProtocolResponse boundary (convert all string keys to symbols, convert camelCase to snake_case) rather than handling every variant at each extraction point.

2. **Engine constructor has 8 parameters** (Impact: Low)
   - **Issue**: `Engine.new` takes 8 keyword arguments (store, utxo_pool, broadcast_queue, proof_store, key_deriver, chain_tracker, network_provider, network, limp_threshold). Four are required.
   - **Why It Matters**: The CLI.boot method shows the assembly complexity -- 15 lines to construct all components. This is manageable but grows with each new component.
   - **Recommendation**: This is acceptable for now. A builder pattern would add abstraction without adding value. The explicit construction is preferable.

#### Initial Recommendations

1. **Normalize API response keys at the boundary** (Priority: Nice-to-Have, Effort: Small)
   - **What**: Add key normalization (deep_symbolize + camelCase-to-snake_case) to ProtocolResponse construction
   - **Why**: Eliminates the multi-key extract pattern and makes normalization happen once
   - **How**: Add a `normalize_keys` method to ProtocolResponse that transforms the data hash on construction

---

### Dr. Lin Wei - Database Architect

**Perspective**: The database schema is the source of truth. Favors constraints over application-level validation, and structural queries over job queue tables.

#### Current State Assessment

The schema is well-designed. 16 tables with clear relationships. Foreign keys enforce referential integrity. `INSERT ON CONFLICT` on `inputs.output_id` provides atomic single-spend enforcement. The `spendable` table as a minimal index (~28 bytes/row) is an excellent pattern for the UTXO scan workload.

Migration 003 adds CHECK constraints: wtxid length = 32 bytes, satoshis >= 0, vout >= 0, sequence <= 4294967295. These catch data integrity violations at the database level regardless of application bugs.

The derived status pattern (no status column on actions) is the strongest design decision in the schema. Status columns inevitably drift from reality; structural state cannot.

#### Strengths Identified

1. **Constraint-driven data integrity**: CHECK constraints on binary field lengths, value ranges, and enum membership mean the database rejects invalid data regardless of which application path writes it.

2. **CASCADE delete for cleanup**: `inputs.action_id` has `ON DELETE CASCADE`. Aborting an action is a single DELETE on actions -- all input locks are released atomically. No orphan cleanup needed.

3. **Partial unique indexes**: `actions.wtxid` is `UNIQUE WHERE wtxid IS NOT NULL`. `baskets.name` is `UNIQUE WHERE deleted_at IS NULL`. These allow NULL values and soft deletes while maintaining uniqueness for active records.

#### Concerns Raised

1. **Spendable and output_baskets lack CASCADE** (Impact: Medium)
   - **Issue**: `spendable` and `output_baskets` have FK to `outputs` but no explicit `ON DELETE CASCADE` in the migration. The outputs table is documented as "never deleted," so this is consistent with the design. However, if an output is ever deleted (bug, manual intervention), orphan spendable/basket rows would remain.
   - **Why It Matters**: The immutability of outputs makes this safe in practice, but defense-in-depth suggests the FK should have CASCADE as a safety net.
   - **Recommendation**: Add `ON DELETE CASCADE` to spendable.output_id and output_baskets.output_id FKs. This is a no-op in normal operation but protects against manual corrections.

2. **No index on outputs.action_id** (Impact: Medium)
   - **Issue**: Several queries filter or join outputs by action_id (promote_action, query_change_output_vouts, promote_change_to_spendable, reap_stale_actions). The outputs table has a composite unique index on `[action_id, vout]` which covers equality lookups, but a standalone index on action_id would optimize the "all outputs for this action" pattern.
   - **Why It Matters**: The composite index on `[action_id, vout]` starts with action_id, so it does cover action_id-only lookups. This is a non-issue -- PostgreSQL can use the leading column of a composite index. Noting for completeness.
   - **Recommendation**: No action needed. The composite index covers it.

3. **Certificate fields stored as text, not bytea** (Impact: Low)
   - **Issue**: `certificate_fields.value` and `certificate_fields.master_key` are `:text` columns. BRC-52 certificate field values are encrypted ciphertext. The binary-first principle suggests these should be `:bytea`.
   - **Why It Matters**: Text columns with binary data can cause encoding issues. However, if the values come in as hex or base64 strings from the spec, text is correct.
   - **Recommendation**: Verify whether certificate field values are binary or text-encoded. If binary, migrate to bytea.

#### Initial Recommendations

1. **Add CASCADE to spendable and output_baskets FKs** (Priority: Nice-to-Have, Effort: Small)
   - **What**: Migration to add `ON DELETE CASCADE` to the output_id foreign keys
   - **Why**: Defense-in-depth against orphan rows if an output is ever manually deleted
   - **How**: `ALTER TABLE spendable DROP CONSTRAINT ..., ADD CONSTRAINT ... ON DELETE CASCADE`

---

### Dr. Kenji Nakamura - Cryptography Reviewer

**Perspective**: Reviews cryptographic code for correctness against specifications, not just "does it work." Insists on test vectors and binary-level verification.

#### Current State Assessment

All cryptographic operations (ECDSA signing, ECDH key exchange, AES-256-GCM encryption, HMAC-SHA256) delegate to the bsv-sdk. The wallet's KeyDeriver handles BRC-42/43 key derivation parameter construction but does not implement the curve operations itself.

The key_deriver_spec.rb (917 lines) covers derivation scenarios including self-derivation, counterparty derivation, privileged keys, and identity key extraction. The constant-time HMAC comparison in Engine is correctly implemented.

BEEF validation (`validate_beef!`) checks structural integrity and optionally verifies merkle roots against a chain tracker. The chain tracker is optional -- when absent, merkle roots are trusted (acceptable for self-generated transactions).

#### Strengths Identified

1. **Delegation to SDK for all crypto primitives**: No hand-rolled secp256k1, no custom AES implementation, no manual SHA256d. The attack surface is limited to key derivation parameter construction and data flow.

2. **Binary wtxid validation throughout**: `BSV::Primitives::Hex.validate_wtxid!` is called at every boundary -- Store, ProofStore, BroadcastQueue, Engine. This catches encoding errors early.

3. **Merkle path normalization handles multiple formats**: The `normalize_merkle_path` method correctly handles binary passthrough, hex string decoding, and TSC format conversion. This robustness is important when dealing with multiple network providers returning proofs in different formats.

#### Concerns Raised

1. **No chain tracker in CLI boot** (Impact: Medium)
   - **Issue**: `CLI.boot` does not construct or inject a `chain_tracker`. This means `validate_beef!` in `internalize_action` skips merkle root verification -- it only checks structural integrity.
   - **Why It Matters**: Without merkle root verification, a crafted BEEF with valid structure but invalid proofs would be accepted. The wallet would credit funds that are not actually confirmed on-chain.
   - **Recommendation**: Implement a chain tracker that verifies merkle roots against block headers from the network provider. Even a simple "fetch header for height, check merkle root" would close this gap.

2. **Fee in import_utxo is hardcoded to 1 sat** (Impact: Low)
   - **Issue**: `import_utxo` uses `fee = 1` for the self-payment. The comment says "token fee for no_send self-payment (BRC-67: inputs > outputs)." However, 1 sat may not be enough for actual broadcast if the transaction is ever sent.
   - **Why It Matters**: The self-payment is `no_send: true`, so it is never broadcast -- the fee is a BRC-67 compliance placeholder. If the design ever changes to broadcast self-payments, 1 sat would be insufficient.
   - **Recommendation**: Document that the 1-sat fee is intentional for no_send only. No code change needed.

#### Initial Recommendations

1. **Implement chain tracker for merkle root verification** (Priority: Important, Effort: Medium)
   - **What**: Create a ChainTracker that verifies block headers via the network provider
   - **Why**: Without it, internalize_action accepts structurally valid but unverified proofs
   - **How**: Implement `ChainTracker#verify_merkle_root(merkle_root, height)` that fetches the block header from WoC and compares merkle roots. Cache headers in the blocks table.

---

## Collaborative Synthesis

### Common Themes

**Strengths** (What multiple members praised):
1. **Interface-driven design with correct dependency direction** (Vasquez, Rahman, Johnson) -- the core/adapter gem split with abstract interfaces is the backbone of testability and extensibility
2. **Constraint-driven schema with derived status** (Wei, Thornton, Oduya) -- the database as source of truth eliminates state drift, and constraints catch bugs regardless of code paths
3. **Binary-first data handling** (Thornton, Nakamura, Okafor) -- consistent wtxid/dtxid convention with validation at every boundary prevents encoding errors
4. **SDK delegation for cryptographic operations** (Nakamura, Okafor) -- zero hand-rolled crypto, attack surface limited to parameter construction

**Concerns** (What multiple members flagged):
1. **Engine.rb size and scope** (Vasquez, Rahman, Petrov) -- at 1,708 lines, it mixes orchestration with transaction mechanics, BEEF assembly, and normalization
2. **Stubbed BRC-100 methods** (Thornton, Nakamura) -- get_height, get_header_for_height, discover_by_attributes, and certificate issuance are unimplemented
3. **Missing chain tracker** (Nakamura, Thornton) -- merkle root verification is skipped when no chain tracker is configured, weakening SPV validation of incoming transactions

**Disagreements** (Where members had different views):
- **Topic**: Engine constructor complexity (8 params)
  - **Johnson**: Noted but acceptable -- explicit construction is preferable to a builder
  - **Oduya**: Agrees -- a builder adds abstraction without value for a solo project
  - **Resolution**: Leave as-is. The 8 params reflect genuine dependencies, not over-engineering.

- **Topic**: Daemon sleep-based polling
  - **Petrov**: Could be more responsive with condition variables
  - **Oduya**: Sleep is fine -- SSE (Phase 3) is the real solution for low-latency
  - **Resolution**: Leave as-is. The polling loop is explicitly temporary until SSE integration.

### Prioritized Findings

**Critical (Address Immediately)**:
- None identified. The system is architecturally sound and operational. No security vulnerabilities requiring immediate remediation.

**Important (Address in Near Term)**:
1. **Extract transaction construction from Engine**: Reduces the largest coupling point in the system and enables focused testing of transaction mechanics
2. **Implement chain tracker for merkle root verification**: Closes an SPV validation gap in internalize_action
3. **Implement get_height/get_header_for_height**: Required for BRC-100 compliance and chain tracker support
4. **Add integration specs for Daemon polling lifecycle**: The Pushable/Fetchable pattern is architecturally significant but under-tested end-to-end

**Nice-to-Have (Consider for Future)**:
1. **Batch ancestor proof resolution**: Reduces BEEF construction from O(depth) queries to O(1)
2. **Split engine_spec.rb into domain-grouped files**: Improves test navigation
3. **Normalize API response keys at ProtocolResponse boundary**: Simplifies normalization code
4. **Add CASCADE to spendable/output_baskets FKs**: Defense-in-depth for manual data corrections

---

## Architectural Health Assessment

### Code Quality

**Rating**: 8/10

**Observations**:
- Consistent style throughout: frozen strings, keyword args, meaningful names
- DESIGN.md accurately reflects the code (rare for architecture docs)
- The wtxid/dtxid naming convention eliminates an entire class of encoding confusion
- Interface modules with YARD documentation serve as living contracts

**Key Issues**:
- Engine.rb at 1,708 lines is the primary code quality concern
- Some Store methods lack the step-by-step commenting found in build_funded_transaction

### Testing

**Coverage**: Estimated 70-80% (Codecov configured, exact number not checked)

**Rating**: 7/10

**Observations**:
- Healthy test-to-code ratio (1.6:1)
- Engine specs cover all BRC-100 methods with mock-based testing
- Postgres specs cover models, constraints, and store operations
- Integration tests exist for on-chain transactions (secrets-gated in CI)
- Spec extraction has begun (porcelain, limp mode) -- good pattern to continue

**Gaps**:
- Daemon polling lifecycle lacks end-to-end integration specs
- Pushable/Fetchable contract compliance tested via pushable_spec.rb and fetchable_spec.rb, but the actual entity implementations (Broadcast, Action) are less thoroughly tested for edge cases in write!
- No load/stress testing infrastructure

### Documentation

**Rating**: 8/10

**Observations**:
- DESIGN.md is comprehensive and accurate (533 lines covering all architectural decisions)
- CLAUDE.md has actionable project conventions
- Interface modules have thorough YARD documentation
- Commit messages follow conventional commits with issue references

**Missing**:
- No deployment/operations guide (acceptable -- it is a library gem)
- No API reference beyond YARD (BRC-100 spec serves this role)
- Key material lifecycle is undocumented

### Security

**Rating**: 7/10

**Observations**:
- All crypto delegates to SDK -- no hand-rolled implementations
- Constant-time HMAC comparison
- Database-enforced single-spend via UNIQUE constraint
- Binary data stays binary (no encoding-related injection vectors)
- BEEF structural validation present

**Concerns**:
- No merkle root verification without chain tracker
- Root key lives in process memory for process lifetime
- WIF loaded from environment variable
- No input size validation on locking scripts or BEEF payloads

### Performance

**Rating**: 7/10

**Observations**:
- 3-4 database round-trips per transaction creation (reasonable)
- Spendable table as a hot-set index is a strong optimization
- Three-tier UTXOPool design scales from single-user to high-throughput
- Recursive ancestor resolution is the main performance concern

**Concerns**:
- BEEF construction is O(depth) queries for unconfirmed chains
- find_or_create patterns are N+1 (low impact due to small N)
- change_output_count issues redundant balance/count queries

### Maintainability

**Rating**: 7/10

**Observations**:
- A newcomer with Ruby and BSV knowledge could understand the architecture from DESIGN.md + interface modules in under an hour
- The dependency injection pattern makes it clear how components fit together
- The plain-hash interface boundary means tests are fast and focused
- Convention documentation (CLAUDE.md) reduces ambiguity

**Challenges**:
- Engine.rb is the primary maintenance burden -- modifications require understanding the full 1,700-line context
- Engine spec at 2,743 lines is daunting for targeted debugging
- The wallet gem contains Services (SDK concern) which may require coordination across repos

---

## Technical Debt Inventory

### High Priority Debt

1. **Engine.rb scope creep**
   - **Impact**: Every new feature touches the most complex file in the project. Transaction construction, BEEF assembly, and normalization logic are not independently testable.
   - **Effort to Resolve**: Medium (extracting existing code to new classes, updating specs)
   - **Recommendation**: Extract before the next major feature addition. The longer Engine grows, the harder extraction becomes.

### Medium Priority Debt

1. **Stubbed BRC-100 methods**
   - **Impact**: Consumers expecting full BRC-100 compliance hit runtime errors on get_height, get_header_for_height, discover_by_attributes
   - **Effort to Resolve**: Small for get_height/get_header_for_height (delegate to network provider), Medium for discover_by_attributes (requires overlay network integration)
   - **Recommendation**: Implement the network-delegatable ones (get_height, get_header_for_height) in the near term. Document discover_by_attributes as a known limitation.

2. **Missing chain tracker**
   - **Impact**: internalize_action accepts structurally valid but unverified BEEF proofs
   - **Effort to Resolve**: Medium (implement ChainTracker, wire into CLI.boot, add to Engine constructor)
   - **Recommendation**: Implement alongside get_header_for_height -- they share the need for block header access.

### Low Priority Debt

1. **Services namespace**: Currently in wallet gem, belongs in SDK. Deferred until SDK interface settles.
2. **Certificate field column types**: May need migration from text to bytea depending on actual data format.
3. **Output type inference**: `promote_with_outputs` infers 'outbound' from field absence rather than explicit declaration.

---

## Risk Assessment

### Technical Risks

1. **SDK API instability** (Likelihood: Medium, Impact: High)
   - **Description**: The wallet depends on bsv-sdk for all cryptographic operations and transaction construction. SDK API changes require wallet-side updates.
   - **Impact**: Breaking SDK changes force coordinated updates across the monorepo
   - **Mitigation**: The two repos are developed in tandem. Interface modules insulate the engine from some SDK changes. Pin SDK versions.

2. **Single-developer bus factor** (Likelihood: Medium, Impact: High)
   - **Description**: One developer holds all context. No code review process.
   - **Impact**: Knowledge loss, code style drift, design regression
   - **Mitigation**: Comprehensive DESIGN.md, CLAUDE.md conventions, architecture framework with principles. These capture institutional knowledge in the repo.

3. **PostgreSQL-only persistence** (Likelihood: Low, Impact: Medium)
   - **Description**: While the interface allows alternative implementations, only PostgreSQL is implemented. Some schema patterns (pg_enum, bytea, partial unique indexes) are PostgreSQL-specific.
   - **Impact**: Porting to another database requires reimplementing the full Store
   - **Mitigation**: The interface module defines the contract. A new implementation would start from the interface, not from adapting PostgreSQL-specific SQL. This is acceptable for a system designed around PostgreSQL's strengths.

### Operational Risks

1. **No monitoring or alerting** (Likelihood: High, Impact: Medium)
   - **Description**: The Daemon logs errors but has no metrics emission, health checks, or alerting. A stalled daemon would go unnoticed.
   - **Impact**: Failed broadcasts or proof acquisitions could go undetected
   - **Mitigation**: Add health metrics to the Daemon (cycle count, last success time, error rate). Production deployment should include process supervision (systemd, supervisord).

2. **No backup/recovery strategy documented** (Likelihood: Medium, Impact: High)
   - **Description**: The PostgreSQL database IS the wallet. Loss of the database and the WIF means loss of funds.
   - **Impact**: Unrecoverable fund loss
   - **Mitigation**: Standard PostgreSQL backup practices (pg_dump, WAL archiving). WIF backup is the user's responsibility. Document the recovery procedure.

---

## Recommendations

### Immediate Actions (0-2 Weeks)

1. **Document key material lifecycle and recovery**
   - **Why**: The WIF is the wallet. No documentation exists for backup/recovery.
   - **How**: Add a "Security and Recovery" section to DESIGN.md covering key storage, backup requirements, and what is needed to restore a wallet.
   - **Owner**: Solo developer
   - **Success Criteria**: A reader can understand what to back up and how to restore
   - **Effort**: 2-4 hours

2. **Implement get_height and get_header_for_height**
   - **Why**: Required for BRC-100 compliance and chain tracker support
   - **How**: Add commands to the WhatsOnChain provider, delegate from Engine
   - **Owner**: Solo developer
   - **Success Criteria**: Both methods return data from the network provider with specs
   - **Effort**: 1-2 days

### Short-Term Actions (2-8 Weeks)

1. **Extract transaction construction from Engine**
   - **Why**: Largest coupling point in the system, blocks focused testing
   - **How**: Create TransactionBuilder, BeefAssembler as Layer 2a helpers. Move ~600 lines of private methods. Update engine specs to test extraction boundaries.
   - **Owner**: Solo developer
   - **Success Criteria**: Engine.rb < 1,000 lines, transaction construction tested in isolation
   - **Effort**: 1-2 weeks

2. **Implement chain tracker for SPV verification**
   - **Why**: internalize_action currently skips merkle root verification
   - **How**: ChainTracker backed by the blocks table, fetches headers from network provider. Wire into CLI.boot. Add verification specs.
   - **Owner**: Solo developer
   - **Success Criteria**: internalize_action verifies merkle roots against block headers
   - **Effort**: 1 week

3. **Split engine_spec.rb into domain-grouped files**
   - **Why**: 2,743-line spec file hinders navigation and targeted testing
   - **How**: Follow the existing extraction pattern (porcelain_spec.rb, limp_mode_spec.rb)
   - **Owner**: Solo developer
   - **Success Criteria**: No single spec file > 500 lines, shared_context covers common setup
   - **Effort**: 2-3 days

### Long-Term Initiatives (2-6 Months)

1. **Tier 2 UTXOPool (pre-split baskets)**
   - **Why**: Reduces contention for multi-consumer use cases
   - **How**: Implement basket-scoped UTXOPool with replenishment policy using existing basket schema columns (target_count, target_value)
   - **Owner**: Solo developer
   - **Success Criteria**: Dedicated baskets with automated replenishment, tested under concurrent access
   - **Effort**: 2-3 weeks

2. **Certificate issuance protocol**
   - **Why**: Currently raises UnsupportedActionError -- blocks certificate-based workflows
   - **How**: Implement the BRC-52 issuance exchange against a certifier URL
   - **Owner**: Solo developer
   - **Success Criteria**: Full certificate lifecycle (issuance, storage, revelation, relinquishment) working end-to-end
   - **Effort**: 2-4 weeks

3. **Move Services to SDK**
   - **Why**: BSV::Network::Services is a general-purpose routing layer, not wallet-specific
   - **How**: Coordinate with SDK repo, move Services + Provider + ProtocolResponse, update wallet to import from SDK
   - **Owner**: Solo developer
   - **Success Criteria**: Services lives in bsv-sdk, wallet depends on it via gem dependency
   - **Effort**: 1-2 weeks (mostly coordination)

---

## Success Metrics

1. **Engine.rb line count**
   - **Baseline**: 1,708 lines
   - **Target**: < 1,000 lines
   - **Timeline**: 8 weeks
   - **How to Measure**: `wc -l gem/bsv-wallet/lib/bsv/wallet/engine.rb`

2. **BRC-100 method completeness**
   - **Baseline**: 24/28 methods implemented (4 stubbed: get_height, get_header_for_height, discover_by_attributes, acquire_certificate :issuance)
   - **Target**: 27/28 (discover_by_attributes requires overlay network, acceptable as deferred)
   - **Timeline**: 4 weeks
   - **How to Measure**: Count methods that don't raise UnsupportedActionError or return empty

3. **Largest spec file**
   - **Baseline**: 2,743 lines (engine_spec.rb)
   - **Target**: < 500 lines per spec file
   - **Timeline**: 4 weeks
   - **How to Measure**: `wc -l gem/bsv-wallet/spec/bsv/wallet/engine_spec.rb`

4. **SPV verification coverage**
   - **Baseline**: Structural BEEF validation only (no merkle root checks)
   - **Target**: Full merkle root verification via chain tracker
   - **Timeline**: 6 weeks
   - **How to Measure**: chain_tracker parameter present in CLI.boot, verification specs passing

---

## Suggested Next Steps

Based on this initial analysis:

1. **Document key material lifecycle**: Quick win that addresses the highest operational risk
2. **Implement get_height/get_header_for_height**: Unblocks chain tracker and BRC-100 completeness
3. **Plan Engine extraction**: Scope the TransactionBuilder/BeefAssembler extraction as a feature branch
4. **Split engine_spec.rb**: Low-risk refactoring that immediately improves developer experience

**Documentation**:
- Create ADR for the Engine extraction decision (TransactionBuilder, BeefAssembler as Layer 2a helpers vs alternative approaches)
- Document the chain tracker design decision when implemented
- Architecture review framework is now set up -- use it for future reviews

**Process**:
- Establish review cadence: quarterly architecture review recommended
- Next review: after Engine extraction and chain tracker implementation (~8 weeks)
- Use specialist reviews for focused concerns (security review after chain tracker, performance review after Tier 2 UTXOPool)

---

## Appendix

### Analysis Methodology

This analysis was conducted using the AI Software Architect framework. Each of the nine team members analyzed the system from their specialized perspective, then findings were synthesized and prioritized collaboratively. The analysis examined:

- Source code across both gems (~4,900 lines library, ~8,000 lines specs)
- Database schema (16 tables, 4 migrations)
- CI configuration (5-version Ruby matrix, integration tests)
- Architecture documentation (DESIGN.md, CLAUDE.md, principles.md)
- Git history (commit patterns, recent feature work)

**Members Participating**:
- Dr. Elena Vasquez - Systems Architect
- James Thornton - BSV Domain Expert
- Nadia Okafor - Security Specialist
- Viktor Petrov - Performance Expert
- Aisha Rahman - Maintainability Expert
- Sam Oduya - Pragmatic Enforcer
- Marcus Johnson - Ruby Expert
- Dr. Lin Wei - Database Architect
- Dr. Kenji Nakamura - Cryptography Reviewer

### Glossary

- **BRC-100**: BSV Request for Comments #100 -- the wallet specification defining 28 methods for wallet operations
- **BRC-42/43**: Key derivation protocols using ECDH for deterministic child key generation
- **BEEF**: Background Evaluation Extended Format -- a binary format for transmitting transactions with their merkle proofs
- **SPV**: Simplified Payment Verification -- verifying transactions using merkle proofs without downloading the full blockchain
- **wtxid**: Wire-order transaction ID (32-byte binary, SHA256d of the transaction)
- **dtxid**: Display-order transaction ID (64-char hex, byte-reversed wtxid for human readability)
- **ARC**: Transaction processing service that accepts broadcasts and reports transaction status
- **UTXO**: Unspent Transaction Output -- the fundamental unit of Bitcoin value
- **Pushable/Fetchable**: Mixin modules enabling entities to declare their own network interaction semantics
- **Limp mode**: Wallet safety mode that blocks outbound operations when balance falls below a threshold

---

**Analysis Complete**
**Next Review**: 2026-07-15 (approximately 8 weeks -- after Engine extraction and chain tracker implementation)
