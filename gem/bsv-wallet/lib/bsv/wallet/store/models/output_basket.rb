# frozen_string_literal: true

module BSV
  module Wallet
    class Store
      module Models
        class OutputBasket < Sequel::Model
          plugin :timestamps, update_on_create: true

          many_to_one :output, class: 'BSV::Wallet::Store::Models::Output'
          many_to_one :basket, class: 'BSV::Wallet::Store::Models::Basket'
          many_to_one :action, class: 'BSV::Wallet::Store::Models::Action'
        end
      end
    end
  end
end
