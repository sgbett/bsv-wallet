# frozen_string_literal: true

require 'spec_helper'
require 'bsv/wallet/cli/global_options'

RSpec.describe BSV::Wallet::CLI::GlobalOptions do
  describe '.default' do
    it 'returns an options object with all-nil/false defaults' do
      opts = described_class.default

      expect(opts.wallet_name).to be_nil
      expect(opts.network).to be_nil
      expect(opts.json).to be(false)
      expect(opts.wif_override).to be_nil
      expect(opts.database_url_override).to be_nil
      expect(opts.env_file).to be_nil
    end
  end

  describe 'immutability' do
    it 'has no setter accessors (Data instances are read-only)' do
      opts = described_class.default
      expect(opts).not_to respond_to(:wallet_name=)
      expect(opts).not_to respond_to(:network=)
      expect(opts).not_to respond_to(:json=)
    end

    it 'is frozen' do
      opts = described_class.default
      expect(opts).to be_frozen
    end
  end

  describe 'keyword construction' do
    it 'accepts all fields as keyword arguments' do
      opts = described_class.new(
        wallet_name: 'alice',
        network: :testnet,
        json: true,
        wif_override: 'L1...',
        database_url_override: 'postgres://u@h/d',
        env_file: '/path/to/.env'
      )

      expect(opts.wallet_name).to eq('alice')
      expect(opts.network).to eq(:testnet)
      expect(opts.json).to be(true)
      expect(opts.wif_override).to eq('L1...')
      expect(opts.database_url_override).to eq('postgres://u@h/d')
      expect(opts.env_file).to eq('/path/to/.env')
    end
  end
end
