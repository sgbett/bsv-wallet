# frozen_string_literal: true

require 'securerandom'

module BSV
  module Wallet
    class Store
      module Models
        class Action < Sequel::Model
          plugin :timestamps, update_on_create: true

          many_to_one  :tx_proof, class: 'BSV::Wallet::Store::Models::TxProof'
          one_to_one   :broadcast_entry, class: 'BSV::Wallet::Store::Models::Broadcast', key: :action_id
          one_to_many  :outputs, class: 'BSV::Wallet::Store::Models::Output'
          one_to_many  :inputs, class: 'BSV::Wallet::Store::Models::Input'
          many_to_many :labels, class: 'BSV::Wallet::Store::Models::Label',
                                join_table: :action_labels,
                                left_key: :action_id, right_key: :label_id

          def before_create
            # UUIDv7 is time-ordered (#198/#222) — sequential inserts on
            # the UNIQUE reference index. Postgres has a server-side
            # default; this branch covers SQLite (and any path that
            # doesn't go through DB defaults).
            self.reference ||= SecureRandom.uuid_v7
            super
          end

          # Derive BRC-100 status from structural state.
          # No status column — the database structure IS the state.
          #
          # :internal marks actions that never go to ARC — incoming BEEF,
          # imported UTXOs, wbikd locks, send_payment porcelain. Distinct
          # from BRC-100's noSend chained-send concept (deferred to #192).
          #
          # @return [Symbol]
          def derived_status
            return :unsigned   if wtxid.nil?
            return :completed  if tx_proof_id
            return :internal   if values[:broadcast_intent] == 'none'
            # A promotions row is recorded only at Phase 4, when the broadcast
            # was accepted (#307) — its existence is the :unproven gate.
            return :unproven   if BSV::Wallet::Store::Models::Promotion.where(action_id: id).any?
            return :failed     if broadcast_entry&.tx_status == 'REJECTED'
            return :sending    if broadcast_entry

            :unprocessed
          end
        end
      end
    end
  end
end
