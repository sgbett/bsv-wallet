# frozen_string_literal: true

require 'spec_helper'
require 'bsv/wallet/cli/secrets'
require 'bsv/wallet/cli/inspect_overrides'

RSpec.describe BSV::Wallet::CLI::Secrets do
  describe '.redact' do
    it 'elides hash values whose keys match sensitive field names' do
      input = { wif: 'L1...', identity_key: '02ab...', wallet: 'alice' }
      result = described_class.redact(input)

      expect(result[:wif]).to eq('[REDACTED]')
      expect(result[:identity_key]).to eq('02ab...') # interchange identifier, not secret
      expect(result[:wallet]).to eq('alice')
    end

    it 'elides derivation_prefix and derivation_suffix' do
      input = { derivation_prefix: 'abc', derivation_suffix: 'def', basket: 'received' }
      result = described_class.redact(input)

      expect(result[:derivation_prefix]).to eq('[REDACTED]')
      expect(result[:derivation_suffix]).to eq('[REDACTED]')
      expect(result[:basket]).to eq('received')
    end

    it 'matches *_key suffixes except identity_key / public_key' do
      input = { root_key: 'X', private_key: 'X', signing_key: 'X', identity_key: 'X', public_key: 'X' }
      result = described_class.redact(input)

      expect(result[:root_key]).to eq('[REDACTED]')
      expect(result[:private_key]).to eq('[REDACTED]')
      expect(result[:signing_key]).to eq('[REDACTED]')
      expect(result[:identity_key]).to eq('X')
      expect(result[:public_key]).to eq('X')
    end

    it 'recurses into nested hashes' do
      input = { outer: { inner: { wif: 'L1...', amount: 100 } } }
      result = described_class.redact(input)

      expect(result[:outer][:inner][:wif]).to eq('[REDACTED]')
      expect(result[:outer][:inner][:amount]).to eq(100)
    end

    it 'recurses into arrays of hashes' do
      input = [{ wif: 'L1' }, { wif: 'L2' }, 'plain string']
      result = described_class.redact(input)

      expect(result[0][:wif]).to eq('[REDACTED]')
      expect(result[1][:wif]).to eq('[REDACTED]')
      expect(result[2]).to eq('plain string')
    end

    it 'matches string keys as well as symbols' do
      input = { 'wif' => 'L1', 'WIF' => 'L2' }
      result = described_class.redact(input)

      expect(result['wif']).to eq('[REDACTED]')
      expect(result['WIF']).to eq('[REDACTED]')
    end

    it 'is idempotent' do
      input = { wif: 'L1', nested: { secret: 's' } }
      once = described_class.redact(input)
      twice = described_class.redact(once)

      expect(twice).to eq(once)
    end

    it 'returns scalars unchanged' do
      expect(described_class.redact(42)).to eq(42)
      expect(described_class.redact(nil)).to be_nil
      expect(described_class.redact('plain')).to eq('plain')
      expect(described_class.redact(:sym)).to eq(:sym)
    end
  end

  describe 'KeyDeriver#inspect' do
    let(:key_deriver) do
      # Deterministic WIF for the test; the inspect output's contents
      # are what matters, not the keypair.
      wif = 'L1RrrnXkcKut5DEMwtDthjwRcTTwED36thyL1DebVrKuwvohjMNi'
      private_key = BSV::Primitives::PrivateKey.from_wif(wif)
      BSV::Wallet::KeyDeriver.new(private_key: private_key)
    end

    it 'elides the root private key from the inspect output' do
      output = key_deriver.inspect
      expect(output).not_to include(key_deriver.root_private_key.to_wif)
    end

    it 'still surfaces the identity_key (interchange identifier)' do
      output = key_deriver.inspect
      expect(output).to include(key_deriver.identity_key[0..10])
    end

    it 'reads as a tagged KeyDeriver' do
      expect(key_deriver.inspect).to start_with('#<BSV::Wallet::KeyDeriver')
    end
  end
end
