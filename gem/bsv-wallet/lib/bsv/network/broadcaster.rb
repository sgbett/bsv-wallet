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
    #   broadcaster = BSV::Network::Broadcaster.new(providers: [gorilla_pool], store: store)
    #   broadcaster.broadcast(raw_tx, wtxid: wtxid)
    #
    # Providers passed here must implement +:broadcast+ and +:get_tx_status+
    # in Arcade-shape -- callback_token kwarg, X-CallbackToken header, and
    # the SSE-aligned response payload. WhatsOnChain's protocol declares the
    # +:broadcast+ capability but its +call_broadcast(tx)+ has no kwargs and
    # its tx_status semantics are different; don't mix it in here. Use it as
    # a chain query provider in +Services+, not a Broadcaster candidate.
    class Broadcaster
      # @param providers [Array<BSV::Network::Provider>] providers in priority order
      # @param store     [BSV::Wallet::Store, nil] store for affinity persistence
      def initialize(providers:, store: nil)
        raise ArgumentError, 'at least one provider is required' if providers.nil? || providers.empty?

        @providers = providers.dup.freeze
        @store = store
        @services = Services.new(providers: @providers)
      end

      attr_reader :providers

      # Broadcast a transaction payload through the affinity-preferred or
      # first broadcast-capable provider, with fallback on retryable errors.
      #
      # On success, persists the responding provider's name to
      # +broadcasts.provider+ keyed on the supplied wtxid -- the affinity
      # survives daemon restart and is keyed off the wallet's wtxid (so the
      # Arcade +"submitted"+ response with no +txid+ still records).
      #
      # The optional +callback_token+ is forwarded to the underlying
      # provider as the +X-CallbackToken+ HTTP header (see #266 + plan
      # §4.1). Both ARC and Arcade protocols already accept this as a
      # per-call kwarg in the SDK, so the value flows straight through
      # +Provider#call+ to the protocol's +call_broadcast+ without any
      # additional plumbing here. Lenient default (nil): tests that do
      # not run an SSE listener can broadcast without the header at the
      # cost of forgoing status push -- production callers (CLI.boot,
      # walletd) always supply one.
      #
      # @param payload [Object] payload accepted by the underlying provider's
      #   +:broadcast+ command (raw bytes for the daemon path, +Transaction+
      #   for the inline path -- no narrowing).
      # @param wtxid [String] 32-byte binary wire-order wtxid the wallet
      #   computed pre-broadcast. Required.
      # @param callback_token [String, nil] Arcade callbackToken to send
      #   as +X-CallbackToken+. When set, the SSE listener subscribed to
      #   the same token receives the resulting status frame.
      # @return [BSV::Network::ProtocolResponse]
      def broadcast(payload, wtxid:, callback_token: nil)
        BSV::Primitives::Hex.validate_wtxid!(wtxid, name: 'Broadcaster#broadcast wtxid')

        candidates = candidates_with_affinity(wtxid)
        kwargs = callback_token ? { callback_token: callback_token } : {}

        @services.call_with_candidates(:broadcast, candidates, payload, **kwargs) do |provider|
          # Affinity is a best-effort hint. A DB failure here does not unwind
          # the successful broadcast — the tx is already in the mempool and
          # the poll loop recovers tx_status on the next pass. Surface it as
          # a targeted warning so a real broadcast failure (which bubbles)
          # stays distinguishable from a bookkeeping miss.
          @store&.record_broadcast_provider(wtxid: wtxid, provider: provider.name)
        rescue StandardError => e
          BSV.logger&.warn do
            '[Broadcaster] affinity write failed (broadcast succeeded, hint lost) ' \
              "dtxid=#{wtxid.reverse.unpack1('H*')} provider=#{provider.name}: #{e.message}"
          end
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

      # Query tx status through the affinity-preferred or first capable
      # provider, with fallback on retryable errors.
      #
      # The wallet's bookkeeping key is the binary wtxid; the wire query
      # uses the display-order +dtxid+ hex string. The SDK's protocol
      # +call_get_tx_status(txid, **)+ takes the dtxid as a *positional*
      # argument (Ruby 3 keyword-arg strictness; passing it as +txid:+
      # raises "unknown keyword: :txid").
      #
      # @param wtxid [String] 32-byte binary wire-order wtxid (affinity key)
      # @param dtxid [String] 64-char display-order hex (sent to ARC)
      # @return [BSV::Network::ProtocolResponse]
      def get_tx_status(wtxid:, dtxid:)
        BSV::Primitives::Hex.validate_wtxid!(wtxid, name: 'Broadcaster#get_tx_status wtxid')

        candidates = candidates_with_affinity(wtxid, command: :get_tx_status)
        @services.call_with_candidates(:get_tx_status, candidates, dtxid)
      end

      private

      # Capable providers with the affinity-preferred provider moved to front.
      def candidates_with_affinity(wtxid, command: :broadcast)
        capable = @providers.select { |p| p.commands.include?(command) }
        preferred = provider_for(wtxid)
        return capable unless preferred && capable.include?(preferred)

        [preferred] + (capable - [preferred])
      end
    end
  end
end
