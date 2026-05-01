# frozen_string_literal: true

# Wallet-specific error classes.
#
# BRC-100 contract errors (Error, InvalidParameterError, InvalidHmacError,
# InvalidSignatureError, UnsupportedActionError) are defined in bsv-sdk
# and inherited via the gem dependency.

module BSV
  module Wallet
    class InsufficientFundsError < Error
      attr_reader :required, :available

      def initialize(message = nil, required: nil, available: nil)
        @required = required
        @available = available
        super(message || "insufficient funds: need #{required}, have #{available}")
      end
    end

    class PoolDepletedError < Error
      def initialize(pool_name)
        super("UTXO pool '#{pool_name}' is depleted; no outputs available for acquisition")
      end
    end

    class InvalidBeefError < Error
      def initialize(message = 'invalid BEEF data')
        super(message, 7)
      end
    end
  end
end
