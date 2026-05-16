# frozen_string_literal: true

module BSV
  module Wallet
    module Postgres
      module Store
        class ActionLabel < Sequel::Model
          plugin :timestamps, update_on_create: true

          many_to_one :action, class: 'BSV::Wallet::Postgres::Store::Action'
          many_to_one :label, class: 'BSV::Wallet::Postgres::Store::Label'
        end
      end
    end
  end
end
