# frozen_string_literal: true

module BSV
  module Wallet
    module Store
      class OutputDetail < Sequel::Model
        many_to_one :output, class: 'BSV::Wallet::Store::Output'
        many_to_one :action, class: 'BSV::Wallet::Store::Action'
      end
    end
  end
end
