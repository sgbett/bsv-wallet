# frozen_string_literal: true

module BSV
  module Wallet
    class Store
      module Models
        class Broadcast < Sequel::Model
          plugin :timestamps, update_on_create: true

          many_to_one :action, class: 'BSV::Wallet::Store::Models::Action'

          # Broadcasts with these statuses are considered terminal — no further polling.
          # MINED_IN_STALE_BLOCK is intentionally excluded: a stale-block tx is valid but
          # on a fork, and must continue to be re-polled until it re-enters the main chain
          # (see docs/wallet-events.md and HLR #182).
          TERMINAL_STATUSES = %w[
            SEEN_ON_NETWORK MINED IMMUTABLE
            REJECTED DOUBLE_SPEND_ATTEMPTED
          ].freeze
        end
      end
    end
  end
end
