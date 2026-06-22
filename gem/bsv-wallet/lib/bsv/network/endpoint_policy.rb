# frozen_string_literal: true

require 'ipaddr'
require 'resolv'
require 'uri'

module BSV
  module Network
    # SSRF gate for caller-supplied peer endpoints (#385 Task 5, #390).
    #
    # Pure validator — no I/O state, no mutation after construction. The
    # +#validate!+ entry point does perform a DNS resolution as part of
    # validation (the only way to defend against a DNS-resolves-to-private
    # attack), but the policy itself holds only configuration. Frozen at
    # construction so callers cannot mutate the rule set out from under
    # an in-flight delivery.
    #
    # The caller-supplied peer endpoint is the wallet's external attack
    # surface: a malicious or compromised endpoint string could redirect
    # an outbound BEEF through a SSRF chain to the cloud provider's
    # metadata endpoint (169.254.169.254 on AWS / GCP / Azure),
    # loopback services on the wallet host, or RFC1918 / unique-local
    # IPv6 destinations on the operator's LAN. Reject all of these by
    # default; the e2e harness opts in via
    # +BSV_WALLET_ALLOW_PRIVATE_ENDPOINTS=1+ to talk to fixtures running
    # on 127.0.0.1.
    #
    # Resolves DNS once at validate time and returns the resolved IP for
    # the caller to dial — set the +Host:+ header to the original
    # hostname so TLS SNI + virtual-host routing still work. This closes
    # the DNS TOCTOU window where +Net::HTTP+ would re-resolve and
    # potentially land on a different (private) IP than the one the
    # policy approved.
    class EndpointPolicy
      class Violation < BSV::Wallet::Error; end

      # Private / link-local / unique-local ranges that an outbound BEEF
      # delivery has no business reaching:
      #
      # - +127.0.0.0/8+ — IPv4 loopback (the wallet host itself).
      # - +10.0.0.0/8+, +172.16.0.0/12+, +192.168.0.0/16+ — RFC1918
      #   private networks (operator LAN, container subnets, k8s pods).
      # - +169.254.0.0/16+ — IPv4 link-local. INCLUDES the cloud
      #   metadata service at 169.254.169.254 — the canonical SSRF
      #   target for credential exfiltration on AWS / GCP / Azure.
      # - +::1/128+ — IPv6 loopback.
      # - +fc00::/7+ — IPv6 unique-local (the IPv6 equivalent of
      #   RFC1918).
      PRIVATE_RANGES = %w[
        127.0.0.0/8
        10.0.0.0/8
        172.16.0.0/12
        192.168.0.0/16
        169.254.0.0/16
        ::1/128
        fc00::/7
      ].map { |r| IPAddr.new(r) }.freeze

      # @param allow_private [Boolean] dev/test escape hatch. Defaults to
      #   reading +ENV['BSV_WALLET_ALLOW_PRIVATE_ENDPOINTS']+ as truthy iff
      #   set to '1'. Used by the e2e harness to talk to local fixture
      #   wallets bound on 127.0.0.1.
      # @param require_https [Boolean] reject plain http://. Defaults
      #   true — plain HTTP gives an on-path attacker the BEEF, the
      #   recipient's identity inference (BRC-29
      #   +sender_identity_key+), and the ability to forge a 200 ACK.
      # @param max_body_bytes [Integer] cap on POST body size. Default
      #   32MiB. A trimmed BEEF for a routine payment is a few kB; this
      #   bound is a defence against either a runaway hydration walk or
      #   a malicious request to ship oversize bundles over peer links.
      def initialize(allow_private: ENV['BSV_WALLET_ALLOW_PRIVATE_ENDPOINTS'] == '1',
                     require_https: true,
                     max_body_bytes: 32 * 1024 * 1024)
        @allow_private = allow_private
        @require_https = require_https
        @max_body_bytes = max_body_bytes
        freeze
      end

      attr_reader :allow_private, :require_https, :max_body_bytes

      # Validate +endpoint+ and return the resolved coordinates for
      # dialling. Each rejection raises +Violation+ with a message that
      # names the rule fired — kept short so a +PeerDelivery::Result+
      # +error_message+ stays log-friendly.
      #
      # @param endpoint [String] absolute URI string
      # @return [Hash] +{ uri: URI, ip: String }+ — +uri+ carries the
      #   parsed endpoint (use +.host+ for the +Host+ header, +.port+
      #   for the dial port); +ip+ is the resolved address to dial.
      # @raise [Violation] for any policy violation
      def validate!(endpoint)
        raise Violation, 'endpoint rejected: must be a non-empty string' unless endpoint.is_a?(String) && !endpoint.empty?

        uri = parse_uri(endpoint)
        validate_scheme!(uri)
        host = extract_host!(uri)
        ip = resolve_host!(host)
        validate_ip!(ip, host)

        { uri: uri, ip: ip }
      end

      # @param byte_size [Integer]
      # @return [Boolean] true iff a body of that size is within the cap
      def allow_body?(byte_size)
        byte_size <= @max_body_bytes
      end

      private

      def parse_uri(endpoint)
        URI.parse(endpoint)
      rescue URI::InvalidURIError => e
        raise Violation, "endpoint rejected: malformed URI (#{e.message})"
      end

      def validate_scheme!(uri)
        scheme = uri.scheme&.downcase
        if @require_https
          raise Violation, "endpoint rejected: scheme=#{scheme.inspect} (https:// required)" unless scheme == 'https'
        else
          raise Violation, "endpoint rejected: scheme=#{scheme.inspect} (http or https required)" unless %w[http https].include?(scheme)
        end
      end

      def extract_host!(uri)
        host = uri.host
        raise Violation, 'endpoint rejected: missing host' if host.nil? || host.empty?

        host
      end

      # Resolve the host to an IP once. We then dial that IP directly
      # and set the +Host:+ header to the original hostname — closes the
      # DNS TOCTOU window where +Net::HTTP+ would re-resolve and
      # potentially land somewhere we never approved.
      #
      # If the host is already a literal IP, +Resolv.getaddress+ returns
      # it unchanged.
      def resolve_host!(host)
        Resolv.getaddress(host)
      rescue Resolv::ResolvError => e
        raise Violation, "endpoint rejected: DNS resolution failed for host=#{host} (#{e.message})"
      end

      def validate_ip!(address, host)
        return if @allow_private

        ip_addr = begin
          IPAddr.new(address)
        rescue IPAddr::InvalidAddressError => e
          raise Violation, "endpoint rejected: invalid resolved IP=#{address} for host=#{host} (#{e.message})"
        end

        return unless PRIVATE_RANGES.any? { |range| range.include?(ip_addr) }

        raise Violation,
              "endpoint rejected: resolved IP=#{address} for host=#{host} is in a private/loopback/link-local range " \
              '(set BSV_WALLET_ALLOW_PRIVATE_ENDPOINTS=1 for local dev/test)'
      end
    end
  end
end
