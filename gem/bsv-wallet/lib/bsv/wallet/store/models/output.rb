# frozen_string_literal: true

module BSV
  module Wallet
    class Store
      module Models
        class Output < Sequel::Model
          # No timestamps plugin — outputs are immutable.
          # created_at is set by the database default.

          # The wallet's WIF-derived root P2PKH locking script bytes,
          # populated by +Store#migrate!+ from
          # +BSV::Wallet::Migration.expected_root_script+ (HLR #467).
          # Application-layer mirror of the per-wallet DB CHECK literal;
          # lets the model spot invalid combinations before the DB rejects.
          class << self
            attr_accessor :expected_root_script
          end

          many_to_one  :action, class: 'BSV::Wallet::Store::Models::Action'
          one_to_one   :spendable_entry, class: 'BSV::Wallet::Store::Models::Spendable', key: :output_id
          one_to_one   :detail, class: 'BSV::Wallet::Store::Models::OutputDetail', key: :output_id
          one_to_one   :input, class: 'BSV::Wallet::Store::Models::Input', key: :output_id
          one_to_one   :output_basket, class: 'BSV::Wallet::Store::Models::OutputBasket', key: :output_id
          many_to_many :tags, class: 'BSV::Wallet::Store::Models::Tag',
                              join_table: :output_tags,
                              left_key: :output_id, right_key: :tag_id

          dataset_module do
            # The UTXO set: outputs in the spendable table and not claimed by any input.
            def spendable
              spendable_ds = BSV::Wallet::Store::Models::Spendable.dataset
                                                                  .where(output_id: Sequel[:outputs][:id]).select(1)
              input_ds = BSV::Wallet::Store::Models::Input.dataset
                                                          .where(output_id: Sequel[:outputs][:id]).select(1)

              where(spendable_ds.exists).exclude(input_ds.exists)
            end

            # Filter outputs by basket membership. Every accepted value
            # applies a real filter — to apply *no* basket filter, omit
            # the call entirely and chain off +#spendable+ directly.
            #
            # - +nil+              → outputs with no +output_baskets+ row (unbasketed).
            # - +String+           → outputs in the named basket.
            # - +Array<String>+    → outputs in any of the named baskets.
            def in_basket(name_or_names)
              if name_or_names.nil?
                basket_ds = BSV::Wallet::Store::Models::OutputBasket.dataset
                                                                    .where(Sequel[:output_baskets][:output_id] => Sequel[:outputs][:id])
                                                                    .select(1)
                exclude(basket_ds.exists)
              else
                names = Array(name_or_names)
                basket_ds = BSV::Wallet::Store::Models::OutputBasket.dataset
                                                                    .join(:baskets, id: :basket_id)
                                                                    .where(Sequel[:output_baskets][:output_id] => Sequel[:outputs][:id])
                                                                    .where(Sequel[:baskets][:name] => names)
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
end
