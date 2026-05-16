# frozen_string_literal: true

module BSV
  module Wallet
    module Postgres
      module Store
        class Label < Sequel::Model
          plugin :timestamps, update_on_create: true

          many_to_many :actions, class: 'BSV::Wallet::Postgres::Store::Action',
                                 join_table: :action_labels,
                                 left_key: :label_id, right_key: :action_id
        end
      end
    end
  end
end
