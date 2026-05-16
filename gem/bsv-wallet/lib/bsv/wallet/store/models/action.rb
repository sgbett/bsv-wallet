# frozen_string_literal: true

require 'securerandom'

module BSV
  module Wallet
    module Store
      class Action < Sequel::Model
        include DisplayTxid
        include BSV::Wallet::Fetchable

        plugin :timestamps, update_on_create: true

        many_to_one  :tx_proof, class: 'BSV::Wallet::Store::TxProof'
        one_to_one   :broadcast_entry, class: 'BSV::Wallet::Store::Broadcast', key: :action_id
        one_to_many  :outputs, class: 'BSV::Wallet::Store::Output'
        one_to_many  :inputs, class: 'BSV::Wallet::Store::Input'
        many_to_many :labels, class: 'BSV::Wallet::Store::Label',
                              join_table: :action_labels,
                              left_key: :action_id, right_key: :label_id

        def before_create
          self.reference ||= SecureRandom.uuid
          super
        end

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

        # -- Fetchable contract --

        def fetch_command
          :get_tx_status
        end

        def fetch_args
          { txid: dtxid }
        end

        def needs_fetch?
          outgoing && !wtxid.nil? && tx_proof_id.nil?
        end

        # Create a TxProof from the network response when proof data is present.
        # No-op when the transaction is not yet mined (no merkle_path/block_height).
        #
        # @param response [BSV::Network::ProtocolResponse] normalized response
        def write!(response)
          data = response.data
          return unless data.is_a?(Hash) && data[:merkle_path] && data[:block_height]

          proof_store = BSV::Wallet::Store::ProofStore.new
          proof_id = proof_store.save_proof(
            wtxid: wtxid,
            proof: {
              height: data[:block_height],
              block_hash: decode_hex(data[:block_hash]),
              merkle_path: decode_hex(data[:merkle_path]),
              raw_tx: raw_tx
            }
          )
          update(tx_proof_id: proof_id)
        end

        private

        def decode_hex(hex)
          return unless hex
          return hex if hex.encoding == Encoding::BINARY

          [hex].pack('H*')
        end
      end
    end
  end
end
