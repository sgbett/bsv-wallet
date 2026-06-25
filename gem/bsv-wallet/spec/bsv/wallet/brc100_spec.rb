# frozen_string_literal: true

require 'bsv-wallet'
require 'bsv/wallet/engine'
require 'bsv/wallet/brc100'

# HLR #428 rule-parity gate exercises +baskets.name+ via the shared
# store context; load it once at file scope.
require_relative 'store/shared_context'

# Class-shape regression spec for the BRC100 wrap layer.
#
# Lifecycle of this class:
# - #364 Phase 7 of #291: introduced as +Engine::BRC100+ mixin.
# - #400 Stage 1 of #396: relocated to sibling +BSV::Wallet::BRC100+
#   (still a mixin).
# - #405 Stage 3 of #396: promoted from +module+ to +class+ composed
#   over an Engine instance via +BRC100.new(engine)+ / +Engine#brc100+.
#
# Post-Stage-3 invariants this spec locks in:
#   - BRC100 is a +Class+ (not a +Module+).
#   - +BSV::Wallet::Engine+ does NOT include BRC100 (the mixin is gone).
#   - +Engine#brc100+ returns a memoised +BRC100+ instance wrapping
#     +self+.
#   - BRC100 still +include+s the SDK contract +Interface::BRC100+ so
#     unimplemented methods would fall through to +NotImplementedError+
#     stubs (currently all 28 are implemented).
#   - The 28 BRC-100 spec method names land on Engine TOO (post-#405
#     commit 4) as the wallet-vocab primitive surface — but those are
#     a different shape (wallet vocab) from BRC100's wraps.
# Frozen list — a future contract change must force a deliberate edit.
# Defined at file scope so the rubocop RSpec/LeakyLocalVariable cop is
# satisfied; the iteration below builds one +it+ per name at load time,
# so a regular +let+ wouldn't work (the array must exist before
# describe-block evaluation, not at example time).
BRC100_SPEC_METHODS = %i[
  create_action sign_action abort_action list_actions internalize_action
  list_outputs relinquish_output
  get_public_key reveal_counterparty_key_linkage reveal_specific_key_linkage
  encrypt decrypt create_hmac verify_hmac create_signature verify_signature
  acquire_certificate list_certificates prove_certificate relinquish_certificate
  discover_by_identity_key discover_by_attributes
  authenticated? wait_for_authentication
  get_height get_header_for_height get_network get_version
].freeze

# HLR #428 rule-by-rule reject fixtures for +#validate_basket_name!+.
# Frozen at file scope so the +each+ iteration below builds one +it+
# per rule at load time — same idiom as +BRC100_SPEC_METHODS+ above.
# Each tuple: +[input, msg_match_regexp, description]+.
BASKET_NAME_REJECT_CASES = [
  ['abc',           /between 5 and 300/,               'rule 1 — length below minimum (3 < 5)'],
  [('x' * 301),     /between 5 and 300/,               'rule 2 — length above maximum (301 > 300)'],
  ['foo!bar',       /lowercase ASCII letters/,         'rule 3 — charset rejects punctuation'],
  ['hello  world',  /consecutive spaces/,              'rule 4 — no two consecutive spaces'],
  ['recipe basket', /not ending with " basket"/,       'rule 5 — no trailing " basket"'],
  ['admin foo',     /not starting with "admin"/,       'rule 6 — no leading "admin" (reserved)'],
  ['default',       /not the reserved name "default"/, 'rule 7 — exact "default" reserved'],
  ['p admi',        /not starting with "p "/,          'rule 8 — no leading "p " (reserved)']
].freeze

# Rule-parity gate fixtures.
#
# Two sets, framing the split as "invalid data → DB CHECK; caller-facing
# policy → conformance layer only":
#
#   * SHAPE/INVALID-DATA rules — length, charset, double-space, trailing
#     +' basket'+, exact +'default'+, leading/trailing whitespace.
#     Enforced at BOTH the conformance layer (rejects the caller) and the
#     DB CHECK (floors the wallet against malformed writes from any path).
#   * RESERVATION rules — +admin+ and +p +. Enforced at the conformance
#     layer ONLY. These ARE valid data the wallet itself stores
#     (+'p wbikd'+ for the WBIKD draft today, +'admin *'+ for ADR-029
#     DBAP tomorrow), so the DB intentionally accepts them; the boundary
#     bounce only applies to application callers.
#
# See +db/migrations/003_schema_constraints.rb+ for the schema floor and
# +docs/reference/brc100-conformance.md+ for the principle. The parity
# gate at the bottom of this file enforces the split per-row.
BASKET_NAME_SHAPE_PARITY_CASES = [
  ['abc',           :name_length],
  [('x' * 301),     :name_length],
  ['foo!bar',       :name_charset],
  ['hello  world',  :name_no_double_sp],
  ['recipe basket', :name_not_basket],
  ['default',       :name_not_default]
  # Leading/trailing-space rules (+name_no_leading_space+,
  # +name_no_trailing_space+) are intentionally absent from this set —
  # they are DB-direct-only enforcement. The conformance validator
  # NORMALISES whitespace away via +strip+ on ingress, so a caller
  # passing +' wallet'+ never reaches the rule-check phase as
  # whitespace-bracketed; the validator sees +'wallet'+ and accepts.
  # The schema CHECK floors against non-BRC-100 writers that bypass
  # normalisation. See +basket_name_validation_spec.rb+ for the
  # DB-direct rejection specs.
].freeze

# Reservation rules — validator rejects, DB accepts. +'p wbikd'+ used
# as the conformance-layer reject because it's the wallet's actual
# WBIKD slot basket, written via Engine→Store direct (proves the boundary
# is bidirectional: bounce at boundary, land via direct).
BASKET_NAME_RESERVATION_PARITY_CASES = [
  ['admin foo', :name_not_admin],
  ['p wbikd',   :name_not_p_prefix]
].freeze

RSpec.describe BSV::Wallet::BRC100 do
  it 'covers exactly the 28 BRC-100 spec methods' do
    expect(BRC100_SPEC_METHODS.length).to eq(28)
  end

  it 'no longer exists at the pre-#400 path BSV::Wallet::Engine::BRC100 (no deprecation alias)' do
    expect { BSV::Wallet::Engine.const_get(:BRC100, false) }.to raise_error(NameError)
  end

  describe 'class shape (#405 Stage 3)' do
    it 'is a Class (was a Module pre-#405)' do
      expect(described_class).to be_a(Class)
    end

    it 'still +include+s the SDK contract Interface::BRC100' do
      expect(described_class.ancestors).to include(BSV::Wallet::Interface::BRC100)
    end

    it 'is NOT in Engine.ancestors (mixin removed)' do
      expect(BSV::Wallet::Engine.ancestors).not_to include(described_class)
    end

    it 'wraps an engine reference passed to .new' do
      fake_engine = Object.new
      instance = described_class.new(fake_engine)
      expect(instance.engine).to be(fake_engine)
    end
  end

  describe 'each of the 28 methods' do
    BRC100_SPEC_METHODS.each do |name|
      it "##{name} is defined on BSV::Wallet::BRC100" do
        owner = described_class.instance_method(name).owner
        expect(owner).to eq(described_class),
                         "expected #{name} on BSV::Wallet::BRC100, found on #{owner} — " \
                         'stub-shadowing or missed move?'
      end
    end
  end

  describe 'Engine#brc100 accessor' do
    let(:engine) { instance_double(BSV::Wallet::Engine) }

    it 'is callable on a real Engine' do
      real_engine = BSV::Wallet::Engine.allocate
      expect(real_engine.brc100).to be_a(described_class)
    end

    it 'is memoised — returns the same instance across calls' do
      real_engine = BSV::Wallet::Engine.allocate
      first = real_engine.brc100
      second = real_engine.brc100
      expect(first).to be(second)
    end
  end

  describe 'smoke: a method delegates to the engine primitive' do
    it '#get_network routes through @engine.get_network' do
      # +BRC100#get_network+ wraps +Engine#get_network+'s return
      # (wallet vocab: the bare network symbol) in BRC-100 vocab
      # +{ network: symbol }+.
      fake_engine = instance_double(BSV::Wallet::Engine, get_network: :mainnet)
      brc100 = described_class.new(fake_engine)

      expect(brc100.get_network).to eq(network: :mainnet)
    end
  end

  # The wrappers continue to ACCEPT +seek_permission:+ from BRC-100
  # callers (it's part of the BRC-100 method contract), even though
  # they no longer forward it to Engine. If a future "cleanup" removed
  # the kwarg from the wrapper signatures thinking it was unused, an
  # external caller passing +seek_permission: true+ would hit
  # +ArgumentError+. These tests lock the wrapper-side acceptance in.
  describe 'BRC-100 contract: wrappers still accept seek_permission:' do
    let(:fake_engine) { instance_double(BSV::Wallet::Engine) }
    let(:brc100) { described_class.new(fake_engine) }

    it '#list_actions accepts seek_permission: without raising' do
      allow(fake_engine).to receive(:list_actions).and_return(total: 0, actions: [])
      expect { brc100.list_actions(labels: [], seek_permission: false) }.not_to raise_error
    end

    it '#internalize_action accepts seek_permission: without raising' do
      allow(fake_engine).to receive(:import_beef).and_return(accepted: true)
      expect do
        brc100.internalize_action(tx: 'beef'.b, outputs: [],
                                  description: 'internalize smoke',
                                  seek_permission: false)
      end.not_to raise_error
    end
  end

  describe '#list_outputs basket validation (BRC-100 spec contract, with HLR #434 nil-affordance)' do
    let(:fake_engine) { instance_double(BSV::Wallet::Engine) }
    let(:brc100) { described_class.new(fake_engine) }

    # Empty / whitespace-only collapse to '' after the HLR #428 normalise
    # step and fail the length rule (0 < BASKET_NAME_MIN = 5). Pre-#428
    # this surfaced as +ArgumentError "basket: required"+; post-#428 the
    # rule-named +InvalidParameterError+ is the load-bearing signal —
    # callers can tell which rule tripped.

    it 'raises InvalidParameterError when basket is empty string (length rule)' do
      expect { brc100.list_outputs(basket: '') }
        .to raise_error(BSV::Wallet::InvalidParameterError, /between 5 and 300/)
    end

    it 'raises InvalidParameterError when basket is whitespace-only (length rule after trim)' do
      expect { brc100.list_outputs(basket: '   ') }
        .to raise_error(BSV::Wallet::InvalidParameterError, /between 5 and 300/)
    end

    it 'delegates to engine.spendable_outputs when basket is supplied' do
      allow(fake_engine).to receive(:spendable_outputs)
        .with(hash_including(basket: 'wallet'))
        .and_return(total: 0, outputs: [])
      expect(brc100.list_outputs(basket: 'wallet')).to eq(total_outputs: 0, outputs: [])
    end

    it 'trims leading/trailing whitespace before delegating to engine' do
      # Per BRC-100 §"Logical Validation Procedures" — interoperable SDK
      # validation trims identifiers before enforcing length limits.
      allow(fake_engine).to receive(:spendable_outputs)
        .with(hash_including(basket: 'wallet'))
        .and_return(total: 0, outputs: [])
      brc100.list_outputs(basket: '  wallet  ')
      expect(fake_engine).to have_received(:spendable_outputs)
        .with(hash_including(basket: 'wallet'))
    end
  end

  describe '#list_outputs basket: nil affordance (HLR #434)' do
    # Intentional divergence from the strict BRC-100 contract: +basket: nil+
    # is accepted as a "show me unbasketed outputs (the wallet's pool,
    # including change)" affordance. TS-conformant callers cannot trigger
    # this (the TS type is non-nullable); only Ruby callers can pass nil.
    # Documented in docs/reference/brc100-conformance.md. Remove when
    # BRC-100 settles change-pool visibility upstream.
    let(:fake_engine) { instance_double(BSV::Wallet::Engine) }
    let(:brc100) { described_class.new(fake_engine) }

    it 'does not raise when basket is nil' do
      allow(fake_engine).to receive(:spendable_outputs)
        .with(hash_including(basket: nil))
        .and_return(total: 0, outputs: [])
      expect { brc100.list_outputs(basket: nil) }.not_to raise_error
    end

    it 'routes basket: nil to engine.spendable_outputs(basket: nil)' do
      allow(fake_engine).to receive(:spendable_outputs)
        .with(hash_including(basket: nil))
        .and_return(total: 0, outputs: [])
      brc100.list_outputs(basket: nil)
      expect(fake_engine).to have_received(:spendable_outputs)
        .with(hash_including(basket: nil))
    end

    it 'returns the BRC-100 hash shape on the nil path' do
      allow(fake_engine).to receive(:spendable_outputs)
        .with(hash_including(basket: nil))
        .and_return(total: 3, outputs: [{ id: 1 }, { id: 2 }, { id: 3 }])
      result = brc100.list_outputs(basket: nil)
      expect(result).to eq(total_outputs: 3, outputs: [{ id: 1 }, { id: 2 }, { id: 3 }])
    end
  end

  # ---- HLR #428 — basket-name validator + ingress normalisation ------
  #
  # The 8 BRC-100 basket-name rules enforced at the conformance boundary,
  # at every entry point that accepts a basket name. Ingress = trim +
  # lowercase + frozen, then rule-check. See:
  # +docs/reference/brc100-conformance.md+ "Reserved names" and
  # "Basket length limit — note a spec inconsistency".

  describe '#validate_basket_name! (HLR #428 — 8 BRC-100 rules)' do
    let(:brc100) { described_class.new(Object.new) }

    BASKET_NAME_REJECT_CASES.each do |input, msg_re, description|
      it "rejects #{input.inspect} — #{description}" do
        expect { brc100.send(:validate_basket_name!, input) }
          .to raise_error(BSV::Wallet::InvalidParameterError, msg_re)
      end
    end

    it 'accepts a name that satisfies all 8 rules' do
      expect { brc100.send(:validate_basket_name!, 'wallet') }.not_to raise_error
    end

    it 'accepts the exact 5-char boundary' do
      expect { brc100.send(:validate_basket_name!, 'aaaaa') }.not_to raise_error
    end

    it 'accepts the exact 300-char boundary' do
      expect { brc100.send(:validate_basket_name!, 'a' * 300) }.not_to raise_error
    end

    it 'rejects the 301-char input (rule 2 boundary)' do
      expect { brc100.send(:validate_basket_name!, 'a' * 301) }
        .to raise_error(BSV::Wallet::InvalidParameterError, /between 5 and 300/)
    end

    it "rejects Cyrillic lookalike 'аdmin foo' (U+0430) on charset, not on reserved" do
      # +'а'+ is U+0430 CYRILLIC SMALL LETTER A — visually identical to
      # ASCII +'a'+. The byte-level +\A[a-z0-9 ]+\z+ rule rejects it
      # before the reserved-name rule fires, closing the visual-spoof
      # bypass surface.
      cyrillic = 'аdmin foo'
      expect { brc100.send(:validate_basket_name!, cyrillic) }
        .to raise_error(BSV::Wallet::InvalidParameterError, /lowercase ASCII letters/)
    end

    it 'rejects embedded NUL byte on charset, not as reserved' do
      expect { brc100.send(:validate_basket_name!, "admin\x00foo") }
        .to raise_error(BSV::Wallet::InvalidParameterError, /lowercase ASCII letters/)
    end

    it "accepts 'pizza' (no false 'p ' prefix)" do
      expect { brc100.send(:validate_basket_name!, 'pizza') }.not_to raise_error
    end
  end

  describe '#normalize_basket_name (HLR #428 — ingress normalisation)' do
    let(:brc100) { described_class.new(Object.new) }

    it 'returns nil for nil input (HLR #434 affordance pass-through)' do
      expect(brc100.send(:normalize_basket_name, nil)).to be_nil
    end

    it 'rejects non-String non-nil input without silent to_s coercion' do
      expect { brc100.send(:normalize_basket_name, :wallet) }
        .to raise_error(BSV::Wallet::InvalidParameterError, /must be a string/)
    end

    it "rejects Array input (an attempted bypass surface, e.g. [['wallet']])" do
      expect { brc100.send(:normalize_basket_name, ['wallet']) }
        .to raise_error(BSV::Wallet::InvalidParameterError, /must be a string/)
    end

    it 'trims leading and trailing whitespace' do
      expect(brc100.send(:normalize_basket_name, '  wallet  ')).to eq('wallet')
    end

    it 'lowercases the input' do
      expect(brc100.send(:normalize_basket_name, 'WALLET')).to eq('wallet')
    end

    it 'composes trim + downcase' do
      expect(brc100.send(:normalize_basket_name, '  Wallet  ')).to eq('wallet')
    end

    it 'returns a frozen string (TOCTOU defence)' do
      result = brc100.send(:normalize_basket_name, 'wallet')
      expect(result).to be_frozen
    end
  end

  describe 'wiring — normalise + validate at every entry point (HLR #428)' do
    let(:fake_engine) { instance_double(BSV::Wallet::Engine) }
    let(:brc100) { described_class.new(fake_engine) }

    describe '#create_action — per outputs[].basket when present' do
      let(:valid_outputs) do
        [{ basket: '  Wallet  ', satoshis: 1000, locking_script: 'aa'.b, output_description: 'unit' }]
      end
      # Mutable capture for what the Engine receives — let-defined Hash
      # so the +allow do |**kw|+ block can stash and the +it+ can read,
      # without instance-variable plumbing.
      let(:capture) { { outputs: nil } }

      before do
        cap = capture
        allow(fake_engine).to receive(:build_action) do |**kw|
          cap[:outputs] = kw[:outputs]
          { wtxid: 'wtxid', atomic_beef: 'beef' }
        end
        allow(fake_engine).to receive(:key_deriver).and_return(nil)
      end

      it 'normalises the per-output basket before forwarding to Engine (frozen)' do
        brc100.create_action(description: 'create wiring', outputs: valid_outputs)
        expect(capture[:outputs].first[:basket]).to eq('wallet')
        expect(capture[:outputs].first[:basket]).to be_frozen
      end

      it 'rejects a reserved basket name on the create path' do
        bad = [{ basket: 'admin foo', satoshis: 1000, locking_script: 'aa'.b, output_description: 'unit' }]
        expect { brc100.create_action(description: 'create wiring', outputs: bad) }
          .to raise_error(BSV::Wallet::InvalidParameterError, /admin/)
      end

      it 'tolerates outputs without a :basket key (per-output basket is optional)' do
        no_basket = [{ satoshis: 1000, locking_script: 'aa'.b, output_description: 'unit' }]
        expect { brc100.create_action(description: 'create wiring', outputs: no_basket) }
          .not_to raise_error
      end
    end

    describe '#internalize_action — only on basket-insertion protocol' do
      let(:capture) { { outputs: nil } }

      it 'normalises insertion_remittance[:basket] on the basket-insertion branch' do
        cap = capture
        allow(fake_engine).to receive(:import_beef) do |**kw|
          cap[:outputs] = kw[:outputs]
          { accepted: true }
        end
        outputs = [{
          output_index: 0, protocol: 'basket insertion',
          insertion_remittance: { basket: '  Wallet  ' }
        }]
        brc100.internalize_action(tx: 'beef'.b, outputs: outputs, description: 'internalize wiring')
        expect(capture[:outputs].first[:insertion_remittance][:basket]).to eq('wallet')
        expect(capture[:outputs].first[:insertion_remittance][:basket]).to be_frozen
      end

      it 'rejects a reserved basket on the basket-insertion branch' do
        allow(fake_engine).to receive(:import_beef).and_return(accepted: true)
        outputs = [{
          output_index: 0, protocol: 'basket insertion',
          insertion_remittance: { basket: 'admin foo' }
        }]
        expect { brc100.internalize_action(tx: 'beef'.b, outputs: outputs, description: 'internalize wiring') }
          .to raise_error(BSV::Wallet::InvalidParameterError, /admin/)
      end

      it 'does NOT validate basket on the wallet-payment branch (no basket carried)' do
        # +protocol: 'wallet payment'+ carries +:payment_remittance+ (no
        # basket key). The wiring must not fire on this branch — a
        # bogus +:basket+ key incidentally present in
        # +payment_remittance+ would still slip through (and is not the
        # validator's job to police).
        allow(fake_engine).to receive(:import_beef).and_return(accepted: true)
        outputs = [{
          output_index: 0, protocol: 'wallet payment',
          payment_remittance: { sender_identity_key: 'aa' }
        }]
        expect { brc100.internalize_action(tx: 'beef'.b, outputs: outputs, description: 'internalize wiring') }
          .not_to raise_error
      end
    end

    describe '#list_outputs — collapsed trim guard into shared call' do
      it 'normalises and validates the basket on the present-basket branch' do
        allow(fake_engine).to receive(:spendable_outputs)
          .with(hash_including(basket: 'wallet'))
          .and_return(total: 0, outputs: [])
        brc100.list_outputs(basket: '  WALLET  ')
        expect(fake_engine).to have_received(:spendable_outputs)
          .with(hash_including(basket: 'wallet'))
      end

      it 'rejects a reserved basket on the list path' do
        expect { brc100.list_outputs(basket: 'admin foo') }
          .to raise_error(BSV::Wallet::InvalidParameterError, /admin/)
      end

      it 'preserves the HLR #434 basket: nil affordance' do
        allow(fake_engine).to receive(:spendable_outputs)
          .with(hash_including(basket: nil))
          .and_return(total: 0, outputs: [])
        expect { brc100.list_outputs(basket: nil) }.not_to raise_error
      end
    end

    describe '#relinquish_output — basket required' do
      it 'normalises and validates the basket before delegating' do
        allow(fake_engine).to receive(:relinquish_output).and_return(true)
        expect { brc100.relinquish_output(basket: '  Wallet  ', output: '0:0') }.not_to raise_error
        expect(fake_engine).to have_received(:relinquish_output).with(output_id: '0:0')
      end

      it 'rejects a reserved basket on the relinquish path' do
        expect { brc100.relinquish_output(basket: 'admin foo', output: '0:0') }
          .to raise_error(BSV::Wallet::InvalidParameterError, /admin/)
      end
    end
  end

  describe 'rule-parity gate — DB CHECK ↔ validator (HLR #428, sub-issue #441)', :store do
    # Drift insurance, design-split-aware (resolved after the +'p wbikd'+
    # regression on the HLR #428 branch).
    #
    # SHAPE rules — length, charset, double-space, trailing +' basket'+:
    # both layers reject. The validator emits +InvalidParameterError+;
    # the DB CHECK trips +Sequel::CheckConstraintViolation+ on the same
    # input.
    #
    # RESERVATION rules — +admin+ / +p +: validator rejects, DB ACCEPTS.
    # The DB intentionally permits these so the wallet's own protocol-
    # reserved baskets (+'p wbikd'+ for WBIKD today; future +'admin *'+
    # baskets for ADR-029 DBAP) can be written via the Engine→Store
    # direct path. The parity-gate spec for reservation rules ASSERTS
    # that the DB insert succeeds — a regression that adds back a
    # DB-level reservation CHECK would surface here as
    # +CheckConstraintViolation+ raised by what should be a clean insert.
    #
    # The +:store+ tag wires in the shared store context (db, store
    # instance, rollback-around-each transaction). The DB half is gated
    # on +baskets.name CHECK+ being present — if #441's migration
    # hasn't run yet, the gate is +skip+ped with a clear marker.

    let(:brc100) { described_class.new(Object.new) }

    # Probe whether #441's CHECKs are live so the gate doesn't false-pass
    # when the migration hasn't run. Suite-scope so the per-spec lookup
    # is cheap.
    def self.basket_check_present?
      if STORE_DATABASE_TYPE == :postgres
        STORE_DB.from(:pg_constraint)
                .join(:pg_class, oid: :conrelid)
                .where(Sequel[:pg_class][:relname] => 'baskets',
                       Sequel[:pg_constraint][:conname] => 'name_charset')
                .any?
      else
        STORE_DB.from(:sqlite_master).where(type: 'table', name: 'baskets').get(:sql).to_s.include?('name_charset')
      end
    end

    BASKET_NAME_SHAPE_PARITY_CASES.each do |bad_name, rule_constraint|
      it "shape rule #{rule_constraint}: validator AND DB reject #{bad_name.inspect}" do
        expect { brc100.send(:validate_basket_name!, bad_name) }
          .to raise_error(BSV::Wallet::InvalidParameterError)

        skip 'sub-issue #441 baskets.name CHECK not yet migrated' unless self.class.basket_check_present?

        expect do
          db.transaction(savepoint: true) { db[:baskets].insert(name: bad_name) }
        end.to raise_error(Sequel::CheckConstraintViolation)
      end
    end

    BASKET_NAME_RESERVATION_PARITY_CASES.each do |bad_name, rule_constraint|
      it "reservation rule #{rule_constraint}: validator rejects, DB ACCEPTS #{bad_name.inspect}" do
        expect { brc100.send(:validate_basket_name!, bad_name) }
          .to raise_error(BSV::Wallet::InvalidParameterError)

        skip 'sub-issue #441 baskets.name CHECK not yet migrated' unless self.class.basket_check_present?

        # Reservation rules are conformance-only — wallet-internal writes
        # via Engine→Store direct must land. A regression that added a
        # DB-level reservation CHECK would raise CheckConstraintViolation
        # here; the spec asserts the clean insert succeeds.
        expect do
          db.transaction(savepoint: true) { db[:baskets].insert(name: bad_name) }
        end.not_to raise_error
      end
    end
  end
end
