# frozen_string_literal: true

require_relative '../../spec_helper'

RSpec.describe BSV::Wallet::BRC29 do
  describe 'PROTOCOL_ID' do
    it 'matches the BRC-29 spec value' do
      expect(described_class::PROTOCOL_ID).to eq([2, '3241645161d8'])
    end

    it 'aliases the SDK constant by identity (one-line swap when SDK moves it)' do
      expect(described_class::PROTOCOL_ID)
        .to equal(BSV::Auth::AuthFetch::PAYMENT_PROTOCOL_ID)
    end

    it 'is frozen' do
      expect(described_class::PROTOCOL_ID).to be_frozen
    end
  end

  describe '.key_id' do
    it 'joins prefix and suffix with a single ASCII space' do
      expect(described_class.key_id('abc', 'xyz')).to eq('abc xyz')
    end

    it 'accepts every character in the base64url subset' do
      token = "#{('A'..'Z').to_a.join}#{('a'..'z').to_a.join}#{('0'..'9').to_a.join}+/=_-"
      expect(described_class.key_id(token, token)).to eq("#{token} #{token}")
    end

    it 'accepts tokens at the byte-length cap' do
      max_token = 'A' * described_class::DERIVATION_TOKEN_MAX_BYTES
      expect(described_class.key_id(max_token, max_token))
        .to eq("#{max_token} #{max_token}")
    end

    context 'when a token is empty' do
      it 'rejects an empty prefix' do
        expect { described_class.key_id('', 'xyz') }
          .to raise_error(described_class::InvalidDerivationToken, /prefix.*empty/)
      end

      it 'rejects an empty suffix' do
        expect { described_class.key_id('abc', '') }
          .to raise_error(described_class::InvalidDerivationToken, /suffix.*empty/)
      end
    end

    context 'when a token contains whitespace' do
      it 'rejects a trailing space in the prefix' do
        expect { described_class.key_id('abc ', 'xyz') }
          .to raise_error(described_class::InvalidDerivationToken, /prefix.*base64url/)
      end

      it 'rejects an embedded NBSP in the suffix' do
        expect { described_class.key_id('abc', 'xyz def') }
          .to raise_error(described_class::InvalidDerivationToken, /suffix.*base64url/)
      end

      it 'rejects a tab' do
        expect { described_class.key_id("abc\tdef", 'xyz') }
          .to raise_error(described_class::InvalidDerivationToken, /prefix.*base64url/)
      end

      it 'rejects a newline' do
        expect { described_class.key_id("abc\ndef", 'xyz') }
          .to raise_error(described_class::InvalidDerivationToken, /prefix.*base64url/)
      end
    end

    context 'when a token contains control bytes' do
      it 'rejects a NUL byte' do
        expect { described_class.key_id("abc\x00def", 'xyz') }
          .to raise_error(described_class::InvalidDerivationToken, /prefix.*base64url/)
      end

      it 'rejects DEL (0x7F)' do
        expect { described_class.key_id('abc', "xyz\x7Fdef") }
          .to raise_error(described_class::InvalidDerivationToken, /suffix.*base64url/)
      end
    end

    context 'when a token exceeds the length cap' do
      it 'rejects a prefix one byte over the cap' do
        oversize = 'A' * (described_class::DERIVATION_TOKEN_MAX_BYTES + 1)
        expect { described_class.key_id(oversize, 'x') }
          .to raise_error(described_class::InvalidDerivationToken, /prefix.*128-byte/)
      end

      it 'rejects a suffix one byte over the cap' do
        oversize = 'A' * (described_class::DERIVATION_TOKEN_MAX_BYTES + 1)
        expect { described_class.key_id('x', oversize) }
          .to raise_error(described_class::InvalidDerivationToken, /suffix.*128-byte/)
      end
    end

    context 'when a token is not a String' do
      it 'rejects nil' do
        expect { described_class.key_id(nil, 'xyz') }
          .to raise_error(described_class::InvalidDerivationToken, /prefix.*String/)
      end

      it 'rejects an integer' do
        expect { described_class.key_id('abc', 1) }
          .to raise_error(described_class::InvalidDerivationToken, /suffix.*String/)
      end
    end

    it 'rejects characters outside the base64url subset' do
      expect { described_class.key_id('abc!', 'xyz') }
        .to raise_error(described_class::InvalidDerivationToken, /prefix.*base64url/)
    end

    it 'raises a StandardError-descended error (rescuable as StandardError)' do
      expect { described_class.key_id('', 'xyz') }.to raise_error(StandardError)
    end
  end
end
