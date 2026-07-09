# frozen_string_literal: true

module BSV
  module Network
    # Write-through chain tracker backed by the +blocks+ table and the
    # Services routing layer. Satisfies the SDK's {Transaction::ChainTracker}
    # duck type so it can be passed to +Transaction::Tx#verify+.
    #
    # Fast path: look up the block by height in the local +blocks+ table.
    # Miss path: fetch the header from the network via Services, persist it,
    # then answer.
    #
    # Fails closed: any error returns +false+ — verification fails rather
    # than passing on incomplete data.
    class ChainTracker < BSV::Transaction::ChainTracker
      # @param store [BSV::Wallet::Store] store providing block header persistence
      # @param services [BSV::Network::Services] routing layer for network calls
      def initialize(store:, services:)
        super()
        @store = store
        @services = services
      end

      # Verify that a merkle root is valid for the given block height.
      #
      # @param root [String] merkle root as a hex string (from SDK's MerklePath#verify)
      # @param height [Integer] block height
      # @return [Boolean]
      def valid_root_for_height?(root, height)
        # +root+ is the SDK's display-order hex output from MerklePath#compute_root_hex.
        # The DB stores wire-order bytes (the wtxid convention). Convert at this
        # boundary: display hex -> display bytes -> wire bytes (reverse).
        root_bin = [root].pack('H*').reverse

        # Fast path: local store
        block = @store.find_block(height: height)
        return block[:merkle_root] == root_bin if block

        # Miss path: fetch header via Services routing layer
        result = @services.call(:get_block_header, height)
        return false unless result.http_success?

        # Provider field names vary: WoC uses 'merkleroot', Chaintracks uses 'merkleRoot'
        fetched_root = result.data['merkleroot'] || result.data['merkleRoot'] || result.data['merkle_root']
        return false unless fetched_root

        # Provider hex is display-order; persist wire-order to match the
        # internal convention. block_hash gets the same treatment below.
        fetched_wire = [fetched_root].pack('H*').reverse
        block_hash = result.data['hash'] || result.data['blockHash'] || result.data['block_hash']
        block_hash_wire = block_hash ? [block_hash].pack('H*').reverse : nil
        persist_block(height: height, merkle_root: fetched_wire, block_hash: block_hash_wire)

        fetched_wire == root_bin
      rescue StandardError => e
        BSV.logger&.warn { "[ChainTracker] valid_root_for_height? error: #{e.message}" }
        false
      end

      # Return the current blockchain height.
      #
      # @return [Integer]
      def current_height
        result = @services.call(:current_height)
        return result.data if result.http_success?

        @store.max_block_height || 0
      rescue StandardError
        @store.max_block_height || 0
      end

      # Height-deduplicated merkle-root lookup for anchor liveness
      # (HLR #516 Sub 6).
      #
      # Returns +{ height => root_bytes | nil }+ — one entry per input
      # height. Wire-order 32-byte binary bytes, matching the persisted
      # convention (never hex, never BUMP-bytes). +nil+ for a height the
      # tracker cannot resolve (fetch failure, network error): distinct
      # from "mismatch" — the anchor-liveness caller must not invalidate
      # on unresolvable heights, only on genuine root mismatches.
      #
      # Empty input short-circuits: no fetches, empty Hash returned.
      #
      # **Batching scope.** This base implementation only guarantees
      # height de-duplication before dispatch — on a store miss it still
      # performs one +get_block_header+ network call per height. Callers
      # wanting a single-sync batch (one header-syncer round trip for
      # the whole set) should use +SpvHeaderChainTracker#known_roots_for_heights+,
      # which does exactly that. (Copilot round-3 on #533.)
      #
      # This is a fast-path helper for +Engine::AnchorLivenessCache+, not
      # a duck-type contract with the SDK.
      #
      # @param heights [Array<Integer>]
      # @return [Hash{Integer => String, nil}]
      def known_roots_for_heights(heights)
        return {} if heights.nil? || heights.empty?

        heights.uniq.to_h do |height|
          [height, resolve_root_for_height(height)]
        end
      end

      private

      # Resolve the wire-order merkle root at +height+, hitting the store
      # first and the network only on miss. Returns +nil+ on any failure
      # (network 5xx, parse error, missing field) so the caller can
      # distinguish "unknown" from "mismatch".
      def resolve_root_for_height(height)
        block = @store.find_block(height: height)
        return block[:merkle_root] if block && block[:merkle_root]

        result = @services.call(:get_block_header, height)
        return nil unless result.http_success?

        fetched_root = result.data['merkleroot'] || result.data['merkleRoot'] || result.data['merkle_root']
        return nil unless fetched_root

        fetched_wire = [fetched_root].pack('H*').reverse
        block_hash = result.data['hash'] || result.data['blockHash'] || result.data['block_hash']
        block_hash_wire = block_hash ? [block_hash].pack('H*').reverse : nil
        persist_block(height: height, merkle_root: fetched_wire, block_hash: block_hash_wire)
        fetched_wire
      rescue StandardError => e
        BSV.logger&.warn { "[ChainTracker] known_roots_for_heights height=#{height} error: #{e.message}" }
        nil
      end

      def persist_block(height:, merkle_root:, block_hash:)
        @store.record_block_header(height: height, merkle_root: merkle_root, block_hash: block_hash)
      rescue Sequel::Error => e
        BSV.logger&.debug { "[ChainTracker] persist_block failed: #{e.message}" }
      end
    end
  end
end
