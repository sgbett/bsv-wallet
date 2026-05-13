# Architecture Review: Chain Tracker Pivot

**Date**: 2026-05-13
**Review Type**: Feature
**Reviewers**: Dr. Elena Vasquez (Systems Architect), James Thornton (BSV Domain Expert), Nadia Okafor (Security Specialist), Viktor Petrov (Performance Expert), Aisha Rahman (Maintainability Expert), Sam Oduya (Pragmatic Enforcer), Marcus Johnson (Ruby Expert), Dr. Lin Wei (Database Architect), Dr. Kenji Nakamura (Cryptography Reviewer)

## Executive Summary

The chain tracker pivot is a high-leverage architectural change that replaces hand-rolled ancestry walking (`resolve_ancestor`, `validate_beef!`, `validate_fee_adequacy!`) with the SDK's existing `Transaction#verify(chain_tracker:)` method. A new `BSV::Network::ChainTracker` implementation bridges the SDK's declarative verification algorithm with the wallet's database (via the `blocks` table) and network services layer (via `BSV::Network::Services`).

This is not a feature addition — it is a correction. The wallet duplicated SDK logic without the verification guarantees. The plan eliminates that duplication, gains full SPV validation for incoming transactions, and establishes the `blocks` table as a self-populating header cache. The design is clean, the scope is contained, and the risk is manageable.

**Overall Assessment**: Strong

**Key Findings**:
- The plan correctly identifies that `Transaction#verify` already implements the exact tree walk the wallet was doing manually
- The write-through chain tracker pattern is the intended SDK integration point, well-documented in the SDK's own `ChainTracker` class comments
- Phase 1 (ProofStore at sign time) is a genuine prerequisite that closes an existing gap in unconfirmed-chaining support

**Critical Actions**:
- Verify that `replace_known_ancestors!` after `from_binary` does not break `Transaction#verify` when TXID-only entries exist at non-terminal positions in the ancestry graph
- Confirm SDK `Transaction#verify` behavior when `source_transaction` is nil on an unproven ancestor's input (`:missing_source` error path)

---

## System Overview

**Feature**: Chain tracker pivot — replace manual ancestry walking with SDK `Transaction#verify`
**Scope**: Wallet engine BEEF construction and verification paths, new `BSV::Network::ChainTracker` class
**Technologies**: Ruby, Sequel/PostgreSQL, BSV Ruby SDK (Transaction, Beef, MerklePath, ChainTracker)
**Architecture style**: Four-layer SOA (operational → services → BRC-100 → consumer)
**Constraints**: Pre-1.0, no release, American English, binary-internally convention

---

## Individual Member Reviews

### Dr. Elena Vasquez — Systems Architect

**Perspective**: Evaluates whether the system's layers and boundaries serve its evolution. Focuses on interface stability and dependency direction.

#### Key Observations
- The chain tracker is the keystone of a clean three-layer integration: SDK (algorithm) ↔ ChainTracker (bridge) ↔ Database + Network (data)
- Dependency direction is correct: wallet gem depends on SDK interfaces, never the reverse
- The `BSV::Network::ChainTracker` namespace follows the established pattern where network infrastructure uses the SDK namespace but lives in the wallet gem
- Engine's role simplifies to pure orchestration — wire data, call SDK, persist results

#### Strengths
1. **Interface alignment**: The SDK's `ChainTracker` base class was designed for exactly this injection pattern. The wallet finally uses it as intended.
2. **Layer discipline**: `wire_ancestor` has zero Store dependencies — it queries ProofStore only. The old `resolve_ancestor` crossed the Store/ProofStore boundary with `find_action` + `resolve_inputs_for_signing`.
3. **Principle 13 adherence**: This is a clean replacement, not an adaptation. Dead code is deleted, not deprecated.

#### Concerns
1. **Engine still owns BEEF construction** (Impact: Low)
   - **Issue**: `build_atomic_beef` is engine logic that calls SDK's `Beef.new.merge_transaction`. This is orchestration, which is the engine's job — but it blurs the line between "tell the SDK what to do" and "assemble SDK objects."
   - **Why it matters**: Future refactors (e.g., BEEF as a first-class service object) would need to extract this.
   - **Recommendation**: Accept for now. The method is 10 lines and purely mechanical. Extracting it would be speculative.

2. **`verify_incoming_transaction!` hard-requires chain_tracker** (Impact: Medium)
   - **Issue**: If `@chain_tracker` is nil, `internalize_action` raises immediately. The current code gracefully degrades (structural validation only).
   - **Why it matters**: Tests and development environments that don't configure a chain tracker will fail to internalize any actions.
   - **Recommendation**: This is intentional and correct — fail closed is the right default for a wallet. But ensure test helpers provide a mock chain tracker easily. Document this as a breaking change for Engine consumers.

#### Recommendations
1. **Ensure Engine constructor documents chain_tracker as effectively required** (Priority: Medium, Effort: Small)
   - **What**: Update the `initialize` docstring to note chain_tracker is required for `internalize_action`
   - **Why**: Prevents confusion when callers omit it and get `InvalidBeefError`
   - **How**: Doc comment update, no code change

---

### James Thornton — BSV Domain Expert

**Perspective**: Guards specification fidelity. Every architectural decision is evaluated against what BRC-100 requires and what the BSV protocol permits.

#### Key Observations
- `Transaction#verify` implements BRC-67 SPV verification as specified — the wallet should have been using it from the start
- The chain tracker's `valid_root_for_height?` is the BRC-67 trust model: you trust whoever provides your block headers
- `replace_known_ancestors!` correctly implements the BRC-100 `trustSelf` / `known_txids` semantics — ancestors known to the receiver are omitted from re-verification
- The output ≤ input check in SDK verify subsumes `validate_fee_adequacy!` with an important difference: SDK checks ALL inputs, the wallet's version skipped inputs without `source_transaction`

#### Strengths
1. **Spec alignment**: Using the SDK's verify means the wallet inherits any future BRC-67/BRC-95 compliance fixes automatically.
2. **Correct trust model**: The chain tracker is the explicit trust boundary — who provides block headers determines the wallet's SPV trust.
3. **Script verification gained**: Incoming transactions now have their unlocking scripts executed. This catches invalid scripts that the current structural-only validation misses entirely.

#### Concerns
1. **TXID-only ancestry gap under verify** (Impact: High)
   - **Issue**: When `replace_known_ancestors!` converts ancestors to TXID-only, those Transaction objects are removed from the BEEF's list. However, `from_binary`'s `wire_source_transactions` already wired `source_transaction` pointers before replacement happened. The concern is: do those in-memory Transaction objects survive `make_txid_only`? Analysis shows they should (Ruby GC won't collect referenced objects), but this is the riskiest assumption in the plan.
   - **Why it matters**: If `source_transaction` pointers are invalidated, `verify` would raise `:missing_source` for ancestors the wallet legitimately trusts.
   - **Recommendation**: Write an explicit integration test: parse BEEF, replace known ancestors, call verify, confirm it succeeds. This is the single most important test for the pivot.

2. **Coinbase maturity check in `MerklePath#verify`** (Impact: Low)
   - **Issue**: The SDK's `MerklePath#verify` checks coinbase maturity: `current_height - block_height >= 100`. This calls `chain_tracker.current_height`, which makes a network call. If the wallet handles any coinbase-adjacent transactions, this adds latency.
   - **Why it matters**: Unlikely in practice (wallets rarely handle coinbase outputs directly), but worth noting.
   - **Recommendation**: No action needed. The `current_height` call is rare and the result can be cached with a short TTL if it becomes an issue.

#### Recommendations
1. **Write TXID-only + verify integration test** (Priority: Critical, Effort: Small)
   - **What**: Test that `from_binary` → `replace_known_ancestors!` → `verify` works correctly
   - **Why**: This is the highest-risk assumption in the plan
   - **How**: Build a BEEF with known ancestors, replace them, verify the subject

---

### Nadia Okafor — Security Specialist

**Perspective**: Treats every external input as hostile and every key operation as a potential leak.

#### Key Observations
- The pivot ADDS security: incoming transactions now undergo full script verification, not just structural validation
- Fail-closed semantics throughout: network failure → false → verification fails → BEEF rejected
- The chain tracker is a trust boundary — its correctness determines SPV security
- No new key material handling — this touches proof/header data only

#### Strengths
1. **Defense in depth gained**: Script verification on incoming BEEF catches malformed unlocking scripts, invalid signatures, and other attacks that structural validation alone cannot detect.
2. **Fail-closed by default**: The chain tracker returns `false` on any error. No path exists where a network failure results in accepting unverified data.
3. **No new attack surface**: The chain tracker only reads from DB and fetches block headers. Block headers are public data — no sensitive information in the fetch path.

#### Concerns
1. **Block header poisoning** (Impact: Medium)
   - **Issue**: If the network services layer returns a falsified block header (compromised provider), the chain tracker would persist and trust it. Future verifications against that block would pass with the poisoned root.
   - **Why it matters**: A poisoned header enables accepting fraudulent merkle proofs for that block.
   - **Recommendation**: Mitigated by the Services routing layer's multi-provider fallback — a single compromised provider is bypassed if others disagree. For defense in depth, consider validating header proof-of-work in a future enhancement (block headers contain the nBits difficulty target). Not required for this pivot.

2. **`StandardError` rescue breadth** (Impact: Low)
   - **Issue**: `valid_root_for_height?` rescues `StandardError`, which catches everything including `NoMethodError`, `TypeError`, etc. These could mask genuine bugs.
   - **Why it matters**: A bug in the chain tracker implementation would silently cause all verifications to fail (returning false), which is safe but hard to diagnose.
   - **Recommendation**: Consider rescuing more specific exceptions (network errors, Sequel errors). Or at minimum, log at `warn` level (which the plan already does). The fail-closed behavior means this is a diagnostic issue, not a security issue.

#### Recommendations
1. **Narrow the rescue clause** (Priority: Low, Effort: Small)
   - **What**: Rescue `Sequel::Error, Net::OpenTimeout, Errno::ECONNREFUSED, IOError` instead of `StandardError`
   - **Why**: Prevents masking implementation bugs while still handling expected failures
   - **How**: Enumerate known failure modes in the rescue clause

---

### Viktor Petrov — Performance Expert

**Perspective**: Asks "what happens at 10x scale?" for every design. Focuses on database round-trips, memory allocation, and algorithmic complexity.

#### Key Observations
- `wire_ancestor` makes exactly the same number of ProofStore queries as `resolve_ancestor`, MINUS the Store queries (`find_action`, `resolve_inputs_for_signing`). Net improvement.
- `blocks` table lookups are PK-indexed (`height UNIQUE`) — O(1) in PostgreSQL's buffer cache
- The write-through cache means repeated verifications against the same block are local. The hot working set of blocks converges quickly.
- `Transaction#verify` parses raw_tx into Transaction objects at every call — these are transient and GC'd after verification

#### Strengths
1. **Fewer DB round-trips**: `wire_ancestor` eliminates 2 queries per unconfirmed ancestor compared to `resolve_ancestor` (no `find_action`, no `resolve_inputs_for_signing`).
2. **Self-warming cache**: The `blocks` table naturally fills with every verification. After initial warm-up, nearly all `valid_root_for_height?` calls are local DB hits.
3. **No new hot paths**: The chain tracker is only exercised during `internalize_action` (incoming). Outgoing BEEF construction skips verification entirely.

#### Concerns
1. **Repeated raw_tx parsing in `wire_ancestor`** (Impact: Low)
   - **Issue**: Each `wire_ancestor` call parses `raw_tx` via `Transaction.from_binary`. For deep unconfirmed chains, the same ancestor might be parsed multiple times across different call paths (though the `visited` set prevents re-entry within a single walk).
   - **Why it matters**: Transaction parsing allocates objects. For typical chains (1-2 unconfirmed ancestors), this is negligible. For pathological chains (10+ unconfirmed), it's measurable.
   - **Recommendation**: No action needed. The `visited` set ensures each wtxid is processed once per walk. Deep unconfirmed chains are rare and indicate the wallet should be waiting for confirmations.

2. **Network latency in verification hot path** (Impact: Medium)
   - **Issue**: On the first `internalize_action` from a new block, the chain tracker makes a synchronous HTTP call to fetch the header. This blocks the entire verification.
   - **Why it matters**: If multiple transactions from the same new block arrive simultaneously, only the first incurs the fetch. But that first one sees full HTTP latency.
   - **Recommendation**: Acceptable. BSV blocks are ~10 minutes apart. The first internalization per block pays the cost; all subsequent ones are cached. If this becomes an issue, pre-fetch headers from broadcast responses (which include `block_height`).

#### Recommendations
1. **Pre-populate blocks from broadcast responses** (Priority: Low, Effort: Small)
   - **What**: When `handle_proof_from_broadcast` receives a merkle_path with `block_height`, also save the block header
   - **Why**: Avoids the first-verification fetch for blocks containing our own transactions
   - **How**: ProofStore.save_proof already calls `find_or_create_block` — verify this populates `merkle_root`

---

### Aisha Rahman — Maintainability Expert

**Perspective**: Evaluates whether a newcomer could understand, modify, and extend the code with confidence.

#### Key Observations
- `wire_ancestor` is dramatically simpler than `resolve_ancestor`: 15 lines vs 45 lines, single code path vs three conditional branches
- The error propagation table in the plan is excellent documentation — every SDK error code mapped to its wallet wrapper
- Deleting four methods and replacing them with two is a net reduction in surface area
- The plan clearly states "no verify on outgoing" — this decision is load-bearing and should be commented in code

#### Strengths
1. **Radical simplification**: `wire_ancestor` has one job — load from ProofStore and attach. No conditional logic, no fallback paths, no cross-concern queries.
2. **SDK as the authority**: By delegating verification to the SDK, the wallet no longer needs to maintain its own understanding of "what constitutes valid." Spec changes are absorbed by SDK updates.
3. **Clear error wrapping**: `verify_incoming_transaction!` catches SDK exceptions and wraps them, preserving the wallet's public error contract.

#### Concerns
1. **"No verify on outgoing" needs code-level justification** (Impact: Medium)
   - **Issue**: The plan states outgoing BEEF is not verified because "we trust our own construction." This is a deliberate asymmetry that will puzzle future maintainers unless documented at the call site.
   - **Why it matters**: A future developer might add a verify call to `build_atomic_beef` for "safety," introducing unnecessary network calls and potential failures.
   - **Recommendation**: Add a comment at the `build_atomic_beef` call site explaining why outgoing BEEF is not verified.

2. **Test strategy needs the TXID-only edge case** (Impact: High)
   - **Issue**: Same as James Thornton's concern. The testing strategy lists 6 areas but doesn't explicitly call out the `replace_known_ancestors!` → `verify` interaction as its own test case.
   - **Why it matters**: This is the highest-risk behavior change and needs its own focused test.
   - **Recommendation**: Add it as testing strategy item 7.

#### Recommendations
1. **Comment the outgoing non-verification decision** (Priority: Medium, Effort: Small)
   - **What**: Add a brief comment at `build_atomic_beef` explaining why verify is not called
   - **Why**: Prevents well-intentioned future additions from breaking the pattern
   - **How**: One-line comment: `# Outgoing BEEF: constructed from our own ProofStore, verification is for incoming untrusted data only`

---

### Sam Oduya — Pragmatic Enforcer

**Perspective**: Challenges every abstraction with "do we need this today?" Protects against speculative design and premature optimization.

#### Key Observations
- This pivot REMOVES complexity — it deletes more code than it adds. That's the rarest and best kind of architectural change.
- The plan explicitly defers Fetchable integration on Block ("simpler, and the Fetchable pattern is designed for daemon-driven polling"). Good judgment.
- No new abstractions introduced — `wire_ancestor` is a plain method, `ChainTracker` inherits an existing SDK class, `verify_incoming_transaction!` is 5 lines.
- The sequencing is linear and each phase is independently testable.

#### Strengths
1. **Net negative complexity**: Four methods deleted, two added. The new methods are simpler than what they replace.
2. **No speculative features**: The plan doesn't add "optional verification on outgoing" or "configurable verification levels" or any other future-proofing noise.
3. **Clean prerequisite**: Phase 1 (ProofStore at sign time) fixes an existing gap, not a speculative one. Without it, `wire_ancestor` can't replace the action-lookup fallback.

#### Concerns
1. **None substantive**. This is exactly the kind of change that should be made: recognizing that existing code reimplements something the dependency already provides, and cutting over. The plan is scoped tightly and doesn't smuggle in unrelated improvements.

#### Recommendations
1. **Ship it** (Priority: High, Effort: Medium)
   - **What**: Implement as planned
   - **Why**: Every day this doesn't land is a day incoming BEEFs aren't script-verified
   - **How**: Follow the sequencing in the plan

**Pragmatic Analysis**: Complexity ratio < 0.5 (more deleted than added). No YAGNI violations detected. All six phases serve the stated goal with no scope creep.

---

### Marcus Johnson — Ruby Expert

**Perspective**: Ensures Ruby code is idiomatic and leverages the language's strengths.

#### Key Observations
- `wire_ancestor` uses idiomatic Ruby: guard clause returns, recursive default parameters (`visited: Set.new`), block-form logging
- The ChainTracker class follows Ruby subclassing conventions correctly (calling `super()` implicitly via inheritance)
- `rescue StandardError => e` followed by `false` is a common Ruby pattern for fail-closed operations
- The `Sequel.blob()` wrapper for binary data is correct for PostgreSQL bytea columns

#### Strengths
1. **Idiomatic simplification**: `wire_ancestor` reads naturally — guard, load, branch on proven/unconfirmed, return. No cleverness.
2. **Correct Sequel usage**: `insert_conflict(target: :height)` is the right Sequel API for `ON CONFLICT DO NOTHING`.
3. **Module discipline**: ChainTracker lives in its own file under `BSV::Network::`, consistent with existing naming.

#### Concerns
1. **`unpack1('H*').downcase` comparison** (Impact: Low)
   - **Issue**: The hex comparison in `valid_root_for_height?` converts binary to hex, lowercases, then compares. The SDK passes `root` as hex already. This works but does string comparison on 64-char strings.
   - **Why it matters**: Binary comparison would be more efficient (32 bytes vs 64 chars) and more consistent with the wallet's "binary internally" principle.
   - **Recommendation**: Compare in binary: `block[:merkle_root] == [root].pack('H*')`. Faster and more consistent.

#### Recommendations
1. **Binary comparison for merkle roots** (Priority: Low, Effort: Small)
   - **What**: Compare `block[:merkle_root] == [root].pack('H*')` instead of hex string comparison
   - **Why**: Consistent with binary-internally principle, marginally faster
   - **How**: `[root].pack('H*')` converts the SDK's hex root to binary for direct comparison

---

### Dr. Lin Wei — Database Architect

**Perspective**: The database schema is the source of truth. Favors constraints over application-level validation.

#### Key Observations
- The `blocks` table already exists with correct constraints (height UNIQUE, merkle_root NOT NULL, CHECK length = 32)
- `INSERT ... ON CONFLICT (height) DO NOTHING` is correct — block headers are immutable, first-writer-wins is safe
- ProofStore.save_proof already calls `find_or_create_block` internally — the chain tracker's write path is complementary, not duplicative
- No migration needed — a significant advantage

#### Strengths
1. **Schema reuse**: The blocks table was designed for this exact use case (PR #80). No schema changes required.
2. **Idempotent writes**: `ON CONFLICT DO NOTHING` means concurrent verifications for the same block height are safe without locking.
3. **Minimal footprint**: One row per block (~80 bytes). Even covering the entire BSV blockchain history (~900k blocks) would be under 100MB.

#### Concerns
1. **Dual write paths for blocks** (Impact: Low)
   - **Issue**: Both `ProofStore.save_proof` (via `find_or_create_block`) and `ChainTracker.persist_block` write to the `blocks` table. Two code paths, same table.
   - **Why it matters**: If the block data format differs between paths (e.g., one provides `block_hash`, the other doesn't), the first writer wins and the second's data is lost.
   - **Recommendation**: This is acceptable — both paths write the same data (height, merkle_root, optionally block_hash). `ON CONFLICT DO NOTHING` ensures consistency. If the first writer provided merkle_root but not block_hash, a later writer with block_hash won't update it. This is a minor data completeness issue, not a correctness issue. Consider `ON CONFLICT DO UPDATE SET block_hash = EXCLUDED.block_hash WHERE blocks.block_hash IS NULL` if block_hash is needed.

#### Recommendations
1. **Consider `ON CONFLICT DO UPDATE` for nullable columns** (Priority: Low, Effort: Small)
   - **What**: Update block_hash if the existing row has NULL and the new write provides a value
   - **Why**: Maximizes data completeness from multiple write paths
   - **How**: `ON CONFLICT (height) DO UPDATE SET block_hash = EXCLUDED.block_hash WHERE blocks.block_hash IS NULL`

---

### Dr. Kenji Nakamura — Cryptography Reviewer

**Perspective**: Reviews cryptographic code for correctness against specifications, not just "does it work."

#### Key Observations
- The chain tracker does not perform any cryptographic operations itself — it delegates entirely to the SDK's `MerklePath#verify` (which computes SHA256d pairs up the merkle tree)
- The SDK's `Transaction#verify` runs the Bitcoin script interpreter on every input — this is the correct and most thorough verification possible
- The write-through cache for block headers creates a local trust anchor — the wallet builds its own view of the blockchain over time

#### Strengths
1. **No new crypto code**: The wallet adds zero cryptographic operations. All merkle root computation, script execution, and signature verification happens in the SDK. This is exactly right — crypto belongs in the SDK.
2. **Correct trust boundary**: The chain tracker is the explicit point where "who do I trust for block headers?" is answered. This is the SPV trust model from Satoshi's whitepaper, implemented correctly.
3. **Script verification adds protection**: Full script execution catches malleated transactions, invalid signatures, and other attacks invisible to structural-only validation.

#### Concerns
1. **No header proof-of-work validation** (Impact: Low)
   - **Issue**: The chain tracker trusts whatever the network returns as a valid header. It does not verify that the header satisfies the proof-of-work difficulty target.
   - **Why it matters**: A compromised or malicious provider could serve a fabricated header with a valid-looking merkle root but insufficient proof-of-work.
   - **Recommendation**: Mitigated by multi-provider routing in Services. For full SPV security, future work could validate nBits/difficulty from the 80-byte header. Not required for this pivot — the current SDK chain trackers (WhatsOnChain, Chaintracks) also trust their providers.

#### Recommendations
1. **Header PoW validation as future enhancement** (Priority: Low, Effort: Medium)
   - **What**: Validate block header proof-of-work when fetching from network
   - **Why**: Defense against header fabrication from compromised providers
   - **How**: Parse full 80-byte header, verify SHA256d < target. Deferred — not in scope for this pivot.

---

## Collaborative Discussion

**Dr. Vasquez**: "This is one of those rare changes where removing code makes the system both simpler and more correct. The SDK was designed with this injection pattern in mind — we're finally using it."

**James Thornton**: "Agreed. My only concern is the `replace_known_ancestors!` interaction with `verify`. The in-memory graph should survive the BEEF list mutation, but we must prove it with a test. That's the single highest-risk assumption."

**Nadia Okafor**: "From a security perspective, this is strictly additive. We gain script verification on every incoming input. The fail-closed chain tracker means no degradation path exists. My `StandardError` rescue concern is cosmetic."

**Viktor Petrov**: "Performance-neutral at worst, slightly better in practice due to fewer DB round-trips. The network latency on first-block verification is real but acceptable — one HTTP call per 10-minute block."

**Aisha Rahman**: "The code reduction is remarkable. `wire_ancestor` is self-explanatory in a way `resolve_ancestor` never was. My only ask: comment the 'no verify on outgoing' decision at the call site."

**Sam Oduya**: "Net negative complexity. No speculative abstractions. Ship it."

**Dr. Nakamura**: "The crypto story is clean — the wallet adds no crypto, the SDK handles everything. The trust boundary is explicit and correct."

**Marcus Johnson**: "One small style note — binary comparison instead of hex in the chain tracker. But that's a one-line change."

**Dr. Wei**: "Schema-wise, this is a perfect fit. The blocks table was built for this. My dual-write-path concern is minor."

### Common Ground

The team agrees on:
1. The pivot is a correctness improvement disguised as a simplification — it should be implemented
2. The `replace_known_ancestors!` → `verify` interaction is the highest-risk behavior and needs an explicit integration test
3. No speculative features should be added (no outgoing verification, no Fetchable on Block, no header PoW validation)

### Areas of Debate

**Topic: Should outgoing BEEF be verified?**
- **Vasquez**: "No. We built it from our own data. Verifying it adds network calls and failure modes for no security benefit."
- **Thornton**: "Agree. BRC-100 doesn't require self-verification of outgoing transactions."
- **Okafor**: "Agree on the security analysis. Our own ProofStore is trusted."
- **Resolution**: No outgoing verification. Document the decision at the call site.

**Topic: `StandardError` rescue breadth**
- **Okafor**: "Narrower rescue would help diagnose bugs."
- **Oduya**: "The current behavior is safe (fail closed). Narrowing the rescue is a refinement, not a requirement. Ship first, refine if diagnostics prove difficult."
- **Resolution**: Ship with `StandardError`, refine if needed. The `warn` logging provides adequate diagnostics.

### Priorities Established

**Critical (Address During Implementation)**:
1. Write integration test for `replace_known_ancestors!` → `verify` interaction
2. Comment the "no verify on outgoing" decision at the `build_atomic_beef` call site

**Important (Address Soon After)**:
1. Use binary comparison in `valid_root_for_height?` instead of hex
2. Update Engine constructor docs to note chain_tracker is effectively required

**Nice-to-Have (Consider Later)**:
1. `ON CONFLICT DO UPDATE` for block_hash completeness
2. Narrower rescue clause in chain tracker
3. Header PoW validation (future enhancement)

---

## Consolidated Findings

### Strengths

1. **SDK alignment**: Uses the SDK's verification algorithm as intended, eliminating duplicated tree-walking logic
2. **Net negative complexity**: Deletes four methods (resolve_ancestor, collect_input_ancestry, validate_beef!, validate_fee_adequacy!), adds two simpler ones (wire_ancestor, verify_incoming_transaction!)
3. **Security improvement**: Gains full script verification on incoming transactions — a capability gap the wallet has had since inception
4. **Self-populating cache**: The blocks table fills naturally through verification, becoming more self-sufficient over time
5. **Clean architecture**: ChainTracker as the bridge between SDK (algorithm), database (persistence), and network (data acquisition)

### Areas for Improvement

1. **Test coverage for TXID-only + verify interaction**:
   - **Current state**: Untested assumption
   - **Desired state**: Explicit integration test
   - **Priority**: High

2. **Code documentation at decision points**:
   - **Current state**: Decision documented in plan only
   - **Desired state**: Comments at call sites explaining asymmetric verify behavior
   - **Priority**: Medium

### Technical Debt

**Resolved by this pivot**:
- Manual ancestry walking duplicating SDK logic — **eliminated**
- Missing SPV script verification on incoming transactions — **fixed**
- Nil chain_tracker silently skipping merkle verification — **fixed** (now fail-closed)

### Risks

**Technical Risks**:
- **TXID-only + verify interaction** (Likelihood: Low, Impact: High)
  - **Description**: If `make_txid_only` invalidates in-memory `source_transaction` pointers, verify would fail on legitimate trusted ancestors
  - **Mitigation**: Integration test before merge. Ruby's GC won't collect referenced objects, so pointers should survive.

---

## Recommendations

### Immediate (During Implementation)

1. **TXID-only integration test**
   - **Why**: Highest-risk assumption in the plan
   - **How**: Build BEEF → parse → replace known ancestors → verify → assert success
   - **Success Criteria**: Test passes with replaced ancestors

2. **Comment outgoing non-verification**
   - **Why**: Load-bearing decision that future maintainers need to understand
   - **How**: One-line comment at `build_atomic_beef` call site

### Short-term (Post-Merge)

1. **Binary comparison in chain tracker**
   - **Why**: Consistent with binary-internally principle
   - **How**: `block[:merkle_root] == [root].pack('H*')`

2. **Pre-populate blocks from broadcast responses**
   - **Why**: Avoid first-verification network fetch for our own blocks
   - **How**: Verify that `find_or_create_block` in ProofStore already handles this

---

## Success Metrics

1. **Code reduction**: `resolve_ancestor` + `validate_beef!` + `validate_fee_adequacy!` + `collect_input_ancestry` deleted (net ~-80 lines)
2. **Verification coverage**: 100% of incoming BEEFs undergo script verification (currently 0%)
3. **Block header cache hit rate**: >95% after warm-up period (measurable via logger output)

---

## Follow-up

**Next Review**: After implementation, verify against HLR #95 acceptance criteria

**Tracking**: HLR sgbett/bsv-wallet#95

**Related**:
- Issue #79 — blocks table normalization (merged in #80)
- Issue #77 — network services architecture (parent)
- Plan: `.claude/plans/20260513-chain-tracker-pivot.md`

---

## Appendix

### Review Methodology

This review was conducted using the AI Software Architect framework with all 9 team members reviewing independently, then collaborating to synthesize findings and prioritize recommendations.

**Pragmatic Mode**: Enabled (Balanced)
- Complexity ratio: < 0.5 (more deleted than added)
- All recommendations evaluated through YAGNI lens — no speculative features approved

### Glossary

- **BEEF**: Background Evaluation Extended Format — container bundling transactions with merkle proofs for SPV verification
- **SPV**: Simplified Payment Verification — verifying transactions using block headers without downloading full blocks
- **BRC-100**: BSV Request for Comments #100 — the wallet specification defining 28 standard methods
- **ChainTracker**: SDK interface for block header lookups, injected into verify methods
- **wire_ancestor**: New method that loads a transaction from ProofStore and attaches it to the input graph
- **resolve_ancestor**: Old method being replaced — manual ancestry walking with action lookups

---

**Review Complete**
