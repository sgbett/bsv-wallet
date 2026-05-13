# frozen_string_literal: true

module BSV
  module Wallet
    module Postgres
      class Broadcast < Sequel::Model
        include BSV::Wallet::Pushable
        include BSV::Wallet::Fetchable

        plugin :timestamps, update_on_create: true

        many_to_one :action, class: 'BSV::Wallet::Postgres::Action'

        # Broadcasts with these statuses are considered terminal — no further polling.
        TERMINAL_STATUSES = %w[
          SEEN_ON_NETWORK MINED IMMUTABLE
          REJECTED DOUBLE_SPEND_ATTEMPTED
        ].freeze

        # Minimum age (seconds) before a broadcast is eligible for status polling.
        FETCH_STALENESS = 30

        # --- Pushable contract ---

        def push_command
          :broadcast
        end

        def push_payload
          action.raw_tx
        end

        def needs_push?
          broadcast_at.nil? && action&.raw_tx
        end

        # --- Fetchable contract ---

        def fetch_command
          :get_tx_status
        end

        def fetch_args
          { txid: action.dtxid }
        end

        def needs_fetch?
          return false unless broadcast_at
          return false if TERMINAL_STATUSES.include?(tx_status)

          broadcast_at < Time.now - FETCH_STALENESS
        end

        # --- Shared write ---

        # Update columns from a normalized Services response.
        #
        # @param response [BSV::Network::ProtocolResponse] normalized response
        def write!(response)
          data = response.data
          return unless data.is_a?(Hash)

          fields = {}
          fields[:broadcast_at] = Time.now if broadcast_at.nil?
          fields[:tx_status] = data[:tx_status] if data[:tx_status]
          fields[:arc_status] = data[:status] if data[:status]
          fields[:block_hash] = decode_hex(data[:block_hash]) if data[:block_hash]
          fields[:block_height] = data[:block_height] if data[:block_height]
          fields[:merkle_path] = decode_hex(data[:merkle_path]) if data[:merkle_path]
          fields[:extra_info] = data[:extra_info] if data[:extra_info]
          fields[:competing_txs] = Sequel.pg_array(data[:competing_txs]) if data[:competing_txs]

          update(fields) unless fields.empty?
        end

        private

        def decode_hex(value)
          return unless value
          return Sequel.blob(value) if value.encoding == Encoding::BINARY

          Sequel.blob([value].pack('H*'))
        end
      end
    end
  end
end
