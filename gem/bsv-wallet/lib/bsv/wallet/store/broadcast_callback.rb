# frozen_string_literal: true

require 'json'
require 'rack'

module BSV
  module Wallet
    class Store
      class BroadcastCallback
        def initialize(broadcast_queue:)
          @broadcast_queue = broadcast_queue
        end

        def call(env)
          request = Rack::Request.new(env)
          body = JSON.parse(request.body.read, symbolize_names: true)
          event = decode_event(body)
          @broadcast_queue.handle_event(event)
          [200, { 'content-type' => 'text/plain' }, ['OK']]
        rescue JSON::ParserError
          [400, { 'content-type' => 'text/plain' }, ['Bad Request']]
        end

        private

        def decode_event(body)
          BSV::Primitives::Hex.validate_dtxid_hex!(body[:txid], name: 'ARC callback txid') if body[:txid]
          {
            wtxid: decode_hex(body[:txid])&.reverse,
            tx_status: body[:txStatus],
            status: body[:status],
            block_hash: decode_hex(body[:blockHash]),
            block_height: body[:blockHeight],
            merkle_path: decode_hex(body[:merklePath]),
            extra_info: body[:extraInfo],
            competing_txs: body[:competingTxs]
          }
        end

        def decode_hex(hex)
          return unless hex

          [hex].pack('H*')
        end
      end
    end
  end
end
