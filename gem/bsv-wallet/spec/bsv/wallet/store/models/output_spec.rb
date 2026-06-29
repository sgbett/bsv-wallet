# frozen_string_literal: true

require_relative '../shared_context'

RSpec.describe BSV::Wallet::Store::Models::Output, :store do
  # broadcast_intent: 'none' so the funded-fixture promotions row (intent='none',
  # no authorising status) satisfies promo_path (#307).
  let(:action) { BSV::Wallet::Store::Models::Action.create(description: 'test action', broadcast_intent: 'none', wtxid: SecureRandom.random_bytes(32), raw_tx: SecureRandom.random_bytes(100)) }

  def create_spendable_output(action_id: action.id, satoshis: 1000, vout: 0, **attrs)
    attrs[:locking_script] ||= SecureRandom.random_bytes(25)
    attrs[:derivation_prefix] ||= SecureRandom.uuid
    attrs[:derivation_suffix] ||= '1'
    attrs[:sender_identity_key] ||= 'self'
    attrs[:spendable_intent] ||= 'spendable'
    output = described_class.create(action_id: action_id, satoshis: satoshis, vout: vout, **attrs)
    # spendable.action_id is FK'd to promotions(action_id) (#307) — the
    # promotions row must exist before the spendable row.
    unless BSV::Wallet::Store::Models::Promotion.where(action_id: action_id).any?
      BSV::Wallet::Store::Models::Promotion.create(action_id: action_id, intent: 'none', authorising_status: nil)
    end
    BSV::Wallet::Store::Models::Spendable.create(
      output_id: output.id, action_id: action_id, spendable_intent: 'spendable'
    )
    output
  end

  # Build a wallet-owned root output (locking_script matches the per-wallet
  # root P2PKH literal, no derivation triple, spendable_intent='spendable')
  # for tests that need a no-controls spendable row.
  def create_root_output(action_id: action.id, satoshis: 1000, vout: 0)
    described_class.create(
      action_id: action_id, satoshis: satoshis, vout: vout,
      locking_script: TEST_ROOT_LOCKING_SCRIPT,
      spendable_intent: 'spendable'
    )
  end

  describe 'creation' do
    it 'creates an immutable output record' do
      output = create_root_output
      expect(output.id).to be_a(Integer)
      expect(output.satoshis).to eq(1000)
      expect(output.created_at).to be_a(Time)
    end

    it 'preserves binary locking_script' do
      output = create_root_output
      expect(output.reload.locking_script.encoding).to eq(Encoding::BINARY)
      expect(output.locking_script).to eq(TEST_ROOT_LOCKING_SCRIPT)
    end

    it 'enforces UNIQUE on action_id + vout' do
      create_root_output(vout: 0)
      expect { create_root_output(satoshis: 500, vout: 0) }
        .to raise_error(Sequel::UniqueConstraintViolation)
    end
  end

  describe 'associations' do
    it 'belongs to action' do
      output = create_root_output
      expect(output.action).to eq(action)
    end

    it 'has one spendable_entry' do
      output = create_spendable_output
      expect(output.reload.spendable_entry).to be_a(BSV::Wallet::Store::Models::Spendable)
    end

    it 'has one detail' do
      output = create_root_output
      BSV::Wallet::Store::Models::OutputDetail.create(output_id: output.id, action_id: action.id, description: 'test output')
      expect(output.reload.detail.description).to eq('test output')
    end

    it 'has one input (when claimed)' do
      output = create_spendable_output
      lock_action = BSV::Wallet::Store::Models::Action.create(description: 'test action')
      BSV::Wallet::Store::Models::Input.create(action_id: lock_action.id, output_id: output.id, vin: 0)
      expect(output.reload.input).to be_a(BSV::Wallet::Store::Models::Input)
    end

    it 'has many tags' do
      output = create_root_output
      tag = BSV::Wallet::Store::Models::Tag.create(tag: 'payment')
      BSV::Wallet::Store::Models::OutputTag.create(output_id: output.id, tag_id: tag.id)
      expect(output.reload.tags.map(&:tag)).to eq(['payment'])
    end
  end

  describe '#spendable?' do
    it 'returns true when spendable and not claimed' do
      output = create_spendable_output
      expect(output.reload.spendable?).to be true
    end

    it 'returns false when claimed by an input' do
      output = create_spendable_output
      lock_action = BSV::Wallet::Store::Models::Action.create(description: 'test action')
      BSV::Wallet::Store::Models::Input.create(action_id: lock_action.id, output_id: output.id, vin: 0)
      expect(output.reload.spendable?).to be false
    end

    it 'returns false when not in spendable set' do
      output = create_root_output
      expect(output.spendable?).to be false
    end
  end

  describe '.spendable' do
    it 'returns outputs that are spendable and not claimed' do
      create_spendable_output(vout: 0)
      create_spendable_output(vout: 1)
      create_root_output(satoshis: 300, vout: 2) # not in spendable

      expect(described_class.spendable.count).to eq(2)
    end

    it 'excludes outputs claimed by inputs' do
      output = create_spendable_output(vout: 0)
      create_spendable_output(vout: 1)

      lock_action = BSV::Wallet::Store::Models::Action.create(description: 'test action')
      BSV::Wallet::Store::Models::Input.create(action_id: lock_action.id, output_id: output.id, vin: 0)

      expect(described_class.spendable.count).to eq(1)
    end
  end

  describe '.in_basket' do
    it 'filters outputs by basket name' do
      basket = BSV::Wallet::Store::Models::Basket.create(name: 'payments')
      output = create_spendable_output(vout: 0)
      create_spendable_output(vout: 1) # not in any basket

      BSV::Wallet::Store::Models::OutputBasket.create(output_id: output.id, basket_id: basket.id, action_id: action.id)

      expect(described_class.in_basket('payments').count).to eq(1)
      expect(described_class.in_basket('other').count).to eq(0)
    end

    it 'matches outputs with no basket row when called with nil' do
      basket = BSV::Wallet::Store::Models::Basket.create(name: 'payments')
      output = create_spendable_output(vout: 0)
      create_spendable_output(vout: 1) # no basket row — unbasketed

      BSV::Wallet::Store::Models::OutputBasket.create(output_id: output.id, basket_id: basket.id, action_id: action.id)

      expect(described_class.in_basket(nil).count).to eq(1)
    end

    it 'matches outputs in any of a list of baskets' do
      a = BSV::Wallet::Store::Models::Basket.create(name: 'first set')
      b = BSV::Wallet::Store::Models::Basket.create(name: 'other set')
      o_a = create_spendable_output(vout: 0)
      o_b = create_spendable_output(vout: 1)
      create_spendable_output(vout: 2) # unbasketed
      BSV::Wallet::Store::Models::OutputBasket.create(output_id: o_a.id, basket_id: a.id, action_id: action.id)
      BSV::Wallet::Store::Models::OutputBasket.create(output_id: o_b.id, basket_id: b.id, action_id: action.id)

      expect(described_class.in_basket(['first set', 'other set']).count).to eq(2)
    end
  end

  describe '.min_satoshis' do
    it 'filters outputs by minimum value' do
      create_spendable_output(satoshis: 100, vout: 0)
      create_spendable_output(satoshis: 500, vout: 1)
      create_spendable_output(satoshis: 1000, vout: 2)

      expect(described_class.min_satoshis(500).count).to eq(2)
    end
  end

  # --- #validate (app-layer mirror of the DB CHECKs, HLR #467) ---
  #
  # The Output model's +#validate+ encodes the same 8-permutation matrix
  # the +outputs+ table CHECKs (+controls_all_or_nothing+ +
  # +spendable_recoverable+) enforce structurally. The two layers exist
  # in parallel: the model surfaces clean field-level errors before the
  # DB rejects, the DB is the structural backstop. These specs exercise
  # the model side via +valid?+ / +errors+ — no DB roundtrip. The
  # +constraints_spec.rb+ matrix covers the same shapes at the DB layer.
  describe '#validate (8-permutation matrix)' do
    let(:root_script) { TEST_ROOT_LOCKING_SCRIPT }
    let(:non_root_script) { SecureRandom.random_bytes(25) }

    def build_output(root:, controls:, intent:)
      attrs = {
        action_id: action.id, satoshis: 1000, vout: 0,
        locking_script: root ? root_script : non_root_script,
        spendable_intent: intent
      }
      if controls
        attrs[:derivation_prefix] = 'prefix'
        attrs[:derivation_suffix] = 'suffix'
        attrs[:sender_identity_key] = 'self'
      end
      described_class.new(attrs)
    end

    # [label, root, controls, intent, valid?]
    matrix = [
      ['root + no_controls + spendable',    true,  false, 'spendable', true],
      ['root + no_controls + none',         true,  false, 'none',      false],
      ['root + controls + spendable',       true,  true,  'spendable', false],
      ['root + controls + none',            true,  true,  'none',      false],
      ['nonroot + no_controls + spendable', false, false, 'spendable', false],
      ['nonroot + no_controls + none',      false, false, 'none',      true],
      ['nonroot + controls + spendable',    false, true,  'spendable', true],
      ['nonroot + controls + none',         false, true,  'none',      true]
    ]

    matrix.each do |label, root, controls, intent, want_valid|
      it "permutation [#{label}] is #{want_valid ? 'valid' : 'invalid'}" do
        output = build_output(root: root, controls: controls, intent: intent)
        if want_valid
          expect(output.valid?).to be(true), "expected valid; got errors=#{output.errors.full_messages}"
          # +Sequel::Model::Errors#[]+ returns +nil+ for an un-touched field
          # (Hash-like, not Array-like). +to_a+ normalises so the assertion
          # is consistent across "no errors" and "field has errors" cases.
          expect(Array(output.errors[:spendable_intent])).to be_empty
        else
          expect(output.valid?).to be(false)
          expect(output.errors[:spendable_intent]).not_to be_nil
          expect(output.errors[:spendable_intent].first).to include('HLR #467')
          expect(output.errors[:spendable_intent].first).to include('intent-and-outcomes.md')
        end
      end
    end

    describe 'controls_all_or_nothing' do
      # Partial derivation triple — orthogonal to the 8-permutation matrix
      # (which only exercises all-three-set or all-three-absent), so
      # specced separately.
      it 'rejects partial fill (prefix + suffix, no sender_identity_key)' do
        output = described_class.new(
          action_id: action.id, satoshis: 1000, vout: 0,
          locking_script: SecureRandom.random_bytes(25),
          spendable_intent: 'spendable',
          derivation_prefix: 'prefix', derivation_suffix: 'suffix',
          sender_identity_key: nil
        )

        expect(output.valid?).to be(false)
        expect(output.errors[:derivation_prefix]).not_to be_empty
        expect(output.errors[:derivation_prefix].first).to include('all set or all absent')
        expect(output.errors[:derivation_prefix].first).to include('HLR #467')
      end

      it 'rejects partial fill (only sender_identity_key set)' do
        output = described_class.new(
          action_id: action.id, satoshis: 1000, vout: 0,
          locking_script: SecureRandom.random_bytes(25),
          spendable_intent: 'none',
          derivation_prefix: nil, derivation_suffix: nil,
          sender_identity_key: 'self'
        )

        expect(output.valid?).to be(false)
        expect(output.errors[:derivation_prefix]).not_to be_empty
      end
    end

    describe 'pre-checks (before structural matrix)' do
      it 'flags missing expected_root_script with a configuration-error message' do
        original = described_class.expected_root_script
        described_class.expected_root_script = nil
        output = described_class.new(
          action_id: action.id, satoshis: 1000, vout: 0,
          locking_script: SecureRandom.random_bytes(25),
          spendable_intent: 'spendable'
        )

        expect(output.valid?).to be(false)
        expect(output.errors[:spendable_intent].first).to include('expected_root_script not configured')
        expect(output.errors[:spendable_intent].first).to include('Store.new(identity_pubkey_hash:)')
      ensure
        described_class.expected_root_script = original
      end

      it 'flags unrecognised spendable_intent values with a field-level message' do
        output = described_class.new(
          action_id: action.id, satoshis: 1000, vout: 0,
          locking_script: SecureRandom.random_bytes(25),
          spendable_intent: 'garbage'
        )

        expect(output.valid?).to be(false)
        expect(output.errors[:spendable_intent].first).to include('must be one of: spendable, none')
        expect(output.errors[:spendable_intent].first).to include('garbage')
      end

      it 'flags nil spendable_intent with a field-level message' do
        output = described_class.new(
          action_id: action.id, satoshis: 1000, vout: 0,
          locking_script: SecureRandom.random_bytes(25),
          spendable_intent: nil
        )

        expect(output.valid?).to be(false)
        expect(output.errors[:spendable_intent].first).to include('must be one of: spendable, none')
      end
    end

    describe 'save behaviour' do
      it 'raises Sequel::ValidationFailed when an invalid output is saved' do
        output = build_output(root: true, controls: false, intent: 'none')

        expect { output.save }.to raise_error(Sequel::ValidationFailed, /HLR #467/)
      end
    end
  end
end
