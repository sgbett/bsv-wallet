# frozen_string_literal: true

require_relative 'base'

module BSV
  module Wallet
    module CLI
      module Commands
        # +bin/wallet consolidate [--target-inputs=N]+ — merge the N
        # smallest spendable outputs into one larger output.
        #
        # Reduces wallet UTXO count without changing total balance.
        # Useful before high-throughput operations (e.g. before a
        # fragmentation run, or to clean up after one). Stays in the
        # wallet's spendable pool — different from +sweep+, which
        # exits funds to a recipient key.
        #
        # Engine picks +N+ smallest + 1 largest (dedupe-aware) as inputs,
        # produces 1 change output. Minimum +N+ is 2 (need at least two
        # outputs to consolidate); default 20.
        #
        # Returns +nil+ from engine when the pool has fewer than +N+
        # spendable outputs — reported here as "pool too small" without
        # an error, since wanting to consolidate an under-sized pool
        # isn't a failure, just a no-op.
        class Consolidate < Base
          MIN_TARGET_INPUTS = 2
          DEFAULT_TARGET_INPUTS = 20

          def name = 'consolidate'

          def build_parser
            @options = {}
            OptionParser.new do |opts|
              opts.banner = 'Usage: bin/wallet consolidate [--target-inputs=N] [--no-send] ' \
                            "(default N=#{DEFAULT_TARGET_INPUTS}, min #{MIN_TARGET_INPUTS})"

              opts.on('--target-inputs=N', Integer,
                      "Number of smallest UTXOs to merge (default #{DEFAULT_TARGET_INPUTS}, min #{MIN_TARGET_INPUTS})") do |v|
                @options[:target_inputs] = v
              end

              opts.on('--no-send',
                      "Build + sign the consolidating action but don't submit it") do
                @options[:no_send] = true
              end
            end
          end

          def call(args)
            parser.parse!(args)
            raise UsageError, "consolidate takes no positional arguments (got #{args.length})" unless args.empty?

            target_inputs = @options[:target_inputs] || DEFAULT_TARGET_INPUTS
            if target_inputs < MIN_TARGET_INPUTS
              raise UsageError,
                    "consolidate --target-inputs must be >= #{MIN_TARGET_INPUTS} (got #{target_inputs})"
            end

            no_send = @options[:no_send] || false
            engine = @ctx[:engine]
            result = engine.consolidate_step(
              target_inputs: target_inputs,
              no_send: no_send,
              accept_delayed_broadcast: !no_send
            )

            if result.nil?
              emit_human "consolidate: pool too small (need #{target_inputs}+ spendable outputs)"
              return 0
            end

            dtxid = result[:wtxid].reverse.unpack1('H*')
            emit_human "consolidate:  #{target_inputs} inputs → 1 output"
            emit_human "no_send:      #{no_send ? 'yes' : 'no'}"
            emit_human "dtxid:        #{dtxid}"
            0
          end
        end
      end
    end
  end
end
