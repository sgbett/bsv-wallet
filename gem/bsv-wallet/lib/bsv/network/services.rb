# frozen_string_literal: true

require 'base64'

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

        candidates = candidates_for(sym)
        call_with_candidates(sym, candidates, *args, **kwargs)
      end

      # Dispatch a command against an explicitly-ordered candidate list.
      #
      # Same retry / backoff / fallback / normalisation as +#call+, but the
      # caller supplies the provider ordering instead of relying on
      # +#candidates_for+. Used by +BSV::Network::Broadcaster+ to overlay
      # wtxid-keyed affinity onto the dispatch path without duplicating
      # the per-provider backoff loop here.
      #
      # When a block is given, it is yielded the +Provider+ that produced
      # the successful response so callers (e.g. Broadcaster) can persist
      # affinity. The block is not invoked on failure.
      #
      # @param command [Symbol] SDK command name
      # @param candidates [Array<BSV::Network::Provider>] ordered providers
      # @yield [provider] succeeding provider (success only)
      # @return [BSV::Network::ProtocolResponse]
      def call_with_candidates(command, candidates, *args, **kwargs)
        sym = command.to_sym
        return no_provider_response(sym) if candidates.empty?

        last_error = nil

        candidates.each do |provider|
          result = call_with_backoff(provider, sym, args, kwargs)

          if result.http_success?
            stash_siblings(sym, result, args, kwargs)
            normalized = normalize(sym, result)
            yield(provider) if block_given?
            return normalized
          end

          return result if result.http_not_found?

          last_error = result
          break unless result.retryable?
        end

        last_error
      end

      # Backoff attempts for a single provider after the TokenBucket has
      # released a request slot. Distinguishes "wallet-side spacing"
      # (TokenBucket) from "provider-side rate-limit / transient 5xx"
      # (retry-with-backoff). Returns the final +ProtocolResponse+ after
      # exhausting attempts.
      RETRYABLE_ATTEMPTS = 3
      RETRYABLE_BACKOFF_BASE_S = 1.0

      def call_with_backoff(provider, sym, args, kwargs)
        result = nil
        RETRYABLE_ATTEMPTS.times do |attempt|
          acquire_rate_limit!(provider)
          result = provider.call(sym, *args, **kwargs)
          return result if result.http_success? || !result.retryable?

          break if attempt == RETRYABLE_ATTEMPTS - 1

          sleep_for = RETRYABLE_BACKOFF_BASE_S * (2**attempt)
          BSV.logger&.debug do
            "[Services] provider=#{provider.name} cmd=#{sym} retryable response; " \
              "backing off #{sleep_for}s (attempt #{attempt + 1}/#{RETRYABLE_ATTEMPTS})"
          end
          backoff_sleep(sleep_for)
        end
        result
      end

      # Indirection so specs can stub backoff to zero without monkey-patching
      # +Kernel#sleep+ globally.
      def backoff_sleep(seconds)
        sleep(seconds)
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
      # @param entity [#push_command, #push_payload, #write!]
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
      # @param entity [#fetch_command, #fetch_args, #write!]
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
      def candidates_for(command)
        @providers.select { |p| p.commands.include?(command) }
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
      #
      # Two upstream protocols answer +:broadcast+ / +:get_tx_status+ with
      # divergent shapes:
      #
      # - **ARC** (TAAL):
      #   +{txid, txStatus, status: <int>, blockHash, blockHeight, merklePath,
      #     extraInfo, competingTxs}+
      # - **Arcade** (GorillaPool):
      #   submit:    +{status: "submitted"}+   (no txid, no txStatus)
      #   resubmit:  +{status: "already submitted", txid, state: <STATUS>}+
      #   tx_status: +{txid, txStatus, status: <int>, blockHash, blockHeight,
      #               merklePath, extraInfo, competingTxs}+  (same shape as ARC's get_tx_status)
      #
      # Arcade's +status+ field is a String for broadcast submissions, an
      # Integer for tx_status queries. The wallet's +arc_status+ column is
      # an integer — so a String +"submitted"+ here would crash on persist.
      # Detect Arcade's submit-string shape and map: +status: "submitted"+
      # → +tx_status: "RECEIVED"+ (the closest ARC equivalent) plus
      # +arc_status: nil+ to skip the integer column write.
      def normalize_broadcast_response(data)
        return data unless data.is_a?(Hash)

        data = normalize_arcade_submit(data)

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

      # Detect Arcade's broadcast submit shape and translate it into
      # the canonical ARC-like shape the wallet downstream consumes.
      #
      # Arcade submit success:    +{"status": "submitted"}+
      # Arcade submit (resubmit): +{"status": "already submitted",
      #                              "txid": "...", "state": "<STATUS>"}+
      # Arcade tx_status query:   +{txid, txStatus, status: <int>, ...}+  (ARC-shaped)
      #
      # The distinguishing marker is +status+ being a String — ARC uses
      # Integer for +status+ (HTTP code). On the Arcade submit branches we
      # translate to +tx_status: "RECEIVED"+ (the equivalent "in flight"
      # signal), preserve any +txid+ Arcade returned, and drop the
      # string status so the downstream +arc_status+ integer column
      # doesn't try to write +"submitted"+.
      def normalize_arcade_submit(data)
        status = data['status'] || data[:status]
        return data unless status.is_a?(String)

        case status
        when 'submitted'
          { 'txStatus' => 'RECEIVED' }
        when 'already submitted'
          {
            'txid' => data['txid'] || data[:txid],
            'txStatus' => data['state'] || data[:state] || 'RECEIVED'
          }
        else
          data
        end
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
