# Copilot Code Review Instructions

## Project Context

bsv-wallet is a Ruby BRC-100 wallet implementation — the layer that manages UTXO lifecycle, transaction construction, broadcasting, and proof management for BSV applications. It delegates all cryptographic operations (signing, key derivation, ECDSA, script interpretation) to the `bsv-ruby-sdk` gem. The wallet itself handles **state transitions** and **data integrity**: which outputs are spendable, which inputs are locked, which transactions are proven, and which proofs are valid.

**Canonical references (defer to these; this file is review guidance, not the source of truth — do not contradict them):** `reference/principle-of-state.md` (state is *read*, not stored — no status columns), `reference/state-representations.md` (the per-element A–F conformance register — e.g. promotion is a `promotions` *row*, not an `outputs.promoted` flag), `reference/state-boundaries.md` (stateless SDK / stateful wallet), `reference/createaction-lifecycle.md` (the action state machine: states-as-predicates + the per-transition validation matrix).

### Layers

The wallet is laid out as four collaborating layers. Engine-level "logical models" (`Engine::Broadcast`, `Engine::TxProof`) hold behavior; Store-level Sequel models hold data. The split is intentional — see `reference/schema-intent.md`.

- **`BSV::Wallet::Engine`** — Layer 3 orchestrator for the 28 BRC-100 methods. Pure logic, no SQL, no network I/O. Drives the 4-phase action lifecycle and dispatches to the domain collaborators below plus `Engine::Broadcast` / `Engine::TxProof` for OMQ-shaped background work. (The funding / construction / BEEF logic that once lived inline on `Engine::Action` was extracted into the collaborators below per #290/#291 — ADR-024.)
- **`Engine::FundingStrategy` · `Engine::TxBuilder` · `Engine::Hydrator` · `Engine::BeefImporter`** — Layer 3 domain collaborators extracted from `Engine::Action` (#291), each DI'd with an `Interface::` contract:
  - **`FundingStrategy`** — input acquisition: selection + the bounded retried `Store#lock_inputs` (initial + top-up), and the fee-fixpoint loop. Owns the lock lifecycle (#323, absorbs #213).
  - **`TxBuilder`** — **store-free** transaction construction: `build` / `build_change` (change derivation + fee fixpoint) / `apply_spends` (deferred-sign finalise). Takes a *resolved* input set by value; signs. "The transaction builder signs." (#336)
  - **`Hydrator`** — store-reading egress: `wire_ancestor` (recursive ProofStore→Tx ancestor wiring), `build_atomic_beef`, `validate_for_handoff!` (SPV self-verify before shipping). (#343)
  - **`BeefImporter`** — store-reading ingress: `import` (parse → trustSelf hydrate → **SPV verify** → persist → promote) of incoming *untrusted* BEEF; consumes `Hydrator#wire_ancestor` one-way. (#357)
- **`BSV::Wallet::Engine::Broadcast`** — logical model wrapping a `broadcasts` row. Lifecycle: `submit` (inline POST to ARC) and `poll_status` (delayed-broadcast catch-up). The OMQ entry points (`pull!`, `reply!`) are how the daemon's scheduler dispatches work. Outcome categorization (`categorize_outcome`, `categorize_reason`) lives here.
- **`BSV::Wallet::Engine::TxProof`** — logical model wrapping a `tx_proofs` row. Lifecycle: `pull!` ingests proofs from ARC/network, normalizes merkle paths (binary / hex / TSC), and links proofs back to actions.
- **`BSV::Wallet::Store`** — Layer 2a persistence. Owns multi-table atomicity (`@db.transaction do ... end`); never exposed to the Engine as Sequel models. **Postgres is the primary backend** (`bytea`, native `uuid`, ENUM types, CHECK constraints, RESTRICT FK semantics); SQLite is a convenience for local iteration and CI-without-services runs. Selected via `DATABASE_URL`.
- **`BSV::Wallet::Store::UTXOPool`** — Layer 2a UTXO selection. Three-tier evolution (simple select → pre-split → TxCache) — current code is tier 1.
- **`BSV::Network::Services`** — Layer 2a network routing. Capability-based provider dispatch, per-provider rate limiting (TokenBucket), bounded backoff on retryable responses (429 / 5xx). Multiple providers can serve the same command; failover is automatic.
- **`BSV::Network::ChainTracker`** — Layer 2a write-through cache for block headers. Backs SDK's `Transaction#verify` for SPV.
- **`BSV::Wallet::Daemon`** + **`Scheduler`** — Layer 2a concurrency. Async reactor hosting `Engine::Broadcast#pull!`, `Engine::Broadcast#reply!`, `Engine::TxProof#pull!` as fibers fed by the scheduler's discovery loops (`pending_pushes`, `pending_polls`, `pending` proofs).
- **Sequel models** under `Store::Models::*` (`Action`, `Output`, `Input`, `Spendable`, `Broadcast`, `TxProof`, `Block`, …) — Layer 2b atomic DB rows. Engine never reaches across the boundary to a model.

Single gem (`bsv-wallet`) supports both Postgres (primary) and SQLite (convenience) through `DATABASE_URL`. The wallet is Postgres-based by design — schema features and constraints assume Postgres semantics. SQLite carries them via translation for fast logic-only specs.

Unit specs branch on `BSV_WALLET_POSTGRES` — unset → in-memory SQLite, set (e.g. `postgres://postgres:postgres@localhost:5433/`) → Postgres at `<base>/bsv_wallet_test`. The spec helper derives the test DB from the base and **ignores `DATABASE_URL`** so an operator's working DATABASE_URL never silently hijacks the spec run. CI runs both branches in a matrix. Integration specs run against Postgres (locally via `.env`-supplied `DATABASE_URL_*` URLs, in CI via the Postgres service container). Anything Postgres-specific (CHECK violations, ENUM rejections, RESTRICT FK, the `prevent_outbound_spendable` trigger) MUST be covered by a spec running against Postgres.

## The 4-Phase Action Lifecycle

Every outgoing transaction goes through four phases, split across two database transactions with the network call in the middle. The split is load-bearing — review changes against it.

| Phase | What | Atomicity |
|------|------|-----------|
| **1 — Lock** | `Store#create_action` inserts the `actions` row (post-#323 "option (a)": with **no** inputs); `Engine::FundingStrategy` then locks inputs via `Store#lock_inputs` (`INSERT ON CONFLICT (output_id) DO NOTHING`). The lock IS the structural double-spend guard. | row create + each lock its own DB transaction |
| **2 — Sign** | `Engine::TxBuilder` builds the tx + runs the change/fee fixpoint (driven by `FundingStrategy`'s loop) + signs; Engine persists `wtxid` + `raw_tx`. Send-path also writes the `broadcasts` row + caller / change output rows (as **pending** — no flag; see Phase 4). | One DB transaction (`Store#sign_action`) |
| **3 — Broadcast** | `Engine::Broadcast#submit` posts to ARC. Inline (`accept_delayed_broadcast: false`) blocks here; delayed lets the daemon pick the row up via push-discovery. Network call — **no DB transaction held**. | None |
| **4 — Promote** | On ARC acceptance, insert a **`promotions` row** (#307/ADR-023 — promotion is a *row*, **not** an `outputs.promoted` flag; the flag was removed) + `spendable` rows. This is the moment outputs join the canonical UTXO set. | One DB transaction (`Store#promote_action_outputs`) |

**Internal path** (`actions.broadcast_intent = 'none'` — used by `internalize_action`, `import_utxo`, wbikd): the action is created, signed, and promoted with no broadcast. Promotion goes through `Store#promote_action`, which inserts the `promotions` row (`intent='none'`, no authorising status) + outputs + spendable. No Phase 3, no `broadcasts` row. `internalizeAction` (incoming-BEEF) runs through `Engine::BeefImporter#import`.

**Send path** (`broadcast_intent IN ('delayed', 'inline')`): four distinct phases as above.

Review rule: any change that touches `actions.broadcast_intent`, the `promotions` table, or the `broadcasts` table must explain which path(s) it affects and which phase boundaries it crosses.

## Critical Convention: Transaction ID Byte Order

This codebase enforces strict binary/string type discipline for transaction IDs.

| Name | Format | Usage |
|------|--------|-------|
| `wtxid` | 32-byte binary, wire order | All internal code: method params, variables, hash keys, DB columns |
| `dtxid` | 64-char hex string, display order | ARC API calls, JSON responses, logs, CLI output |
| `txid` | Varies | BRC-100 spec names only (`:txid` return key, `known_txids:` param) |

**Conversion:** `dtxid = wtxid.reverse.unpack1('H*')` — the `DisplayTxid` module provides `#dtxid` on `Action` and `TxProof` models.

**Validation:** `BSV::Primitives::Hex.validate_wtxid!` rejects display-order hex passed where wire-order binary is expected; `validate_dtxid_hex!` does the reverse. Both fire at entry points (`Store#sign_action`, `#stage_action`, `#find_action`, `#save_proof`, etc.).

**DB convention extends to merkle roots and block hashes.** The `blocks` table stores wire-order bytes. `ChainTracker#valid_root_for_height?` reverses the SDK's display-order hex before comparing against the DB. Both writers to the `blocks` table (`find_or_create_block` via BEEF proofs, and `ChainTracker#persist_block` via WoC headers) agree on wire-order bytes.

**Review rule:** any code that calls `.reverse`, `.unpack1('H*')`, or `[x].pack('H*')` on a transaction ID, merkle root, or block hash is a byte-order boundary. Verify direction matches the context (internal = wire-order binary, external = display-order hex).

## Threat Model

**Funds at risk** is the guiding principle. The wallet manages real UTXOs — bugs cause stuck funds, double-spends, or lost outputs.

### UTXO Lifecycle (Critical — funds at risk)

- **Input locking atomicity**: `Engine::FundingStrategy` locks inputs via `Store#lock_inputs` (`INSERT ON CONFLICT (output_id) DO NOTHING`) — post-#323 the initial lock is no longer folded into `create_action` (option (a): the row is created with `inputs: []`, then FundingStrategy locks). Two concurrent transactions can't both claim the same UTXO. Verify any change preserves the all-or-nothing per-lock guarantee.
- **Top-up locking**: `Store#lock_inputs` appends inputs to an existing action with all-or-nothing semantics (rolls back on any conflict, returns 0). Used by the funding loop to top up. Verify the caller checks the return value — appending output IDs to the locked set when the lock rolled back desynchronises subsequent `base_vin` calculations.
- **Promote timing**: outputs become spendable only at Phase 4, and promotion is a **`promotions` row** (#307/ADR-023), not an `outputs.promoted` flag (the flag was removed). Send-path: `Store#promote_action_outputs` after ARC acceptance — the row's composite FK to `broadcasts(action_id, tx_status)` (+ `auth_not_rejected` CHECK) gates it to a non-rejected status. Internal-path: `Store#promote_action` (`intent='none'`, no status). The `spendable.action_id → promotions` FK means a UTXO row cannot exist without an authorising promotion. Premature promotion creates UTXOs against transactions miners may reject. Verify Phase 4 only runs on ARC-accepted broadcasts or on `broadcast_intent = 'none'`.
- **Reaper safety**: `Store#reap_stale_actions` deletes stale Phase 1/2 actions via CASCADE. The guard is `Sequel.~(broadcast_intent: 'none')` AND `wtxid IS NOT NULL` — i.e. only actions that took the send path AND signed but never broadcast-accepted are reaped. Verify any change preserves both clauses; reaping a `broadcast_intent = 'none'` (internal-path) action would delete confirmed UTXOs.
- **Spendable integrity**: the `spendable` table IS the wallet's UTXO set. A row's presence = available. Verify spent outputs are removed atomically with input creation, and that `BEFORE INSERT` trigger `prevent_outbound_spendable` is not bypassed.

### Funding Loop (Critical — funds at risk)

The funding loop lives in `Engine::FundingStrategy` (#323); the per-attempt build + fee fixpoint is `Engine::TxBuilder#build_change` (#336, store-free, takes a resolved input set by value). The mechanics below are unchanged from the former `Action#generate_change` / `run_funding_loop`, only relocated.

- **Caller-inputs shortfall**: `TxBuilder#build_change` returns `{ shortfall: N }` when input sats don't cover outputs + fee. `FundingStrategy`'s top-up loop only fires for wallet-selected inputs (`caller_supplied_inputs: false`). Caller-supplied input shortfalls raise `InsufficientFundsError` immediately — the wallet does not extend a caller-supplied input set. Verify any change keeps this asymmetry; auto-extending caller inputs is a silent fund-routing change.
- **Fee detection**: `TxBuilder#build_change` computes `required_fee` via `FeeModels::SatoshisPerKilobyte#compute_fee(tx)` against the templated tx, not via `Transaction#fee` (which silently drops change rather than raising on insufficient inputs). Verify the comparison `surplus = total_input_satoshis - sum(caller_outputs)` against `required_fee` is preserved.
- **Order of operations** in `TxBuilder#build_change`: build → attach templates → fee check → distribute_change → shuffle → sign. Sighashes commit to final output positions, so the shuffle must happen before signing. Distribute must happen after fee check (Benford remainder targets the change set). Verify reorderings.
- **`change_count: 1` semantics**: consolidation and sweep both pass `change_count: 1` to constrain the funding loop to a single change output. The pool's default (`@utxo_pool.change_output_count`) creates ~8 change for grooming. Verify any consolidation-shaped flow uses the override.

### Input Resolution (Critical — funds at risk)

- **Source outpoint correctness**: `Store#resolve_inputs_for_signing` joins `inputs → outputs → source_actions` to recover `source_wtxid` and `source_vout`. A wrong join means the transaction is built against the wrong source output → invalid sighash → unspendable UTXO.
- **Key derivation parameters**: resolved `derivation_prefix`, `derivation_suffix`, and `sender_identity_key` go to `KeyDeriver` to derive the signing key. Wrong parameters → wrong private key → invalid signature → funds stuck.
- **Wire order consistency**: `source_wtxid` from the DB is passed directly to `TransactionInput#prev_wtxid`. Both must be wire-order binary. A byte-reversal here references a non-existent UTXO.

### BEEF / SPV Validation (High — counterfeit transaction risk)

- **`Engine::BeefImporter#verify_incoming_transaction!`** is the single ingress SPV gate (#357 — was `Action.internalize`). It delegates to SDK's `Transaction#verify(chain_tracker:)` with the **real** chain_tracker (not the egress `TrustedSelfChainTracker`), performing SPV (scripts + merkle proofs + fee adequacy) in one pass, and wraps `VerificationError` as `InvalidBeefError`. Skipping this call means accepting counterfeit transactions.
- **trustSelf semantics**: `BeefImporter#replace_known_ancestors!` runs only *after* `save_beef_proofs` (so trimming never discards an unpersisted proof) and only when `trust_self == 'known'`. It replaces known ancestors with TXID-only entries — never the subject transaction. Replacing the subject would bypass SPV. `hydrate_known_sources!` runs *before* verify, so it cannot smuggle unverified ancestors past the gate.

### Broadcast Lifecycle (High — transaction loss)

- **Push vs poll discovery**: the daemon's `Scheduler` queries `Engine::Broadcast.pending_pushes` for never-attempted broadcasts (`broadcast_at IS NULL`) and `Engine::Broadcast.pending_polls` for in-flight ones (`broadcast_at IS NOT NULL`, non-terminal status). `Engine::TxProof.pending` handles proof acquisition. Each runs on a fixed interval.
- **ARC response byte order**: ARC's payloads use `txid` as display-order hex. Normalization at the `Services` layer maps the various provider field shapes (`txStatus` / `tx_status`, `blockHash` / `block_hash`, …) into one canonical key set. Anywhere in the wallet that reads from `broadcasts.tx_status`, `block_hash`, etc. is reading from this normalized shape.
- **Outcome categorization**: `Engine::Broadcast#categorize_outcome` maps ARC `tx_status` to terminal vs transient. `abort_action` is wired for definitive rejections (REJECTED, DOUBLE_SPEND_ATTEMPTED, MALFORMED). Misclassifying a transient as terminal would delete in-flight work.
- **Rate-limit handling**: `Services#call` retries the same provider on retryable responses (429 / 5xx) with bounded exponential backoff before falling over to the next provider. Verify that a change to `Services` doesn't bypass either the TokenBucket spacing or the backoff retry.

### Proof Management (Medium — completeness)

- **`save_beef_proofs` subject linking**: the subject transaction's proof must be linked to the action via `Store#link_proof`. Without this link the action never reaches `:completed` status.
- **Merkle path normalization**: ARC may return merkle paths as binary, hex, or TSC format. `Engine::TxProof#normalize_merkle_path` (and `normalize_tsc_merkle_path`) handle all three. Verify any new path source goes through the normalizer.
- **Merkle root byte order**: `Store#derive_merkle_root` returns wire-order bytes (matching the wtxid convention). `ChainTracker#valid_root_for_height?` reverses the SDK's display-order hex before comparing. Both writers to `blocks` agree on wire-order. A regression here silently passes WoC-written rows while failing BEEF-written rows (the bug pattern surfaced by the 3-wallet cascade).

## Review Focus Areas

### Transaction ID / Merkle Root Boundaries

Any code touching `wtxid`, `dtxid`, merkle roots, or block hashes:
- Verify `.reverse` direction matches context (display = reversed wire)
- Check DB lookups use `Sequel.blob(wtxid)` (not raw string)
- Ensure `validate_wtxid!` / `validate_dtxid_hex!` guard entry points
- Verify ARC-facing code uses `dtxid` (display-order hex)
- Verify the `blocks` table convention (wire-order in DB; conversion at the `ChainTracker` boundary)

### Database Atomicity

Multi-table operations live inside `@db.transaction do ... end`:
- `Store#create_action`: the `actions` row (post-#323 the initial input lock is no longer folded in — `FundingStrategy` locks via `Store#lock_inputs` separately)
- `Store#sign_action`: action update + tx_proofs upsert + broadcasts row (send-path) + outputs + change_outputs in one transaction
- `Store#stage_action`: deferred-signing equivalent; same shape minus the broadcasts row
- `Store#promote_action`: the `promotions` row (`intent='none'`) + outputs + spendable + baskets + details + tags (internal-path) in one transaction
- `Store#promote_action_outputs`: insert the `promotions` row + `spendable` (send-path) in one transaction — no `outputs.promoted` flag (#307)
- `Store#lock_inputs`: append inputs to existing action, all-or-nothing

Breaking atomicity yields partial state subsequent operations cannot recover from.

### Interface Boundary Contracts

Engine ↔ Store communication uses plain hashes — no Sequel models cross the boundary. Verify:
- Store methods return `Hash` / `Array<Hash>`, never `Sequel::Model`
- Engine never calls `.reload`, `.dataset`, `.update` (model methods)
- Binary columns (`wtxid`, `raw_tx`, `locking_script`, `merkle_root`, `block_hash`) stay `Encoding::BINARY` through the boundary

### Postgres-Primary Backend

Postgres is the production target; SQLite is a convenience for fast logic-only specs. Review changes that touch persistence with that order in mind:
- New schema features should use Postgres-native types where the design calls for them (`bytea`, `uuid`, ENUM, CHECK). SQLite carries them via translation.
- New behaviour that relies on a Postgres-specific constraint (NOT NULL CHECK, ENUM rejection, RESTRICT FK, the `prevent_outbound_spendable` trigger) MUST have a spec that runs against Postgres — SQLite carries the schema via translation and won't surface the regression.
- New DB-touching test helpers must read the configured DB URL, never hardcode `sqlite://`. Integration specs use the `.env`-supplied `DATABASE_URL_*` URLs (Postgres) locally and the CI Postgres service in CI — overriding with sqlite tmpdir paths silently strips Postgres coverage from the bin/ porcelain layer.

## What NOT to Flag

- **`txid:` key in BRC-100 return hashes**: `{ txid: wtxid, tx: beef }` — the key name is spec-mandated, the value is wire-order binary. Correct.
- **`PathElement.new(txid: true)`**: SDK's boolean flag indicating a merkle path element is a transaction (not a hash). Not a naming violation.
- **`known_txids` parameter name**: BRC-100 spec name. Values inside ARE validated as wire-order binary.
- **ARC payload `txid:` field**: ARC's JSON schema uses this field name for display-order hex. Their API contract.
- **`action.dtxid` for ARC calls**: display-order hex is what ARC expects.
- **No ActiveRecord**: this project uses Sequel deliberately. Don't suggest AR patterns.
- **American English**: `internalize`, `randomize`, etc. — matches BRC-100 spec method names. (Overrides the global British convention.)
- **Derived status (no status column)**: `Action#derived_status` computes state from structure (`wtxid`, `tx_proof_id`, `broadcast_intent`, existence of a `promotions` row, presence of a `broadcasts` row). There is no stored `status` field and no `outputs.promoted` flag — by design (see `reference/principle-of-state.md`, `reference/state-representations.md`).
- **`Gemfile.lock` not committed**: standard practice for gems.
- **Engine namespace nesting**: `Engine::Broadcast`, `Engine::TxProof`, `Engine::OmqSupport` are logical models in the Engine namespace. They are intentionally not Store-level.
- **Missing `require 'set'` (and other autoloaded core stdlib)**: do NOT flag `Set` usage for a missing `require 'set'`. The gem floors at `required_ruby_version >= 3.3`, and `Set` has been an **autoloaded core constant since Ruby 3.2** — it resolves with no explicit require on every supported version. There is deliberately no `require 'set'` anywhere in `lib/`, yet `Set` is used across several files; this is the established convention, not a hidden dependency. (Same applies to other stdlib that Ruby ≥3.2 autoloads.)

## Style

- Be specific: cite file paths and line numbers.
- Lead with **funds impact** or **data integrity impact**, not style concerns.
- Provide fix recommendations with code, not just problem statements.
- Skip cosmetic issues unless they have a correctness implication.
- Focus on the diff, not the entire codebase. Pre-existing patterns are not new findings.
