# frozen_string_literal: true

module BSV
  module Wallet
    class Store
      module Models
        class Broadcast < Sequel::Model
          plugin :timestamps, update_on_create: true

          many_to_one :action, class: 'BSV::Wallet::Store::Models::Action'

          # Broadcasts with these statuses are considered terminal — no further polling.
          TERMINAL_STATUSES = %w[
            SEEN_ON_NETWORK MINED IMMUTABLE
            REJECTED DOUBLE_SPEND_ATTEMPTED
          ].freeze

          # Minimum age (seconds) before a broadcast is eligible for status polling.
          FETCH_STALENESS = 30
        end
      end
    end
  end
end
