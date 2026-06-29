# frozen_string_literal: true

module BSV
  module Network
    # Pure, I/O-free 80-byte block-header parser and proof-of-work validator
    # (HLR #335, opt-in PoW-validated header verification).
    #
    # bsv-sdk 0.25.0 ships no header / PoW primitive, so this is genuinely
    # new ground. The class does three things and nothing else:
    #
    # 1. Parse the canonical 80-byte wire header into its six fields.
    # 2. Compute the block hash via the SDK's +BSV::Primitives::Digest.sha256d+
    #    (never hand-rolled — the SDK owns the crypto).
    # 3. Validate the embedded proof of work: decode the compact +nBits+
    #    target and check that the block hash, read as a little-endian
    #    256-bit integer, is at or below it.
    #
    # No network access, no database, no state beyond the parsed fields.
    # Suitable for the chain tracker to call on data it has already fetched.
    #
    # == Byte-order convention
    #
    # +prev_hash+ and +merkle_root+ are held as the 32 raw wire bytes the
    # header carries — no reversal during parse. This matches the wallet's
    # +wtxid+ convention (wire/internal order is canonical; reversal to
    # display order happens only at service / display boundaries). The
    # display-hex form a human or a WhatsOnChain payload would show is the
    # byte-reverse of these.
    #
    # == Fail-closed posture
    #
    # This is a security primitive and a sole misbehaving service is the
    # threat model. Every failure mode resolves to "not a valid header"
    # rather than an exception that a caller's +rescue+ might swallow into
    # a truthy value:
    #
    # - +parse+ rejects anything that is not exactly 80 bytes *before* it
    #   unpacks (raising {InvalidHeaderError} — the tracker treats any
    #   failure as +false+).
    # - {.target_from_bits} returns +nil+ for a malformed compact target
    #   (negative sign bit, zero mantissa, or > 256-bit overflow), and
    #   +#valid_pow?+ maps that +nil+ to +false+. A bogus +nBits+ can
    #   never be coerced into an easy target.
    # - {.from_service_fields} round-trips the assembled hash against the
    #   service-supplied display hash when one is given, and returns +nil+
    #   on mismatch.
    class BlockHeader
      # Raised when the byte string handed to {.parse} is not exactly the
      # 80-byte header length. Carried as a typed error so callers can
      # distinguish a structural reject from an unrelated +StandardError+;
      # the chain tracker simply treats any raised failure as +false+.
      class InvalidHeaderError < BSV::Wallet::Error; end

      # Canonical serialised header length in bytes.
      HEADER_SIZE = 80

      # 2^256 — one past the largest value a 256-bit target may hold. Any
      # decoded target at or above this has overflowed and is rejected.
      MAX_TARGET_EXCLUSIVE = 1 << 256

      # @return [Integer] block version (LE uint32)
      attr_reader :version

      # @return [String] 32 raw wire bytes of the previous block hash (no reversal)
      attr_reader :prev_hash

      # @return [String] 32 raw wire bytes of the merkle root (no reversal)
      attr_reader :merkle_root

      # @return [Integer] block timestamp, seconds since the Unix epoch (LE uint32)
      attr_reader :time

      # @return [Integer] compact +nBits+ proof-of-work target (LE uint32)
      attr_reader :bits

      # @return [Integer] proof-of-work nonce (LE uint32)
      attr_reader :nonce

      # @return [String] the exact 80 raw bytes this header was parsed from
      attr_reader :raw

      # Parse an 80-byte wire header.
      #
      # Fails closed before unpacking: a +bytes+ argument that is +nil+, not
      # a String, or not exactly {HEADER_SIZE} long raises
      # {InvalidHeaderError}. The original byte slice is retained verbatim
      # for {#block_hash} so the hash is always taken over the bytes as
      # received — never a re-serialisation that could drift.
      #
      # @param bytes [String] 80 raw bytes, +version|prev_hash|merkle_root|time|bits|nonce+
      # @return [BlockHeader]
      # @raise [InvalidHeaderError] if +bytes+ is not exactly 80 bytes
      def self.parse(bytes)
        unless bytes.is_a?(String) && bytes.bytesize == HEADER_SIZE
          raise InvalidHeaderError, "block header must be #{HEADER_SIZE} bytes, got #{bytes.respond_to?(:bytesize) ? bytes.bytesize : bytes.inspect}"
        end

        # Treat the slice as binary regardless of the caller's encoding so
        # the field offsets are byte offsets, not character offsets.
        raw = bytes.b
        version, prev_hash, merkle_root, time, bits, nonce =
          raw.unpack('V a32 a32 V V V')

        new(
          version: version,
          prev_hash: prev_hash,
          merkle_root: merkle_root,
          time: time,
          bits: bits,
          nonce: nonce,
          raw: raw
        )
      end

      # Assemble and parse an 80-byte header from a WhatsOnChain-shaped
      # +/block/{height}/header+ field set.
      #
      # WhatsOnChain returns decoded *fields*, not raw bytes, so the header
      # has to be reconstructed before it can be hashed. Two field-level
      # quirks of that payload are handled here:
      #
      # - +bits+ arrives as a hex *string* (e.g. +"180d589d"+), not an
      #   integer — decoded with +to_i(16)+ before packing.
      # - +previousblockhash+ and +merkleroot+ are *display* hex (the
      #   human-facing, byte-reversed form) — reversed back to wire order
      #   during assembly so the reconstructed bytes match the chain.
      #
      # When +hash:+ (WhatsOnChain's display-hex block hash) is supplied,
      # the assembled header's own hash is checked against it as an
      # integrity guard; a mismatch returns +nil+ rather than a header that
      # claims an identity it cannot prove.
      #
      # @param version [Integer] block version
      # @param previousblockhash [String] previous block hash, display hex
      # @param merkleroot [String] merkle root, display hex
      # @param time [Integer] block timestamp (Unix seconds)
      # @param bits [String] compact target as a hex string (WhatsOnChain form)
      # @param nonce [Integer] proof-of-work nonce
      # @param hash [String, nil] optional display-hex block hash for round-trip verification
      # @return [BlockHeader, nil] the parsed header, or +nil+ if assembly or the integrity check fails
      def self.from_service_fields(version:, previousblockhash:, merkleroot:, time:, bits:, nonce:, hash: nil)
        # +bits+ is the compact target as a hex string (WhatsOnChain form).
        # Require exactly 8 hex digits: a shorter, longer, or non-hex value
        # would otherwise be silently coerced by +to_i(16)+ and truncated to
        # 32 bits by +pack('V')+, smuggling a *different* target past
        # assembly. A malformed +bits+ is a malformed header — fail closed.
        return unless bits.is_a?(String) && bits.match?(/\A\h{8}\z/)

        raw = [version].pack('V') +
              [previousblockhash].pack('H*').reverse +
              [merkleroot].pack('H*').reverse +
              [time].pack('V') +
              [bits.to_i(16)].pack('V') +
              [nonce].pack('V')

        return nil unless raw.bytesize == HEADER_SIZE

        header = parse(raw)

        # Round-trip integrity: the assembled header must hash to the
        # service-claimed block hash. block_hash is wire order; reverse to
        # the display hex the service speaks before comparing.
        if hash
          assembled_display = header.block_hash.reverse.unpack1('H*')
          return nil unless assembled_display.casecmp?(hash)
        end

        header
      rescue InvalidHeaderError, TypeError, ArgumentError
        # Bad field types (e.g. a non-hex +bits+ string, a +nil+ hash
        # field) collapse to a closed failure rather than propagating.
        # +pack('V')+ masks out-of-range integers to 32 bits rather than
        # raising, so a malformed numeric field assembles a wrong header
        # that then fails the round-trip hash check (or downstream PoW /
        # linkage) — fail-closed without needing a RangeError rescue.
        nil
      end

      # Decode a compact +nBits+ target into its full 256-bit integer form,
      # following Bitcoin Core's +SetCompact+.
      #
      # The compact form is +exponent (1 byte) << 24 | mantissa (3 bytes)+.
      # The decoded target is the mantissa scaled by a power of 256 chosen
      # by the exponent.
      #
      # Returns +nil+ — never an exception, never a clamped value — for any
      # malformed compact target, so a caller can treat "no target" as
      # "invalid proof of work":
      #
      # - *sign bit set* (+bits & 0x00800000+): Bitcoin's compact format
      #   reserves a sign bit. A negative target is meaningless for PoW.
      # - *zero mantissa*: a zero target can never be met; treat the header
      #   as invalid rather than dividing into it.
      # - *overflow past 256 bits*: a mantissa shifted so far left that the
      #   target would not fit in 256 bits cannot be a real chain target.
      #   Guarded in full (not just +exponent > 34+) so a high exponent
      #   paired with any non-zero mantissa is caught.
      #
      # @param bits [Integer] compact target (the header's +nBits+ field)
      # @return [Integer, nil] the decoded 256-bit target, or +nil+ if malformed
      def self.target_from_bits(bits)
        # Sign bit set — reserved, negative targets are not valid PoW.
        return nil if bits.anybits?(0x0080_0000)

        exponent = bits >> 24
        mantissa = bits & 0x007f_ffff

        # Zero mantissa — an unsatisfiable (zero) target.
        return nil if mantissa.zero?

        target =
          if exponent <= 3
            mantissa >> (8 * (3 - exponent))
          else
            mantissa << (8 * (exponent - 3))
          end

        # Overflow — a target that does not fit in 256 bits is not a real
        # chain target. Checking the materialised value (rather than a
        # bound on the exponent alone) catches every overflowing
        # exponent/mantissa pairing exactly.
        return nil if target >= MAX_TARGET_EXCLUSIVE

        target
      end

      # @param version [Integer]
      # @param prev_hash [String] 32 raw wire bytes
      # @param merkle_root [String] 32 raw wire bytes
      # @param time [Integer]
      # @param bits [Integer]
      # @param nonce [Integer]
      # @param raw [String] the 80 raw bytes the fields were parsed from
      def initialize(version:, prev_hash:, merkle_root:, time:, bits:, nonce:, raw:)
        @version = version
        @prev_hash = prev_hash
        @merkle_root = merkle_root
        @time = time
        @bits = bits
        @nonce = nonce
        @raw = raw
      end

      # The block hash: SHA256d over the exact 80 bytes this header was
      # parsed from. Reuses the SDK digest; the original slice is hashed
      # rather than a re-serialisation, so the result cannot drift from
      # what the network signed.
      #
      # @return [String] 32 wire bytes (display-hex is the byte-reverse of this)
      def block_hash
        BSV::Primitives::Digest.sha256d(@raw)
      end

      # The decoded proof-of-work target for this header's +nBits+.
      #
      # @return [Integer, nil] decoded 256-bit target, or +nil+ if +nBits+ is malformed
      def target
        self.class.target_from_bits(@bits)
      end

      # Whether the header's proof of work is valid: the block hash, read as
      # a *little-endian* 256-bit integer, must be at or below the decoded
      # target. Equality counts as valid (Bitcoin uses +<=+).
      #
      # The block hash is wire/little-endian, so it is reversed to obtain
      # the big-endian integer to compare against the target. A malformed
      # +nBits+ (target +nil+) is invalid PoW, not an error.
      #
      # @return [Boolean]
      def valid_pow?
        decoded_target = target
        return false if decoded_target.nil?

        # Reverse wire (LE) bytes -> big-endian, then to an integer.
        hash_value = block_hash.reverse.unpack1('H*').to_i(16)
        hash_value <= decoded_target
      end

      # Whether this header chains onto +parent+: its +prev_hash+ must equal
      # the parent's block hash. Both are raw wire bytes, so the comparison
      # is a direct byte equality with no reversal.
      #
      # @param parent [BlockHeader] the candidate predecessor header
      # @return [Boolean]
      def links_to?(parent)
        @prev_hash == parent.block_hash
      end
    end
  end
end
