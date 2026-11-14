# frozen_string_literal: true

require 'spec_helper'
require 'bsv-wallet'

RSpec.describe BSV::Wallet::Engine::HintEnvelope do
  let(:beef) { "\x01\x01\x01\x01#{'b' * 40}".b }

  describe '.encode / .decode' do
    it 'round-trips the action id and the BEEF bytes' do
      message = described_class.encode(action_id: 7, beef: beef)

      expect(described_class.decode([message])).to eq(action_id: 7, beef: beef)
    end

    it 'carries an action id up to the 64-bit maximum' do
      message = described_class.encode(action_id: (2**64) - 1, beef: beef)

      expect(described_class.decode([message])[:action_id]).to eq((2**64) - 1)
    end

    it 'decodes to plain data: an Integer and a binary String' do
      hint = described_class.decode([described_class.encode(action_id: 7, beef: beef)])

      expect(hint[:action_id]).to be_an(Integer)
      expect(hint[:beef]).to be_a(String)
      expect(hint[:beef].encoding).to eq(Encoding::BINARY)
    end
  end

  describe '.encode' do
    it 'refuses a negative action id' do
      expect { described_class.encode(action_id: -1, beef: beef) }.to raise_error(ArgumentError, /action_id/)
    end

    it 'refuses a non-Integer action id' do
      expect { described_class.encode(action_id: '7', beef: beef) }.to raise_error(ArgumentError, /action_id/)
    end

    it 'refuses an empty BEEF' do
      expect { described_class.encode(action_id: 7, beef: ''.b) }.to raise_error(ArgumentError, /BEEF/)
    end

    it 'refuses a BEEF over the cap' do
      stub_const("#{described_class}::MAX_BEEF_BYTES", 8)

      expect { described_class.encode(action_id: 7, beef: 'x' * 9) }.to raise_error(ArgumentError, /BEEF/)
    end
  end

  describe '.decode' do
    let(:valid) { described_class.encode(action_id: 7, beef: beef) }

    it 'refuses a Marshal payload' do
      marshalled = Marshal.dump(action_id: 7, beef: beef)

      expect { described_class.decode([marshalled]) }.to raise_error(described_class::MalformedError, /version/)
    end

    it 'refuses a message of more than one frame' do
      expect { described_class.decode([valid, valid]) }.to raise_error(described_class::MalformedError, /frame/)
    end

    it 'refuses a message with no frames' do
      expect { described_class.decode([]) }.to raise_error(described_class::MalformedError, /frame/)
    end

    it 'refuses a message no longer than the header' do
      expect { described_class.decode([valid.byteslice(0, 9)]) }
        .to raise_error(described_class::MalformedError, /short/)
    end

    it 'refuses an unknown version' do
      expect { described_class.decode(["\x02".b + valid.byteslice(1..)]) }
        .to raise_error(described_class::MalformedError, /version/)
    end

    it 'refuses a BEEF over the cap' do
      message = valid
      stub_const("#{described_class}::MAX_BEEF_BYTES", beef.bytesize - 1)

      expect { described_class.decode([message]) }.to raise_error(described_class::MalformedError, /exceeds/)
    end

    it 'accepts a BEEF exactly at the cap' do
      message = valid
      stub_const("#{described_class}::MAX_BEEF_BYTES", beef.bytesize)

      expect(described_class.decode([message])[:beef]).to eq(beef)
    end
  end

  describe '.max_bytes' do
    it 'is the header plus the BEEF cap, the largest frame a valid hint needs' do
      expect(described_class.max_bytes).to eq(described_class::HEADER_BYTES + described_class::MAX_BEEF_BYTES)
    end
  end
end
