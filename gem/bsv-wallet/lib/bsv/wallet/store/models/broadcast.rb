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

          # ARC tx_status values that indicate the network has accepted the
          # broadcast (Phase 4 trigger). Subset of TERMINAL_STATUSES that
          # represents success rather than rejection. ACCEPTED_BY_NETWORK is
          # included because ARC reports it as an interim accepted state
          # before SEEN_ON_NETWORK in some configurations.
          ACCEPTED_STATUSES = %w[
            SEEN_ON_NETWORK ACCEPTED_BY_NETWORK MINED IMMUTABLE
          ].freeze
        end
      end
    end
  end
end
