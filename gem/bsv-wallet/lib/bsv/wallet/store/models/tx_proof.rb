# frozen_string_literal: true

module BSV
  module Wallet
    class Store
      module Models
        class TxProof < Sequel::Model
          include DisplayTxid

          plugin :timestamps, update_on_create: true

          many_to_one :block, class: 'BSV::Wallet::Store::Models::Block'
          one_to_many :actions, class: 'BSV::Wallet::Store::Models::Action'
        end
      end
    end
  end
end
