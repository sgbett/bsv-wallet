# frozen_string_literal: true

module BSV
  module Wallet
    module Postgres
      class Spendable < Sequel::Model(:spendable)
        many_to_one :output, class: 'BSV::Wallet::Postgres::Output'
      end
    end
  end
end
