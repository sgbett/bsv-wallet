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

        @providers = providers.dup.freeze
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
      # @return [BSV::Network::ProtocolResponse]
      def call(command, *args, **kwargs)
        sym = command.to_sym

        # Serve from sibling memo if available
        memo_result = check_sibling_memo(sym, args, kwargs)
        return memo_result if memo_result

        candidates = candidates_for(sym, args, kwargs)
        return no_provider_response(sym) if candidates.empty?

        last_error = nil

        candidates.each do |provider|
          acquire_rate_limit!(provider)

          result = provider.call(sym, *args, **kwargs)

          if result.http_success?
            stash_siblings(sym, result, args, kwargs)
            normalized = normalize(sym, result)
            record_affinity(sym, provider, normalized)
            return normalized
          end

          return result if result.http_not_found?

          last_error = result
          break unless result.retryable?
        end

        last_error
      end

      # Union of all commands available across all registered providers.
      #
      # @return [Set<Symbol>]
      def commands
        @providers.reduce(Set.new) { |acc, p| acc | p.commands }
      end

      # Push an entity to the network.
      #
      # Calls +entity.push_command+ and +entity.push_payload+, dispatches
      # through the routing layer, and writes the response back on success.
      #
      # @param entity [#push_command, #push_payload, #write!] a Pushable entity
      # @return [BSV::Network::ProtocolResponse]
      def push!(entity)
        command = entity.push_command
        payload = entity.push_payload
        response = call(command, payload)

        if response.http_success?
          entity.write!(response)
        else
          BSV.logger&.warn { "[Services] push! failed: #{response.error_message}" }
        end

        response
      end

      # Fetch state from the network into an entity.
      #
      # Calls +entity.fetch_command+ and +entity.fetch_args+, dispatches
      # through the routing layer, and writes the response back on success.
      #
      # @param entity [#fetch_command, #fetch_args, #write!] a Fetchable entity
      # @return [BSV::Network::ProtocolResponse]
      def fetch!(entity)
        command = entity.fetch_command
        args = entity.fetch_args
        response = call(command, **args)

        if response.http_success?
          entity.write!(response)
        else
          BSV.logger&.warn { "[Services] fetch! failed: #{response.error_message}" }
        end

        response
      end

      # Returns the registered providers (frozen at construction time).
      #
      # @return [Array<BSV::Network::Provider>]
      attr_reader :providers

      private

      # --- Routing ---

      # Build the ordered candidate list for a command.
      # For :get_tx_status, broadcast affinity moves the preferred provider to front.
      def candidates_for(command, args = [], kwargs = {})
        capable = @providers.select { |p| p.commands.include?(command) }

        if command == :get_tx_status
          txid = (kwargs[:txid] || args.first).to_s
          affinity = @mutex.synchronize { @broadcast_affinity[txid] }
          capable = [affinity] + (capable - [affinity]) if affinity && capable.include?(affinity)
        end

        capable
      end

      # Synthetic error response when no provider serves a command.
      # No real HTTP response — construct with nil and override success.
      def no_provider_response(command)
        ProtocolResponse.new(nil, http_success: false,
                                  error_message: "no provider serves :#{command}")
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

        result.with(data: normalized_data)
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
      MAX_MEMO_ENTRIES = 100
      private_constant :MEMO_TTL, :MAX_MEMO_ENTRIES

      # When :get_tx returns JungleBus data with a merkle_proof, stash it
      # so a subsequent :get_merkle_path can serve it without a network call.
      # Called with the raw (pre-normalization) result.
      def stash_siblings(command, result, args, kwargs)
        return unless command == :get_tx && result.http_success?

        data = result.data
        return unless data.is_a?(Hash) && data['merkle_proof'] && !data['merkle_proof'].empty?

        txid = args.first || kwargs[:txid]
        return unless txid

        @mutex.synchronize do
          @sibling_memo.shift if @sibling_memo.size >= MAX_MEMO_ENTRIES
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

        ProtocolResponse.new(nil, data: entry[:data], http_success: true)
      end

      # --- Broadcast Affinity ---

      MAX_AFFINITY_ENTRIES = 1000
      private_constant :MAX_AFFINITY_ENTRIES

      def record_affinity(command, provider, result)
        return unless command == :broadcast && result.http_success?

        txid = result.data[:txid]
        return unless txid

        @mutex.synchronize do
          @broadcast_affinity.shift if @broadcast_affinity.size >= MAX_AFFINITY_ENTRIES
          @broadcast_affinity[txid.to_s] = provider
        end
      end

      # --- Token Bucket ---

      # Simple token bucket rate limiter. One per provider.
      # Refills at +rate+ tokens per second. Burst capacity is max(rate, 1)
      # so that sub-1 rates (e.g. 0.5 req/sec) can still acquire a token.
      class TokenBucket
        def initialize(rate)
          raise ArgumentError, 'rate must be positive' unless rate.to_f.positive?

          @rate = rate.to_f
          @capacity = [@rate, 1.0].max
          @tokens = @capacity
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
          @tokens = [@tokens + (elapsed * @rate), @capacity].min
          @last_refill = now
        end
      end
    end
  end
end
