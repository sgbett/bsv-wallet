# frozen_string_literal: true

require 'json'
require 'rack'

module BSV
  module Wallet
    module Postgres
      # Rack app that receives ARC TransactionStatus webhook POSTs
      # and delegates to a BroadcastQueue instance.
      #
      # Mount however the host application prefers:
      #   - Standalone: rackup with config.ru
      #   - Rails: mount BroadcastCallback.new(broadcast_queue:) => '/arc/callback'
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
          {
            txid:          decode_hex(body[:txid]),
            tx_status:     body[:txStatus],
            status:        body[:status],
            block_hash:    decode_hex(body[:blockHash]),
            block_height:  body[:blockHeight],
            merkle_path:   decode_hex(body[:merklePath]),
            extra_info:    body[:extraInfo],
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
