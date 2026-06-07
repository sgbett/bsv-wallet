# frozen_string_literal: true

module BSV
  module Wallet
    # Shared boot sequence for CLI utilities.
    #
    # Each bin/ tool runs in its own OS process, so the global
    # Sequel::Model.db is safe — only one wallet per process.
    #
    # Two boot modes:
    #
    #   * **End-user mode** (+wallet_name: nil+): single wallet, settings
    #     come from +BSV::Wallet.config+ (the +configure+ block in
    #     +~/.bsv-wallet/config.rb+, falling back to ENV defaults). See
    #     +lib/bsv/wallet/config.rb+ and +config/config.example.rb+.
    #
    #   * **Dev/test mode** (+wallet_name: 'alice'+ etc.): per-wallet WIF
    #     and DB URL via +BSV_WALLET_WIF_<NAME>+, +DATABASE_URL_<NAME>+,
    #     or derived from +BSV_WALLET_POSTGRES+. See #292 for the planned
    #     centralised fixture surface.
    #
    # @example
    #   wallet_name, args = BSV::Wallet::CLI.extract_wallet_name(ARGV)
    #   ctx = BSV::Wallet::CLI.boot(wallet_name: wallet_name)
    #   engine = ctx[:engine]
    module CLI
      module_function

      # Boot a wallet engine for the named wallet.
      #
      # Auto-discovers the store backend, runs migrations, and
      # constructs all Layer 2a components + the Engine.
      #
      # @param wallet_name [String, nil] e.g. "alice", "bob", or nil for default
      # @param network [Symbol] :mainnet or :testnet
      # @return [Hash] { engine:, utxo_pool:, key_deriver:, db:, identity_key:, private_key: }
      def boot(wallet_name: nil, network: :mainnet)
        require 'sequel'
        require 'logger'
        require 'bsv-wallet'

        # Load the end-user configure block first so any consumer
        # reading +BSV::Wallet.config.x+ during boot sees the user's
        # overrides, not just the ENV defaults Config#initialize
        # bakes in.
        BSV::Wallet.load_config_file!

        unless BSV.logger
          BSV.logger = Logger.new($stderr)
          BSV.logger.level = Logger::DEBUG
        end

        # Named wallets (alice/bob/etc.) are dev/test fixtures — keep the
        # legacy env_fetch chain until #292 lands a centralised fixture
        # surface. End-user (unnamed) mode reads BSV::Wallet.config.
        wif = wallet_name ? env_fetch('WIF', wallet_name) : BSV::Wallet.config.wif
        abort 'Set WIF or configure c.wif in ~/.bsv-wallet/config.rb' if wif.nil? || wif.empty?

        db_url = if wallet_name
                   env_fetch_optional('DATABASE_URL', wallet_name) ||
                     derive_postgres_url(wallet_name)
                 else
                   BSV::Wallet.config.database_url
                 end
        db_url ||= default_sqlite_url(wallet_name)

        store = BSV::Wallet::Store.connect(db_url)
        store.migrate!
        db = store.db

        utxo_pool = BSV::Wallet::Store::UTXOPool.new(store: store)

        private_key = BSV::Primitives::PrivateKey.from_wif(wif)
        key_deriver = BSV::Wallet::KeyDeriver.new(private_key: private_key)

        # Two providers, distinct roles:
        # - GorillaPool (Arcade protocol — bsv-sdk 0.22.0+) serves broadcast.
        # - WhatsOnChain serves chain queries (get_tx, get_utxos,
        #   get_merkle_path, get_block_header) and is also the default
        #   +@network_provider+ for the direct-lookup paths in Engine
        #   that bypass Services.
        # Services routes per command; +candidates_for+ filters to the
        # provider(s) that declare the capability.
        network_provider = BSV::Network::Providers::WhatsOnChain.default(network: network)
        broadcast_provider = BSV::Network::Providers::GorillaPool.default(testnet: network != :mainnet)
        network_services = BSV::Network::Services.new(
          providers: [broadcast_provider, network_provider]
        )
        # Broadcaster's candidate list is broadcast-only providers (Arcade/ARC
        # path via GorillaPool). The WhatsOnChain +network_provider+ stays in
        # +network_services+ for chain queries (:get_tx, :get_merkle_path,
        # etc.) and is the Engine's +@network_provider+ for direct lookups,
        # but is not a broadcast/get_tx_status candidate -- WoC's
        # +call_broadcast(tx)+ has no +**+ for callback_token and its
        # +get_tx_status+ shape isn't Arcade-compatible, so a fallback from
        # GorillaPool to WoC raises (or returns a malformed response).
        network_broadcaster = BSV::Network::Broadcaster.new(
          providers: [broadcast_provider],
          store: store
        )
        chain_tracker = BSV::Network::ChainTracker.new(store: store, services: network_services)

        # Limp threshold reads from BSV::Wallet.config (which Integer()s
        # the LIMP_THRESHOLD env var at Config#initialize, raising a
        # clear error on bad input — the abort previously here is
        # subsumed by that earlier failure).
        limp_threshold = BSV::Wallet.config.limp_threshold

        # Arcade callbackToken: deterministic from the WIF so the SSE
        # listener (daemon-side) and the inline broadcast POST (engine-side)
        # converge on the same routing identifier without an extra
        # persistence layer. See #266.
        callback_token = BSV::Wallet::CallbackToken.derive(wif)

        engine = BSV::Wallet::Engine.new(
          store: store,
          utxo_pool: utxo_pool,
          services: network_services,
          broadcaster: network_broadcaster,
          key_deriver: key_deriver,
          chain_tracker: chain_tracker,
          network_provider: network_provider,
          network: network,
          limp_threshold: limp_threshold,
          callback_token: callback_token
        )

        {
          engine: engine,
          utxo_pool: utxo_pool,
          key_deriver: key_deriver,
          db: db,
          identity_key: key_deriver.identity_key,
          private_key: private_key,
          callback_token: callback_token
        }
      end

      # Derive a per-wallet Postgres URL from a shared base.
      #
      # When +BSV_WALLET_POSTGRES+ holds a base URL (e.g.
      # +postgres://postgres:postgres@localhost:5433/+), each named
      # wallet maps to its own database +bsv_wallet_<name>+. This lets
      # a single env var configure every wallet without per-wallet
      # +DATABASE_URL_<NAME>+ entries. (Dev/test fixture surface; #292
      # plans to centralise this alongside the named-wallet WIFs.)
      #
      # Returns nil when no wallet name is given (the unnamed default
      # boot falls through to SQLite) or when the base is unset, so an
      # explicit DATABASE_URL and the SQLite fallback both still apply.
      #
      # @param wallet_name [String, nil]
      # @return [String, nil]
      def derive_postgres_url(wallet_name)
        return unless wallet_name

        base = ENV.fetch('BSV_WALLET_POSTGRES', nil)&.strip
        return if base.nil? || base.empty?

        "#{base.chomp('/')}/bsv_wallet_#{wallet_name}"
      end

      # Build the default SQLite URL when DATABASE_URL is unset.
      #
      # @param wallet_name [String, nil]
      # @return [String]
      def default_sqlite_url(wallet_name)
        require 'fileutils'
        suffix = wallet_name || 'default'
        path = File.expand_path("~/.bsv-wallet/#{suffix}.db")
        FileUtils.mkdir_p(File.dirname(path))
        "sqlite://#{path}"
      end

      # Extract wallet name from the argument list.
      #
      # The wallet name is the first argument if it matches a simple
      # identifier pattern (letters/digits/underscores, starts with a letter).
      # Flags (--foo) and hex strings (64-char txids) are not wallet names.
      #
      # @param argv [Array<String>]
      # @return [Array(String, Array<String>)] [wallet_name_or_nil, remaining_args]
      def extract_wallet_name(argv)
        first = argv.first
        if first && !first.start_with?('-') && first.match?(/\A[a-zA-Z]\w{0,31}\z/)
          [first, argv[1..]]
        else
          [nil, argv.dup]
        end
      end

      # Resolve an environment variable with optional wallet-name suffix.
      #
      # @example
      #   env_fetch('WIF', 'alice')  # => ENV['BSV_WALLET_WIF_ALICE'] || ENV['WIF_ALICE'] || ENV['WIF'] || abort
      #   env_fetch('WIF', nil)      # => ENV['WIF'] || abort
      #
      # @param base_name [String] e.g. "WIF", "DATABASE_URL"
      # @param wallet_name [String, nil]
      # @return [String]
      def env_fetch(base_name, wallet_name)
        if wallet_name
          prefixed = "BSV_WALLET_#{base_name}_#{wallet_name.upcase}"
          suffixed = "#{base_name}_#{wallet_name.upcase}"
          ENV.fetch(prefixed) { ENV.fetch(suffixed) { ENV.fetch(base_name) { abort "Set #{prefixed} or #{suffixed}" } } }
        else
          ENV.fetch(base_name) { abort "Set #{base_name}" }
        end
      end

      # Same fallback chain as env_fetch, but returns nil rather than
      # aborting when nothing is set. Used for DATABASE_URL, which has
      # backend-specific defaults applied downstream.
      #
      # @param base_name [String]
      # @param wallet_name [String, nil]
      # @return [String, nil]
      def env_fetch_optional(base_name, wallet_name)
        if wallet_name
          prefixed = "BSV_WALLET_#{base_name}_#{wallet_name.upcase}"
          suffixed = "#{base_name}_#{wallet_name.upcase}"
          ENV.fetch(prefixed, nil) || ENV.fetch(suffixed, nil) || ENV.fetch(base_name, nil)
        else
          ENV.fetch(base_name, nil)
        end
      end

      # Output formatting for CLI tools.
      #
      # Binary data goes to stdout as binary when piped, hex when interactive.
      # JSON data goes to stdout as formatted JSON when interactive, compact when piped.
      # Human-readable summaries always go to stderr.
      module Output
        module_function

        # Write binary data to stdout or file.
        #
        # @param data [String] binary data
        # @param output_file [String, nil] write to file instead of stdout
        # @param binary [Boolean] force binary output even to TTY
        def write_binary(data, output_file: nil, binary: false)
          if output_file
            File.binwrite(output_file, data)
          elsif binary || !$stdout.tty?
            $stdout.binmode
            $stdout.write(data)
          else
            $stdout.puts data.unpack1('H*')
          end
        end

        # Write a hash/array as JSON to stdout.
        #
        # @param obj [Hash, Array] JSON-serializable object
        # @param output_file [String, nil] write to file instead of stdout
        def write_json(obj, output_file: nil)
          require 'json'
          json = $stdout.tty? ? JSON.pretty_generate(obj) : JSON.generate(obj)
          if output_file
            File.write(output_file, json)
          else
            $stdout.puts json
          end
        end
      end
    end
  end
end
