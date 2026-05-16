# frozen_string_literal: true

require_relative '../shared_context'

RSpec.describe BSV::Wallet::Store::Output, :store do
  let(:action) { BSV::Wallet::Store::Action.create(outgoing: true, description: 'test action', nlocktime: 0, wtxid: SecureRandom.random_bytes(32), raw_tx: SecureRandom.random_bytes(100)) }

  def create_spendable_output(action_id: action.id, satoshis: 1000, vout: 0, **attrs)
    attrs[:locking_script] ||= SecureRandom.random_bytes(25)
    attrs[:derivation_prefix] ||= SecureRandom.uuid
    attrs[:derivation_suffix] ||= '1'
    attrs[:sender_identity_key] ||= 'self'
    output = described_class.create(action_id: action_id, satoshis: satoshis, vout: vout, **attrs)
    BSV::Wallet::Store::Spendable.create(output_id: output.id, action_id: action_id)
    output
  end

  describe 'creation' do
    it 'creates an immutable output record' do
      output = described_class.create(action_id: action.id, satoshis: 1000, vout: 0, locking_script: SecureRandom.random_bytes(25), output_type: 'root')
      expect(output.id).to be_a(Integer)
      expect(output.satoshis).to eq(1000)
      expect(output.created_at).to be_a(Time)
    end

    it 'preserves binary locking_script' do
      script = SecureRandom.random_bytes(25)
      output = described_class.create(action_id: action.id, satoshis: 1000, vout: 0, locking_script: script, output_type: 'root')
      expect(output.reload.locking_script.encoding).to eq(Encoding::BINARY)
      expect(output.locking_script).to eq(script)
    end

    it 'enforces UNIQUE on action_id + vout' do
      described_class.create(action_id: action.id, satoshis: 1000, vout: 0, locking_script: SecureRandom.random_bytes(25), output_type: 'root')
      expect { described_class.create(action_id: action.id, satoshis: 500, vout: 0, locking_script: SecureRandom.random_bytes(25), output_type: 'root') }
        .to raise_error(Sequel::UniqueConstraintViolation)
    end
  end

  describe 'associations' do
    it 'belongs to action' do
      output = described_class.create(action_id: action.id, satoshis: 1000, vout: 0, locking_script: SecureRandom.random_bytes(25), output_type: 'root')
      expect(output.action).to eq(action)
    end

    it 'has one spendable_entry' do
      output = create_spendable_output
      expect(output.reload.spendable_entry).to be_a(BSV::Wallet::Store::Spendable)
    end

    it 'has one detail' do
      output = described_class.create(action_id: action.id, satoshis: 1000, vout: 0, locking_script: SecureRandom.random_bytes(25), output_type: 'root')
      BSV::Wallet::Store::OutputDetail.create(output_id: output.id, action_id: action.id, description: 'test output')
      expect(output.reload.detail.description).to eq('test output')
    end

    it 'has one input (when claimed)' do
      output = create_spendable_output
      lock_action = BSV::Wallet::Store::Action.create(outgoing: true, description: 'test action', nlocktime: 0)
      BSV::Wallet::Store::Input.create(action_id: lock_action.id, output_id: output.id, vin: 0)
      expect(output.reload.input).to be_a(BSV::Wallet::Store::Input)
    end

    it 'has many tags' do
      output = described_class.create(action_id: action.id, satoshis: 1000, vout: 0, locking_script: SecureRandom.random_bytes(25), output_type: 'root')
      tag = BSV::Wallet::Store::Tag.create(tag: 'payment')
      BSV::Wallet::Store::OutputTag.create(output_id: output.id, tag_id: tag.id)
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
      lock_action = BSV::Wallet::Store::Action.create(outgoing: true, description: 'test action', nlocktime: 0)
      BSV::Wallet::Store::Input.create(action_id: lock_action.id, output_id: output.id, vin: 0)
      expect(output.reload.spendable?).to be false
    end

    it 'returns false when not in spendable set' do
      output = described_class.create(action_id: action.id, satoshis: 1000, vout: 0, locking_script: SecureRandom.random_bytes(25), output_type: 'root')
      expect(output.spendable?).to be false
    end
  end

  describe '.spendable' do
    it 'returns outputs that are spendable and not claimed' do
      create_spendable_output(vout: 0)
      create_spendable_output(vout: 1)
      described_class.create(action_id: action.id, satoshis: 300, vout: 2, locking_script: SecureRandom.random_bytes(25), output_type: 'root') # not in spendable

      expect(described_class.spendable.count).to eq(2)
    end

    it 'excludes outputs claimed by inputs' do
      output = create_spendable_output(vout: 0)
      create_spendable_output(vout: 1)

      lock_action = BSV::Wallet::Store::Action.create(outgoing: true, description: 'test action', nlocktime: 0)
      BSV::Wallet::Store::Input.create(action_id: lock_action.id, output_id: output.id, vin: 0)

      expect(described_class.spendable.count).to eq(1)
    end
  end

  describe '.in_basket' do
    it 'filters outputs by basket name' do
      basket = BSV::Wallet::Store::Basket.create(name: 'payments')
      output = create_spendable_output(vout: 0)
      create_spendable_output(vout: 1) # not in any basket

      BSV::Wallet::Store::OutputBasket.create(output_id: output.id, basket_id: basket.id, action_id: action.id)

      expect(described_class.in_basket('payments').count).to eq(1)
      expect(described_class.in_basket('other').count).to eq(0)
    end

    it 'treats outputs without basket rows as default basket' do
      basket = BSV::Wallet::Store::Basket.create(name: 'payments')
      output = create_spendable_output(vout: 0)
      create_spendable_output(vout: 1) # not in any basket — implicit default

      BSV::Wallet::Store::OutputBasket.create(output_id: output.id, basket_id: basket.id, action_id: action.id)

      expect(described_class.in_basket('default').count).to eq(1)
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
end
