# frozen_string_literal: true

require 'openssl'

module E2E
  # Deterministic derivation of N test wallet WIFs from a single funding
  # key (+BSV_WALLET_WIF_SDK+). Mirrors the snippet in
  # +.claude/strategies/Feature-testing.md+ §On Chain Setup.
  #
  # For each child index +i+ in 0..N-1:
  #   child_bn = (root_bn * (i + 2)) % SECP256K1_N
  #   child_pk = PrivateKey.new(child_bn)
  #
  # The multiplicative shift by +(i + 2)+ avoids +i = 0+ producing the
  # parent key. The modulus is the secp256k1 curve order — values are
  # mapped back into the valid private-key range.
  #
  # Naming: this is NOT BIP-32 / BRC-42. It's a deliberately simple
  # deterministic derivation chosen for the e2e harness so we don't have
  # to manage 5 additional WIFs out of band. Loss of +BSV_WALLET_WIF_SDK+
  # means loss of all 5 test wallets — acceptable, they're test funds.
  module WalletDerivation
    # secp256k1 curve order.
    SECP256K1_N = OpenSSL::BN.new(
      'FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141',
      16
    )

    # Default wallet labels for the 5-wallet harness.
    WALLET_NAMES = %w[w1 w2 w3 w4 w5].freeze

    module_function

    # Derive +count+ child WIFs from +sdk_wif+.
    #
    # @param sdk_wif [String] base58-check WIF of the funding key
    # @param count [Integer] number of child wallets to derive
    # @return [Array<String>] +count+ WIF strings, deterministic by index
    def derive_wifs(sdk_wif:, count: WALLET_NAMES.length)
      sdk_pk = BSV::Primitives::PrivateKey.from_wif(sdk_wif)
      root = sdk_pk.bn

      Array.new(count) do |i|
        child_bn = (root * OpenSSL::BN.new(i + 2)) % SECP256K1_N
        BSV::Primitives::PrivateKey.new(child_bn).to_wif
      end
    end

    # Convenience: derive a hash keyed by wallet name.
    #
    # @return [Hash{String => String}] name → WIF
    def derive_by_name(sdk_wif:, names: WALLET_NAMES)
      wifs = derive_wifs(sdk_wif: sdk_wif, count: names.length)
      names.zip(wifs).to_h
    end
  end
end
