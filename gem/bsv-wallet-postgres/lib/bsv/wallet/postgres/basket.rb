# frozen_string_literal: true

module BSV
  module Wallet
    module Postgres
      class Basket < Sequel::Model
        plugin :timestamps, update_on_create: true

        one_to_many :output_baskets, class: 'BSV::Wallet::Postgres::OutputBasket'
      end
    end
  end
end
