# frozen_string_literal: true

module BSV
  module Wallet
    class Store
      module Models
        class Broadcast < Sequel::Model
          plugin :timestamps, update_on_create: true

          many_to_one :action, class: 'BSV::Wallet::Store::Models::Action'

          # ARC tx_status classification sets live in BSV::Wallet::ArcStatus
          # (accepted / rejected / terminal) — the single source of truth
          # shared with the Engine and the background broadcast worker.
        end
      end
    end
  end
end
