# frozen_string_literal: true

module BSV
  module Wallet
    module Postgres
      module Store
        class Tag < Sequel::Model
          plugin :timestamps, update_on_create: true

          many_to_many :outputs, class: 'BSV::Wallet::Postgres::Store::Output',
                                 join_table: :output_tags,
                                 left_key: :tag_id, right_key: :output_id
        end
      end
    end
  end
end
