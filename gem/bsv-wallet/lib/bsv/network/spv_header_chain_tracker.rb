# frozen_string_literal: true

module BSV
  module Network
    # PoW-validated chain tracker for the opt-in +spv_headers+ trust model
    # (HLR #335).
    #
    # The sibling {ChainTracker} trusts a chain-query Service's answer for a
    # merkle root outright. This tracker trusts *no* service answer on its
    # face: it extends a locally-validated header chain from a baked-in
    # {Checkpoints checkpoint} via {HeaderSyncer} — every header PoW-checked
    # and linked to its predecessor before it is believed — and answers
    # merkle-root questions only from that validated chain. The trust
    # surface is the one checkpoint header; everything else is verified.
    #
    # Satisfies the SDK's {Transaction::ChainTracker} duck type so it drops
    # into +Transaction::Tx#verify+ exactly where {ChainTracker} does. It is
    # selected at boot when +config.trust_model+ is +:spv_headers+;
    # otherwise the trusted-service {ChainTracker} is used and behaviour is
    # unchanged.
    #
    # == Fail-closed
    #
    # Matches the sibling's posture: any error, any height below the
    # checkpoint, and any height the sync could not reach all resolve to
    # +false+ — verification fails rather than passing on data the wallet
    # could not validate.
    class SpvHeaderChainTracker < BSV::Transaction::ChainTracker
      # Headroom synced above a queried height so the SDK's coinbase
      # maturity check (an offset-0 leaf must sit ≥ 100 blocks below the
      # tip) is always satisfied for the leaves being verified. {#current_height}
      # returns the validated tip, so syncing this far past the leaf keeps
      # the tip ≥ 100 above it.
      MATURITY_HEADROOM = 100

      # @param store [BSV::Wallet::Store] block-header persistence
      # @param services [BSV::Network::Services] chain-query routing layer
      # @param network [Symbol] +:mainnet+ — selects the default checkpoint
      # @param checkpoint [Hash, nil] explicit +{ height:, header: }+
      #   override (+config.spv_checkpoint+); +nil+ → {Checkpoints.for}.
      def initialize(store:, services:, network: :mainnet, checkpoint: nil)
        super()
        @store = store
        @checkpoint = checkpoint || Checkpoints.for(network)
        @syncer = HeaderSyncer.new(store: store, services: services, checkpoint: @checkpoint)
      end

      # Verify that a merkle root is valid for the given block height,
      # against the locally-validated header chain.
      #
      # Fail-closed below the checkpoint (the chain has no validated header
      # there to check against). Otherwise extends the validated chain to
      # +height + {MATURITY_HEADROOM}+ (keeping the tip far enough above the
      # leaf for the SDK's coinbase-maturity check), then compares the
      # stored header's merkle_root at +height+ to the request. A height the
      # sync could not reach is "not covered" → +false+.
      #
      # @param root [String] merkle root as display-order hex (the SDK's
      #   +MerklePath#compute_root_hex+ output)
      # @param height [Integer] block height
      # @return [Boolean]
      def valid_root_for_height?(root, height)
        # Below the anchor there is nothing validated to compare against.
        return false if height < @checkpoint[:height]

        # Extend the chain far enough above the leaf for coinbase maturity.
        # +max+ guards a (defensive) negative/zero height arithmetic edge.
        @syncer.sync_to!([height + MATURITY_HEADROOM, height].max)

        raw = @store.header_at(height: height)
        return false unless raw # sync could not reach this height — fail-closed

        # +root+ is display-order hex; the stored header embeds wire-order
        # bytes (wtxid convention). Convert at the boundary: display hex →
        # display bytes → wire bytes (reverse), matching ChainTracker.
        root_wire = [root].pack('H*').reverse
        stored_root = raw.b[36, 32] # merkle_root occupies header bytes 36..67
        stored_root == root_wire
      rescue StandardError => e
        BSV.logger&.warn { "[SpvHeaderChainTracker] valid_root_for_height? error: #{e.message}" }
        false
      end

      # The current chain height: the validated tip from the store.
      #
      # Deliberately NOT the +:current_height+ Services call — that asks an
      # untrusted service for the tip, which this model does not believe.
      # The +{MATURITY_HEADROOM}+-block over-sync in {#valid_root_for_height?}
      # guarantees the tip sits far enough above any leaf being verified for
      # the SDK's coinbase-maturity check.
      #
      # @return [Integer]
      def current_height
        @syncer.validated_tip
      rescue StandardError => e
        BSV.logger&.warn { "[SpvHeaderChainTracker] current_height error: #{e.message}" }
        @checkpoint[:height]
      end
    end
  end
end
