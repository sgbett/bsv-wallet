# frozen_string_literal: true

module BSV
  module Wallet
    module Postgres
      module Store
        class OutputTag < Sequel::Model
          plugin :timestamps, update_on_create: true

          many_to_one :output, class: 'BSV::Wallet::Postgres::Store::Output'
          many_to_one :tag, class: 'BSV::Wallet::Postgres::Store::Tag'
        end
      end
    end
  end
end
