# frozen_string_literal: true

module BSV
  module Wallet
    # Shared boot sequence for CLI utilities.
    #
    # Each bin/ tool runs in its own OS process, so the global
    # Sequel::Model.db is safe — only one wallet per process.
    #
    # Backend selection:
    #   - If DATABASE_URL is set, its scheme determines the adapter
    #     (postgres:// or postgresql:// → Postgres via pg gem,
    #      anything else → SQLite).
    #   - If DATABASE_URL is unset, defaults to SQLite at
    #     ~/.bsv-wallet/<name>.db.
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
      # @return [Hash] { engine:, key_deriver:, proof_store:, db:, identity_key:, private_key: }
      def boot(wallet_name: nil, network: :mainnet)
        begin
          require 'dotenv/load'
        rescue LoadError
          # dotenv is optional — env vars can come from shell profile or CI
        end
        require 'sequel'
        require 'logger'
        require 'bsv-wallet'

        unless BSV.logger
          BSV.logger = Logger.new($stderr)
          BSV.logger.level = Logger::DEBUG
        end

        wif = env_fetch('WIF', wallet_name)
        db_url = env_fetch_optional('DATABASE_URL', wallet_name)
        db_url ||= default_sqlite_url(wallet_name)

        BSV::Wallet::Store::Connection.connect(db_url)
        BSV::Wallet::Store::Connection.migrate!
        BSV::Wallet::Store::Connection.bind_models!
        db = BSV::Wallet::Store::Connection.db

        services = BSV::Wallet::Store.bootstrap(db: db)

        private_key = BSV::Primitives::PrivateKey.from_wif(wif)
        key_deriver = BSV::Wallet::KeyDeriver.new(private_key: private_key)

        network_provider = BSV::Network::Providers::WhatsOnChain.send(network)
        network_services = BSV::Network::Services.new(providers: [network_provider])
        chain_tracker = BSV::Network::ChainTracker.new(db: db, services: network_services)

        limp_threshold_raw = ENV.fetch('LIMP_THRESHOLD', BSV::Wallet::Engine::LIMP_THRESHOLD)
        begin
          limp_threshold = Integer(limp_threshold_raw)
        rescue ArgumentError
          abort "LIMP_THRESHOLD must be a valid integer (got #{limp_threshold_raw.inspect})"
        end

        engine = BSV::Wallet::Engine.new(
          store: services[:store],
          utxo_pool: services[:utxo_pool],
          broadcast_queue: services[:broadcast_queue],
          proof_store: services[:proof_store],
          key_deriver: key_deriver,
          chain_tracker: chain_tracker,
          network_provider: network_provider,
          network: network,
          limp_threshold: limp_threshold
        )

        {
          engine: engine,
          utxo_pool: services[:utxo_pool],
          key_deriver: key_deriver,
          proof_store: services[:proof_store],
          db: db,
          identity_key: key_deriver.identity_key,
          private_key: private_key
        }
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
