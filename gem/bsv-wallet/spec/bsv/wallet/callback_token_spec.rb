# frozen_string_literal: true

require 'bsv-wallet'

RSpec.describe BSV::Wallet::CallbackToken do
  describe '.derive' do
    let(:wif_a) { 'L1aW4aubDFB7yfras2S1mN3bqg9nwySY8nkoLmJebSLD5BWv3ENZ' }
    let(:wif_b) { 'KxSP9mMNXTbBVAfAFFmNqXLLZpKp7XR1xZv8XbgwAU6kJYtfdAYy' }

    it 'returns a 32-char hex string' do
      token = described_class.derive(wif_a)
      expect(token).to match(/\A[0-9a-f]{32}\z/)
    end

    it 'is deterministic — same WIF produces the same token' do
      first = described_class.derive(wif_a)
      second = described_class.derive(wif_a)
      expect(second).to eq(first)
    end

    it 'differentiates between WIFs' do
      expect(described_class.derive(wif_a)).not_to eq(described_class.derive(wif_b))
    end

    it 'uses the domain-separation tag (changing it changes the output)' do
      # Sanity-check: the token isn't just HMAC-of-WIF-with-empty-key;
      # the DOMAIN constant is in the construction.
      expected = OpenSSL::HMAC.digest('SHA256', wif_a, described_class::DOMAIN)[0, 16].unpack1('H*')
      expect(described_class.derive(wif_a)).to eq(expected)
    end

    it 'raises ArgumentError on nil' do
      expect { described_class.derive(nil) }.to raise_error(ArgumentError, /non-empty/)
    end

    it 'raises ArgumentError on empty string' do
      expect { described_class.derive('') }.to raise_error(ArgumentError, /non-empty/)
    end
  end
end
