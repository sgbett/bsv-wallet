# Architectural Principles — bsv-wallet

## Universal Principles

### 1. Simplicity Over Cleverness
Solve the problem at hand, not hypothetical future problems. Three similar lines of code are better than a premature abstraction. Complexity must be justified by concrete requirements.

### 2. Separation of Concerns
Each module has one reason to change. The wallet gem defines interfaces and orchestration; the postgres gem implements persistence. Network routing is separate from entity lifecycle. CLI tools are thin wrappers over engine methods.

### 3. Testability by Design
Every component is testable in isolation. Store operations are transactional. Engine accepts pluggable dependencies. Daemon takes callable queries, not concrete models. Specs use transaction rollback, not teardown.

### 4. Security by Default
External input is hostile. Binary data stays binary internally — hex only at boundaries. Key material never appears in logs. Cryptographic operations use SDK primitives, never hand-rolled.

## Ruby-Specific Principles

### 5. Idiomatic Ruby
Use the language's strengths: modules for shared behavior (Pushable/Fetchable), Sequel for database operations, frozen string literals everywhere. Match existing code style before introducing new patterns.

### 6. Interface-Driven Design
Define contracts via Interface modules with NotImplementedError defaults. The wallet gem declares what's needed; the postgres gem provides implementations. Never depend upward — postgres depends on wallet, not vice versa.

## BSV/BRC-100 Principles

### 7. Specification Fidelity
BRC-100 defines the public API surface. Method names, parameter shapes, and return values match the specification. When the spec says `txid`, the code says `txid` with a boundary comment. American English follows the spec, not personal preference.

### 8. Binary Internally, Display at Boundaries
Wire-order `wtxid` (32-byte binary) inside the system. Display-order `dtxid` (64-char hex) at API boundaries, JSON output, and logs. No exceptions. The convention is documented in CLAUDE.md and enforced by naming.

### 9. The Database IS the State
Derived status comes from structural queries, not status columns. The query is the job queue — `needs_fetch?` derives pending work from column state. No separate job tables when the structure already encodes the information.

### 10. Entity Owns Its Behavior
Database entities declare their own network capabilities (Pushable/Fetchable). The entity knows what command to call, what to send, and how to write the response. Manager classes route and retry; they don't map fields.

## Persistence Principles

### 11. Constraints at the Schema Level
CHECK constraints, NOT NULL, and foreign keys enforce data integrity in PostgreSQL. Application-level validation is a convenience, not the authority. If a column must be 32 bytes, the schema says so.

### 12. Store Owns Atomicity
Multi-table transactions live inside Store methods. Engine never opens a transaction — it calls Store methods that handle their own atomicity. This keeps the transaction boundary clear and testable.

## Operational Principles

### 13. Replace, Don't Adapt
Architectural pivots are wholesale replacement, not incremental adaptation. Old code resists reshaping — a clean rewrite from the spec produces better results than patching assumptions into existing structures.

### 14. Git History Is Documentation
The repository is the project record. Every commit tells a story. Botched merges are permanent damage. Never merge without green CI and full confidence.
