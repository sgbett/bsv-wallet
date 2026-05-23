# frozen_string_literal: true

module BSV
  module Wallet
    class Store
      module Models
        class Certificate < Sequel::Model
          plugin :timestamps, update_on_create: true

          one_to_many :certificate_fields, class: 'BSV::Wallet::Store::Models::CertificateField'
        end
      end
    end
  end
end
