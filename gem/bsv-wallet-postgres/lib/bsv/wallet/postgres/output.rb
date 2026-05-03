# frozen_string_literal: true

module BSV
  module Wallet
    module Postgres
      class Output < Sequel::Model
        # No timestamps plugin — outputs are immutable.
        # created_at is set by the database default.

        many_to_one  :action, class: 'BSV::Wallet::Postgres::Action'
        one_to_one   :spendable_entry, class: 'BSV::Wallet::Postgres::Spendable', key: :output_id
        one_to_one   :detail, class: 'BSV::Wallet::Postgres::OutputDetail', key: :output_id
        one_to_one   :input, class: 'BSV::Wallet::Postgres::Input', key: :output_id
        one_to_one   :output_basket, class: 'BSV::Wallet::Postgres::OutputBasket', key: :output_id
        many_to_many :tags, class: 'BSV::Wallet::Postgres::Tag',
                            join_table: :output_tags,
                            left_key: :output_id, right_key: :tag_id

        dataset_module do
          # The UTXO set: outputs in the spendable table and not claimed by any input.
          def spendable
            spendable_ds = BSV::Wallet::Postgres::Spendable.dataset
              .where(output_id: Sequel[:outputs][:id]).select(1)
            input_ds = BSV::Wallet::Postgres::Input.dataset
              .where(output_id: Sequel[:outputs][:id]).select(1)

            where(spendable_ds.exists).exclude(input_ds.exists)
          end

          # Filter outputs belonging to a named basket.
          # 'default' is implicit — outputs with no output_baskets row.
          def in_basket(name)
            if name == 'default'
              basket_ds = BSV::Wallet::Postgres::OutputBasket.dataset
                .where(Sequel[:output_baskets][:output_id] => Sequel[:outputs][:id])
                .select(1)
              exclude(basket_ds.exists)
            else
              basket_ds = BSV::Wallet::Postgres::OutputBasket.dataset
                .join(:baskets, id: :basket_id)
                .where(Sequel[:output_baskets][:output_id] => Sequel[:outputs][:id])
                .where(Sequel[:baskets][:name] => name)
                .select(1)
              where(basket_ds.exists)
            end
          end

          # Filter outputs with at least the given satoshi value.
          def min_satoshis(value)
            where { satoshis >= value }
          end
        end

        def spendable?
          !spendable_entry.nil? && input.nil?
        end

        def basket
          output_basket&.basket
        end
      end
    end
  end
end
