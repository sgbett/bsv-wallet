# frozen_string_literal: true

using BSV::Wallet::Txid

require 'json'
require 'net/http'
require 'openssl'

module BSV
  module Network
    # Wallet→peer BEEF delivery over HTTP (#385 Task 5, #390).
    #
    # The v1 transport for +Engine::Transmission+. Synchronous HTTP POST
    # of the BRC-29 envelope to a caller-supplied endpoint, with ACK
    # validation that includes wtxid binding (so a captive portal /
    # wrong host returning 200 OK can never get recorded as a successful
    # delivery).
    #
    # The class composes +EndpointPolicy+ for SSRF defence and is
    # injected into +Engine::Transmission+ via the +delivery:+ kwarg.
    # Phase-2 will swap this object for a daemon-async deliverer without
    # touching +Engine::Transmission+ — the seam is the whole point.
    #
    # No new gem dependencies: plain +Net::HTTP+. Body cap, TLS verify,
    # explicit timeouts, no redirect follow.
    class PeerDelivery
      # Delivery outcome — keyword struct so callers can pattern-match
      # on +#outcome+. Each failure mode is a distinct symbol so the
      # caller can choose a different remediation per case (operator
      # alert vs. silent retry-eligible vs. mark-bad-endpoint, etc.).
      #
      # Outcome codes:
      #   - +:delivered+               — 200 OK + valid ACK + wtxid match
      #   - +:endpoint_policy_violation+ — +EndpointPolicy+ rejected the endpoint
      #   - +:tls_failure+             — TLS / certificate error during dial
      #   - +:dns_failure+             — host could not be resolved at dial time
      #     (distinct from policy: policy resolves in +validate!+, this code
      #     fires if a transport-layer DNS error still surfaces)
      #   - +:transport_error+         — generic socket / connection error
      #   - +:timeout+                 — connect or read timeout exceeded
      #   - +:non_200+                 — HTTP response was not 200 OK
      #   - +:body_too_large+          — request body exceeds policy cap
      #   - +:malformed_ack+           — 200 OK but body wasn't a valid JSON
      #     ACK envelope
      #   - +:wrong_acked_wtxid+       — 200 OK + JSON, but the +wtxid+ field
      #     did not match the subject wtxid we tried to deliver. Crypto gate
      #     (HLR #385 specialist synthesis): HTTP 200 alone proves nothing.
      Result = Struct.new(:outcome, :wtxid, :http_status, :error_message, keyword_init: true) do
        def delivered?
          outcome == :delivered
        end
      end

      DEFAULT_CONNECT_TIMEOUT = 5
      DEFAULT_READ_TIMEOUT = 30

      # @param policy [EndpointPolicy] SSRF gate. Default is the
      #   +EndpointPolicy.new+ at construction time (reads the
      #   +BSV_WALLET_ALLOW_PRIVATE_ENDPOINTS+ env var once).
      # @param connect_timeout [Integer] seconds; default 5.
      # @param read_timeout [Integer] seconds; default 30. Slow peer
      #   must not silently wedge the wallet.
      def initialize(policy: EndpointPolicy.new,
                     connect_timeout: DEFAULT_CONNECT_TIMEOUT,
                     read_timeout: DEFAULT_READ_TIMEOUT)
        @policy = policy
        @connect_timeout = connect_timeout
        @read_timeout = read_timeout
      end

      attr_reader :policy

      # POST the envelope to the peer endpoint and validate the ACK.
      #
      # The wire envelope is the JSON encoding of +envelope+ with +beef:+
      # rendered as hex (BEEF is binary; JSON is text). Mirror of the
      # existing +bin/create+ → +bin/receive+ stdin/stdout shape, lifted
      # to HTTP for Phase-1 transport.
      #
      # ACK contract (Phase-1):
      #   - 200 OK
      #   - +Content-Type+ starting with +application/json+
      #   - body = +{ "accepted": true, "wtxid": "<dtxid>" }+
      #   - +wtxid+ must match the +subject_wtxid+ we delivered
      #
      # Without the wtxid binding, a captive portal or a wrong-host
      # endpoint returning generic 200 OK would be recorded as a
      # successful delivery — the BeefParty trimmer would then over-trim
      # the next transmit to that "peer", and the actual peer would
      # silently miss everything thereafter.
      #
      # @param endpoint [String] absolute URI (https:// in prod)
      # @param envelope [Hash] +{ beef:, outputs:, sender_identity_key:,
      #   protocol_version: }+ — keys consumed by the receiver's
      #   +internalize_action+.
      # @param subject_wtxid [String] 32-byte wire-order wtxid for the
      #   subject of this delivery. Used for ACK binding.
      # @return [Result]
      def deliver(endpoint:, envelope:, subject_wtxid:)
        validated = @policy.validate!(endpoint)

        body = JSON.generate(envelope_with_hex_beef(envelope))
        unless @policy.allow_body?(body.bytesize)
          return Result.new(
            outcome: :body_too_large,
            error_message: "body size #{body.bytesize} exceeds cap #{@policy.max_body_bytes}"
          )
        end

        response = post(validated, body)
        evaluate_response(response, subject_wtxid: subject_wtxid)
      rescue EndpointPolicy::Violation => e
        Result.new(outcome: :endpoint_policy_violation, error_message: e.message)
      rescue Net::OpenTimeout, Net::ReadTimeout => e
        Result.new(outcome: :timeout, error_message: e.message)
      rescue OpenSSL::SSL::SSLError => e
        Result.new(outcome: :tls_failure, error_message: e.message)
      rescue SocketError => e
        Result.new(outcome: :dns_failure, error_message: e.message)
      rescue Errno::ECONNREFUSED, Errno::EHOSTUNREACH, Errno::ENETUNREACH, IOError => e
        Result.new(outcome: :transport_error, error_message: e.message)
      end

      private

      # BEEF is binary; over-the-wire JSON carries it as hex. The
      # +bin/create+ → +bin/receive+ JSON shape uses the same
      # representation, so a Phase-1 peer keeps its existing decoder.
      def envelope_with_hex_beef(envelope)
        envelope.merge(beef: envelope[:beef].unpack1('H*'))
      end

      # Construct the connection with the *hostname* — +Net::HTTP+ uses
      # +@address+ for BOTH TLS SNI AND certificate hostname
      # verification. Dialling +Net::HTTP.new(ip, ...)+ would put the
      # IP into +@address+, then +VERIFY_PEER+ would compare the
      # cert's SAN against the IP and fail every legitimate peer.
      #
      # +http.ipaddr=+ overrides only the dial address, leaving
      # +@address+ (and therefore SNI + hostname-verify) as the
      # original hostname. That preserves the DNS TOCTOU mitigation
      # (we dial the IP the policy approved) while letting TLS
      # complete normally. +Host:+ is derived from +@address+ — no
      # need to set it explicitly.
      def post(validated, body)
        uri = validated[:uri]
        ip = validated[:ip]
        port = uri.port || (uri.scheme == 'https' ? 443 : 80)
        use_ssl = uri.scheme == 'https'

        http = Net::HTTP.new(uri.host, port)
        http.ipaddr = ip if http.respond_to?(:ipaddr=)
        http.use_ssl = use_ssl
        http.verify_mode = OpenSSL::SSL::VERIFY_PEER if use_ssl
        http.open_timeout = @connect_timeout
        http.read_timeout = @read_timeout

        request = Net::HTTP::Post.new(uri.request_uri)
        request['Content-Type'] = 'application/json'
        request.body = body

        http.start { |conn| conn.request(request) }
      end

      # ACK contract is strict: 200, JSON, +accepted: true+, and a
      # +wtxid+ that matches what we sent. Anything else gets a
      # taxonomy-specific outcome.
      def evaluate_response(response, subject_wtxid:)
        status = response.code.to_i
        return non_200(response, status) unless status == 200

        content_type = response['Content-Type'].to_s
        unless content_type.start_with?('application/json')
          return Result.new(
            outcome: :malformed_ack,
            http_status: status,
            error_message: "Content-Type=#{content_type.inspect} (expected application/json)"
          )
        end

        parsed = parse_ack(response.body, status)
        return parsed if parsed.is_a?(Result)

        accepted = parsed['accepted']
        ack_wtxid = parsed['wtxid']
        unless accepted == true && ack_wtxid.is_a?(String)
          return Result.new(
            outcome: :malformed_ack,
            http_status: status,
            error_message: 'ACK missing accepted:true or wtxid'
          )
        end

        expected_dtxid = subject_wtxid.to_dtxid
        if ack_wtxid != expected_dtxid
          return Result.new(
            outcome: :wrong_acked_wtxid,
            wtxid: ack_wtxid,
            http_status: status,
            error_message: "ACK wtxid=#{ack_wtxid} does not match subject_dtxid=#{expected_dtxid}"
          )
        end

        Result.new(outcome: :delivered, wtxid: ack_wtxid, http_status: status)
      end

      def parse_ack(body, status)
        JSON.parse(body)
      rescue JSON::ParserError => e
        Result.new(
          outcome: :malformed_ack,
          http_status: status,
          error_message: "JSON parse failed: #{e.message}"
        )
      end

      # HTTP-status outcome — symbolic +:non_200+ (HTTP nomenclature
      # talks about "non-200 responses"; the digits are part of the
      # canonical phrase). The AC names this outcome explicitly and
      # renaming away from HTTP-canonical hurts grep.
      def non_200(response, status) # rubocop:disable Naming/VariableNumber
        # Truncate to avoid logging an oversize error body. Operator
        # gets enough to diagnose; full body lands at debug level only.
        snippet = response.body.to_s[0, 200]
        Result.new(
          outcome: :non_200, # rubocop:disable Naming/VariableNumber
          http_status: status,
          error_message: "HTTP #{status} #{response.message}: #{snippet}"
        )
      end
    end
  end
end
