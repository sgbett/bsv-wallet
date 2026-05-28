# frozen_string_literal: true

require 'spec_helper'

RSpec.describe BSV::Wallet::ProviderStack do
  describe '.build' do
    context 'on mainnet' do
      around do |example|
        original = ENV.fetch('BSV_ARC_TAAL_KEY', nil)
        example.run
      ensure
        ENV['BSV_ARC_TAAL_KEY'] = original
      end

      it 'returns GorillaPool, TAAL, and WhatsOnChain when TAAL key is set' do
        ENV['BSV_ARC_TAAL_KEY'] = 'mainnet_test_key'
        names = described_class.build(network: :mainnet).map(&:name)
        expect(names).to eq(%w[GorillaPool TAAL WhatsOnChain])
      end

      it 'omits TAAL when the key is unset' do
        ENV.delete('BSV_ARC_TAAL_KEY')
        names = described_class.build(network: :mainnet).map(&:name)
        expect(names).to eq(%w[GorillaPool WhatsOnChain])
      end

      it 'treats an empty TAAL key as unset' do
        ENV['BSV_ARC_TAAL_KEY'] = '   '
        names = described_class.build(network: :mainnet).map(&:name)
        expect(names).to eq(%w[GorillaPool WhatsOnChain])
      end

      it 'puts GorillaPool first so it gets the first broadcast attempt' do
        ENV['BSV_ARC_TAAL_KEY'] = 'mainnet_test_key'
        expect(described_class.build(network: :mainnet).first.name).to eq('GorillaPool')
      end

      it 'every provider in the stack serves :broadcast' do
        ENV['BSV_ARC_TAAL_KEY'] = 'mainnet_test_key'
        stack = described_class.build(network: :mainnet)
        stack.each do |p|
          expect(p.commands).to include(:broadcast),
                                "#{p.name} cannot serve :broadcast"
        end
      end
    end

    context 'on testnet' do
      around do |example|
        original = ENV.fetch('BSV_ARC_TAAL_KEY', nil)
        ENV['BSV_ARC_TAAL_KEY'] = 'mainnet_test_key'
        example.run
      ensure
        ENV['BSV_ARC_TAAL_KEY'] = original
      end

      it 'omits TAAL even when the key is set (no published testnet ARC)' do
        names = described_class.build(network: :testnet).map(&:name)
        expect(names).to eq(%w[GorillaPool WhatsOnChain])
      end
    end
  end

  describe '.include_taal?' do
    around do |example|
      original = ENV.fetch('BSV_ARC_TAAL_KEY', nil)
      example.run
    ensure
      ENV['BSV_ARC_TAAL_KEY'] = original
    end

    it 'is true on mainnet when the key is set' do
      ENV['BSV_ARC_TAAL_KEY'] = 'mainnet_test_key'
      expect(described_class.include_taal?(:mainnet)).to be(true)
    end

    it 'is false on testnet even when the key is set' do
      ENV['BSV_ARC_TAAL_KEY'] = 'mainnet_test_key'
      expect(described_class.include_taal?(:testnet)).to be(false)
    end

    it 'is false on mainnet when the key is unset' do
      ENV.delete('BSV_ARC_TAAL_KEY')
      expect(described_class.include_taal?(:mainnet)).to be(false)
    end
  end
end
