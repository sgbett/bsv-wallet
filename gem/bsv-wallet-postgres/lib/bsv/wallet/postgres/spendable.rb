# frozen_string_literal: true

module BSV
  module Wallet
    module Postgres
      class Spendable < Sequel::Model(:spendable)
        many_to_one :output, class: 'BSV::Wallet::Postgres::Output'
        many_to_one :action, class: 'BSV::Wallet::Postgres::Action'
      end
    end
  end
end
