# frozen_string_literal: true

require 'spec_helper'
require_relative 'support/wallet_derivation'
require_relative 'support/wallet_harness'

RSpec.describe E2E::WalletHarness do # rubocop:disable RSpec/SpecFilePathFormat
  let(:sdk_wif) { BSV::Primitives::PrivateKey.generate.to_wif }

  around do |example|
    snapshot = ENV.to_h
    example.run
  ensure
    ENV.replace(snapshot)
  end

  describe '.install_derived_wifs!' do
    it 'sets BSV_WALLET_WIF_W1..W5 from BSV_WALLET_WIF_SDK' do
      ENV['BSV_WALLET_WIF_SDK'] = sdk_wif
      described_class.install_derived_wifs!
      %w[W1 W2 W3 W4 W5].each do |slot|
        expect(ENV.fetch("BSV_WALLET_WIF_#{slot}", nil)).to be_a(String)
        expect(ENV.fetch("BSV_WALLET_WIF_#{slot}", nil)).not_to be_empty
      end
    end

    it 'derives the same WIF for the same SDK key (deterministic)' do
      ENV['BSV_WALLET_WIF_SDK'] = sdk_wif
      described_class.install_derived_wifs!
      first = (1..5).map { |i| ENV.fetch("BSV_WALLET_WIF_W#{i}", nil) }

      # Clear all five so the second pass genuinely re-derives the full set,
      # guarding against a regression that only re-derives a subset.
      (1..5).each { |i| ENV.delete("BSV_WALLET_WIF_W#{i}") }
      described_class.install_derived_wifs!
      second = (1..5).map { |i| ENV.fetch("BSV_WALLET_WIF_W#{i}", nil) }

      expect(first).to eq(second)
    end

    it 'raises a clear error when BSV_WALLET_WIF_SDK is not set' do
      ENV.delete('BSV_WALLET_WIF_SDK')
      expect { described_class.install_derived_wifs! }.to raise_error(KeyError)
    end
  end

  describe '.test_wallet_names' do
    it 'returns w1..w5' do
      expect(described_class.test_wallet_names).to eq(%w[w1 w2 w3 w4 w5])
    end
  end

  describe '.all_wallet_names' do
    it 'prepends sdk to test_wallet_names' do
      expect(described_class.all_wallet_names).to eq(%w[sdk w1 w2 w3 w4 w5])
    end
  end

  describe '.sdk_identity_key' do
    it 'returns the identity_key derived from BSV_WALLET_WIF_SDK' do
      ENV['BSV_WALLET_WIF_SDK'] = sdk_wif
      pk = BSV::Primitives::PrivateKey.from_wif(sdk_wif)
      expected = BSV::Wallet::KeyDeriver.new(private_key: pk).identity_key
      expect(described_class.sdk_identity_key).to eq(expected)
    end
  end

  describe '.required_env' do
    it 'lists BSV_WALLET_WIF_SDK + DATABASE_URL_SDK + DATABASE_URL_W1..5' do
      expect(described_class.required_env).to contain_exactly(
        'BSV_WALLET_WIF_SDK',
        'DATABASE_URL_SDK',
        'DATABASE_URL_W1', 'DATABASE_URL_W2', 'DATABASE_URL_W3',
        'DATABASE_URL_W4', 'DATABASE_URL_W5'
      )
    end
  end

  describe '.missing_env' do
    it 'is empty when every required key is set' do
      described_class.required_env.each { |k| ENV[k] = 'x' }
      expect(described_class.missing_env).to eq([])
    end

    it 'lists keys that are unset' do
      described_class.required_env.each { |k| ENV.delete(k) }
      ENV['BSV_WALLET_WIF_SDK'] = sdk_wif
      expect(described_class.missing_env).not_to include('BSV_WALLET_WIF_SDK')
      expect(described_class.missing_env).to include('DATABASE_URL_SDK')
    end

    it 'treats whitespace-only values as unset' do
      described_class.required_env.each { |k| ENV[k] = '   ' }
      expect(described_class.missing_env).to eq(described_class.required_env)
    end
  end
end
