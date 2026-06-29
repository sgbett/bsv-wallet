# frozen_string_literal: true

require_relative 'shared_context'

# Store-level block-header persistence for the +spv_headers+ model (#335):
# append-or-reject in +record_block_header+, plus the +validated_tip+ /
# +header_at+ readers. Runs on both backends (+:store+, no +:postgres+
# gate) — the in-memory SQLite default run must pass; Postgres is QA-verified.
#
# Header bytes are bound via +Sequel.blob+ so the +header_length+ (= 80)
# and +header_root_match+ (bytes 36..67 == merkle_root) CHECKs see byte
# lengths, not character counts.
RSpec.describe 'Store block-header append-or-reject (#335)', :store do
  # An 80-byte header carrying +root+ at the merkle_root offset (bytes
  # 36..67). +tag+ varies the surrounding bytes so two headers with the
  # same root still differ (the competing-header case).
  def header_with_root(root, tag: 0x11)
    (+(tag.chr * 36).b) << root.b << (+"\x22".b * 12)
  end

  let(:root)       { SecureRandom.random_bytes(32) }
  let(:other_root) { SecureRandom.random_bytes(32) }
  let(:hash_bin)   { SecureRandom.random_bytes(32) }

  describe '#record_block_header with a header (validated row)' do
    it 'persists the header, merkle_root and block_hash' do
      store.record_block_header(height: 955_000, merkle_root: root,
                                block_hash: hash_bin, header: header_with_root(root))

      expect(store.header_at(height: 955_000)).to eq(header_with_root(root))
      expect(store.find_block(height: 955_000)[:merkle_root]).to eq(root)
      expect(store.find_block(height: 955_000)[:block_hash]).to eq(hash_bin)
    end

    it 're-presenting the identical header is an idempotent no-op' do
      hdr = header_with_root(root)
      store.record_block_header(height: 955_000, merkle_root: root, header: hdr)
      expect do
        store.record_block_header(height: 955_000, merkle_root: root, header: hdr)
      end.not_to raise_error
      expect(store.header_at(height: 955_000)).to eq(hdr)
    end

    it 'rejects a COMPETING header at an already-validated height (reorg evidence preserved)' do
      original = header_with_root(root, tag: 0x11)
      store.record_block_header(height: 955_000, merkle_root: root, header: original)

      competing = header_with_root(root, tag: 0x33) # same root, different bytes
      expect do
        store.record_block_header(height: 955_000, merkle_root: root, header: competing)
      end.to raise_error(BSV::Wallet::CompetingBlockHeaderError)

      # The original validated row is untouched.
      expect(store.header_at(height: 955_000)).to eq(original)
    end

    it 'upgrades a trusted-service (header-NULL) row to validated in place' do
      # Trusted path first: merkle_root only, no header.
      store.record_block_header(height: 955_000, merkle_root: root)
      expect(store.header_at(height: 955_000)).to be_nil

      # Validated path: same height, supply the header → upgrade.
      hdr = header_with_root(root)
      store.record_block_header(height: 955_000, merkle_root: root,
                                block_hash: hash_bin, header: hdr)
      expect(store.header_at(height: 955_000)).to eq(hdr)
    end
  end

  describe '#record_block_header trusted-service path (no header)' do
    it 'does NOT downgrade a header-bearing row to NULL' do
      hdr = header_with_root(root)
      store.record_block_header(height: 955_000, merkle_root: root, header: hdr)

      # A trusted-path re-touch at the same height must leave the header intact.
      store.record_block_header(height: 955_000, merkle_root: root, block_hash: hash_bin)

      expect(store.header_at(height: 955_000)).to eq(hdr)
    end

    it 'still upserts merkle_root for a header-NULL row (today’s behaviour)' do
      store.record_block_header(height: 955_001, merkle_root: root)
      store.record_block_header(height: 955_001, merkle_root: other_root)
      expect(store.find_block(height: 955_001)[:merkle_root]).to eq(other_root)
    end
  end

  describe '#header_at' do
    it 'returns the 80-byte header for a validated row' do
      hdr = header_with_root(root)
      store.record_block_header(height: 955_000, merkle_root: root, header: hdr)
      expect(store.header_at(height: 955_000)).to eq(hdr)
    end

    it 'returns nil for a header-NULL (trusted-service) row' do
      store.record_block_header(height: 955_000, merkle_root: root)
      expect(store.header_at(height: 955_000)).to be_nil
    end

    it 'returns nil for an absent height' do
      expect(store.header_at(height: 999_999)).to be_nil
    end
  end

  describe '#validated_tip' do
    let(:checkpoint) { 955_000 }

    def validate(height)
      r = SecureRandom.random_bytes(32)
      store.record_block_header(height: height, merkle_root: r, header: header_with_root(r))
    end

    it 'returns nil when the chain is unseeded (no checkpoint row)' do
      expect(store.validated_tip(from_height: checkpoint)).to be_nil
    end

    it 'returns the checkpoint height when only the anchor is validated' do
      validate(checkpoint)
      expect(store.validated_tip(from_height: checkpoint)).to eq(checkpoint)
    end

    it 'advances over a contiguous run of validated rows' do
      (checkpoint..(checkpoint + 4)).each { |h| validate(h) }
      expect(store.validated_tip(from_height: checkpoint)).to eq(checkpoint + 4)
    end

    it 'STOPS at a gap — a header-island above a missing height is not the tip' do
      validate(checkpoint)
      validate(checkpoint + 1)
      validate(checkpoint + 2)
      # gap at checkpoint+3
      validate(checkpoint + 4)
      validate(checkpoint + 5)
      expect(store.validated_tip(from_height: checkpoint)).to eq(checkpoint + 2)
    end

    it 'ignores a trusted-service (header-NULL) row when computing the run' do
      validate(checkpoint)
      validate(checkpoint + 1)
      # trusted-only row at checkpoint+2 → breaks the validated run there
      store.record_block_header(height: checkpoint + 2, merkle_root: SecureRandom.random_bytes(32))
      validate(checkpoint + 3)
      expect(store.validated_tip(from_height: checkpoint)).to eq(checkpoint + 1)
    end

    it 'returns nil when the checkpoint height itself is not validated' do
      # A validated island above the checkpoint, but no anchor row.
      validate(checkpoint + 1)
      validate(checkpoint + 2)
      expect(store.validated_tip(from_height: checkpoint)).to be_nil
    end
  end
end
