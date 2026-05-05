# frozen_string_literal: true

module BSV
  module Wallet
    module Postgres
      class OutputDetail < Sequel::Model
        many_to_one :output, class: 'BSV::Wallet::Postgres::Output'
        many_to_one :action, class: 'BSV::Wallet::Postgres::Action'
      end
    end
  end
end
