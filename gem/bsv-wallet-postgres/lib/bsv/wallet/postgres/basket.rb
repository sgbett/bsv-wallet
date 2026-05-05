# frozen_string_literal: true

module BSV
  module Wallet
    module Postgres
      class Basket < Sequel::Model
        plugin :timestamps, update_on_create: true

        one_to_many :output_baskets, class: 'BSV::Wallet::Postgres::OutputBasket'

        dataset_module do
          def active
            where(deleted_at: nil)
          end
        end
      end
    end
  end
end
