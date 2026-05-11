# frozen_string_literal: true

module BSV
  module Wallet
    module Postgres
      class TxProof < Sequel::Model
        include DisplayTxid
        plugin :timestamps, update_on_create: true

        many_to_one :block, class: 'BSV::Wallet::Postgres::Block'
        one_to_many :actions, class: 'BSV::Wallet::Postgres::Action'
        one_to_many :tx_reqs, class: 'BSV::Wallet::Postgres::TxReq'
      end
    end
  end
end
