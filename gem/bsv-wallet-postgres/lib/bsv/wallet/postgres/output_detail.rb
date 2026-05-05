# frozen_string_literal: true

module BSV
  module Wallet
    module Postgres
      class OutputDetail < Sequel::Model
        many_to_one :output, class: 'BSV::Wallet::Postgres::Output'
      end
    end
  end
end
