# frozen_string_literal: true

require_relative 'base'

module BSV
  module Wallet
    module CLI
      module Commands
        # +bin/wallet sweep --to=<root_key_hex>+ — drain every spendable
        # output back to the recipient's root P2PKH address.
        #
        # Blank-slate operational tool. Locks a single caller output to
        # the recipient's *root* P2PKH (literal +hash160(recipient_pubkey)+,
        # NOT a BRC-42-derived address), so the receiving wallet's DB can
        # be wiped and re-imported by scanning the root address with
        # +bin/wallet import+. Any rounding surplus against the actual
        # fee is dropped on the funding loop's change-key slot.
        #
        # +--to+ takes the recipient's 66-char compressed pubkey hex
        # (02/03 prefix); the engine's +validate_recipient_key!+ is a
        # second line of defence after CLI-side +parse_pubkey_hex+.
        # +--no-send+ keeps the swept action unsubmitted (build + sign
        # + return BEEF for handoff without publishing).
        #
        # Empty-pool case (engine returns nil) is reported as "nothing
        # to sweep" without an error — sweeping an empty wallet is a
        # no-op, not a failure. Dust-only wallet (fee exceeds total)
        # raises +InsufficientFundsError+ → exit 1 with the engine's
        # message.
        class Sweep < Base
          def name = 'sweep'

          def build_parser
            @options = {}
            OptionParser.new do |opts|
              opts.banner = 'Usage: bin/wallet sweep --to=<root_key_hex> [--no-send]'

              opts.on('--to=ROOT_KEY_HEX',
                      "Recipient's 66-char compressed pubkey hex (02/03 prefix)") do |v|
                @options[:to] = v
              end

              opts.on('--no-send',
                      "Build + sign the swept action but don't submit it") do
                @options[:no_send] = true
              end
            end
          end

          def call(args)
            parser.parse!(args)
            raise UsageError, "sweep takes no positional arguments (got #{args.inspect})" unless args.empty?

            recipient = @options[:to]
            raise UsageError, 'sweep requires --to=<root_key_hex> (66-char compressed pubkey starting 02/03)' if recipient.nil? || recipient.empty?

            parse_pubkey_hex(recipient)

            no_send = @options[:no_send] || false
            engine = @ctx[:engine]
            result = engine.sweep(
              recipient: recipient,
              no_send: no_send,
              accept_delayed_broadcast: !no_send
            )

            if result.nil?
              emit_human 'sweep:    no spendable outputs (nothing to sweep)'
              return 0
            end

            dtxid = result[:wtxid].reverse.unpack1('H*')
            emit_human "swept to: #{recipient[0..15]}..."
            emit_human "no_send:  #{no_send ? 'yes' : 'no'}"
            emit_human "dtxid:    #{dtxid}"
            0
          end
        end
      end
    end
  end
end
