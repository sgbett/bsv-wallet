# frozen_string_literal: true

require_relative 'base'

module BSV
  module Wallet
    module CLI
      module Commands
        # +bin/wallet balance+ — total satoshis across spendable outputs.
        #
        #   balance                        # scalar across all baskets
        #   balance --basket=<name>        # scalar in named basket
        #   balance --basket=none          # scalar in unbasketed pool
        #   balance --outputs              # shortcut for +list outputs+
        #                                  # (prints rows instead of scalar)
        #
        # Routes +engine.spendable_outputs+ directly — the native
        # surface bypasses BRC-100 wrapper semantics (basket-required,
        # change-pool ambiguity). Scalar mode prints the total to
        # stdout; human-readable summary (identity, basket label, count)
        # goes to stderr.
        class Balance < Base
          def name = 'balance'

          def build_parser
            @options = { outputs: false }
            OptionParser.new do |opts|
              opts.banner = 'Usage: bin/wallet balance [--basket=<name>|none] [--outputs]'

              opts.on('--basket=NAME',
                      'Basket filter (omit for all, "none" for unbasketed)') do |v|
                @options[:basket] = v == 'none' ? nil : v
                @options[:basket_given] = true
              end

              opts.on('--outputs',
                      'List individual outputs instead of just the total') do
                @options[:outputs] = true
              end
            end
          end

          def call(args)
            parser.parse!(args)
            engine = @ctx[:engine]

            if @options[:outputs]
              call_outputs(engine)
            else
              call_scalar(engine)
            end
            0
          end

          private

          # Scalar path: prints the satoshi sum to stdout. Human summary
          # to stderr.
          def call_scalar(engine)
            sum_args = aggregate_args(:sum)
            count_args = aggregate_args(:count)

            total = engine.spendable_outputs(**sum_args)
            count = engine.spendable_outputs(**count_args)

            $stdout.puts total

            emit_human "wallet:   #{@global_options.wallet_name || '(default)'}"
            emit_human "identity: #{@ctx[:identity_key]}"
            emit_human "basket:   #{basket_label}"
            emit_human "outputs:  #{count}"
            emit_human "balance:  #{total} sats"
          end

          # +--outputs+ path: same as +list outputs+ — full result set,
          # NDJSON when piped/forced, table-ish summary when interactive.
          def call_outputs(engine)
            list_args = aggregate_args(nil).merge(limit: 100)
            result = engine.spendable_outputs(**list_args)
            outputs = result.is_a?(Hash) ? (result[:outputs] || []) : []

            outputs.each { |o| emit_ndjson_row(o) }

            emit_human "wallet:   #{@global_options.wallet_name || '(default)'}"
            emit_human "basket:   #{basket_label}"
            emit_human "outputs:  #{outputs.length} (limit=100; use `list outputs --all` to raise the cap to 10000 — engine clamps there)"
          end

          # Build the aggregate kwargs Hash. Only includes +basket:+ when
          # the flag was explicitly given, so +Engine#spendable_outputs+
          # uses its +BASKET_UNSPECIFIED+ default for the no-filter case.
          def aggregate_args(aggregate)
            args = aggregate ? { aggregate: aggregate } : {}
            args[:basket] = @options[:basket] if @options[:basket_given]
            args
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
