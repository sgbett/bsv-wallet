# frozen_string_literal: true

module BSV
  module Wallet
    module Postgres
      class Input < Sequel::Model
        plugin :timestamps, update_on_create: true

        many_to_one :action, class: 'BSV::Wallet::Postgres::Action'
        many_to_one :output, class: 'BSV::Wallet::Postgres::Output'
      end
    end
  end
end
