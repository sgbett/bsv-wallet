# frozen_string_literal: true

module BSV
  module Wallet
    module Postgres
      class OutputBasket < Sequel::Model
        plugin :timestamps, update_on_create: true

        many_to_one :output, class: 'BSV::Wallet::Postgres::Output'
        many_to_one :basket, class: 'BSV::Wallet::Postgres::Basket'
      end
    end
  end
end
