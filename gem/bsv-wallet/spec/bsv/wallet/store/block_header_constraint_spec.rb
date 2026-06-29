# frozen_string_literal: true

require_relative 'shared_context'

# The +header_length+ and +header_root_match+ CHECKs on +blocks+ (#335).
# Unlike +constraints_spec.rb+ (gated +:postgres+ because it exercises
# ALTER-added rules), these are inline +create_table+ constraints, so both
# backends enforce them — hence +:store+ alone, no +:postgres+ gate. The
# in-memory SQLite default run must pass; Postgres is verified in QA.
#
# All header bytes are bound via +Sequel.blob+ so SQLite's +length()+ counts
# bytes, not characters — matching how +constraints_spec.rb+ inserts
# +merkle_root+ / +block_hash+ blobs.
RSpec.describe 'blocks header constraints', :store do
  # Build an 80-byte header carrying +root+ at the merkle_root offset
  # (bytes 36..67, 0-indexed): 36 bytes of version+prev_hash, then the
  # 32-byte root, then 12 bytes of time+bits+nonce.
  def header_with_root(root, total: 80)
    body = (+"\x11".b * 36) << root.b << (+"\x22".b * 12)
    body = body[0, total] if total < body.bytesize
    body << ("\x00".b * (total - body.bytesize)) if total > body.bytesize
    body
  end

  let(:root) { SecureRandom.random_bytes(32) }

  it 'accepts an 80-byte header whose embedded root matches merkle_root' do
    expect do
      db[:blocks].insert(height: 700_001, merkle_root: Sequel.blob(root),
                         header: Sequel.blob(header_with_root(root)))
    end.not_to raise_error
  end

  it 'accepts a NULL header (trusted-service row)' do
    expect do
      db[:blocks].insert(height: 700_002, merkle_root: Sequel.blob(root), header: nil)
    end.not_to raise_error
  end

  it 'rejects a header of 79 bytes' do
    expect do
      db.transaction(savepoint: true) do
        db[:blocks].insert(height: 700_003, merkle_root: Sequel.blob(root),
                           header: Sequel.blob(header_with_root(root, total: 79)))
      end
    end.to raise_error(Sequel::CheckConstraintViolation)
  end

  it 'rejects a header of 81 bytes' do
    expect do
      db.transaction(savepoint: true) do
        db[:blocks].insert(height: 700_004, merkle_root: Sequel.blob(root),
                           header: Sequel.blob(header_with_root(root, total: 81)))
      end
    end.to raise_error(Sequel::CheckConstraintViolation)
  end

  it 'rejects an 80-byte header whose embedded root differs from merkle_root' do
    other_root = SecureRandom.random_bytes(32)
    expect do
      db.transaction(savepoint: true) do
        db[:blocks].insert(height: 700_005, merkle_root: Sequel.blob(root),
                           header: Sequel.blob(header_with_root(other_root)))
      end
    end.to raise_error(Sequel::CheckConstraintViolation)
  end
end
