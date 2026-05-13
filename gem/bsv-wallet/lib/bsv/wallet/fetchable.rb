# frozen_string_literal: true

module BSV
  module Wallet
    # Mixin contract for entities that can fetch state from the network.
    #
    # Include this module in any model that needs to poll a network
    # service for updated state (e.g. checking transaction status,
    # retrieving merkle proofs).
    #
    # The including class must override every method — the defaults
    # raise NotImplementedError to enforce the contract.
    #
    # Designed to work alongside Pushable. When a class includes both,
    # only one +write!+ method exists — the class must provide its own
    # override that handles both push and fetch response shapes.
    module Fetchable
      # The protocol command to invoke (e.g. +:get_tx_status+).
      #
      # @return [Symbol]
      def fetch_command
        raise NotImplementedError, "#{self.class}#fetch_command not implemented"
      end

      # The arguments to pass to the protocol command.
      #
      # @return [Hash]
      def fetch_args
        raise NotImplementedError, "#{self.class}#fetch_args not implemented"
      end

      # Update self from the network response after a successful fetch.
      #
      # @param response [Hash] normalized response data
      def write!(response)
        raise NotImplementedError, "#{self.class}#write! not implemented"
      end

      # Whether this entity currently needs fetching.
      #
      # @return [Boolean]
      def needs_fetch?
        raise NotImplementedError, "#{self.class}#needs_fetch? not implemented"
      end
    end
  end
end
