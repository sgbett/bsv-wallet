# frozen_string_literal: true

module BSV
  module Wallet
    module Postgres
      # Convenience method for models with a wtxid column.
      # Converts wire-order binary wtxid to display-order hex — the
      # human-readable format used by block explorers and external APIs.
      #
      # Include on any Sequel::Model whose table has a wtxid bytea column.
      module DisplayTxid
        # Display-order hex transaction ID (reversed from wire-order wtxid).
        #
        # @return [String, nil] 64-character hex string, or nil if wtxid is nil
        def dtxid
          return unless wtxid

          BSV::Primitives::Hex.validate_wtxid!(wtxid, name: "#{self.class.name}#dtxid")
          wtxid.reverse.unpack1('H*')
        end
        alias dtxid_hex dtxid
      end
    end
  end
end
