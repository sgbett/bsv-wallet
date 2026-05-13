# frozen_string_literal: true

module BSV
  module Network
    # Write-through chain tracker backed by the +blocks+ table and the
    # Services routing layer. Satisfies the SDK's {BSV::Transaction::ChainTracker}
    # duck type so it can be passed to +Transaction#verify+.
    #
    # Fast path: look up the block by height in the local +blocks+ table.
    # Miss path: fetch the header from the network via Services, persist it,
    # then answer.
    #
    # Fails closed: any error returns +false+ — verification fails rather
    # than passing on incomplete data.
    class ChainTracker < BSV::Transaction::ChainTracker
      # @param db [Sequel::Database] database handle with a +blocks+ table
      # @param services [BSV::Network::Services] routing layer for network calls
      def initialize(db:, services:)
        super()
        @db = db
        @services = services
      end

      # Verify that a merkle root is valid for the given block height.
      #
      # @param root [String] merkle root as a hex string (from SDK's MerklePath#verify)
      # @param height [Integer] block height
      # @return [Boolean]
      def valid_root_for_height?(root, height)
        root_bin = [root].pack('H*')

        # Fast path: local blocks table
        block = @db[:blocks].where(height: height).first
        return block[:merkle_root] == root_bin if block

        # Miss path: fetch header via Services routing layer
        result = @services.call(:get_block_header, height)
        return false unless result.http_success?

        # Provider field names vary: WoC uses 'merkleroot', Chaintracks uses 'merkleRoot'
        fetched_root = result.data['merkleroot'] || result.data['merkleRoot'] || result.data['merkle_root']
        return false unless fetched_root

        block_hash = result.data['hash'] || result.data['blockHash'] || result.data['block_hash']
        persist_block(height: height, merkle_root: fetched_root, block_hash: block_hash)

        [fetched_root].pack('H*') == root_bin
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

        @db[:blocks].max(:height) || 0
      rescue StandardError
        @db[:blocks].max(:height) || 0
      end

      private

      def persist_block(height:, merkle_root:, block_hash:)
        root_bin = [merkle_root].pack('H*')
        hash_bin = block_hash ? [block_hash].pack('H*') : nil
        @db[:blocks].insert_conflict(target: :height).insert(
          height: height,
          merkle_root: Sequel.blob(root_bin),
          block_hash: hash_bin ? Sequel.blob(hash_bin) : nil
        )
      rescue Sequel::Error => e
        BSV.logger&.debug { "[ChainTracker] persist_block failed: #{e.message}" }
      end
    end
  end
end
