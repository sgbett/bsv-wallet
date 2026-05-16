# frozen_string_literal: true

module BSV
  module Wallet
    module Store
      class OutputTag < Sequel::Model
        plugin :timestamps, update_on_create: true

        many_to_one :output, class: 'BSV::Wallet::Store::Output'
        many_to_one :tag, class: 'BSV::Wallet::Store::Tag'
      end
    end
  end
end
