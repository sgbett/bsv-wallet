# frozen_string_literal: true

module BSV
  module Wallet
    module Postgres
      class ActionLabel < Sequel::Model
        plugin :timestamps, update_on_create: true

        many_to_one :action, class: 'BSV::Wallet::Postgres::Action'
        many_to_one :label, class: 'BSV::Wallet::Postgres::Label'

        dataset_module do
          def active
            where(deleted_at: nil)
          end
        end
      end
    end
  end
end
