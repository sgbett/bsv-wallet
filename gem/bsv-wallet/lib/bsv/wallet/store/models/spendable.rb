# frozen_string_literal: true

module BSV
  module Wallet
    class Store
      module Models
        class Spendable < Sequel::Model(:spendable)
          many_to_one :output, class: 'BSV::Wallet::Store::Models::Output'
          many_to_one :action, class: 'BSV::Wallet::Store::Models::Action'
        end
      end
    end
  end
end
