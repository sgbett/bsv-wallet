# frozen_string_literal: true

module BSV
  module Wallet
    class Store
      module Models
        class ActionLabel < Sequel::Model
          plugin :timestamps, update_on_create: true

          many_to_one :action, class: 'BSV::Wallet::Store::Models::Action'
          many_to_one :label, class: 'BSV::Wallet::Store::Models::Label'
        end
      end
    end
  end
end
