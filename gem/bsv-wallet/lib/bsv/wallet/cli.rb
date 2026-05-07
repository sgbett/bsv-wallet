# frozen_string_literal: true

module BSV
  module Wallet
    # Shared boot sequence for CLI utilities.
    #
    # Each bin/ tool runs in its own OS process, so the global
    # Sequel::Model.db is safe — only one wallet per process.
    #
    # @example
    #   wallet_name, args = BSV::Wallet::CLI.extract_wallet_name(ARGV)
    #   ctx = BSV::Wallet::CLI.boot(wallet_name: wallet_name)
    #   engine = ctx[:engine]
    module CLI
      module_function

      # Boot a wallet engine for the named wallet.
      #
      # Connects to the database, runs migrations, and constructs
      # all Layer 2a components + the Engine.
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
        require 'bsv-wallet-postgres'

        unless BSV.logger
          BSV.logger = Logger.new($stderr)
          BSV.logger.level = Logger::DEBUG
        end

        wif = env_fetch('WIF', wallet_name)
        db_url = env_fetch('DATABASE_URL', wallet_name)

        db = Sequel.connect(db_url)
        db.extension :pg_enum
        db.extension :pg_array
        db.extension :pg_json
        BSV::Wallet::Postgres.connect(db)

        Sequel.extension :migration
        migrations_path = File.join(
          Gem::Specification.find_by_name('bsv-wallet-postgres').gem_dir,
          'db', 'migrations'
        )
        Sequel::Migrator.run(db, migrations_path)

        private_key = BSV::Primitives::PrivateKey.from_wif(wif)
        key_deriver = BSV::Wallet::KeyDeriver.new(private_key: private_key)

        store = BSV::Wallet::Postgres::Store.new(db: db)
        proof_store = BSV::Wallet::Postgres::ProofStore.new(db: db)
        utxo_pool = BSV::Wallet::Postgres::UTXOPool.new(store: store)

        network_provider = BSV::Network::Providers::WhatsOnChain.send(network)

        limp_threshold_raw = ENV.fetch('LIMP_THRESHOLD', BSV::Wallet::Engine::LIMP_THRESHOLD)
        begin
          limp_threshold = Integer(limp_threshold_raw)
        rescue ArgumentError
          abort "LIMP_THRESHOLD must be a valid integer (got #{limp_threshold_raw.inspect})"
        end

        engine = BSV::Wallet::Engine.new(
          store: store,
          utxo_pool: utxo_pool,
          broadcast_queue: BSV::Wallet::Postgres::BroadcastQueue.new(db: db),
          proof_store: proof_store,
          key_deriver: key_deriver,
          network_provider: network_provider,
          network: network,
          limp_threshold: limp_threshold
        )

        {
          engine: engine,
          utxo_pool: utxo_pool,
          key_deriver: key_deriver,
          proof_store: proof_store,
          db: db,
          identity_key: key_deriver.identity_key,
          private_key: private_key
        }
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
