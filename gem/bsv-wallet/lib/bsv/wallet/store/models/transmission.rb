# frozen_string_literal: true

module BSV
  module Wallet
    class Store
      module Models
        # A wallet→peer BEEF delivery at grain (action × counterparty).
        # Delivery status is derived from +acked_at+ presence, not stored —
        # there is no status column (principle of state, ADR-025).
        class Transmission < Sequel::Model
          plugin :timestamps, update_on_create: true

          many_to_one :action, class: 'BSV::Wallet::Store::Models::Action'
          one_to_many :transmission_txids, class: 'BSV::Wallet::Store::Models::TransmissionTxid'
        end
      end
    end
  end
end
