# frozen_string_literal: true

module BSV
  module Wallet
    class Store
      module Models
        # Persistence row for Arcade SSE listener cursors. The token (PK)
        # is a wallet-derived callbackToken (HMAC-from-WIF via
        # +BSV::Wallet::CallbackToken#derive+) that the wallet supplies
        # to Arcade for callback scoping; last_event_id is the SSE frame
        # id (nanosecond timestamp) of the most recently bus-pushed
        # event. No FK -- the token is an external identifier, not a row
        # in any other wallet table. See db/migrations/010_sse_cursors.rb
        # and #251 / #262.
        class SseCursor < Sequel::Model
          unrestrict_primary_key
        end
      end
    end
  end
end
