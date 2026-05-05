# frozen_string_literal: true

module BSV
  module Wallet
    module Postgres
      class Certificate < Sequel::Model
        plugin :timestamps, update_on_create: true

        one_to_many :certificate_fields, class: 'BSV::Wallet::Postgres::CertificateField'

        dataset_module do
          def active
            where(deleted_at: nil)
          end
        end
      end
    end
  end
end
