# frozen_string_literal: true

require_relative '../shared_context'

RSpec.describe BSV::Wallet::Store::Setting, :store do
  describe '.get / .set' do
    it 'stores and retrieves a value' do
      described_class.set('network', 'mainnet')
      expect(described_class.get('network')).to eq('mainnet')
    end

    it 'returns nil for missing keys' do
      expect(described_class.get('nonexistent')).to be_nil
    end

    it 'updates existing values' do
      described_class.set('network', 'mainnet')
      described_class.set('network', 'testnet')
      expect(described_class.get('network')).to eq('testnet')
      expect(described_class.where(key: 'network').count).to eq(1)
    end
  end
end
