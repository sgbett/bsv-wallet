# frozen_string_literal: true

module BSV
  module Network
    # Extends the wallet's locally-validated block-header chain (HLR #335).
    #
    # Single responsibility: the fetch → validate → persist process that
    # grows a contiguous, PoW-checked run of headers upward from a trust
    # anchor (the {Checkpoints checkpoint}). Each candidate header is
    # fetched per-height from a chain-query Service, parsed and validated
    # by {BlockHeader} (PoW + linkage to its already-validated
    # predecessor), and only then persisted. The result is a chain the
    # wallet trusts because it verified every link — not because a service
    # asserted it.
    #
    # == Fail-closed
    #
    # A sole misbehaving service is the threat model. Every failure mode —
    # a network miss, a header that fails PoW, a header that does not link
    # to its predecessor, a malformed field set — *stops* the sync at the
    # last good height. The bad header is never persisted and the validated
    # tip never advances past it. A caller asking about a height the sync
    # could not reach gets "not covered", which the tracker resolves to a
    # failed verification.
    #
    # == DoS bound
    #
    # +sync_to!+ refuses any target more than {MAX_SYNC_SPAN} above the
    # current validated tip *before fetching anything*. A hostile BEEF can
    # claim a leaf at height 10^9; without the cap that would spin an
    # unbounded fetch loop. The cap is generous enough to absorb a stale
    # checkpoint (a release that fell behind the tip) yet bounded enough
    # that an absurd height costs one comparison, not millions of HTTP
    # round-trips.
    #
    # == In-process tip memo
    #
    # The validated tip and the tip header are memoised for the syncer's
    # lifetime and advanced as rows are persisted, so repeated
    # +sync_to!+ calls for nearby heights do not re-read the tip from the
    # database each time. The memo is a cache over canonical state: cold,
    # it is seeded from the store (or from the checkpoint when the chain is
    # unseeded); dropping it and rebuilding from the +blocks+ table
    # reproduces identical behaviour.
    class HeaderSyncer
      # Maximum number of headers a single +sync_to!+ may extend the chain
      # by. Generous on purpose — covers a checkpoint that has drifted well
      # below the tip — while still refusing the absurd heights a malicious
      # service or BEEF could feed (the DoS bound).
      MAX_SYNC_SPAN = 100_000

      # @return [Integer] the checkpoint (anchor) height
      attr_reader :checkpoint_height

      # @param store [BSV::Wallet::Store] block-header persistence
      # @param services [BSV::Network::Services] chain-query routing layer
      # @param checkpoint [Hash{Symbol => Object}] +{ height:, header: }+ —
      #   the trust anchor (see {Checkpoints.for}). +header+ is a
      #   {BlockHeader} or the raw 80 bytes.
      def initialize(store:, services:, checkpoint:)
        @store = store
        @services = services
        @checkpoint_height = checkpoint.fetch(:height)
        @checkpoint_header = coerce_header(checkpoint.fetch(:header))
        @tip_height = nil
        @tip_header = nil
      end

      # Extend the validated chain up to +target_height+.
      #
      # No-op when the tip already covers the target. Returns the validated
      # tip after the attempt (which equals the last good height when the
      # sync stopped fail-closed short of the target).
      #
      # @param target_height [Integer]
      # @return [Integer] the validated tip after syncing
      def sync_to!(target_height)
        seed_if_needed!
        return @tip_height if target_height <= @tip_height

        # DoS bound — refuse an absurd span before any fetch happens.
        span = target_height - @tip_height
        if span > MAX_SYNC_SPAN
          BSV.logger&.warn do
            "[HeaderSyncer] refusing sync of #{span} headers (tip=#{@tip_height} " \
              "target=#{target_height} cap=#{MAX_SYNC_SPAN}) — fail-closed"
          end
          return @tip_height
        end

        extend_chain!(target_height)
        @tip_height
      end

      # The current validated tip (seeds from the store / checkpoint on
      # first read).
      #
      # @return [Integer]
      def validated_tip
        seed_if_needed!
        @tip_height
      end

      private

      # Seed the in-process tip from canonical state, persisting the
      # checkpoint header row first if the chain has never been seeded.
      # Idempotent and cheap after the first call.
      def seed_if_needed!
        return if @tip_height

        # If the store holds no validated row at/below the checkpoint, the
        # anchor row does not exist yet — persist it. It is the one header
        # trusted on faith; everything above is validated against it.
        persist_checkpoint! unless @store.header_at(height: @checkpoint_height)

        @tip_height = @store.validated_tip(from_height: @checkpoint_height) || @checkpoint_height
        @tip_header = load_header(@tip_height) || @checkpoint_header
      end

      # Write the checkpoint as a validated, header-bearing row — the chain
      # anchor.
      def persist_checkpoint!
        persist(@checkpoint_height, @checkpoint_header)
      end

      # Fetch → validate → persist each height from tip+1 to target,
      # stopping fail-closed at the first failure. Persists the run in one
      # transaction so a partial fetch sequence commits atomically.
      def extend_chain!(target_height)
        @store.db.transaction do
          ((@tip_height + 1)..target_height).each do |height|
            header = fetch_and_validate(height)
            break unless header # fail-closed: stop, do not advance

            persist(height, header)
            @tip_header = header
            @tip_height = height
          end
        end
      end

      # Fetch the header at +height+ and validate it against the current
      # tip header. Returns the validated {BlockHeader}, or +nil+ on any
      # failure (network miss, bad PoW, broken linkage, malformed fields).
      def fetch_and_validate(height)
        result = @services.call(:get_block_header, height)
        return unless result&.http_success?

        header = build_header(result.data)
        return unless header

        # PoW must hold AND the header must chain onto the validated tip.
        return unless header.valid_pow?
        return unless header.links_to?(@tip_header)

        header
      rescue StandardError => e
        BSV.logger&.warn { "[HeaderSyncer] fetch/validate failed at height #{height}: #{e.message}" }
        nil
      end

      # Reconstruct a {BlockHeader} from a Service +:get_block_header+
      # payload. WhatsOnChain returns decoded fields, not raw bytes; map
      # its keys to {BlockHeader.from_service_fields} (which reverses the
      # display-hex hashes to wire order and decodes the hex +bits+
      # string). The wallet's Services layer normalises WoC's +merkleroot+
      # to +merkle_root+, so read that key here.
      #
      # @param data [Hash, nil]
      # @return [BlockHeader, nil]
      def build_header(data)
        return unless data.is_a?(Hash)

        BlockHeader.from_service_fields(
          version: data['version'],
          previousblockhash: data['previousblockhash'],
          merkleroot: data['merkle_root'] || data['merkleroot'],
          time: data['time'],
          bits: data['bits'],
          nonce: data['nonce'],
          hash: data['hash']
        )
      end

      # Persist a validated header row (header bytes + extracted merkle_root
      # + block_hash + height). The store enforces append-or-reject.
      def persist(height, header)
        @store.record_block_header(
          height: height,
          merkle_root: header.merkle_root,
          block_hash: header.block_hash,
          header: header.raw
        )
      end

      # Load and parse the stored header at +height+ into a {BlockHeader},
      # or +nil+ when no validated row is present there.
      def load_header(height)
        raw = @store.header_at(height: height)
        return unless raw

        BlockHeader.parse(raw)
      rescue BlockHeader::InvalidHeaderError
        nil
      end

      # Coerce a checkpoint's +header+ (a {BlockHeader} or raw 80 bytes)
      # into a {BlockHeader}.
      def coerce_header(header)
        return header if header.is_a?(BlockHeader)

        BlockHeader.parse(header)
      end
    end
  end
end
