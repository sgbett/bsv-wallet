# frozen_string_literal: true

module BSV
  module Wallet
    # Base error for all wallet operations. Carries a machine-readable code
    # per the BRC-100 error structure.
    class Error < StandardError
      attr_reader :code

      def initialize(message, code = 1)
        @code = code
        super(message)
      end
    end

    class InsufficientFundsError < Error
      attr_reader :required, :available

      def initialize(message = nil, required: nil, available: nil)
        @required = required
        @available = available
        super(message || "insufficient funds: need #{required}, have #{available}")
      end
    end

    class InvalidParameterError < Error
      attr_reader :parameter

      def initialize(parameter, must_be = 'valid')
        @parameter = parameter
        super("the #{parameter} parameter must be #{must_be}", 6)
      end
    end

    class InvalidHmacError < Error
      def initialize(message = 'the provided HMAC is invalid')
        super(message, 3)
      end
    end

    class InvalidSignatureError < Error
      def initialize(message = 'the provided signature is invalid')
        super(message, 4)
      end
    end

    class UnsupportedActionError < Error
      def initialize(method_name = 'this method')
        super("#{method_name} is not supported by this wallet implementation", 2)
      end
    end

    class PoolDepletedError < Error
      def initialize(pool_name)
        super("UTXO pool '#{pool_name}' is depleted; no outputs available for acquisition")
      end
    end
  end
end
