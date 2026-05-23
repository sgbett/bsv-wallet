# frozen_string_literal: true

module BSV
  module Wallet
    class Store
      module Models
        class Basket < Sequel::Model
          plugin :timestamps, update_on_create: true

          one_to_many :output_baskets, class: 'BSV::Wallet::Store::Models::OutputBasket'
        end
      end
    end
  end
end
