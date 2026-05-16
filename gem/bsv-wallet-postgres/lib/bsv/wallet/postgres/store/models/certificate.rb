# frozen_string_literal: true

module BSV
  module Wallet
    module Postgres
      module Store
        class Certificate < Sequel::Model
          plugin :timestamps, update_on_create: true

          one_to_many :certificate_fields, class: 'BSV::Wallet::Postgres::Store::CertificateField'
        end
      end
    end
  end
end
