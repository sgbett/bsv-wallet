# frozen_string_literal: true

module BSV
  module Network
    # Per-network trust anchors for the +spv_headers+ trust model (HLR #335).
    #
    # A checkpoint is a single, hard-coded block at a known height whose
    # full 80-byte header is baked into the gem. It is the root from which
    # {HeaderSyncer} extends a locally-validated, contiguous, PoW-checked
    # header chain. The wallet trusts this one header on faith — every
    # header above it is validated against it (and against its own
    # predecessor) before being persisted, so the trust surface is exactly
    # this constant and nothing else.
    #
    # == Why a recent checkpoint
    #
    # The mainnet checkpoint sits a few hundred blocks below the live tip
    # at release time. That bounds the cost of a wallet's *first* sync: a
    # fresh wallet need only fetch and validate the handful of headers
    # between the checkpoint and the height it is asked about, not the
    # entire chain from genesis. The checkpoint header itself is assembled
    # from its six wire fields and *self-verified* at load: its recomputed
    # +block_hash+ must equal the published block hash, or boot fails loud
    # rather than seeding the chain with a header that lies about its
    # identity.
    #
    # NOTE: refresh the mainnet checkpoint toward the chain tip each
    # release. Letting it drift far below the tip inflates every fresh
    # wallet's first-sync span (and pushes it toward the DoS cap in
    # {HeaderSyncer::MAX_SYNC_SPAN}). The block chosen here was a few
    # hundred blocks below the tip when this was authored.
    module Checkpoints
      # Raised when a checkpoint is requested for a network the
      # +spv_headers+ model does not (yet) support. Phase-1 is mainnet
      # only; testnet has no checkpoint baked in.
      class UnsupportedNetworkError < BSV::Wallet::Error; end

      # Raised at load time if a baked-in checkpoint's header cannot be
      # assembled from its fields, or fails its own block-hash round-trip.
      # A checkpoint that cannot prove its identity is unusable as a trust
      # anchor — fail loud, never seed the chain with it.
      class CorruptCheckpointError < BSV::Wallet::Error; end

      # Mainnet trust anchor: block 955000.
      #
      # Authored when the live tip was ~955617 (~600 blocks above), so a
      # fresh wallet's first sync is tiny. The fields below are the block's
      # wire header values; {BlockHeader.from_service_fields} reassembles
      # the 80 bytes and round-trips the +hash+ as an integrity guard.
      MAINNET_HEIGHT = 955_000

      MAINNET_HEADER_FIELDS = {
        version: 849_149_952,
        previousblockhash: '00000000000000002e75e6e58db6fba4cef5fcd8746488da460e7e14ae800ff5',
        merkleroot: 'c9606c93dce3dd1e67498adb3c148a5b28ebf58c199ed3cde7c6dd4ce3a149e0',
        time: 1_782_344_335,
        bits: '18300d4b',
        nonce: 582_574_457,
        hash: '0000000000000000096bfd8763ea4a9b0866e37435ee959f50e49c1fa67ccfef'
      }.freeze

      # Return the trust anchor for +network+.
      #
      # @param network [Symbol] +:mainnet+ (phase-1) — anything else raises.
      # @return [Hash{Symbol => Object}] +{ height: Integer, header: BlockHeader }+
      # @raise [UnsupportedNetworkError] for a network with no baked-in checkpoint
      # @raise [CorruptCheckpointError] if the baked-in header fails its self-verification
      def self.for(network)
        case network&.to_sym
        when :mainnet
          { height: MAINNET_HEIGHT, header: mainnet_header }
        when :testnet
          raise UnsupportedNetworkError,
                'spv_headers has no testnet checkpoint (phase-1 mainnet only)'
        else
          raise UnsupportedNetworkError,
                "spv_headers has no checkpoint for network #{network.inspect} (phase-1 mainnet only)"
        end
      end

      # Assemble and self-verify the mainnet checkpoint header.
      #
      # +from_service_fields+ returns +nil+ when the assembled header's hash
      # does not match the supplied +hash:+ — that is the round-trip guard.
      # A +nil+ here means the baked-in constant is internally inconsistent,
      # which is a build-time defect, so it is escalated to a raised
      # {CorruptCheckpointError} rather than a silent +nil+.
      #
      # @return [BlockHeader]
      # @raise [CorruptCheckpointError]
      def self.mainnet_header
        header = BlockHeader.from_service_fields(**MAINNET_HEADER_FIELDS)
        return header if header

        raise CorruptCheckpointError,
              "mainnet checkpoint header (height #{MAINNET_HEIGHT}) failed self-verification"
      end
    end
  end
end
