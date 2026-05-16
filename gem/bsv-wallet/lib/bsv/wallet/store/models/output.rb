# frozen_string_literal: true

module BSV
  module Wallet
    module Store
      class Output < Sequel::Model
        # No timestamps plugin — outputs are immutable.
        # created_at is set by the database default.

        many_to_one  :action, class: 'BSV::Wallet::Store::Action'
        one_to_one   :spendable_entry, class: 'BSV::Wallet::Store::Spendable', key: :output_id
        one_to_one   :detail, class: 'BSV::Wallet::Store::OutputDetail', key: :output_id
        one_to_one   :input, class: 'BSV::Wallet::Store::Input', key: :output_id
        one_to_one   :output_basket, class: 'BSV::Wallet::Store::OutputBasket', key: :output_id
        many_to_many :tags, class: 'BSV::Wallet::Store::Tag',
                            join_table: :output_tags,
                            left_key: :output_id, right_key: :tag_id

        dataset_module do
          # The UTXO set: outputs in the spendable table and not claimed by any input.
          def spendable
            spendable_ds = BSV::Wallet::Store::Spendable.dataset
                                                        .where(output_id: Sequel[:outputs][:id]).select(1)
            input_ds = BSV::Wallet::Store::Input.dataset
                                                .where(output_id: Sequel[:outputs][:id]).select(1)

            where(spendable_ds.exists).exclude(input_ds.exists)
          end

          # Filter outputs belonging to a named basket.
          # 'default' is implicit — outputs with no output_baskets row.
          def in_basket(name)
            if name == 'default'
              basket_ds = BSV::Wallet::Store::OutputBasket.dataset
                                                          .where(Sequel[:output_baskets][:output_id] => Sequel[:outputs][:id])
                                                          .select(1)
              exclude(basket_ds.exists)
            else
              basket_ds = BSV::Wallet::Store::OutputBasket.dataset
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
