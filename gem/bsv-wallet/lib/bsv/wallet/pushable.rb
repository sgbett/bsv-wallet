# frozen_string_literal: true

module BSV
  module Wallet
    # Mixin contract for entities that can be pushed to the network.
    #
    # Include this module in any model that needs to submit data to a
    # network service (e.g. broadcasting a transaction via ARC).
    # The including class must override every method — the defaults
    # raise NotImplementedError to enforce the contract.
    #
    # Designed to work alongside Fetchable. When a class includes both,
    # only one +write!+ method exists — the class must provide its own
    # override that handles both push and fetch response shapes.
    module Pushable
      # The protocol command to invoke (e.g. +:broadcast+).
      #
      # @return [Symbol]
      def push_command
        raise NotImplementedError, "#{self.class}#push_command not implemented"
      end

      # The payload to send (e.g. raw_tx binary).
      #
      # @return [Object]
      def push_payload
        raise NotImplementedError, "#{self.class}#push_payload not implemented"
      end

      # Update self from the network response after a successful push.
      #
      # @param response [Hash] normalized response data
      def write!(response)
        raise NotImplementedError, "#{self.class}#write! not implemented"
      end

      # Whether this entity currently needs pushing.
      #
      # @return [Boolean]
      def needs_push?
        raise NotImplementedError, "#{self.class}#needs_push? not implemented"
      end
    end
  end
end
