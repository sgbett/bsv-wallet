# frozen_string_literal: true

module BSV
  module Wallet
    module Store
      class CertificateField < Sequel::Model
        plugin :timestamps, update_on_create: true

        many_to_one :certificate, class: 'BSV::Wallet::Store::Certificate'
      end
    end
  end
end
