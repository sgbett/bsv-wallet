# frozen_string_literal: true

module BSV
  module Wallet
    module Postgres
      module Store
        class OutputDetail < Sequel::Model
          many_to_one :output, class: 'BSV::Wallet::Postgres::Store::Output'
          many_to_one :action, class: 'BSV::Wallet::Postgres::Store::Action'
        end
      end
    end
  end
end
