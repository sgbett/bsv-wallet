# frozen_string_literal: true

module BSV
  module Network
    # Wallet-side broadcast orchestration above SDK providers.
    #
    # Owns provider selection for broadcast and persisted affinity keyed
    # on the wallet-computed wtxid. Composes an internal +Services+
    # instance so backoff, retry, fallback, rate-limiting, and response
    # normalisation ride along unchanged -- this class layers selection
    # only.
    #
    # @example
    #   broadcaster = BSV::Network::Broadcaster.new(providers: [gp, woc], store: store)
    #   broadcaster.broadcast(raw_tx, wtxid: wtxid)
    class Broadcaster
      # @param providers [Array<BSV::Network::Provider>] providers in priority order
      # @param store     [BSV::Wallet::Store, nil] store for affinity persistence
      def initialize(providers:, store: nil)
        raise ArgumentError, 'at least one provider is required' if providers.nil? || providers.empty?

        @providers = providers.dup.freeze
        @store = store
        @services = Services.new(providers: @providers)
      end

      attr_reader :providers, :store

      # Broadcast a transaction payload through the affinity-preferred or
      # first broadcast-capable provider, with fallback on retryable errors.
      #
      # On success, persists the responding provider's name to
      # +broadcasts.provider+ keyed on the supplied wtxid -- the affinity
      # survives daemon restart and is keyed off the wallet's wtxid (so the
      # Arcade +"submitted"+ response with no +txid+ still records).
      #
      # @param payload [Object] payload accepted by the underlying provider's
      #   +:broadcast+ command (raw bytes for the daemon path, +Transaction+
      #   for the inline path -- no narrowing).
      # @param wtxid [String] 32-byte binary wire-order wtxid the wallet
      #   computed pre-broadcast. Required.
      # @return [BSV::Network::ProtocolResponse]
      def broadcast(payload, wtxid:)
        BSV::Primitives::Hex.validate_wtxid!(wtxid, name: 'Broadcaster#broadcast wtxid')

        candidates = candidates_with_affinity(wtxid)

        @services.call_with_candidates(:broadcast, candidates, payload) do |provider|
          @store&.record_broadcast_provider(wtxid: wtxid, provider: provider.name)
        end
      end

      # Provider that previously handled a broadcast for the given wtxid.
      #
      # Reads +broadcasts.provider+ via the store, then resolves the name
      # to a +Provider+ instance from +@providers+. Returns +nil+ when no
      # affinity is recorded, the store is not configured, or the provider
      # named in the column is no longer registered (config drift across
      # restart) -- callers then fall through to capability-only routing.
      #
      # @param wtxid [String] 32-byte binary wire-order wtxid
      # @return [BSV::Network::Provider, nil]
      def provider_for(wtxid)
        BSV::Primitives::Hex.validate_wtxid!(wtxid, name: 'Broadcaster#provider_for wtxid')
        return unless @store

        name = @store.broadcast_provider_for(wtxid: wtxid)
        return unless name

        @providers.find { |p| p.name == name }
      end

      private

      # Capable providers with affinity-preferred provider moved to front.
      def candidates_with_affinity(wtxid)
        capable = @providers.select { |p| p.commands.include?(:broadcast) }
        preferred = provider_for(wtxid)
        return capable unless preferred && capable.include?(preferred)

        [preferred] + (capable - [preferred])
      end
    end
  end
end
