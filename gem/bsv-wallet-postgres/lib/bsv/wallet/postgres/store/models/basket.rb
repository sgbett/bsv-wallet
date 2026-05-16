# frozen_string_literal: true

module BSV
  module Wallet
    module Postgres
      module Store
        class Basket < Sequel::Model
          plugin :timestamps, update_on_create: true

          one_to_many :output_baskets, class: 'BSV::Wallet::Postgres::Store::OutputBasket'
        end
      end
    end
  end
end
