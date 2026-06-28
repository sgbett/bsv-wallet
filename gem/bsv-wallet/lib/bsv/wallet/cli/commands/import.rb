# frozen_string_literal: true

require_relative 'base'

module BSV
  module Wallet
    module CLI
      module Commands
        # +bin/wallet import+ — scan the wallet's root P2PKH address for
        # untracked on-chain UTXOs and internalise them via self-payment.
        #
        # Phase 3 sister of +bin/wallet receive+: receive accepts a BEEF
        # or BRC-29 envelope (push); import scans the address (pull).
        # Both ultimately go through +engine.import_utxo+ per UTXO; the
        # +basket:+ kwarg threads through to the same basket-routing
        # mechanism HLR #436 added for pinpoint import.
        #
        # +--basket=<name>+ routes imported funds into a named basket
        # (excluded from auto-funding by HLR #435's basket filter).
        # +--include-unconfirmed+ scans mempool UTXOs too (default: only
        # confirmed). +--no-send+ keeps the internalising self-payment
        # built-and-signed but unsubmitted.
        #
        # Phase 3 scans the root P2PKH address only. HD/WBIKD-derived
        # receive addresses (#28 / future) would extend the scan
        # surface; engine support for that scanning is downstream.
        class Import < Base
          def name = 'import'

          def build_parser
            @options = {}
            OptionParser.new do |opts|
              opts.banner = 'Usage: bin/wallet import [--basket=<name>] [--no-send] [--include-unconfirmed]'

              opts.on('--basket=NAME',
                      'Route imported outputs into a named basket (excluded from auto-fund pool)') do |v|
                @options[:basket] = v
              end

              opts.on('--no-send',
                      "Build the internalising self-payment but don't submit it") do
                @options[:no_send] = true
              end

              opts.on('--include-unconfirmed',
                      'Include mempool (unconfirmed) UTXOs in the scan') do
                @options[:include_unconfirmed] = true
              end
            end
          end

          def call(args)
            parser.parse!(args)
            raise UsageError, "import takes no positional arguments (got #{args.length})" unless args.empty?

            engine = @ctx[:engine]
            result = engine.import_wallet(
              basket: @options[:basket],
              no_send: @options[:no_send] || false,
              include_unconfirmed: @options[:include_unconfirmed] || false
            )

            count = result[:imported] || 0
            emit_human "imported:    #{count} UTXO#{'s' unless count == 1}"
            emit_human "basket:      #{@options[:basket] || '(unbasketed pool)'}"
            emit_human "include unconfirmed: #{@options[:include_unconfirmed] ? 'yes' : 'no'}"
            emit_human "no_send:     #{@options[:no_send] ? 'yes' : 'no'}"
            0
          end
        end
      end
    end
  end
end
