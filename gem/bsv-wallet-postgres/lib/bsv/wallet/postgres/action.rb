# frozen_string_literal: true

module BSV
  module Wallet
    module Postgres
      class Action < Sequel::Model
        include DisplayTxid
        plugin :timestamps, update_on_create: true

        many_to_one  :tx_proof, class: 'BSV::Wallet::Postgres::TxProof'
        one_to_one   :broadcast_entry, class: 'BSV::Wallet::Postgres::Broadcast', key: :action_id
        one_to_many  :outputs, class: 'BSV::Wallet::Postgres::Output'
        one_to_many  :inputs, class: 'BSV::Wallet::Postgres::Input'
        many_to_many :labels, class: 'BSV::Wallet::Postgres::Label',
                              join_table: :action_labels,
                              left_key: :action_id, right_key: :label_id

        # Derive BRC-100 status from structural state.
        # No status column — the database structure IS the state.
        #
        # @return [Symbol]
        def derived_status
          return :unsigned   if wtxid.nil?
          return :completed  if tx_proof_id
          return :nosend     if values[:broadcast] == 'none'
          return :unproven   unless outputs_dataset.empty?
          return :failed     if broadcast_entry&.tx_status == 'REJECTED'
          return :sending    if broadcast_entry
          :unprocessed
        end
      end
    end
  end
end
