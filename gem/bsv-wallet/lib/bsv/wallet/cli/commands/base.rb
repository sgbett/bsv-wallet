# frozen_string_literal: true

require 'json'
require 'optparse'
require_relative '../errors'
require_relative '../secrets'
require_relative '../global_options'

module BSV
  module Wallet
    module CLI
      module Commands
        # Abstract base for +bin/wallet+ subcommand classes. One instance
        # per dispatched invocation; +#call(ctx, args)+ is the entry point.
        #
        # Contract (subclasses MUST):
        #   - implement +#name+        — the subcommand token (e.g. "balance")
        #   - implement +#call(args)+  — returns +Integer+ exit code
        #     (the boot +ctx+ is passed via +#initialize+; +#call+ only
        #     receives the remaining argv slice for this command)
        #   - implement +#build_parser+ — defines the per-command +OptionParser+
        #
        # Helpers (subclasses MAY use):
        #   - +#emit_json(payload)+        — JSON to stdout, redacted, with
        #                                    NDJSON support for streamed
        #                                    output via +emit_ndjson_row+
        #   - +#emit_human(line)+          — human-readable line to stderr
        #   - +#read_binary_input(file:)+  — binmode-safe BEEF ingest
        #   - +#parse_pubkey_hex(hex)+     — validates hex pubkey, raises
        #                                    +UsageError+ on malformed input
        #
        # Error contract:
        #   - +raise UsageError+ for bad flags / missing required args
        #   - +raise EngineError+ for engine-side failures (or let
        #     +BSV::Wallet::Error+ bubble; dispatcher wraps it)
        #   - never +abort+ or +exit+ inside +#call+ — bypasses the
        #     dispatcher's rescue and is untestable
        class Base
          # +ctx+: result of +CLI.boot+ ({ engine:, utxo_pool:, ... }).
          # Subclasses access +ctx[:engine]+, +ctx[:utxo_pool]+, etc.
          # +global_options+: the +GlobalOptions+ value object (read for
          # +--json+ etc.).
          def initialize(ctx:, global_options:)
            @ctx = ctx
            @global_options = global_options
          end

          # Subcommand token. Subclasses override.
          # @return [String]
          def name
            self.class.name.split('::').last.downcase
          end

          # Process +args+ and emit results. Returns the process exit code.
          # @param args [Array<String>] remaining argv after the
          #   subcommand token (global flags and the subcommand have
          #   already been consumed by +Dispatcher+).
          # @return [Integer] exit code
          def call(_args)
            raise NotImplementedError, "#{self.class}#call must be implemented"
          end

          # Memoised OptionParser for the subcommand. Banner format is
          # +Usage: bin/wallet <name> [options] <args>+. Subclasses
          # override +#build_parser+ to add flags.
          # @return [OptionParser]
          def parser
            @parser ||= build_parser
          end

          # Subclasses define their +OptionParser+ here. Default is a
          # banner-only parser (no flags).
          # @return [OptionParser]
          def build_parser
            OptionParser.new do |opts|
              opts.banner = "Usage: bin/wallet #{name} [options]"
            end
          end

          # Print +@parser.help+. Used by the dispatcher when
          # +--help+ / +-h+ appears in the subcommand's argv slice.
          def help
            $stdout.puts parser.help
          end

          protected

          # JSON to stdout, with secrets redaction applied by default.
          # Pretty when stdout is a TTY (and +--json+ wasn't forced),
          # compact when piped or +--json+ is set.
          #
          # +redact: false+ skips the redaction layer. Use for outputs
          # that DELIBERATELY carry derivation hints to the recipient
          # (BRC-29 payment message envelopes) — those hints are the
          # whole point of the envelope and must reach the other side.
          # Default stays +redact: true+ — opt-out is intentional.
          #
          # For NDJSON (streamed list output), call +#emit_ndjson_row+
          # per row instead — never buffer the full set in memory.
          #
          # @param payload [Hash, Array]
          # @param redact [Boolean] apply +Secrets.redact+ before emit
          def emit_json(payload, redact: true)
            payload = Secrets.redact(payload) if redact
            json =
              if pretty_json?
                JSON.pretty_generate(payload)
              else
                JSON.generate(payload)
              end
            $stdout.puts json
          end

          # One NDJSON row to stdout. Use in a loop:
          #
          #   results.each { |row| emit_ndjson_row(row) }
          #
          # Always compact (one object per line). Redaction applied.
          #
          # @param row [Hash]
          def emit_ndjson_row(row)
            $stdout.puts JSON.generate(Secrets.redact(row))
          end

          # Human-readable line to stderr. Use for progress, summaries,
          # warnings, anything not destined for shell piping. Applies
          # the same string-level redaction as the dispatcher's
          # top-level rescue, so a stray +wif=+, +private_key:+,
          # +derivation_prefix:+, or +derivation_suffix:+ in a summary
          # line doesn't leak. Interchange identifiers (+identity_key+,
          # +public_key+, +pubkey+) pass through unredacted — they're
          # not secret material per the pubkey-hex carve-out.
          #
          # @param line [String]
          def emit_human(line)
            warn redact_text(line)
          end

          # String-level redaction matching +Secrets::SENSITIVE_FIELD+.
          # Matches +key=value+ / +key: value+ tokens for sensitive
          # field names; leaves interchange identifiers
          # (+identity_key+, +public_key+) untouched.
          def redact_text(text)
            text.to_s.gsub(TEXT_REDACTION) do
              "#{Regexp.last_match(1)}#{Secrets::REDACTED}"
            end
          end

          # Same pattern, same source-of-truth as +Dispatcher::MESSAGE_REDACTION+
          # — built from +Secrets::SENSITIVE_FIELD_NAMES_PATTERN+ so all
          # three redaction surfaces (JSON, exception messages, human
          # output) move together. Compound identifiers like
          # +sender_identity_key+ pass through unredacted (interchange
          # identifier, not secret material).
          TEXT_REDACTION = /\b(#{Secrets::SENSITIVE_FIELD_NAMES_PATTERN}[=:]\s*)\S+/i

          # Read binary input from +--file=<path>+ or stdin. Always
          # +binmode+ — text-mode reads would mangle BEEF bytes with
          # encoding errors or CRLF translation.
          #
          # +max_bytes:+ bounds the read at source rather than after the
          # fact. Without it, a 10 GiB stdin pipe slurps fully into
          # memory before any caller-side size cap can fire — OOM before
          # UsageError. Callers should pass +cap + 1+ so the returned
          # bytesize signals "at or over the cap" unambiguously.
          #
          # @param file [String, nil]
          # @param max_bytes [Integer, nil] hard ceiling on bytes read
          # @return [String] binary content
          def read_binary_input(file: nil, max_bytes: nil)
            bytes =
              if file
                read_file_safely(file, max_bytes)
              else
                raise UsageError, 'no input on stdin (pipe BEEF bytes or use --file=<path>)' if $stdin.tty?

                $stdin.binmode
                max_bytes ? $stdin.read(max_bytes) : $stdin.read
              end
            # IO#read with a length returns nil at immediate EOF (empty
            # file, closed stdin); without length it returns "". Normalise
            # so callers can rely on +#bytesize+ / +#empty?+ unconditionally.
            bytes || (+'').b
          end

          # File.binread raises Errno::* (ENOENT, EACCES, EISDIR, …)
          # which the dispatcher's rescue chain doesn't catch (CLI::Error
          # / Wallet::Error / OptionParser::ParseError / SystemExit only).
          # Wrap to UsageError so a missing or unreadable +--file+ becomes
          # exit-2 with a clean message rather than a stack trace.
          def read_file_safely(file, max_bytes)
            max_bytes ? File.binread(file, max_bytes) : File.binread(file)
          rescue Errno::ENOENT
            raise UsageError, "input file not found: #{file}"
          rescue SystemCallError => e
            raise UsageError, "input file #{file}: #{e.message}"
          end

          # Validate a hex-encoded compressed public key (66 chars,
          # +02+ or +03+ prefix). Centralised here so every command
          # taking a pubkey flag (+--counterparty+, +--to=<root_key_hex>+,
          # etc.) goes through the same check; malformed input fails at
          # parse time with a clear error rather than deep in BRC-42
          # derivation.
          #
          # @param hex [String]
          # @return [String] the validated hex (echoed back for chaining)
          # @raise [UsageError]
          def parse_pubkey_hex(hex)
            return hex if hex.is_a?(String) && hex.match?(/\A(02|03)[0-9a-fA-F]{64}\z/)

            raise UsageError,
                  "invalid public key: expected 66-char hex starting 02 or 03, got #{safe_preview(hex)}"
          end

          # Validate a basket name against the schema's DB CHECK rules
          # (mirrors all seven +baskets_name_*+ constraints in
          # +001_create_schema.rb:266-272+). Without this gate, invalid
          # names reach the engine and bubble as
          # +Sequel::CheckConstraintViolation+ — outside the dispatcher's
          # never-raises-uncaught rescue chain.
          #
          # Schema floor (enforced here): length 5-300, lowercase ASCII
          # letters/digits/spaces, no consecutive spaces, no leading or
          # trailing space, not the literal +'default'+, no trailing
          # +' basket'+ suffix. These are the DB CHECK constraints; every
          # path that writes to +baskets+ obeys them.
          #
          # NOT enforced here (BRC-100 conformance layer only —
          # +BSV::Wallet::BRC100#validate_basket_name!+): +'admin'+ prefix
          # and +'p '+ prefix. Native +bin/wallet+ legitimately uses these
          # for wallet-internal baskets (+'p wbikd'+ for WBIKD address
          # slots per the WBIKD draft; +'admin *'+ for permission tokens
          # per ADR-029); the sibling +bin/brc100+ surface (HLR #431) is
          # where those tighter spec-mandated rules belong.
          BASKET_NAME_MIN = 5
          BASKET_NAME_MAX = 300
          BASKET_NAME_CHARSET = /\A[a-z0-9 ]+\z/

          def validate_basket!(name)
            unless name.is_a?(String) && name.length.between?(BASKET_NAME_MIN, BASKET_NAME_MAX)
              raise UsageError,
                    "--basket=<name> must be #{BASKET_NAME_MIN}-#{BASKET_NAME_MAX} chars " \
                    "(got #{safe_preview(name)})"
            end

            unless name.match?(BASKET_NAME_CHARSET)
              raise UsageError,
                    '--basket=<name> must contain only lowercase ASCII letters, digits, and spaces ' \
                    "(got #{safe_preview(name)})"
            end

            raise UsageError, '--basket=<name> must not contain consecutive spaces' if name.include?('  ')

            raise UsageError, '--basket=<name> must not start with a space' if name.start_with?(' ')

            raise UsageError, '--basket=<name> must not end with a space' if name.end_with?(' ')

            raise UsageError, %(--basket=<name> must not end with " basket" (schema reservation)) if name.end_with?(' basket')

            return unless name == 'default'

            raise UsageError, %(--basket=<name> cannot be "default" (schema reservation))
          end

          # Defence against accidental secret disclosure in error
          # messages. An operator mistyping a WIF (or anything else
          # long) into a wrong slot — recipient, --to, <action_id> —
          # would otherwise have the raw value echoed to stderr / logs
          # / CI output if the validator dumped +#inspect+. Short
          # values pass through verbatim (diagnostic for typos; too
          # short to be a WIF); long values get a prefix + length
          # indicator that's diagnostic without being a disclosure
          # surface.
          #
          # @param value [Object] anything responding to +#to_s+
          # @param limit [Integer] threshold above which truncation kicks in
          # @return [String] inspect-shaped preview safe for error messages
          def safe_preview(value, limit: 20)
            s = value.to_s
            return s.inspect if s.length <= limit

            "#{s.slice(0, 8).inspect[0..-2]}…\" (#{s.length} chars)"
          end

          # +true+ iff JSON output should be pretty-formatted (TTY +
          # no +--json+ force flag).
          # @return [Boolean]
          def pretty_json?
            $stdout.tty? && !@global_options.json
          end
        end
      end
    end
  end
end
