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

    class LimpModeError < Error
      attr_reader :balance, :threshold

      def initialize(balance:, threshold:)
        @balance = balance
        @threshold = threshold
        super("wallet is in limp mode: balance #{balance} sats is below " \
              "operating threshold #{threshold} sats — receive funds to restore normal operations")
      end
    end

    # Raised by Store#abort_action when the target action has any promoted
    # outputs. Aborting such an action would delete canonical UTXOs and
    # their history. abortAction is for unfinished work, not for rewinding
    # already-committed (internal-path or post-broadcast) actions.
    class CannotAbortPromotedActionError < Error
      def initialize(message = 'cannot abort action with promoted outputs')
        super
      end
    end
  end
end
