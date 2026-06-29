# frozen_string_literal: true

module BSV
  module Wallet
    # BRC-29 payment derivation primitives. One canonical home for the
    # protocol identifier and the +key_id+ composition used at every BRC-29
    # send/receive site in the wallet.
    #
    # +PROTOCOL_ID+ aliases +BSV::Auth::AuthFetch::PAYMENT_PROTOCOL_ID+
    # rather than restating the literal +[2, '3241645161d8']+. The SDK
    # constant currently lives under +Auth::AuthFetch+ — one consumer of
    # BRC-29, not its owner — and a future namespace move there is a
    # one-line wallet change at this seam.
    #
    # +key_id+ enforces byte-exact composition. A two-space typo, an NBSP,
    # or a control byte at any send site silently breaks key recovery on
    # the receive side, so the helper validates the charset (base64url
    # subset), length (≤128 chars), and non-empty contract on both inputs
    # before joining. Inline +"#{prefix} #{suffix}"+ at call sites is
    # banned by +rake brc29:guard+ — every BRC-29 derivation must route
    # through this method.
    module BRC29
      PROTOCOL_ID = BSV::Auth::AuthFetch::PAYMENT_PROTOCOL_ID

      DERIVATION_TOKEN_PATTERN = %r{\A[A-Za-z0-9+/=_-]+\z}
      DERIVATION_TOKEN_MAX_BYTES = 128

      class InvalidDerivationToken < StandardError; end

      # Compose the BRC-29 +key_id+ from the per-payment derivation prefix
      # and suffix. Returns +"#{prefix} #{suffix}"+ — a single ASCII space
      # between the two tokens, per the spec invoice-number format.
      #
      # @param prefix [String] BRC-29 derivation prefix
      # @param suffix [String] BRC-29 derivation suffix
      # @return [String] the composed key_id
      # @raise [InvalidDerivationToken] if either token is empty, exceeds
      #   {DERIVATION_TOKEN_MAX_BYTES} bytes, or contains characters
      #   outside the base64url subset (whitespace and control bytes
      #   included)
      def self.key_id(prefix, suffix)
        validate_derivation_token!(prefix, role: 'prefix')
        validate_derivation_token!(suffix, role: 'suffix')
        "#{prefix} #{suffix}"
      end

      # Validate a BRC-29 derivation token (prefix or suffix) against the
      # charset/length contract without composing a key_id. Used at
      # untrusted boundaries (e.g. the CLI envelope ingress) to reject
      # adversarial values at the boundary rather than letting them
      # surface as InvalidDerivationToken mid-spend later.
      #
      # @param token [String] the derivation token to validate
      # @param role [String] descriptor for error messages ('prefix' /
      #   'suffix' / 'derivation_prefix' / etc.)
      # @raise [InvalidDerivationToken] on any contract violation
      def self.validate_derivation_token!(token, role:)
        unless token.is_a?(String)
          raise InvalidDerivationToken,
                "BRC-29 derivation #{role} must be a String (got #{token.class})"
        end

        if token.empty?
          raise InvalidDerivationToken,
                "BRC-29 derivation #{role} must not be empty"
        end

        if token.bytesize > DERIVATION_TOKEN_MAX_BYTES
          raise InvalidDerivationToken,
                "BRC-29 derivation #{role} exceeds #{DERIVATION_TOKEN_MAX_BYTES}-byte limit " \
                "(got #{token.bytesize})"
        end

        return if token.match?(DERIVATION_TOKEN_PATTERN)

        raise InvalidDerivationToken,
              "BRC-29 derivation #{role} contains characters outside the base64url subset " \
              "[A-Za-z0-9+/=_-] (got #{token.inspect})"
      end
    end
  end
end
