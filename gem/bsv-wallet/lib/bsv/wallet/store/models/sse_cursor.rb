# frozen_string_literal: true

module BSV
  module Wallet
    class Store
      module Models
        # Persistence row for Arcade SSE listener cursors. The token (PK)
        # is the Arcade-issued callbackToken; last_event_id is the SSE
        # frame id (nanosecond timestamp) of the most recently bus-pushed
        # event. No FK -- the token is external to the wallet's data
        # model. See db/migrations/010_sse_cursors.rb and #251 / #262.
        class SseCursor < Sequel::Model
          unrestrict_primary_key
        end
      end
    end
  end
end
