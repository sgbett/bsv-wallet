# frozen_string_literal: true

module BSV
  module Wallet
    module Store
      class OutputBasket < Sequel::Model
        plugin :timestamps, update_on_create: true

        many_to_one :output, class: 'BSV::Wallet::Store::Output'
        many_to_one :basket, class: 'BSV::Wallet::Store::Basket'
        many_to_one :action, class: 'BSV::Wallet::Store::Action'
      end
    end
  end
end
