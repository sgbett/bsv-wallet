# frozen_string_literal: true

module BSV
  module Wallet
    module Postgres
      class TxReq < Sequel::Model
        plugin :timestamps, update_on_create: true

        many_to_one :tx_proof, class: 'BSV::Wallet::Postgres::TxProof'
      end
    end
  end
end
