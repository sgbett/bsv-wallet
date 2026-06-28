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
        # Broadcast mode: default is +:delayed+ (queue for daemon via OMQ,
        # batching multi-UTXO scans to avoid an N+1 ARC round-trip per
        # discovered UTXO). +--inline+ opts into synchronous per-UTXO
        # broadcast (useful for small wallets wanting immediate
        # confirmation, or e2e tests that need to see status before the
        # next step). +--inline+ and +--no-send+ are mutually exclusive
        # — they select different broadcast strategies, not modifiers.
        #
        # Phase 3 scans the root P2PKH address only. HD/WBIKD-derived
        # receive addresses (#28 / future) would extend the scan
        # surface; engine support for that scanning is downstream.
        class Import < Base
          def name = 'import'

          def build_parser
            @options = {}
            OptionParser.new do |opts|
              opts.banner = 'Usage: bin/wallet import [--basket=<name>] [--inline|--no-send] [--include-unconfirmed]'

              opts.on('--basket=NAME',
                      'Route imported outputs into a named basket (excluded from auto-fund pool)') do |v|
                @options[:basket] = v
              end

              opts.on('--inline',
                      'Force synchronous per-UTXO broadcast (default: queue for daemon)') do
                @options[:inline] = true
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

            # Validate +--basket+ against the schema's DB CHECK rules
            # (length, charset, no consecutive spaces). Without this,
            # invalid names reach +import_utxo+ → +find_or_create_basket+
            # and surface as +Sequel::CheckConstraintViolation+ outside
            # the dispatcher's rescue chain. The empty-string case is
            # the most common operator confusion ("I just want
            # unbasketed") — caught explicitly so the message can point
            # at the right alternative.
            basket = @options[:basket]
            if basket.is_a?(String) && basket.empty?
              raise UsageError,
                    '--basket=<name> must be non-empty ' \
                    '(omit --basket entirely for the unbasketed pool)'
            end
            validate_basket!(basket) if basket

            no_send = @options[:no_send] || false
            inline = @options[:inline] || false
            if no_send && inline
              raise UsageError,
                    'import: --no-send and --inline are mutually exclusive ' \
                    '(they select different broadcast strategies)'
            end

            engine = @ctx[:engine]
            result = engine.import_wallet(
              basket: basket,
              no_send: no_send,
              # +!inline+ collapses cleanly: default (neither flag) →
              # +true+ (daemon-queued); +--inline+ → +false+ (sync ARC).
              # When +no_send: true+, the engine ignores this — but the
              # mutual-exclusion guard above means we never reach that
              # combination anyway.
              accept_delayed_broadcast: !inline,
              include_unconfirmed: @options[:include_unconfirmed] || false
            )

            count = result[:imported] || 0
            broadcast_mode =
              if no_send then 'no_send'
              elsif inline then 'inline (sync ARC)'
              else 'delayed (queued)'
              end

            emit_human "imported:    #{count} UTXO#{'s' unless count == 1}"
            emit_human "basket:      #{basket || '(unbasketed pool)'}"
            emit_human "broadcast:   #{broadcast_mode}"
            emit_human "include unconfirmed: #{@options[:include_unconfirmed] ? 'yes' : 'no'}"
            0
          end
        end
      end
    end
  end
end
