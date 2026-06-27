# frozen_string_literal: true

require 'json'
require 'optparse'
require_relative '../errors'
require_relative '../secrets'

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

          # JSON to stdout, with secrets redaction applied. Pretty when
          # stdout is a TTY (and +--json+ wasn't forced), compact when
          # piped or +--json+ is set.
          #
          # For NDJSON (streamed list output), call +#emit_ndjson_row+
          # per row instead — never buffer the full set in memory.
          #
          # @param payload [Hash, Array]
          def emit_json(payload)
            redacted = Secrets.redact(payload)
            json =
              if pretty_json?
                JSON.pretty_generate(redacted)
              else
                JSON.generate(redacted)
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
          # warnings, anything not destined for shell piping. Goes
          # through +Secrets.redact+ at the string level via the
          # +#inspect+ overrides on key-bearing classes.
          #
          # @param line [String]
          def emit_human(line)
            warn line
          end

          # Read binary input from +--file=<path>+ or stdin. Always
          # +binmode+ — text-mode reads would mangle BEEF bytes with
          # encoding errors or CRLF translation.
          #
          # @param file [String, nil]
          # @return [String] binary content
          def read_binary_input(file: nil)
            if file
              File.binread(file)
            else
              raise UsageError, 'no input on stdin (pipe BEEF bytes or use --file=<path>)' if $stdin.tty?

              $stdin.binmode
              $stdin.read
            end
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
                  "invalid public key: expected 66-char hex starting 02 or 03, got #{hex.inspect}"
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
