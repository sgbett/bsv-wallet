# frozen_string_literal: true

module BSV
  module Wallet
    class Store
      module Models
        class CertificateField < Sequel::Model
          plugin :timestamps, update_on_create: true

          many_to_one :certificate, class: 'BSV::Wallet::Store::Models::Certificate'
        end
      end
    end
  end
end
