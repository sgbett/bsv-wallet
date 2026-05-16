# frozen_string_literal: true

module BSV
  module Wallet
    module Store
      class Input < Sequel::Model
        plugin :timestamps, update_on_create: true

        many_to_one :action, class: 'BSV::Wallet::Store::Action'
        many_to_one :output, class: 'BSV::Wallet::Store::Output'
      end
    end
  end
end
