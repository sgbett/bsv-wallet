# frozen_string_literal: true

module BSV
  module Wallet
    module Postgres
      class Broadcast < Sequel::Model
        plugin :timestamps, update_on_create: true

        many_to_one :action, class: 'BSV::Wallet::Postgres::Action'
      end
    end
  end
end
