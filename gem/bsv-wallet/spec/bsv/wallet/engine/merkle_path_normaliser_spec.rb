# frozen_string_literal: true

require 'spec_helper'
require 'bsv-wallet'

RSpec.describe BSV::Wallet::Engine::MerklePathNormaliser do
  # Real-shaped wtxid; +normalize_tsc+ runs validate_wtxid! which rejects
  # anything not exactly 32 binary bytes.
  let(:wtxid) { SecureRandom.random_bytes(32) }
  let(:dtxid) { wtxid.reverse.unpack1('H*') }

  describe '.normalize' do
    it 'passes binary (ASCII-8BIT) merkle paths through unchanged' do
      binary = SecureRandom.random_bytes(40)
      expect(described_class.normalize(binary, wtxid)).to equal(binary)
    end

    it 'decodes hex strings to binary' do
      bytes = "\x01\x02\x03\xfe\xff".b
      hex = bytes.unpack1('H*')
      expect(described_class.normalize(hex, wtxid)).to eq(bytes)
    end

    it 'falls back to a binary reinterpretation when the string is neither binary nor pure hex' do
      mixed = 'not-hex-and-not-binary'
      result = described_class.normalize(mixed, wtxid)
      expect(result.encoding).to eq(Encoding::ASCII_8BIT)
    end

    it 'delegates a Hash to .normalize_tsc' do
      tsc = { txOrId: dtxid, index: 0, nodes: [], blockHeight: 100 }
      fake = double('MerklePath', to_binary: 'BINARY_RESULT'.b)
      allow(BSV::Transaction::MerklePath).to receive(:from_tsc).and_return(fake)
      expect(described_class.normalize(tsc, wtxid)).to eq('BINARY_RESULT'.b)
    end
  end

  describe '.normalize_tsc' do
    it 'accepts snake_case keys (tx_or_id / block_height) as well as camelCase' do
      tsc = { tx_or_id: dtxid, index: 1, nodes: [], block_height: 200 }
      fake = double('MerklePath', to_binary: 'BIN'.b)
      allow(BSV::Transaction::MerklePath).to receive(:from_tsc).and_return(fake)

      described_class.normalize_tsc(tsc, wtxid)

      expect(BSV::Transaction::MerklePath).to have_received(:from_tsc).with(
        dtxid_hex: dtxid, index: 1, nodes: [], block_height: 200
      )
    end

    it 'falls back to deriving dtxid from the wtxid when txOrId is omitted' do
      tsc = { index: 0, nodes: [], blockHeight: 50 }
      fake = double('MerklePath', to_binary: 'BIN'.b)
      allow(BSV::Transaction::MerklePath).to receive(:from_tsc).and_return(fake)

      described_class.normalize_tsc(tsc, wtxid)

      expect(BSV::Transaction::MerklePath).to have_received(:from_tsc).with(
        hash_including(dtxid_hex: dtxid)
      )
    end

    it 'raises when wtxid is not 32 binary bytes (validate_wtxid! guard)' do
      tsc = { txOrId: dtxid, index: 0, nodes: [], blockHeight: 1 }
      expect { described_class.normalize_tsc(tsc, 'too-short') }.to raise_error(ArgumentError)
    end
  end
end
