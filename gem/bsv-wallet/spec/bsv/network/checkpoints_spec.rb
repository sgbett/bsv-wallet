# frozen_string_literal: true

require 'bsv-wallet'

# The baked-in trust anchors for the +spv_headers+ model (HLR #335).
# Pure constant assembly + self-verification — no DB, no network.
RSpec.describe BSV::Network::Checkpoints do
  describe '.for(:mainnet)' do
    subject(:checkpoint) { described_class.for(:mainnet) }

    it 'returns the height-955000 anchor with a BlockHeader' do
      expect(checkpoint[:height]).to eq(955_000)
      expect(checkpoint[:header]).to be_a(BSV::Network::BlockHeader)
    end

    it 'self-verifies: the assembled header hashes to the published block hash' do
      # block_hash is wire order; the published hash is display hex — reverse
      # to compare. A drift here means the baked-in fields are inconsistent.
      assembled_display = checkpoint[:header].block_hash.reverse.unpack1('H*')
      expect(assembled_display).to eq('0000000000000000096bfd8763ea4a9b0866e37435ee959f50e49c1fa67ccfef')
    end

    it 'carries valid proof of work' do
      expect(checkpoint[:header].valid_pow?).to be true
    end

    it 'is a genuine 80-byte header' do
      expect(checkpoint[:header].raw.bytesize).to eq(80)
    end
  end

  describe '.for(:testnet)' do
    it 'raises UnsupportedNetworkError (phase-1 is mainnet only)' do
      expect { described_class.for(:testnet) }
        .to raise_error(described_class::UnsupportedNetworkError, /testnet/)
    end
  end

  describe '.for(unknown)' do
    it 'raises UnsupportedNetworkError for an unrecognised network' do
      expect { described_class.for(:regtest) }
        .to raise_error(described_class::UnsupportedNetworkError, /regtest/)
    end

    it 'raises UnsupportedNetworkError for nil' do
      expect { described_class.for(nil) }
        .to raise_error(described_class::UnsupportedNetworkError)
    end
  end
end
