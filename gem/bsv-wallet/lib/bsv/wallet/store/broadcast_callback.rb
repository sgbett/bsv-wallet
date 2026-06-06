# frozen_string_literal: true

require 'json'
require 'rack'

module BSV
  module Wallet
    class Store
      # Rack endpoint for ARC broadcast callbacks.
      #
      # Parses the camelCase ARC TransactionStatus JSON, decodes it into
      # the internal event hash, and hands off to EventApplicator. The
      # decode step (camelCase -> snake_case + hex -> binary) stays here
      # because it is HTTP-shape-specific; the SSE listener (#264) has
      # its own decode for the +data:+-line JSON it receives.
      class BroadcastCallback
        def initialize(store:, applicator: nil)
          @applicator = applicator || EventApplicator.new(store: store)
        end

        def call(env)
          request = Rack::Request.new(env)
          body = JSON.parse(request.body.read, symbolize_names: true)
          @applicator.apply(decode_event(body))

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
