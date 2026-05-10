# frozen_string_literal: true

require 'base64'
require 'set'

module BSV
  module Network
    # Porcelain routing layer above SDK providers/protocols.
    #
    # Same +call(command, *args, **kwargs)+ interface as Provider — drop-in
    # replacement. Adds capability-based routing, fallback on retryable errors,
    # per-provider rate limiting, response normalization, and opportunistic
    # sibling data caching.
    #
    # @example
    #   services = BSV::Network::Services.new(providers: [gorilla_pool, woc])
    #   services.call(:broadcast, tx)
    #   services.call(:get_tx, txid)
    #   services.call(:get_utxos, address)
    class Services
      # @param providers [Array<BSV::Network::Provider>] providers in priority order
      def initialize(providers:)
        raise ArgumentError, 'at least one provider is required' if providers.nil? || providers.empty?

        @providers = providers.freeze
        @buckets = providers.each_with_object({}) do |p, h|
          h[p] = TokenBucket.new(p.rate_limit) if p.rate_limit
        end
        @sibling_memo = {}
        @broadcast_affinity = {}
        @mutex = Mutex.new
      end

      # Dispatch a command with provider routing and fallback.
      #
      # @param command [Symbol] SDK command name
      # @param args    [Array]  positional arguments forwarded to the provider
      # @param kwargs  [Hash]   keyword arguments forwarded to the provider
      # @return [Result::Success, Result::Error, Result::NotFound]
      def call(command, *args, **kwargs)
        sym = command.to_sym

        # Serve from sibling memo if available
        memo_result = check_sibling_memo(sym, args, kwargs)
        return memo_result if memo_result

        candidates = candidates_for(sym)
        return no_provider_error(sym) if candidates.empty?

        last_error = nil

        candidates.each do |provider|
          acquire_rate_limit!(provider)

          result = provider.call(sym, *args, **kwargs)

          if result.success?
            stash_siblings(sym, result, args, kwargs)
            normalized = normalize(sym, result)
            record_affinity(sym, provider, normalized)
            return normalized
          end

          return result if result.not_found?

          last_error = result
          break unless result.respond_to?(:retryable?) && result.retryable?
        end

        last_error
      end

      # Union of all commands available across all registered providers.
      #
      # @return [Set<Symbol>]
      def commands
        @providers.reduce(Set.new) { |acc, p| acc | p.commands }
      end

      # Returns the registered providers (frozen at construction time).
      #
      # @return [Array<BSV::Network::Provider>]
      attr_reader :providers

      private

      # --- Routing ---

      # Build the ordered candidate list for a command.
      # For :get_tx_status, broadcast affinity moves the preferred provider to front.
      def candidates_for(command)
        capable = @providers.select { |p| p.commands.include?(command) }

        if command == :get_tx_status
          affinity = @mutex.synchronize { @broadcast_affinity.values.last }
          capable = [affinity] + (capable - [affinity]) if affinity && capable.include?(affinity)
        end

        capable
      end

      def no_provider_error(command)
        Result::Error.new(message: "no provider serves :#{command}", retryable: false)
      end

      # --- Rate Limiting ---

      def acquire_rate_limit!(provider)
        bucket = @buckets[provider]
        bucket&.acquire!
      end

      # --- Normalization ---

      NORMALIZED_COMMANDS = %i[broadcast get_tx_status get_tx].freeze
      private_constant :NORMALIZED_COMMANDS

      def normalize(command, result)
        return result unless NORMALIZED_COMMANDS.include?(command)

        data = result.data
        normalized_data =
          case command
          when :broadcast, :get_tx_status
            normalize_broadcast_response(data)
          when :get_tx
            normalize_get_tx(data)
          end

        Result::Success.new(data: normalized_data, metadata: result.metadata)
      end

      # Canonical broadcast/tx_status response: symbol keys, consistent field names.
      # Handles string keys, symbol keys, camelCase, snake_case — produces one shape.
      def normalize_broadcast_response(data)
        return data unless data.is_a?(Hash)

        {
          txid: extract(data, 'txid', :txid, 'txId', :txId),
          tx_status: extract(data, 'txStatus', :txStatus, :tx_status, 'tx_status'),
          status: extract(data, 'status', :status),
          block_hash: extract(data, 'blockHash', :blockHash, :block_hash, 'block_hash'),
          block_height: extract(data, 'blockHeight', :blockHeight, :block_height, 'block_height'),
          merkle_path: extract(data, 'merklePath', :merklePath, :merkle_path, 'merkle_path'),
          extra_info: extract(data, 'extraInfo', :extraInfo, :extra_info, 'extra_info'),
          competing_txs: extract(data, 'competingTxs', :competingTxs, :competing_txs, 'competing_txs')
        }
      end

      # Canonical get_tx response: hex string.
      # JungleBus returns a JSON hash with base64-encoded transaction.
      # WoC returns a hex string directly.
      def normalize_get_tx(data)
        return data if data.is_a?(String)
        return data unless data.is_a?(Hash) && data['transaction']

        binary = Base64.decode64(data['transaction'])
        binary.unpack1('H*')
      end

      def extract(hash, *keys)
        keys.each { |k| return hash[k] if hash.key?(k) }
        nil
      end

      # --- Sibling Memo ---

      MEMO_TTL = 5
      private_constant :MEMO_TTL

      # When :get_tx returns JungleBus data with a merkle_proof, stash it
      # so a subsequent :get_merkle_path can serve it without a network call.
      # Called with the raw (pre-normalization) result.
      def stash_siblings(command, result, args, kwargs)
        return unless command == :get_tx && result.success?

        data = result.data
        return unless data.is_a?(Hash) && data['merkle_proof'] && !data['merkle_proof'].empty?

        txid = args.first || kwargs[:txid]
        return unless txid

        @mutex.synchronize do
          @sibling_memo[txid.to_s] = {
            data: data['merkle_proof'],
            stashed_at: Time.now
          }
        end
      end

      # Check if :get_merkle_path can be served from the sibling memo.
      def check_sibling_memo(command, args, kwargs)
        return unless command == :get_merkle_path

        txid = (kwargs[:txid] || args.first).to_s
        return if txid.empty?

        entry = @mutex.synchronize { @sibling_memo.delete(txid) }
        return unless entry
        return if Time.now - entry[:stashed_at] > MEMO_TTL

        # Return the base64-encoded merkle proof as the raw data.
        # The caller handles decoding — this matches what a direct
        # JungleBus get_merkle_path would return.
        Result::Success.new(data: entry[:data])
      end

      # --- Broadcast Affinity ---

      def record_affinity(command, provider, result)
        return unless command == :broadcast && result.success?

        txid = result.data[:txid]
        return unless txid

        @mutex.synchronize { @broadcast_affinity[txid.to_s] = provider }
      end

      # --- Token Bucket ---

      # Simple token bucket rate limiter. One per provider.
      # Refills at +rate+ tokens per second, capacity of 1 burst.
      class TokenBucket
        def initialize(rate)
          @rate = rate.to_f
          @tokens = @rate
          @last_refill = Time.now
          @mutex = Mutex.new
        end

        # Block until a token is available, then consume it.
        def acquire!
          loop do
            @mutex.synchronize do
              refill
              if @tokens >= 1.0
                @tokens -= 1.0
                return
              end
            end
            sleep(0.05)
          end
        end

        private

        def refill
          now = Time.now
          elapsed = now - @last_refill
          @tokens = [@tokens + (elapsed * @rate), @rate].min
          @last_refill = now
        end
      end
    end
  end
end
