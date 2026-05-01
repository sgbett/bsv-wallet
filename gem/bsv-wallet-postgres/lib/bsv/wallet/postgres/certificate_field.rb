# frozen_string_literal: true

module BSV
  module Wallet
    module Postgres
      class CertificateField < Sequel::Model
        plugin :timestamps, update_on_create: true

        many_to_one :certificate, class: 'BSV::Wallet::Postgres::Certificate'
      end
    end
  end
end
