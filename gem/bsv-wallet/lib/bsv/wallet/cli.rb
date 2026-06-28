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
    #   * **Dev/test mode** (+wallet_name: 'alice'+ etc.): named-wallet
    #     fixtures resolve through +BSV::Wallet::Fixtures+ (the
    #     +configure+ block in +~/.bsv-wallet/fixtures.rb+, falling
    #     back to the gem-bundled default which reads
    #     +BSV_WALLET_WIF_<NAME>+ / +DATABASE_URL_<NAME>+ /
    #     +BSV_WALLET_POSTGRES+ from shell ENV). See
    #     +lib/bsv/wallet/fixtures.rb+ and +config/fixtures.rb+.
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
      # @param network [Symbol, nil] :mainnet or :testnet; nil → read from config
      # @param wif_override [String, nil] explicit WIF (from +--wif+ /
      #   +--wif-file+); +nil+ → fall back to Fixtures / Config / ENV
      # @param database_url_override [String, nil] explicit DB URL (from
      #   +--database-url+); +nil+ → fall back to Fixtures / Config / ENV
      # @return [Hash] { engine:, utxo_pool:, key_deriver:, db:, identity_key:, private_key: }
      def boot(wallet_name: nil, network: nil, wif_override: nil, database_url_override: nil)
        require 'sequel'
        require 'logger'
        require 'bsv-wallet'

        # Load both configuration files first so any consumer reading
        # +BSV::Wallet.config.x+ or +BSV::Wallet::Fixtures.wallet(...)+
        # during boot sees user/operator overrides, not just the ENV
        # defaults baked into Config + Fixtures' example file.
        BSV::Wallet.load_config_file!
        BSV::Wallet::Fixtures.load_config_file! if wallet_name

        # Network: explicit kwarg wins; otherwise read from config
        # (which itself defaults BSV_WALLET_NETWORK → :mainnet).
        network ||= BSV::Wallet.config.network

        unless BSV.logger
          BSV.logger = Logger.new($stderr)
          BSV.logger.level = Logger::DEBUG
        end

        # Resolution order (highest → lowest):
        #   1. Explicit overrides from +bin/wallet+ global flags
        #      (+wif_override+ / +database_url_override+).
        #   2. Fixtures registry (named wallets — dev/test mode).
        #   3. +BSV::Wallet.config+ (end-user mode).
        # Override + Fixtures may combine: e.g. +--wif=...+ with the
        # named wallet's database_url, or vice versa.
        wif = wif_override
        db_url = database_url_override

        if wallet_name
          fixture = BSV::Wallet::Fixtures.wallet(wallet_name)
          wif ||= fixture&.wif
          db_url ||= fixture&.database_url
        else
          wif ||= BSV::Wallet.config.wif
          db_url ||= BSV::Wallet.config.database_url
        end
        abort missing_wif_message(wallet_name) if wif.nil? || wif.empty?
        db_url ||= default_sqlite_url(wallet_name)

        # KeyDeriver comes first — Store needs +identity_pubkey_hash+ for the
        # per-wallet +outputs.spendable_recoverable+ CHECK literal at migration
        # time (HLR #467).
        private_key = BSV::Primitives::PrivateKey.from_wif(wif)
        key_deriver = BSV::Wallet::KeyDeriver.new(private_key: private_key)

        store = BSV::Wallet::Store.connect(db_url, identity_pubkey_hash: key_deriver.identity_pubkey_hash)
        store.migrate!
        store.verify_schema! # HLR #467 — fail fast on schema/WIF mismatch (restore-to-wrong-DB, drift)
        db = store.db

        utxo_pool = BSV::Wallet::Store::UTXOPool.new(store: store)

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

      # Context-aware error message for the missing-WIF abort.
      #
      # @param wallet_name [String, nil]
      # @return [String]
      def missing_wif_message(wallet_name)
        return 'Set WIF or configure c.wif in ~/.bsv-wallet/config.rb' unless wallet_name

        registered = BSV::Wallet::Fixtures.registry.names.map { |n| ":#{n}" }.join(', ')
        if BSV::Wallet::Fixtures.wallet(wallet_name)
          # Wallet IS registered but its WIF is empty — operator just needs
          # to set BSV_WALLET_WIF_<NAME> (the shipped default reads it).
          "Fixture wallet :#{wallet_name} has no WIF. Set BSV_WALLET_WIF_#{wallet_name.upcase} or " \
            "pin the WIF explicitly in ~/.bsv-wallet/fixtures.rb (registered: #{registered})."
        else
          # Wallet NOT registered at all — operator needs to add the
          # registration; setting an ENV var won't help.
          "No fixture wallet :#{wallet_name} (registered: #{registered}). " \
            "Add `f.wallet :#{wallet_name}, wif: ...` to ~/.bsv-wallet/fixtures.rb."
        end
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
