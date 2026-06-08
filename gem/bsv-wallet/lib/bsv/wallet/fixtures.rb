# frozen_string_literal: true

module BSV
  module Wallet
    # Dev/test named-wallet registry.
    #
    # Centralises every named-wallet fixture the wallet uses — +alice+,
    # +bob+, +carol+ (integration specs), +sdk+ (e2e harness funder),
    # +w1+..+w5+ (e2e wallet fleet), +test+ (unit spec DB). Companion
    # to {BSV::Wallet.configure} — same audience-split frame: end-user
    # config is +BSV::Wallet.configure+, dev/test fixtures are
    # +BSV::Wallet::Fixtures.configure+.
    #
    # Three usage modes:
    #
    #   1. Do nothing — operators with a complete shell ENV
    #      (BSV_WALLET_WIF_<NAME>, BSV_WALLET_POSTGRES) get the
    #      standard registrations via the gem-bundled default at
    #      +config/fixtures.rb+ (auto-loaded if no user override).
    #
    #   2. Pin values in +~/.bsv-wallet/fixtures.rb+:
    #        f.wallet :alice, wif: 'L1...', database_url: 'postgres://...'
    #
    #   3. Register dynamically at runtime — the e2e harness derives
    #      +w1+..+w5+ WIFs from the funding key and registers each.
    #
    # @see BSV::Wallet::Fixtures.configure
    # @see BSV::Wallet::Fixtures.load_config_file!
    module Fixtures
      # Value object — a single named fixture wallet.
      Wallet = Struct.new(:name, :wif, :database_url, keyword_init: true)

      # Holds the registered fixtures + the shared postgres base.
      class Registry
        include Enumerable

        # Postgres base URL (e.g. +postgres://postgres:postgres@localhost:5433/+)
        # used to derive per-wallet DB URLs when not overridden.
        attr_accessor :postgres_base

        def initialize
          @postgres_base = nil
          @wallets = {}
        end

        # Register a named wallet. Both +wif:+ and +database_url:+ are
        # optional — +database_url+ derives from +postgres_base+ when
        # not given (or stays nil if no base).
        #
        # @param name [Symbol, String]
        # @param wif [String, nil]
        # @param database_url [String, nil]
        # @return [Wallet]
        def wallet(name, wif: nil, database_url: nil)
          sym = name.to_sym
          @wallets[sym] = Wallet.new(
            name: sym,
            wif: wif,
            database_url: database_url || derive_database_url(sym)
          )
        end

        # @param name [Symbol, String]
        # @return [Wallet, nil]
        def [](name)
          @wallets[name.to_sym]
        end

        # Iterate registered fixtures (Wallet objects).
        def each(&)
          @wallets.values.each(&)
        end

        # @return [Array<Symbol>]
        def names
          @wallets.keys
        end

        private

        def derive_database_url(name)
          base = @postgres_base&.strip
          return nil if base.nil? || base.empty?

          "#{base.chomp('/')}/bsv_wallet_#{name}"
        end
      end

      # Singleton registry. Lazy: first access instantiates.
      #
      # @return [Registry]
      def self.registry
        @registry ||= Registry.new
      end

      # Configuration block — yields the singleton Registry so the
      # user's +~/.bsv-wallet/fixtures.rb+ (or runtime callers like
      # the e2e harness) can register wallets.
      #
      #   BSV::Wallet::Fixtures.configure do |f|
      #     f.postgres_base = ENV.fetch('BSV_WALLET_POSTGRES', nil)
      #     f.wallet :alice, wif: ENV.fetch('BSV_WALLET_WIF_ALICE', nil)
      #   end
      #
      # @yield [Registry]
      # @return [Registry]
      def self.configure
        yield(registry)
        registry
      end

      # Look up a named fixture wallet. Returns nil when the name is
      # not registered.
      #
      # @param name [Symbol, String]
      # @return [Wallet, nil]
      def self.wallet(name)
        registry[name]
      end

      # Reset the singleton — drops all registrations so the next
      # +registry+ access instantiates fresh. Test helper.
      def self.reset!
        @registry = nil
      end

      # Path to the gem-bundled default fixtures file. Auto-loaded
      # when no user override exists, so a fresh checkout / CI runner
      # picks up the standard +alice+/+bob+/+carol+/+sdk+/+w1+..+w5+
      # registrations from shell ENV without any setup.
      DEFAULT_FILE = File.expand_path('../../../config/fixtures.rb', __dir__).freeze

      # Load the dev/test fixtures file.
      #
      # Resolution: explicit +path+ argument > +BSV_WALLET_FIXTURES+
      # env var > +~/.bsv-wallet/fixtures.rb+ (user override) >
      # +DEFAULT_FILE+ (gem-bundled). The gem default registers the
      # standard named wallets from shell ENV, so an operator with
      # +BSV_WALLET_POSTGRES+ + +BSV_WALLET_WIF_<NAME>+ set needs no
      # personal fixtures file. Errors propagate.
      #
      # @param path [String, nil]
      # @return [String, nil] path loaded, or nil if no file resolves
      def self.load_config_file!(path = nil)
        path ||= ENV.fetch('BSV_WALLET_FIXTURES', nil)
        path ||= File.expand_path('~/.bsv-wallet/fixtures.rb')
        path = DEFAULT_FILE unless File.exist?(path)
        return unless File.exist?(path)

        BSV.logger&.info { "[BSV::Wallet::Fixtures] loading: #{path}" }
        load(path)
        path
      end
    end
  end
end
