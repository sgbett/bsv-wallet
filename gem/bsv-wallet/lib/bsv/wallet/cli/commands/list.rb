# frozen_string_literal: true

require_relative 'base'

module BSV
  module Wallet
    module CLI
      module Commands
        # +bin/wallet list <noun>+ — power-user query over wallet state.
        #
        #   bin/wallet list outputs                              # all spendable, --limit=100
        #   bin/wallet list outputs --basket=<name> --limit=50
        #   bin/wallet list outputs --all                        # no limit (caveat: scale)
        #   bin/wallet --json list outputs                       # NDJSON (one row per line)
        #   bin/wallet list actions --label=<name>               # --label REQUIRED
        #   bin/wallet list actions --label=<n1> --label=<n2>    # match-any across labels
        #
        # +--json+ is a GLOBAL flag (parsed before the subcommand). The
        # NDJSON output mode fires when +--json+ is set OR when stdout
        # is not a TTY.
        #
        # +list actions+ is label-required because +Engine#list_actions+
        # has no unfiltered primitive; +Engine::Action.list+ returns an
        # empty set when no labels match. Unfiltered listing is a
        # follow-up engine addition, out of scope for Phase 1.
        #
        # Defaults: +--limit=100+; +--all+ is the explicit opt-out.
        # +--json+ output is NDJSON — one JSON object per line; never
        # buffers the full set in memory. TTY output is the same row
        # stream, formatted lightly for human reading.
        class List < Base
          NOUNS = %w[outputs actions].freeze
          DEFAULT_LIMIT = 100

          def name = 'list'

          def build_parser
            @options = { limit: DEFAULT_LIMIT, offset: 0, labels: [] }
            OptionParser.new do |opts|
              opts.banner = 'Usage: bin/wallet list <outputs|actions> [options]'

              opts.on('--limit=N', Integer, "Result cap (default: #{DEFAULT_LIMIT}, --all to remove)") do |v|
                @options[:limit] = v
              end

              opts.on('--offset=N', Integer, 'Result offset (default: 0)') do |v|
                @options[:offset] = v
              end

              opts.on('--all', 'Remove --limit ceiling (caveat: hydrates full set)') do
                @options[:all] = true
              end

              opts.on('--basket=NAME',
                      'Outputs only: filter by basket ("none" for unbasketed)') do |v|
                @options[:basket] = v == 'none' ? nil : v
                @options[:basket_given] = true
              end

              opts.on('--label=NAME',
                      'Actions only: filter by label (repeat for match-any)') do |v|
                @options[:labels] << v
              end
            end
          end

          def call(args)
            parser.parse!(args)
            noun = args.shift
            raise UsageError, "list requires a noun: one of #{NOUNS.join(', ')}" if noun.nil?
            raise UsageError, "unknown list noun: #{noun.inspect} (expected #{NOUNS.join(', ')})" unless NOUNS.include?(noun)

            send(:"list_#{noun}")
            0
          end

          private

          def list_outputs
            engine = @ctx[:engine]
            query = { limit: effective_limit, offset: @options[:offset] }
            query[:basket] = @options[:basket] if @options[:basket_given]

            result = engine.spendable_outputs(**query)
            outputs = result.is_a?(Hash) ? (result[:outputs] || []) : []
            total = result.is_a?(Hash) ? result[:total] : outputs.length

            outputs.each { |o| emit_ndjson_row(o) }

            emit_human 'noun:    outputs'
            emit_human "basket:  #{basket_label}"
            emit_human "rows:    #{outputs.length} of #{total}"
            emit_human "limit:   #{@options[:all] ? '(all)' : effective_limit}"
          end

          def list_actions
            if @options[:labels].empty?
              raise UsageError,
                    'list actions requires at least one --label=<name> ' \
                    '(engine has no unfiltered actions primitive yet)'
            end

            engine = @ctx[:engine]
            result = engine.list_actions(
              labels: @options[:labels],
              label_query_mode: :any,
              limit: effective_limit,
              offset: @options[:offset]
            )
            actions = result.is_a?(Hash) ? (result[:actions] || []) : []
            total = result.is_a?(Hash) ? result[:total] : actions.length

            actions.each { |a| emit_ndjson_row(a) }

            emit_human 'noun:    actions'
            emit_human "labels:  #{@options[:labels].join(', ')}"
            emit_human "rows:    #{actions.length} of #{total}"
            emit_human "limit:   #{@options[:all] ? '(all)' : effective_limit}"
          end

          # +--all+ passes a very large limit through to the engine,
          # rather than hand-rolling a streaming query. Engine caps
          # internally; the CLI's job is to opt out of its OWN ceiling.
          def effective_limit
            @options[:all] ? 10_000 : @options[:limit]
          end

          def basket_label
            return '(all)' unless @options[:basket_given]
            return '(unbasketed)' if @options[:basket].nil?

            @options[:basket]
          end
        end
      end
    end
  end
end
