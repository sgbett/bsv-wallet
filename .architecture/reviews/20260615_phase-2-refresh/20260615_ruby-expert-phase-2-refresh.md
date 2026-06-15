# Ruby Expert Review — Phase 2 Refresh (#290)

**Reviewer:** Marcus Johnson, Ruby Expert (`ruby_expert`)
**Target:** Issue #290 comment "Phase 2 refresh — classification after #307 + #296 egress landed (2026-06-15)"
**Scope:** Idiomatic-Ruby lens on the refreshed `Engine::Action` re-classification for the #291 Engine refactor. Design-stage review; no code.

---

## Perspective

I evaluate whether the proposed collaborators read as idiomatic Ruby 3.x — objects with clear interfaces, composed cleanly, leveraging the language rather than fighting it — and whether anti-patterns from other ecosystems are leaking in. The classification work in #290 is conceptual (where does behaviour live); my job is to make sure the *shape* the extraction HLRs reach for is Ruby-shaped. The classification itself is sound and well-reasoned. I have little to flag in the *decisions* and three guardrails to flag in the *form*.

## Assessment

The refresh is good Ruby thinking. Correction 1 (verification is SDK-delegated, fold two ~6-line adapters into one `verify_beef(tx, chain_tracker:, error:)` helper rather than minting a "verifier" collaborator) is exactly the YAGNI-disciplined, parameterise-don't-subclass instinct Ruby rewards — the variant *is* the injected `chain_tracker` and the `error:` class, nothing more. Correction 2 (state `output_type` explicitly, delete the field-shape inference) removes a guessing-from-absence smell that ADR-023 now makes unnecessary. The collaborator boundaries (`FundingStrategy`, `TxBuilder`/`ChangeGenerator`, `Hydrator`, `BeefImporter`) map onto genuine single responsibilities, and the sequence is risk-ordered.

My concern is not *which* collaborators but *how they get wired*. The current `Engine::Action` pattern leans on two reach-through idioms that the split will multiply if not designed out now: `engine.send(:private_method)` (11 sites) and `action.send(:private_instance_method)` / `helper.send(...)` (10 sites within `action.rb` itself). At one collaborator these are a wrinkle; at five they become the dominant inter-object protocol. That is the thing to settle at design stage, because it dictates the constructor signatures the extraction HLRs commit to.

## Strengths

- **Collaborator-as-object framing already established.** `Engine::Broadcast` is the template: constructed with explicit keyword dependencies (`store:`, `broadcaster:`, `applicator:`...), lazy-defaulted where autoload cost matters, holds no back-reference to Engine. The new collaborators have a working idiom to copy — they do not need to invent one.
- **`Interface::Store` / `Interface::UTXOPool` give a ready vocabulary for contracts.** These are `NotImplementedError`-stub modules documenting the method surface a backend must satisfy. The same device makes each new collaborator's dependency *explicit and reviewable* rather than "whatever `engine` happens to respond to".
- **Correction 1 is idiomatic dependency injection in miniature.** Passing `chain_tracker:` and `error:` into one helper is the Ruby way to express "two behaviours, one mechanism". Resisting the "bidirectional verifier" abstraction is the right call — it would be a class that exists only to hold a `send` to the SDK.
- **Thin class-method shells over a workflow read well.** `self.create` / `self.internalize` staying as orchestration entry points, with mass moved to injected collaborators, is a legitimate Ruby shape (cf. service objects with a `.call`).

## Concerns

### C1 — `engine.send(:private)` reach-through is an anti-pattern; design it out now (severity: high)

`Action.create` reaches into Engine privates 7 times: `require_key_deriver!`, `determine_broadcast`, `enforce_limp_mode!`, `enforce_headroom_against!` (×2), `select_inputs`, `publish_beef_hint`. `run_funding_loop` adds `select_inputs`. The `send(:...)` bypasses Ruby's visibility precisely *because* these aren't public — it is the codebase telling you the boundary is wrong. Split `Action` into five collaborators that each need a slice of this set and you propagate `send` reach-through across the whole new surface. `FundingStrategy` needs `select_inputs` + `enforce_headroom_against!`; `TxBuilder` needs `require_key_deriver!`. Each will reach through `engine` unless the dependency is made explicit at construction.

**Fix:** Treat the reach-through set as the *specification of what each collaborator actually depends on*, and inject those things directly rather than the whole `engine`. Three of the privates are pure policy with no Engine state worth hiding (`determine_broadcast`, `enforce_headroom_against!`, the limp/headroom predicates) — they are candidates for a small plain object (e.g. `BroadcastPolicy` / a value-returning `Headroom` check) or for promotion to genuine public Engine methods. `select_inputs` is a one-line delegation to `@utxo_pool.select` + lock-decrement; `FundingStrategy` should take `utxo_pool:` and `store:`, not `engine:`. `require_key_deriver!` is a guard on `key_deriver`; inject `key_deriver:` and let the collaborator guard. The test: a collaborator's constructor keyword list should name exactly what it touches. If the only honest answer is `engine:`, the responsibility hasn't actually been carved out.

### C2 — `action.send(:instance_method)` within Action shows class-method/instance split confusion; settle the object model (severity: medium)

Inside `action.rb`, `self.create` builds a bare instance (`new(engine:, row:)`) then calls its privates via `action.send(:build_transaction, ...)`, `action.send(:build_atomic_beef, ...)`, etc.; `self.internalize` does the same through a row-less `helper` (`new(engine:, row: {id: nil})`). This is a class method reaching into instance privates on an object it just made only to access methods — the "row-less helper instance" is a code smell: an instance that isn't really an instance of anything. It signals that those methods (`build_transaction`, `build_atomic_beef`, `wire_ancestor`, `parse_beef`, ...) are *not* per-action lifecycle behaviour — they're the collaborator behaviour the split is meant to relocate.

**Fix:** Let the extraction resolve this rather than carrying it forward. Once `build_transaction` lives on `TxBuilder` and `build_atomic_beef`/`wire_ancestor` on `Hydrator`, the row-less-helper dance disappears: `self.create` calls `tx_builder.build(...)` and `hydrator.atomic_beef(...)` on real, single-purpose objects with public methods. Guardrail for the HLRs: collaborator methods that `Action` invokes should be **public on the collaborator**, never private methods reached by `send`. If a method stays on `Action` as genuine lifecycle behaviour (`sign!`, `abort!`), it's an instance method on a row-bearing instance and needs no `send`.

### C3 — `resolve_locking_script` / `resolve_unlocking_script` duplication will fan out under the split (severity: low)

`self.resolve_locking_script` (class) and `resolve_unlocking_script` (instance) are byte-identical apart from the lock/unlock `Script` constructor. The encoding-sniff (`ASCII_8BIT || !hex?`) belongs in one place. Under the split, `TxBuilder` will own both call sites; if it copies both methods the duplication ossifies.

**Fix:** One private helper on `TxBuilder` — `script_from(data, kind:)` or two one-liners over a shared `decode_script(data)`. Trivial, but the moment to do it is during extraction, not after.

## Recommendations

1. **Adopt explicit-dependency injection over `engine:` back-reference for the new collaborators.** Each extraction HLR's first design question: *what does this collaborator touch?* Inject exactly that (`store:`, `utxo_pool:`, `key_deriver:`, `chain_tracker:`) via keyword args, mirroring `Engine::Broadcast`. The `engine.send(:...)` set is the inventory of hidden dependencies to make explicit — not a pattern to replicate. This is the single highest-leverage call for the whole refactor and it must be made at design stage because it fixes the constructor signatures.

2. **Define an `Interface::` contract module per collaborator where it has a non-trivial surface** (`FundingStrategy`, `TxBuilder`, `Hydrator`, `BeefImporter`), the same `NotImplementedError`-stub device as `Interface::Store`/`Interface::UTXOPool`. Cheap, documents the boundary, and gives specs a contract to assert against. Skip it for `ChangeGenerator` if it stays a single `#generate` — don't manufacture ceremony for a one-method object.

3. **Make collaborator methods public; ban `send`-reach-through in the extracted design.** Acceptance criterion for each extraction HLR: zero `collaborator.send(:private)` from `Action`. If `Action` needs it, it's public on the collaborator. This kills both C1 and C2 in one rule and is trivially greppable in review.

4. **Plain objects, not modules, for these collaborators.** `Interface::Store` is a *module* because it's a mixed-in contract over a base class with backend adapters — a different problem. `FundingStrategy` et al. are stateless-ish strategy objects constructed with their dependencies; idiomatic Ruby makes those plain classes with keyword-injected collaborators (the `Engine::Broadcast` form), not mixins. Don't reach for modules here.

5. **Fold the `verify_beef` de-dup (Correction 1) and the script-decode de-dup (C3) into the `BeefImporter`/`TxBuilder` HLRs respectively** — not as separate tidy-up PRs. They are small and belong with the substantive extraction that creates their home.

No blocking concerns at design stage. The classification is right; the one thing to fix *before* the extraction HLRs lock in constructor shapes is the reach-through dependency style (C1/C2). Settle "inject what you touch, methods are public" now and the rest of the refactor falls out cleanly.
