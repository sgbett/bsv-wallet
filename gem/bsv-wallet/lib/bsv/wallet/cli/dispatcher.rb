# frozen_string_literal: true

require 'optparse'
require 'uri'
require_relative 'errors'
require_relative 'secrets'
require_relative 'inspect_overrides'
require_relative 'global_options'
require_relative 'commands/base'
require_relative 'commands/balance'
require_relative 'commands/list'

module BSV
  module Wallet
    module CLI
      # +bin/wallet+ argv router. The dispatcher's job is the boring
      # parts (parsing global flags, enforcing the secrets policy,
      # selecting the command class, translating exceptions to exit
      # codes). All command-specific behaviour lives in
      # +Commands::<Verb>+ subclasses.
      #
      # Public entry point: +Dispatcher.call(argv)+ — typically wired
      # to +ARGV+ by +bin/wallet+.
      module Dispatcher
        # Explicit command registry. Frozen hash beats +const_get+
        # gymnastics (no autoload races) and beats +case/when+ (greppable).
        # Adding a command means a line here AND a +Commands::<Verb>+
        # class — no implicit registration.
        COMMANDS = {
          'balance' => Commands::Balance,
          'list' => Commands::List
        }.freeze

        module_function

        # Entry point. Returns the process exit code; +bin/wallet+
        # passes that to +exit+. Never raises uncaught — every error
        # path resolves to a structured stderr line + exit code.
        #
        # @param argv [Array<String>]
        # @return [Integer]
        def call(argv)
          opts, remaining = parse_global_options(argv.dup)

          if remaining.empty? || remaining.first == 'help' || remaining.first == '--help' || remaining.first == '-h'
            print_global_help
            return 0
          end

          name = remaining.shift
          command_class = COMMANDS[name]
          raise UsageError, "unknown command: #{name.inspect} (available: #{COMMANDS.keys.join(', ')})" unless command_class

          ctx = boot_engine(opts)
          command = command_class.new(ctx: ctx, global_options: opts)

          if remaining.include?('--help') || remaining.include?('-h')
            command.help
            return 0
          end

          command.call(remaining)
        rescue CLI::Error => e
          warn "error: #{e.message}"
          e.exit_code
        rescue BSV::Wallet::Error => e
          warn "engine error: #{e.message}"
          1
        rescue OptionParser::ParseError => e
          warn "usage: #{e.message}"
          2
        end

        # Parse the global flag layer; everything after the first
        # non-flag token is left for the subcommand. Enforces the
        # secrets-on-the-CLI policy in-line:
        #   - +--wif=<wif>+ on TTY without +--allow-insecure-wif+ → refuse
        #   - +--database-url+ with embedded password               → refuse
        #   - +--wif-file=<path>+ mode/owner check
        #   - +--env=<file>+ lstat → mode/owner → realpath ordering
        #
        # @param argv [Array<String>]
        # @return [Array(GlobalOptions, Array<String>)]
        def parse_global_options(argv)
          wallet_name = nil
          network = nil
          json = false
          wif_argv = nil
          wif_file = nil
          allow_insecure_wif = false
          database_url = nil
          env_file = nil
          env_allow_symlink = false

          parser = OptionParser.new do |opts|
            opts.on('--wallet=NAME') { |v| wallet_name = v }
            opts.on('--wif=WIF') { |v| wif_argv = v }
            opts.on('--wif-file=PATH') { |v| wif_file = v }
            opts.on('--allow-insecure-wif') { allow_insecure_wif = true }
            opts.on('--database-url=URL') { |v| database_url = v }
            opts.on('--env=FILE') { |v| env_file = v }
            opts.on('--env-allow-symlink') { env_allow_symlink = true }
            opts.on('--network=NET') { |v| network = v.to_sym }
            opts.on('--json') { json = true }
            opts.on('-h', '--help')
          end
          remaining = parser.order(argv)

          load_env_file!(env_file, env_allow_symlink) if env_file

          wif_override = resolve_wif_override(wif_argv, wif_file, allow_insecure_wif)
          database_url_override = check_database_url!(database_url)

          opts = GlobalOptions.new(
            wallet_name: wallet_name,
            network: network,
            json: json,
            wif_override: wif_override,
            database_url_override: database_url_override,
            env_file: env_file
          )
          [opts, remaining]
        end

        # Boot the engine with the parsed global options.
        # Threads +wif_override+ / +database_url_override+ into
        # +CLI.boot+. +CLI.boot+ accepts both as +nil+-defaulted kwargs,
        # falling back to ENV/Fixtures when not supplied — backward-compat
        # for +bin/walletd+ and other callers.
        def boot_engine(opts)
          CLI.boot(
            wallet_name: opts.wallet_name,
            network: opts.network,
            wif_override: opts.wif_override,
            database_url_override: opts.database_url_override
          )
        end

        # WIF resolution: +--wif-file+ > +--wif+ (if allowed) > nil.
        # Returns the raw WIF string for downstream consumption, or
        # +nil+ if neither flag was set (falls through to ENV/Fixtures).
        #
        # @return [String, nil]
        def resolve_wif_override(wif_argv, wif_file, allow_insecure_wif)
          return read_wif_file!(wif_file) if wif_file
          return nil unless wif_argv

          if $stdin.tty? && !allow_insecure_wif
            raise InsecureWifError,
                  '--wif=<wif> on TTY refused (shell-history capture is total wallet compromise). ' \
                  'Use BSV_WALLET_WIF_<NAME> env, --wif-file=<path> (mode 0600), or ' \
                  '--allow-insecure-wif if you accept the risk (dev/test only).'
          end
          wif_argv
        end

        # Read a WIF from +--wif-file=<path>+. Mode-checked (must be 0600
        # or stricter) and owner-checked.
        # @return [String]
        def read_wif_file!(path)
          stat = File.stat(path)
          raise UsageError, "--wif-file #{path}: not a regular file" unless stat.file?
          raise UsageError, "--wif-file #{path}: must be owned by the invoker" unless stat.owned?
          raise UsageError, "--wif-file #{path}: mode must be 0600 or stricter (got 0#{(stat.mode & 0o777).to_s(8)})" if stat.mode.anybits?(0o077)

          File.read(path).strip
        end

        # +--database-url+ accepts a URL but rejects an embedded password
        # in +userinfo+. Argv exposure for DB credentials is the same
        # leakage path as WIF.
        # @return [String, nil]
        def check_database_url!(url)
          return nil if url.nil?

          parsed = URI.parse(url)
          # +URI#password+ returns the colon-separated suffix in userinfo;
          # nil if no colon. (Username alone is fine — many local
          # Postgres setups use the unix socket with user= and no
          # password.)
          if parsed.password
            raise UsageError,
                  '--database-url with embedded password refused (argv leakage). ' \
                  'Move the password to PGPASSFILE / ~/.pgpass.'
          end
          url
        rescue URI::InvalidURIError => e
          raise UsageError, "--database-url: invalid URI: #{e.message}"
        end

        # +--env=<file>+ loader. Strict policy:
        #   1. +File.lstat+ FIRST to detect symlinks (regular +File.stat+
        #      silently follows them and would miss the policy).
        #   2. Mode + owner check on the lstat'd entry.
        #   3. +File.realpath+ LAST — realpath resolves symlinks, so it
        #      must run after the symlink check or the policy is defeated.
        #
        # Only keys with the documented +BSV_WALLET_*+ / +DATABASE_URL_*+
        # / +PG*+ prefixes are loaded; arbitrary ENV injection from an
        # attacker-writable file is refused.
        def load_env_file!(path, allow_symlink)
          raise UsageError, "--env file not found: #{path}" unless File.exist?(path)

          lstat = File.lstat(path)
          raise UsageError, "--env #{path}: symlinks refused (use --env-allow-symlink to opt in)" if lstat.symlink? && !allow_symlink

          # For the symlink-allowed case we stat the target; for the
          # normal case lstat IS the target.
          stat = allow_symlink ? File.stat(path) : lstat

          raise UsageError, "--env #{path}: must be a regular file" unless stat.file?
          raise UsageError, "--env #{path}: must be owned by the invoker" unless stat.owned?
          raise UsageError, "--env #{path}: mode must be 0600 or stricter (got 0#{(stat.mode & 0o777).to_s(8)})" if stat.mode.anybits?(0o077)

          # Resolve through symlinks LAST (only meaningful when
          # +--env-allow-symlink+ is set — otherwise we've already
          # refused symlinks above).
          canonical = File.realpath(path)

          File.foreach(canonical) do |line|
            line = line.strip
            next if line.empty? || line.start_with?('#')

            key, value = line.split('=', 2)
            next unless key && value
            next unless env_key_allowed?(key)
            next if ENV[key] # seed-mechanism: don't override

            ENV[key] = value.gsub(/\A["']|["']\z/, '')
          end
        end

        def env_key_allowed?(key)
          key.match?(/\A(BSV_WALLET_|DATABASE_URL|PG)/)
        end

        def print_global_help
          puts <<~HELP
            Usage: bin/wallet [global-flags] <command> [command-args]

            Global flags:
              --wallet=<name>          Resolve via Fixtures registry
              --wif=<wif>              Explicit WIF (refused on TTY by default)
              --wif-file=<path>        Read WIF from mode-0600 file
              --allow-insecure-wif     Permit --wif=<wif> on TTY (dev/test)
              --database-url=<url>     DB URL (userinfo must not embed password)
              --env=<file>             Seed process ENV from dotenv-style file
              --env-allow-symlink      Permit --env path to be a symlink
              --network=<mainnet|testnet>
              --json                   Force JSON output even on TTY (NDJSON for list)
              --help, -h               Show this message

            Commands:
              #{COMMANDS.keys.sort.map { |c| "  #{c}" }.join("\n  ").strip}

            Run `bin/wallet <command> --help` for command-specific options.
          HELP
        end
      end
    end
  end
end
