# Stage 3 — BRC100 Composition + `do_` Prefix Revert (#405)

Plan companion to HLR #405. The endpoint of #396. Converts `BSV::Wallet::BRC100` from an Engine mixin to a class composed over Engine, and reverts the `do_` prefix Stage 2 scaffolded onto the 28 Engine primitives. After this lands, the umbrella issue closes.

Per the HLR's "atomic single PR" decision (#405 decision 1), the entire change lives in one PR. The plan splits the work into **5 commits** that each keep the suite green — not because the architectural shift is decomposable into stand-alone landings (it isn't; the PR has to be one cohesive whole), but for reviewability.

## Commit sequence

### Commit 1 — Plan file (this document)

Lands first so subsequent commits reference it. No code change.

### Commit 2 — `Engine#brc100` accessor + 178-site migration (mechanical)

Add a trivial accessor on Engine:

```ruby
def brc100
  self
end
```

While BRC100 is still a mixin, `self` IS the engine, and engine responds to all 28 BRC-100 methods via the mixin. So `engine.brc100.create_action(...)` works identically to `engine.create_action(...)`. The accessor is a transitional shim — its body changes in commit 3.

Then sweep all 178 call-sites:

| File | Approx sites | Migration |
|---|---|---|
| `spec/bsv/wallet/engine_spec.rb` | ~120 | `engine.<brc100-method>` → `engine.brc100.<method>` |
| `spec/bsv/wallet/engine/porcelain_spec.rb` | ~15 | same |
| `spec/bsv/wallet/engine/limp_mode_spec.rb` | ~5 | same |
| `spec/bsv/wallet/engine/wbikd_spec.rb` | ~5 | same |
| `spec/bsv/wallet/engine/action_spec.rb` | ~10 | same |
| `bin/create_action` | 1 | `engine.create_action(...)` → `engine.brc100.create_action(...)` |
| `bin/send` | 1 | same |
| `bin/receive` | 1 | same |
| `bin/internalize` | 1 | same |
| `lib/bsv/wallet/engine.rb` (`import_utxo`) | 1 | internal `create_action` → `brc100.create_action` |

Suite stays green throughout — `engine.brc100.create_action` resolves through the accessor → self → mixin → BRC100#create_action, no semantic change.

### Commit 3 — BRC100 module → class + drop the mixin

The architectural shift. Three coordinated edits:

1. **`lib/bsv/wallet/brc100.rb`**:
   - `module BRC100` → `class BRC100`
   - Add `def initialize(engine); @engine = engine; end`
   - Method bodies: bare `do_<name>(...)` → `@engine.do_<name>(...)`
   - Move BRC-100 spec-shape validators from Engine to BRC100 as private methods (the validators are spec-shape concerns per ADR-026 d.6). Move list:
     - `validate_description!`
     - `validate_reference!`
     - `validate_create_action_params!`
     - `validate_output_ownership!`
     - `validate_wtxid!` (the BeefImporter-style cert hex validation that BRC100 currently calls inline)
   - `secure_compare` is for `verify_hmac` — already called on `@engine` (where `do_verify_hmac` lives); stays on Engine.

2. **`lib/bsv/wallet/engine.rb`**:
   - Remove `include ::BSV::Wallet::BRC100` (line 37 today).
   - Remove the eager `require_relative 'brc100'` (line 8 today). The autoload entry in `wallet.rb` is the canonical entry now.
   - Replace `Engine#brc100`'s commit-2 trivial body with `@brc100 ||= BSV::Wallet::BRC100.new(self)` (memoised).
   - Remove the moved validators from Engine.

3. **`lib/bsv/wallet/wallet.rb`** — autoload entry stays (already added in Stage 1).

After this commit:
- `engine.create_action(...)` raises NoMethodError (no longer defined on Engine).
- `engine.brc100.create_action(...)` works (via the accessor + the new BRC100 class).
- The 28 BRC-100 method names ARE NOT on Engine at this point — they're on BRC100 only.
- The 28 `do_*` primitives ARE on Engine.

Suite still green because commit 2 migrated all sites to `engine.brc100.<method>`.

### Commit 4 — Drop the `do_` prefix on Engine primitives (mechanical rename)

28 method renames on Engine: `do_build_action` → `build_action`, `do_sign_action` → `sign_action`, ... `do_get_version` → `get_version`.

Two files change:
- **`lib/bsv/wallet/engine.rb`** — 28 `def do_<name>` → `def <name>` renames + a few internal references update.
- **`lib/bsv/wallet/brc100.rb`** — 28 `@engine.do_<name>` → `@engine.<name>` updates.

After this commit:
- `Engine#sign_action(...)` returns wallet vocab `{ wtxid:, atomic_beef: }`.
- `BRC100#sign_action(...)` returns BRC-100 vocab `{ txid:, tx: }`.
- Two methods, same name, distinct classes — no MRO collision since BRC100 is no longer in Engine's ancestry.

Engine spec coverage already exists for both vocabs:
- "wallet-vocab primitive surface" describe block (Stage 2 PR 1) — assertions reference `do_build_action` etc.; rename to `build_action`.
- "read-side primitive surface" describe block (Stage 2 PR 2) — references `do_<name>` constants; rename array entries.
- Per-BRC-100-method blocks (`#create_action`, `#encrypt`, etc.) — already use `engine.brc100.<method>` after commit 2.

### Commit 5 — Spec invariants + doc cross-references

Two threads:

**1. `spec/bsv/wallet/brc100_spec.rb` rewrite.** The MRO/ancestry assertions become obsolete:
- ❌ `BSV::Wallet::Engine.ancestors` includes `BSV::Wallet::BRC100` — false after the mixin drop.
- ❌ `BSV::Wallet::Engine.ancestors` includes `Interface::BRC100` transitively via BRC100 — false.
- ❌ `Engine.instance_methods(false)` does not include any of the 28 — INVERTED; Engine now DOES define the 28 spec-aligned names (without the `do_` prefix).
- ❌ Each of the 28 is owned by `BSV::Wallet::BRC100` — true but trivial; assertion form changes.

Replace with class-shape assertions:

```ruby
RSpec.describe BSV::Wallet::BRC100 do
  it 'is a class (was a module pre-#405)' do
    expect(described_class).to be_a(Class)
  end

  it 'has the 28 BRC-100 spec methods' do
    BRC100_SPEC_METHODS.each do |name|
      expect(described_class.instance_method(name)).to be_a(UnboundMethod)
    end
  end

  it 'is NOT in Engine.ancestors (no longer a mixin)' do
    expect(BSV::Wallet::Engine.ancestors).not_to include(described_class)
  end

  it 'wraps an engine reference passed to .new' do
    fake_engine = Object.new
    instance = described_class.new(fake_engine)
    expect(instance.instance_variable_get(:@engine)).to be(fake_engine)
  end

  it 'still includes Interface::BRC100 for the SDK contract' do
    expect(described_class.ancestors).to include(BSV::Wallet::Interface::BRC100)
  end

  it 'no longer at the pre-#400 path BSV::Wallet::Engine::BRC100 (kept from Stage 1)' do
    expect { BSV::Wallet::Engine.const_get(:BRC100, false) }.to raise_error(NameError)
  end
end
```

**2. Doc cross-references**:
- `.architecture/decisions/adrs/20260619_ADR-026-engine-primitive-granularity.md` — the "Stage 2 naming scaffold" implementation note changes from forward-looking to past-tense recording: "Stage 3 reverted the `do_` prefix in PR #<this>".
- `.claude/plans/20260620-stage-2-primitive-extraction.md` — add a one-line footer pointing forward to Stage 3 completion.
- `reference/principle-of-state.md` — collaborator list mentions BRC100. Verify wording still applies post-composition (likely fine; BRC100 is still a collaborator, just now composed not mixed-in).

## Acceptance gate at every commit

- Full unit suite green Postgres + SQLite
- Rubocop clean
- (Commit 3+ only) Integration suite green

## Spec migration nuances

Most spec assertions look like:

```ruby
result = engine.create_action(description: '...', outputs: [...])
expect(result).to include(:txid, :tx)
```

After commit 2, this becomes:

```ruby
result = engine.brc100.create_action(description: '...', outputs: [...])
expect(result).to include(:txid, :tx)
```

The `:txid` / `:tx` BRC-100 keys are preserved because `brc100.create_action` is the wrap layer.

For tests that exercise the wallet-vocab primitives directly (the "wallet-vocab primitive surface" blocks Stage 2 added), commit 4's rename updates them: `engine.do_build_action(...)` → `engine.build_action(...)`. Return-shape assertions on `{ wtxid:, atomic_beef: }` stay unchanged.

## Open at implementation time

- **`Engine.allocate.instance_variable_set(:@network_name, :mainnet)` in `brc100_spec.rb`'s smoke** — currently exercises BRC100#get_network through the mixin. After Stage 3, `Engine#get_network` returns the network symbol directly; BRC100#get_network wraps it. The smoke test moves to BRC100: instantiate a BRC100 wrapping a stub engine that responds to `get_network`.
- **`Engine::Action` namespace** — `Engine::Action.list`, `.find`, `.create`, etc. stay where they are. Stage 3 doesn't reshape the `Engine::Action` class — its instance methods landed cleanly in Stage 2 PR 1.
- **`reject_action`** on Engine — operator-facing helper, not part of the 28. Stays on Engine unchanged.
- **CI `changes` filter** — should fire on `lib/bsv/wallet/*.rb` and `bin/*` changes (already does). No CI surgery needed.
