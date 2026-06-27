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
          opts, remaining, help_requested = parse_global_options(argv.dup)

          # Global help shortcuts: explicit -h/--help anywhere in the
          # global slice, the literal 'help' command, or no command
          # supplied at all. None of these should boot the engine —
          # `bin/wallet -h balance` previously ran balance silently.
          if help_requested || remaining.empty? || remaining.first == 'help'
            print_global_help
            return 0
          end

          name = remaining.shift
          command_class = COMMANDS[name]
          raise UsageError, "unknown command: #{name.inspect} (available: #{COMMANDS.keys.join(', ')})" unless command_class

          # Per-command help: same short-circuit — print and exit
          # before booting the engine. The command needs to exist (we
          # checked above) but doesn't need its ctx wired.
          if remaining.include?('--help') || remaining.include?('-h')
            command_class.new(ctx: nil, global_options: opts).help
            return 0
          end

          ctx = boot_engine(opts)
          command = command_class.new(ctx: ctx, global_options: opts)
          command.call(remaining)
        rescue CLI::Error => e
          warn "error: #{redact_message(e.message)}"
          e.exit_code
        rescue BSV::Wallet::Error => e
          warn "engine error: #{redact_message(e.message)}"
          1
        rescue OptionParser::ParseError => e
          warn "usage: #{redact_message(e.message)}"
          2
        rescue SystemExit => e
          # +CLI.boot+ uses +abort+ on missing-WIF / Fixtures-not-found
          # paths, which raises +SystemExit+ and would otherwise bypass
          # the dispatcher's never-raises-uncaught contract (and
          # terminate any RSpec run that loaded the dispatcher). Convert
          # to a clean integer return; +abort+ has already written its
          # own stderr line so we don't duplicate it.
          e.status || 1
        end

        # Apply +Secrets+ patterns at the string level. Exception
        # messages may quote argv tokens (a malformed +--wif=<wif>+
        # value, a +--database-url+ containing a password) — bubbling
        # those to stderr verbatim would defeat the secrets policy.
        # Matches the same field names +Secrets::SENSITIVE_FIELD+
        # scrubs in JSON, including the carve-outs for interchange
        # identifiers (+identity_key+, +public_key+) which stay
        # visible. Token-shaped (+\w++) to avoid greedy spans across
        # whitespace.
        def redact_message(message)
          message.to_s.gsub(MESSAGE_REDACTION) do
            "#{Regexp.last_match(1)}#{Secrets::REDACTED}"
          end
        end

        # Field-name + separator capture group. Matches keys that
        # +Secrets::SENSITIVE_FIELD+ would scrub, followed by an
        # +=+/+:+/space separator. Pubkey-identifier carve-outs
        # (+identity_key+, +public_key+, +pubkey+) are NOT matched —
        # they're interchange identifiers, not secret material.
        MESSAGE_REDACTION = /
          \b(
            (?:
              wif |
              secret |
              (?!identity_|public_|pub)\w*_(?:key|priv) |
              (?:private|signing|root)_key |
              derivation_(?:prefix|suffix)
            )
            [=:]\s*
          )
          \S+
        /xi

        # Parse the global flag layer; everything after the first
        # non-flag token is left for the subcommand. Enforces the
        # secrets-on-the-CLI policy in-line:
        #   - +--wif=<wif>+ on TTY without +--allow-insecure-wif+ → refuse
        #   - +--database-url+ with embedded password               → refuse
        #   - +--wif-file=<path>+ mode/owner check
        #   - +--env=<file>+ lstat → mode/owner → realpath ordering
        #
        # @param argv [Array<String>]
        # @return [Array(GlobalOptions, Array<String>, Boolean)]
        #   +[opts, remaining, help_requested]+ — the parsed value
        #   object, the remaining argv after global flags are consumed,
        #   and a flag indicating +-h+/+--help+ was set anywhere in
        #   the global slice.
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
          help_requested = false

          parser = OptionParser.new do |opts|
            # Blank/whitespace --wallet falls through to +nil+ so
            # +CLI.boot+'s end-user-mode branch fires (read from
            # +BSV::Wallet.config+) instead of looking up Fixtures
            # for the literal empty string.
            opts.on('--wallet=NAME') { |v| wallet_name = v.to_s.strip.empty? ? nil : v.to_s.strip }
            opts.on('--wif=WIF') { |v| wif_argv = v }
            opts.on('--wif-file=PATH') { |v| wif_file = v }
            opts.on('--allow-insecure-wif') { allow_insecure_wif = true }
            opts.on('--database-url=URL') { |v| database_url = v }
            opts.on('--env=FILE') { |v| env_file = v }
            opts.on('--env-allow-symlink') { env_allow_symlink = true }
            # Blank/whitespace networks fall through to +nil+ so
            # +CLI.boot+'s +network ||= BSV::Wallet.config.network+
            # fallback fires. +":""+ would be a junk symbol that
            # bypasses the fallback.
            opts.on('--network=NET') { |v| network = v.to_s.strip.empty? ? nil : v.to_s.strip.to_sym }
            opts.on('--json') { json = true }
            opts.on('-h', '--help') { help_requested = true }
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
          [opts, remaining, help_requested]
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
        # or stricter), owner-checked, symlink-refused. Same shape as the
        # +--env+ loader: +lstat+ first (symlink detection happens
        # before any read), then mode/owner, then read. All syscall
        # errors get wrapped as +UsageError+ to preserve the
        # dispatcher's never-raises-uncaught contract.
        # @return [String]
        def read_wif_file!(path)
          lstat =
            begin
              File.lstat(path)
            rescue Errno::ENOENT
              raise UsageError, "--wif-file #{path}: file not found"
            rescue SystemCallError => e
              raise UsageError, "--wif-file #{path}: #{e.message}"
            end

          raise UsageError, "--wif-file #{path}: symlinks refused (resolve the path before passing)" if lstat.symlink?
          raise UsageError, "--wif-file #{path}: not a regular file" unless lstat.file?
          raise UsageError, "--wif-file #{path}: must be owned by the invoker" unless lstat.owned?
          raise UsageError, "--wif-file #{path}: mode must be 0600 or stricter (got 0#{(lstat.mode & 0o777).to_s(8)})" if lstat.mode.anybits?(0o077)

          begin
            File.read(path).strip
          rescue SystemCallError => e
            raise UsageError, "--wif-file #{path}: #{e.message}"
          end
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
          # Use +lstat+ as the existence check too — +File.exist?+ follows
          # symlinks, which would (a) misclassify a broken symlink as
          # "not found" (hiding the policy violation), and (b) add a
          # TOCTOU window between the existence check and the lstat.
          lstat =
            begin
              File.lstat(path)
            rescue Errno::ENOENT
              raise UsageError, "--env file not found: #{path}"
            rescue SystemCallError => e
              raise UsageError, "--env #{path}: #{e.message}"
            end
          raise UsageError, "--env #{path}: symlinks refused (use --env-allow-symlink to opt in)" if lstat.symlink? && !allow_symlink

          # For the symlink-allowed case we stat the target; for the
          # normal case lstat IS the target.
          stat =
            if allow_symlink
              begin
                File.stat(path)
              rescue SystemCallError => e
                raise UsageError, "--env #{path}: #{e.message}"
              end
            else
              lstat
            end

          raise UsageError, "--env #{path}: must be a regular file" unless stat.file?
          raise UsageError, "--env #{path}: must be owned by the invoker" unless stat.owned?
          raise UsageError, "--env #{path}: mode must be 0600 or stricter (got 0#{(stat.mode & 0o777).to_s(8)})" if stat.mode.anybits?(0o077)

          # Resolve through symlinks LAST (only meaningful when
          # +--env-allow-symlink+ is set — otherwise we've already
          # refused symlinks above).
          canonical =
            begin
              File.realpath(path)
            rescue SystemCallError => e
              raise UsageError, "--env #{path}: #{e.message}"
            end

          begin
            File.foreach(canonical) do |line|
              line = line.strip
              next if line.empty? || line.start_with?('#')

              key, value = line.split('=', 2)
              next unless key && value
              next unless env_key_allowed?(key)
              next if ENV[key] # seed-mechanism: don't override

              ENV[key] = value.gsub(/\A["']|["']\z/, '')
            end
          rescue SystemCallError => e
            raise UsageError, "--env #{path}: #{e.message}"
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
              --json                   Use compact JSON (no pretty-printing on TTY); `list` always emits NDJSON regardless
              --help, -h               Show this message

            Commands:
            #{COMMANDS.keys.sort.map { |c| "  #{c}" }.join("\n")}

            Run `bin/wallet <command> --help` for command-specific options.
          HELP
        end
      end
    end
  end
end
