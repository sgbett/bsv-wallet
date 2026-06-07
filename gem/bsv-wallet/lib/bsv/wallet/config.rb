# frozen_string_literal: true

module BSV
  module Wallet
    # End-user wallet configuration surface.
    #
    # Centralises every end-user-facing knob the wallet exposes —
    # database URL, WIF, limp mode threshold, daemon pool size, EF
    # cache size, hint socket. Dev/test fixtures (named-wallet WIFs,
    # +BSV_WALLET_POSTGRES+ base, +DATABASE_URL_<NAME>+ overrides)
    # are out of scope here; see #292.
    #
    # Defaults read ENV at instantiation, preserving today's
    # shell-env-driven behaviour. The configure block in a user's
    # +~/.bsv-wallet/config.rb+ (or wherever +BSV_WALLET_CONFIG+
    # points) can override any of these.
    #
    # Three usage modes for an end user:
    #
    #   1. Do nothing — Config defaults read shell ENV. Set
    #      +LIMP_THRESHOLD=100000+ in your shell and it just works.
    #
    #   2. Pin values in +~/.bsv-wallet/config.rb+:
    #        c.limp_threshold = 100_000
    #      ignoring the ENV var entirely.
    #
    #   3. Read alternate ENV vars or compute values:
    #        c.limp_threshold = Integer(ENV.fetch('MY_LIMP', '50000'))
    #
    # @see BSV::Wallet.configure
    # @see BSV::Wallet.load_config_file!
    class Config
      # Database URL for end-user single-wallet boot (sqlite:// or postgres://).
      attr_accessor :database_url

      # Wallet private key, WIF format. End-user single-wallet boot.
      attr_accessor :wif

      # +:mainnet+ or +:testnet+.
      attr_accessor :network

      # Limp mode threshold (sats). Below this, outbound is blocked.
      attr_accessor :limp_threshold

      # Sequel connection pool size for walletd.
      attr_accessor :daemon_pool_size

      # EF hint cache capacity (entries).
      attr_accessor :tx_cache_size

      # Optional cross-process EF hint socket path. +nil+ = feature off.
      attr_accessor :hints_socket

      def initialize
        @database_url     = ENV.fetch('DATABASE_URL', nil)
        @wif              = ENV.fetch('WIF', nil)
        @network          = ENV.fetch('BSV_WALLET_NETWORK', 'mainnet').to_sym
        @limp_threshold   = Integer(ENV.fetch('LIMP_THRESHOLD', '50000'))
        @daemon_pool_size = Integer(ENV.fetch('BSV_WALLET_DAEMON_SEQUEL_CONNECTIONS', '16'))
        @tx_cache_size    = Integer(ENV.fetch('BSV_WALLET_TX_CACHE_SIZE', '1000'))
        @hints_socket     = blank_to_nil(ENV.fetch('BSV_WALLET_HINTS_SOCKET', nil))
      end

      private

      # Blank-or-unset normalises to nil — a set-but-empty env (e.g.
      # +export BSV_WALLET_HINTS_SOCKET=+ in a shell) would otherwise
      # be a truthy "" that downstream callers can't usefully act on.
      def blank_to_nil(value)
        return if value.nil?
        return if value.strip.empty?

        value
      end
    end

    # Singleton Config instance. Lazy: first access instantiates.
    #
    # @return [Config]
    def self.config
      @config ||= Config.new
    end

    # User-facing configuration block. Yields the singleton Config so
    # the user's +~/.bsv-wallet/config.rb+ can override any setting.
    #
    #   BSV::Wallet.configure do |c|
    #     c.limp_threshold = 100_000
    #     c.hints_socket   = '/tmp/bsv-wallet-hints.sock'
    #   end
    #
    # @yield [Config]
    # @return [Config] the populated singleton
    def self.configure
      yield(config)
      config
    end

    # Reset the singleton — drops the current Config so the next
    # +config+ access instantiates fresh. Primarily a test helper for
    # examples that mutate ENV and need a clean Config rebuild.
    def self.reset_config!
      @config = nil
    end

    # Load the user's configuration file if present.
    #
    # Resolution: explicit +path+ argument > +BSV_WALLET_CONFIG+ env
    # var > +~/.bsv-wallet/config.rb+ default. Absent file is a clean
    # no-op (operator without a config file falls back to Config's
    # ENV-reading defaults). Errors propagate — bad config = loud
    # boot failure, not a silent swallow.
    #
    # @param path [String, nil]
    # @return [String, nil] the path that was loaded, or +nil+
    def self.load_config_file!(path = nil)
      path ||= ENV.fetch('BSV_WALLET_CONFIG',
                         File.expand_path('~/.bsv-wallet/config.rb'))
      return unless File.exist?(path)

      BSV.logger&.info { "[BSV::Wallet] loading config: #{path}" }
      load(path)
      path
    end
  end
end
