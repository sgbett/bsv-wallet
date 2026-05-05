# frozen_string_literal: true

module BSV
  module Wallet
    module Postgres
      class Tag < Sequel::Model
        plugin :timestamps, update_on_create: true

        many_to_many :outputs, class: 'BSV::Wallet::Postgres::Output',
                               join_table: :output_tags,
                               left_key: :tag_id, right_key: :output_id

        dataset_module do
          def active
            where(deleted_at: nil)
          end
        end
      end
    end
  end
end
