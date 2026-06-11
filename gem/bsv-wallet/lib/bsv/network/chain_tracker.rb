# frozen_string_literal: true

module BSV
  module Network
    # Write-through chain tracker backed by the +blocks+ table and the
    # Services routing layer. Satisfies the SDK's {BSV::Transaction::ChainTracker}
    # duck type so it can be passed to +Tx#verify+.
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

      private

      def persist_block(height:, merkle_root:, block_hash:)
        @store.record_block_header(height: height, merkle_root: merkle_root, block_hash: block_hash)
      rescue Sequel::Error => e
        BSV.logger&.debug { "[ChainTracker] persist_block failed: #{e.message}" }
      end
    end
  end
end
