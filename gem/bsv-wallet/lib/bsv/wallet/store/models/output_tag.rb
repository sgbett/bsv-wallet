# frozen_string_literal: true

module BSV
  module Wallet
    class Store
      module Models
        class OutputTag < Sequel::Model
          plugin :timestamps, update_on_create: true

          many_to_one :output, class: 'BSV::Wallet::Store::Models::Output'
          many_to_one :tag, class: 'BSV::Wallet::Store::Models::Tag'
        end
      end
    end
  end
end
