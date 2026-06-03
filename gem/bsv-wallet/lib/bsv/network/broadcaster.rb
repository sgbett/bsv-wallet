# frozen_string_literal: true

module BSV
  module Network
    # Wallet-side broadcast orchestration above SDK providers.
    #
    # Owns provider selection for broadcast and (in later tasks) persisted
    # affinity keyed on the wallet-computed wtxid. Composes an internal
    # +Services+ instance so backoff, retry, fallback, rate-limiting, and
    # response normalisation ride along unchanged — this class layers
    # selection only.
    #
    # @example
    #   broadcaster = BSV::Network::Broadcaster.new(providers: [gp, woc], store: store)
    #   broadcaster.broadcast(raw_tx, wtxid: wtxid)
    class Broadcaster
      # @param providers [Array<BSV::Network::Provider>] providers in priority order
      # @param store     [BSV::Wallet::Store, nil] store for affinity persistence (used in Task 3+)
      def initialize(providers:, store: nil)
        raise ArgumentError, 'at least one provider is required' if providers.nil? || providers.empty?

        @providers = providers.dup.freeze
        @store = store
        @services = Services.new(providers: @providers)
      end

      attr_reader :providers, :store

      # Broadcast a transaction payload through the first broadcast-capable provider.
      #
      # @param payload [Object] payload accepted by the underlying provider's
      #   +:broadcast+ command (raw bytes for the daemon path, +Transaction+
      #   for the inline path — no narrowing).
      # @param wtxid [String] 32-byte binary wire-order wtxid the wallet
      #   computed pre-broadcast. Required.
      # @return [BSV::Network::ProtocolResponse]
      def broadcast(payload, wtxid:)
        _ = wtxid
        @services.call(:broadcast, payload)
      end

      # Provider that previously handled a broadcast for the given wtxid.
      #
      # Placeholder for Task 2 — affinity lookup against the DB lands in
      # Task 3 once +broadcasts.provider+ is wired. Returns +nil+ so the
      # selection overlay degrades to first-capable routing.
      #
      # @param wtxid [String] 32-byte binary wire-order wtxid
      # @return [BSV::Network::Provider, nil]
      def provider_for(wtxid)
        _ = wtxid
        nil
      end
    end
  end
end
