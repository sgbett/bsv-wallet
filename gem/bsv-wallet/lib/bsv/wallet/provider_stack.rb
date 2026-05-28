# frozen_string_literal: true

module BSV
  module Wallet
    # Builds the ordered network provider list used by +Services+
    # (broadcast routing, fallback, per-provider rate limiting).
    #
    # The stack is deliberately ARC-heavy: two ARC providers fronting
    # +:broadcast+ so a rate-limit / 5xx on one falls back to the other
    # before the wallet times out the action. WoC stays in the stack
    # for chain queries (+:get_tx+, +:get_utxos+, +:get_merkle_path+)
    # and as a third-line broadcast fallback.
    #
    # Stack composition (mainnet):
    #   1. GorillaPool — anonymous-capable ARC; first to try.
    #   2. TAAL        — added IF +BSV_ARC_TAAL_KEY+ is set.
    #   3. WhatsOnChain — chain queries + last-resort broadcast.
    #
    # Testnet drops TAAL entirely (no published testnet ARC) and uses
    # GorillaPool's testnet ARC + WoC's testnet API.
    #
    # @example wire into Services
    #   providers = BSV::Wallet::ProviderStack.build(network: :mainnet)
    #   services  = BSV::Network::Services.new(providers: providers)
    #
    # Env vars consumed:
    #   - +BSV_ARC_TAAL_KEY+ — TAAL ARC API key (e.g. +mainnet_abc...+).
    #     Optional. When absent, TAAL is omitted from the stack.
    module ProviderStack
      module_function

      # Build the provider list for +network+. Order is significant:
      # +Services+ tries providers in order for each command.
      #
      # @param network [Symbol] +:mainnet+ or +:testnet+
      # @return [Array<BSV::Network::Provider>]
      def build(network: :mainnet)
        providers = []
        providers << gorilla_pool(network)
        providers << taal(network) if include_taal?(network)
        providers << whats_on_chain(network)
        providers
      end

      # @return [Boolean] true when a TAAL provider will be added on +build+
      def include_taal?(network)
        network == :mainnet && taal_key_present?
      end

      def gorilla_pool(network)
        BSV::Network::Providers::GorillaPool.default(testnet: network != :mainnet)
      end

      def taal(_network)
        BSV::Network::Providers::TAAL.mainnet(api_key: ENV.fetch('BSV_ARC_TAAL_KEY'))
      end

      def whats_on_chain(network)
        BSV::Network::Providers::WhatsOnChain.send(network)
      end

      def taal_key_present?
        ENV['BSV_ARC_TAAL_KEY'].to_s.strip.length.positive?
      end
    end
  end
end
