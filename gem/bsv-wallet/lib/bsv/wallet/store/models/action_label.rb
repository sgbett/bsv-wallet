# frozen_string_literal: true

module BSV
  module Wallet
    module Store
      class ActionLabel < Sequel::Model
        plugin :timestamps, update_on_create: true

        many_to_one :action, class: 'BSV::Wallet::Store::Action'
        many_to_one :label, class: 'BSV::Wallet::Store::Label'
      end
    end
  end
end
