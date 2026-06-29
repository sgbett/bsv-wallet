# frozen_string_literal: true

RSpec.describe BSV::Network::BlockHeader do
  # --- Real mainnet vectors ---------------------------------------------
  #
  # Convention reminder: +prev_hash+ / +merkle_root+ / +block_hash+ are wire
  # (internal) order bytes; the display hex a human or WhatsOnChain would
  # show is the byte-reverse. Helpers below convert at the boundary.

  def display_to_wire(hex)
    [hex].pack('H*').reverse
  end

  def wire_to_display(bytes)
    bytes.reverse.unpack1('H*')
  end

  # Genesis (height 0). The raw 80-byte header is well-known and
  # deterministic; assembled here from its canonical fields.
  let(:genesis_block_hash_display) { '000000000019d6689c085ae165831e934ff763ae46a2a6c172b3f1b60a8ce26f' }
  let(:genesis_merkle_display)     { '4a5e1e4baab89f3a32518a88c31bc87f618f76673e2cc77ab2127b7afdeda33b' }
  let(:genesis_raw) do
    [1].pack('V') +                                       # version
      display_to_wire('0' * 64) +                         # prev_hash (all zero)
      display_to_wire(genesis_merkle_display) +           # merkle_root
      [1_231_006_505].pack('V') +                         # time
      [0x1d00ffff].pack('V') +                            # bits
      [2_083_236_893].pack('V')                           # nonce
  end
  let(:genesis) { described_class.parse(genesis_raw) }

  # Height 1. prev_hash is the genesis block hash; used for +links_to?+.
  let(:height1_merkle_display) { '0e3e2357e806b6cdb1f70b54c3a3a17b6714ee1f0e68bebb44a74b1efd512098' }
  let(:height1_block_hash_display) { '00000000839a8e6886ab5951d76f411475428afc90947ee320161bbf18eb6048' }
  let(:height1_raw) do
    [1].pack('V') +
      display_to_wire(genesis_block_hash_display) + # prev_hash == genesis hash
      display_to_wire(height1_merkle_display) +
      [1_231_469_665].pack('V') +
      [0x1d00ffff].pack('V') +
      [2_573_394_689].pack('V')
  end
  let(:height1) { described_class.parse(height1_raw) }

  # The classic difficulty-1 target — the decode of nBits 0x1d00ffff.
  let(:difficulty_one_target) do
    0x00000000FFFF0000000000000000000000000000000000000000000000000000
  end

  describe '.parse' do
    it 'splits the 80-byte header into its six fields with no hash reversal' do
      expect(genesis.version).to eq(1)
      expect(genesis.prev_hash).to eq(display_to_wire('0' * 64))
      expect(genesis.merkle_root).to eq(display_to_wire(genesis_merkle_display))
      expect(genesis.time).to eq(1_231_006_505)
      expect(genesis.bits).to eq(0x1d00ffff)
      expect(genesis.nonce).to eq(2_083_236_893)
    end

    it 'retains the exact bytes it was handed (for an undrifted block hash)' do
      expect(genesis.raw).to eq(genesis_raw)
    end

    it 'treats prev_hash / merkle_root as raw wire bytes (display is the reverse)' do
      expect(wire_to_display(genesis.merkle_root)).to eq(genesis_merkle_display)
    end
  end

  describe '#block_hash (SHA256d via the SDK digest)' do
    it 'reproduces the genesis block hash' do
      expect(wire_to_display(genesis.block_hash)).to eq(genesis_block_hash_display)
    end

    it 'reproduces the height-1 block hash' do
      expect(wire_to_display(height1.block_hash)).to eq(height1_block_hash_display)
    end

    it 'returns 32 wire bytes' do
      expect(genesis.block_hash.bytesize).to eq(32)
    end

    it 'delegates to BSV::Primitives::Digest.sha256d over the raw 80 bytes' do
      allow(BSV::Primitives::Digest).to receive(:sha256d).and_call_original
      genesis.block_hash
      expect(BSV::Primitives::Digest).to have_received(:sha256d).with(genesis_raw)
    end
  end

  describe '.target_from_bits (compact nBits decode)' do
    it 'decodes 0x1d00ffff to the difficulty-1 target' do
      expect(described_class.target_from_bits(0x1d00ffff)).to eq(difficulty_one_target)
    end

    it 'decodes 0x1b0404cb to its scaled target' do
      expect(described_class.target_from_bits(0x1b0404cb))
        .to eq(0x00000000000404CB000000000000000000000000000000000000000000000000)
    end

    it 'decodes a small-exponent (<= 3) target by right-shifting the mantissa' do
      # exponent 1: target = mantissa >> (8 * (3 - 1)) = 0x123456 >> 16 = 0x12
      expect(described_class.target_from_bits(0x01123456)).to eq(0x12)
      # exponent 3: no shift.
      expect(described_class.target_from_bits(0x03123456)).to eq(0x123456)
    end

    # --- Invalid compact targets: decode rejected (nil) ----------------

    it 'rejects a target with the sign bit set (0x00800000)' do
      expect(described_class.target_from_bits(0x00800000)).to be_nil
      # And any sign-bit-set value, even with a plausible exponent.
      expect(described_class.target_from_bits(0x1d80ffff)).to be_nil
    end

    it 'rejects a zero-mantissa target' do
      expect(described_class.target_from_bits(0x20000000)).to be_nil
      expect(described_class.target_from_bits(0x04000000)).to be_nil
    end

    it 'rejects an overflowing (> 256-bit) target' do
      # 0xff123456: exponent 0xff, large left shift -> well past 256 bits.
      expect(described_class.target_from_bits(0xff123456)).to be_nil
      # exponent 34 (0x22) shifts by 248 bits; a mantissa >= 0x100 then needs
      # more than 256 bits -> overflow.
      expect(described_class.target_from_bits(0x22000100)).to be_nil
      # exponent 35 (0x23) always overflows for any non-zero mantissa.
      expect(described_class.target_from_bits(0x23000001)).to be_nil
    end

    it 'accepts the boundary that still fits within 256 bits' do
      # exponent 34 (0x22), mantissa 0x0000ff -> 0xff << 248 = top byte set, fits.
      expect(described_class.target_from_bits(0x220000ff)).to eq(0xff << 248)
      # exponent 34, mantissa 0x000001 -> 0x01 << 248, the lowest overflow-free
      # value at this exponent.
      expect(described_class.target_from_bits(0x22000001)).to eq(1 << 248)
    end
  end

  describe '#valid_pow? (block hash as a little-endian integer <= target)' do
    it 'is true for genesis (real PoW at the difficulty-1 target)' do
      expect(genesis.valid_pow?).to be(true)
    end

    it 'is true for the height-1 mainnet header' do
      expect(height1.valid_pow?).to be(true)
    end

    context 'endianness — comparison is on the LE-interpreted hash' do
      # Genesis hash bytes, but with bits reset to a HARDER target than the
      # hash actually meets, so the same hash is now numerically ABOVE the
      # target. 0x1b00ffff decodes to 0x...0000ffff00..., smaller than the
      # genesis hash 0x...0019d668..., so the (reversed) hash value exceeds
      # it. Proves the comparison really uses the LE-interpreted hash.
      let(:above_target_raw) do
        genesis_raw[0...72] + [0x1b00ffff].pack('V') + genesis_raw[76..]
      end
      let(:above_target) { described_class.parse(above_target_raw) }

      it 'rejects a header whose hash sits numerically above the target' do
        # Sanity: the genesis hash is above the 0x1b00ffff target.
        gh = genesis.block_hash.reverse.unpack1('H*').to_i(16)
        expect(gh).to be > described_class.target_from_bits(0x1b00ffff)
        expect(above_target.valid_pow?).to be(false)
      end

      it 'accepts equality (hash == target is valid, the <= boundary)' do
        # Mining a hash exactly equal to the target is infeasible, so drive
        # the boundary directly: stub the hash to the target's own bytes
        # (wire/LE order) and assert the equal case is admitted. A strict
        # +<+ would wrongly reject this.
        target_value = genesis.target
        # Big-endian target -> wire (LE) 32 bytes the way block_hash returns.
        equal_wire = [format('%064x', target_value)].pack('H*').reverse
        allow(genesis).to receive(:block_hash).and_return(equal_wire)
        expect(genesis.valid_pow?).to be(true)
      end
    end

    it 'is false when nBits is malformed (target nil), never raising' do
      bad_raw = genesis_raw[0...72] + [0x00800000].pack('V') + genesis_raw[76..]
      bad = described_class.parse(bad_raw)
      expect(bad.target).to be_nil
      expect { bad.valid_pow? }.not_to raise_error
      expect(bad.valid_pow?).to be(false)
    end

    context 'low difficulty but valid (the locked residual)' do
      # A correctly-formed header with valid PoW at an EASY (regtest-style)
      # target. Documents the accepted residual risk: a malicious sole
      # service could mine a cheap fork. The validator must NOT reject this
      # — PoW validity is independent of difficulty height.
      let(:easy_raw) do
        [
          '01000000' \
          '0000000000000000000000000000000000000000000000000000000000000000' \
          '1111111111111111111111111111111111111111111111111111111111111111' \
          '00f15365' \
          'ffff7f20' \
          '00000000'
        ].pack('H*')
      end
      let(:easy) { described_class.parse(easy_raw) }

      it 'accepts valid PoW at a regtest-difficulty (0x207fffff) target' do
        expect(easy.bits).to eq(0x207fffff)
        expect(easy.target).to eq(0x7fffff << (8 * 29))
        expect(easy.valid_pow?).to be(true)
      end
    end
  end

  describe '#links_to?' do
    it 'is true when prev_hash equals the parent block hash (raw wire compare)' do
      expect(height1.links_to?(genesis)).to be(true)
    end

    it 'is false for a non-linking parent' do
      # height1 does not chain onto itself.
      expect(height1.links_to?(height1)).to be(false)
      # Nor does genesis chain onto height1.
      expect(genesis.links_to?(height1)).to be(false)
    end
  end

  describe 'malformed input — fail closed before unpack' do
    it 'rejects a 79-byte header' do
      expect { described_class.parse(genesis_raw[0...79]) }
        .to raise_error(described_class::InvalidHeaderError)
    end

    it 'rejects an 81-byte header' do
      expect { described_class.parse("#{genesis_raw}\x00") }
        .to raise_error(described_class::InvalidHeaderError)
    end

    it 'rejects nil' do
      expect { described_class.parse(nil) }
        .to raise_error(described_class::InvalidHeaderError)
    end

    it 'rejects a non-String argument' do
      expect { described_class.parse(80) }
        .to raise_error(described_class::InvalidHeaderError)
    end
  end

  describe '.from_service_fields (WhatsOnChain field set -> wire header)' do
    # Real genesis fields in WhatsOnChain shape: bits is a hex STRING, and
    # previousblockhash / merkleroot are display hex.
    def genesis_fields(overrides = {})
      {
        version: 1,
        previousblockhash: '0' * 64,
        merkleroot: genesis_merkle_display,
        time: 1_231_006_505,
        bits: '1d00ffff',
        nonce: 2_083_236_893
      }.merge(overrides)
    end

    it 'assembles a header that reproduces the genesis block hash' do
      header = described_class.from_service_fields(**genesis_fields)
      expect(wire_to_display(header.block_hash)).to eq(genesis_block_hash_display)
    end

    it 'reverses display-hex prev_hash / merkle_root to wire order' do
      header = described_class.from_service_fields(**genesis_fields)
      expect(wire_to_display(header.merkle_root)).to eq(genesis_merkle_display)
      expect(header.prev_hash).to eq(display_to_wire('0' * 64))
    end

    it 'decodes the hex-string bits field to an integer' do
      header = described_class.from_service_fields(**genesis_fields)
      expect(header.bits).to eq(0x1d00ffff)
    end

    it 'passes the round-trip integrity check when the correct hash is supplied' do
      header = described_class.from_service_fields(**genesis_fields(hash: genesis_block_hash_display))
      expect(header).not_to be_nil
      expect(header.valid_pow?).to be(true)
    end

    it 'fails closed (nil) when a wrong hash is supplied' do
      wrong = 'f' * 64
      expect(described_class.from_service_fields(**genesis_fields(hash: wrong))).to be_nil
    end

    it 'fails closed (nil) on a nil hash field rather than raising' do
      # A nil display-hex field reaches +pack('H*')+ and raises TypeError,
      # which the method rescues into a closed (nil) failure.
      expect(described_class.from_service_fields(**genesis_fields(previousblockhash: nil)))
        .to be_nil
    end

    it 'does not certify a non-hex bits field as valid PoW' do
      # +"not-hex".to_i(16)+ is 0 (Ruby parses no leading hex digits), so a
      # garbage bits field assembles a header with bits == 0. That is a
      # zero-mantissa target, so it decodes to nil and never passes PoW —
      # the fail-closed posture holds even though assembly itself succeeds.
      header = described_class.from_service_fields(**genesis_fields(bits: 'not-hex'))
      expect(header.bits).to eq(0)
      expect(header.target).to be_nil
      expect(header.valid_pow?).to be(false)
    end
  end
end
