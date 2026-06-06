# frozen_string_literal: true

require 'openssl'

module BSV
  module Wallet
    # Deterministic Arcade callbackToken derivation.
    #
    # Arcade scopes its SSE +/events?callbackToken=...+ stream by token
    # and matches it against the +X-CallbackToken+ header carried on each
    # broadcast POST. The wallet needs a stable per-wallet identifier so
    # the listener and the submit-side use the same value -- otherwise the
    # listener subscribes to one stream and Arcade publishes status events
    # on another.
    #
    # We derive the token from the wallet's WIF via HMAC-SHA256 truncated
    # to 16 bytes (32-char hex). Two properties matter:
    #
    # - **Deterministic.** Same WIF, same token. The listener and the
    #   broadcast POST converge on one stream without an extra persistence
    #   layer (no settings table row, no env var, no boot ordering).
    # - **Recoverable.** Lose the wallet DB but keep the WIF -- you can
    #   still reconnect the SSE stream by deriving the same token. The
    #   wallet's recoverability story is "key + chain history reconstructs
    #   everything" (see WBIKD derivation memory); the callback token
    #   inherits the same property.
    #
    # The token is a **routing identifier, not a secret**. Arcade does not
    # treat it as authentication -- knowing a token lets you receive that
    # subscriber's status frames, not act on the wallet. Truncating HMAC
    # to 16 bytes is therefore fine; collision-resistance dominates over
    # cryptographic strength.
    module CallbackToken
      # Domain-separation tag so the same WIF used to derive other
      # HMAC-based identifiers in the future does not collide with this
      # one. Plain ASCII; matches the recommended construction in #266.
      DOMAIN = 'sse-callback-token'

      module_function

      # Derive the Arcade callbackToken for a wallet identified by its
      # WIF secret.
      #
      # @param wif_secret [String] WIF string (or any non-empty string used
      #   as the HMAC key)
      # @return [String] 32-char lowercase hex (16 raw bytes truncated from
      #   the HMAC-SHA256 output)
      # @raise [ArgumentError] when +wif_secret+ is nil or empty -- this
      #   guard catches mis-wired callers (e.g. CLI.boot before the WIF is
      #   resolved) rather than silently producing a token from an empty
      #   key
      def derive(wif_secret)
        raise ArgumentError, 'wif_secret must be non-empty' if wif_secret.nil? || wif_secret.empty?

        raw = OpenSSL::HMAC.digest('SHA256', wif_secret, DOMAIN)
        raw[0, 16].unpack1('H*')
      end
    end
  end
end
