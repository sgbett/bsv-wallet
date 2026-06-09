# frozen_string_literal: true

require 'spec_helper'
require_relative 'wallet_derivation'
require_relative 'wallet_harness'

RSpec.describe E2E::WalletHarness do # rubocop:disable RSpec/SpecFilePathFormat
  let(:sdk_wif) { BSV::Primitives::PrivateKey.generate.to_wif }
  let(:base) { 'postgres://localhost:5432/' }

  around do |example|
    snapshot = ENV.to_h
    example.run
  ensure
    ENV.replace(snapshot)
    BSV::Wallet::Fixtures.reset!
  end

  describe '.install_fixtures!' do
    it 'registers sdk + w1..w5 with WIFs derived from BSV_WALLET_WIF_SDK' do
      ENV['BSV_WALLET_WIF_SDK'] = sdk_wif
      ENV['BSV_WALLET_POSTGRES'] = base
      described_class.install_fixtures!

      expect(BSV::Wallet::Fixtures.wallet(:sdk).wif).to eq(sdk_wif)
      %w[w1 w2 w3 w4 w5].each do |name|
        wallet = BSV::Wallet::Fixtures.wallet(name.to_sym)
        expect(wallet.wif).to be_a(String).and(satisfy { |w| !w.empty? })
        expect(wallet.database_url).to eq("postgres://localhost:5432/bsv_wallet_#{name}")
      end
    end

    it 'is deterministic — re-running yields the same derived WIFs' do
      ENV['BSV_WALLET_WIF_SDK'] = sdk_wif
      ENV['BSV_WALLET_POSTGRES'] = base
      described_class.install_fixtures!
      first = (1..5).map { |i| BSV::Wallet::Fixtures.wallet(:"w#{i}").wif }

      BSV::Wallet::Fixtures.reset!
      described_class.install_fixtures!
      second = (1..5).map { |i| BSV::Wallet::Fixtures.wallet(:"w#{i}").wif }

      expect(first).to eq(second)
    end

    it 'raises a clear error when BSV_WALLET_WIF_SDK is not set' do
      ENV.delete('BSV_WALLET_WIF_SDK')
      ENV['BSV_WALLET_POSTGRES'] = base
      expect { described_class.install_fixtures! }.to raise_error(KeyError)
    end

    it 'raises a clear error when BSV_WALLET_POSTGRES is not set' do
      ENV['BSV_WALLET_WIF_SDK'] = sdk_wif
      ENV.delete('BSV_WALLET_POSTGRES')
      expect { described_class.install_fixtures! }.to raise_error(KeyError)
    end

    it 'raises a clear error when BSV_WALLET_POSTGRES is blank or whitespace-only' do
      ENV['BSV_WALLET_WIF_SDK'] = sdk_wif
      ENV['BSV_WALLET_POSTGRES'] = '   '
      expect { described_class.install_fixtures! }.to raise_error(KeyError)
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
    it 'lists BSV_WALLET_WIF_SDK + BSV_WALLET_POSTGRES' do
      expect(described_class.required_env).to contain_exactly(
        'BSV_WALLET_WIF_SDK',
        'BSV_WALLET_POSTGRES'
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
      expect(described_class.missing_env).to include('BSV_WALLET_POSTGRES')
    end

    it 'treats whitespace-only values as unset' do
      described_class.required_env.each { |k| ENV[k] = '   ' }
      expect(described_class.missing_env).to eq(described_class.required_env)
    end
  end
end
