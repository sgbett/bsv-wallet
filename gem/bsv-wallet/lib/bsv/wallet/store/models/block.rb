# frozen_string_literal: true

module BSV
  module Wallet
    module Store
      class Block < Sequel::Model
        plugin :timestamps, update_on_create: true

        one_to_many :tx_proofs, class: 'BSV::Wallet::Store::TxProof'
      end
    end
  end
end
