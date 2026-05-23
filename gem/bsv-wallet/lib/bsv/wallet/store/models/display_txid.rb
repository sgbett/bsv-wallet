# frozen_string_literal: true

module BSV
  module Wallet
    class Store
      module Models
        module DisplayTxid
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
end
