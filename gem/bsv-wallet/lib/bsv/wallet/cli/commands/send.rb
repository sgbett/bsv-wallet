# frozen_string_literal: true

require 'json'
require 'securerandom'
require_relative 'base'

module BSV
  module Wallet
    module CLI
      module Commands
        # +bin/wallet send <recipient> <sats>+ — pay outbound.
        #
        # Polymorphic on recipient shape:
        #
        #   send <base58_address> <sats>  # vanilla P2PKH; no envelope output
        #   send <identity_key_hex> <sats>  # BRC-29 derivation; envelope to stdout
        #
        # Per ADR-030, this verb is atomic create+publish. The engine bundles
        # persistence with publication; there is no separate "now broadcast it"
        # step. +--broadcast=inline+ maps to sync ARC dispatch;
        # +--broadcast=async+ to daemon-queued via OMQ hint.
        #
        # Base58 path: decode the address to a pubkey hash, build a P2PKH
        # output, call +engine.build_action+. No envelope — the recipient
        # already knows their key by definition (they generated the address).
        #
        # Identity-key path: generate a per-payment derivation prefix, derive
        # the recipient's public key via BRC-42 (counterparty: identity key,
        # protocol: BRC-29 magic), build the P2PKH output to that key, call
        # +engine.build_action+. Emit a JSON envelope to stdout carrying the
        # BEEF + per-output derivation hints so the recipient can recover the
        # private key.
        #
        # The envelope shape matches the existing porcelain flow (BEEF in hex
        # + flat per-output hint array). A strict-BRC-29-spec format is a
        # follow-up if/when cross-implementation interop matters.
        class Send < Base
          # BRC-29 protocol magic per spec: invoice number is
          # "2-3241645161d8-<prefix> <suffix>". The +derive_public_key+
          # call assembles this via +protocol_id: [2, <prefix>]+ + the
          # BRC-29 magic is implicit in how callers structure +protocol_id+
          # for this codebase. The existing porcelain uses
          # +protocol_id: [2, pay_prefix]+ — pre-Phase-2 convention; keeping
          # it so envelope shape stays interoperable with the existing
          # +bin/receive+ during the transition.
          BRC29_PROTOCOL_LEVEL = 2

          # Suffix is per-UTXO. With a single payment output we use the
          # fixed suffix '1' (matches existing porcelain convention).
          PAYMENT_SUFFIX = '1'

          def name = 'send'

          def build_parser
            @options = {}
            OptionParser.new do |opts|
              opts.banner = 'Usage: bin/wallet send <recipient> <sats> [--broadcast=inline|async] [--description=<text>]'

              opts.on('--broadcast=MODE', %w[inline async],
                      'Broadcast mode: inline (sync ARC) or async (daemon-queued). Default: inline') do |v|
                @options[:broadcast] = v.to_sym
              end

              opts.on('--description=TEXT',
                      "Action description (default: 'cli-send')") do |v|
                @options[:description] = v
              end
            end
          end

          def call(args)
            parser.parse!(args)
            recipient, sats_arg = args
            raise UsageError, 'send requires <recipient> <sats>' if recipient.nil? || sats_arg.nil?

            sats = parse_satoshis(sats_arg)
            kind = detect_recipient_kind(recipient)

            engine = @ctx[:engine]
            accept_delayed = @options[:broadcast] == :async
            description = @options[:description] || 'cli-send'

            case kind
            when :base58
              call_base58(engine, recipient, sats, description, accept_delayed)
            when :identity_key
              call_identity_key(engine, recipient, sats, description, accept_delayed)
            end
            0
          end

          private

          # Recipient shape detection. Pubkey identity keys are 66-char hex
          # starting +02+/+03+; addresses are Base58Check (26-35 chars,
          # Base58 alphabet, +1+/+3+/+m+/+n+ leading char). The shapes
          # don't overlap.
          def detect_recipient_kind(recipient)
            return :identity_key if recipient.match?(/\A(02|03)[0-9a-fA-F]{64}\z/)
            return :base58 if recipient.match?(/\A[mn123][1-9A-HJ-NP-Za-km-z]{25,34}\z/)

            raise UsageError,
                  "send recipient #{recipient.inspect} not recognised " \
                  '(expected Base58 P2PKH address or 66-char hex identity key)'
          end

          def parse_satoshis(arg)
            sats = Integer(arg, 10)
            raise UsageError, "send sats must be > 0 (got #{sats})" if sats <= 0

            sats
          rescue ArgumentError
            raise UsageError, "send sats must be an integer (got #{arg.inspect})"
          end

          # Base58 path. Decode address, build P2PKH, build_action with no
          # derivation hints (engine marks the output 'outbound' per the
          # +build_output_specs+ default). No envelope on stdout — the
          # recipient is presumed to control the address-resolved key
          # already and finds the output by chain scan.
          def call_base58(engine, address, sats, description, accept_delayed)
            # Base58Check decode → 21-byte payload (version byte + 20-byte
            # pubkey hash). Slice off the version; build P2PKH from the
            # hash. Version byte not validated here — the regex already
            # constrained the leading character to mainnet/testnet P2PKH
            # prefixes; a fuller version-byte allowlist is a follow-up
            # when we model network-aware sends.
            pubkey_hash = BSV::Primitives::Base58.check_decode(address)[1..]
            locking_script = BSV::Script::Script.p2pkh_lock(pubkey_hash).to_binary

            result = engine.build_action(
              description: description,
              outputs: [
                { satoshis: sats, locking_script: locking_script,
                  output_description: 'payment' }
              ],
              accept_delayed_broadcast: accept_delayed,
              no_send: false,
              randomize_outputs: false
            )

            dtxid = result[:wtxid].reverse.unpack1('H*')
            emit_human 'kind:     base58'
            emit_human "to:       #{address}"
            emit_human "sats:     #{sats}"
            emit_human "broadcast: #{accept_delayed ? 'async (queued)' : 'inline (sync)'}"
            emit_human "dtxid:    #{dtxid}"
          end

          # Identity-key path. Generate derivation prefix, derive
          # recipient's pubkey via BRC-42 with BRC-29 protocol level, build
          # P2PKH to derived key, +build_action+. Emit JSON envelope to
          # stdout with BEEF + hints so recipient can recover the key.
          def call_identity_key(engine, identity_key, sats, description, accept_delayed)
            key_deriver = @ctx[:key_deriver]
            sender_identity_key = @ctx[:identity_key]

            prefix = BSV::Wallet.random_derivation
            derived_pub = key_deriver.derive_public_key(
              protocol_id: [BRC29_PROTOCOL_LEVEL, prefix],
              key_id: PAYMENT_SUFFIX,
              counterparty: identity_key,
              for_self: true
            )
            locking_script = BSV::Script::Script.p2pkh_lock(
              BSV::Primitives::Digest.hash160(derived_pub)
            ).to_binary

            result = engine.build_action(
              description: description,
              outputs: [
                { satoshis: sats,
                  locking_script: locking_script,
                  derivation_prefix: prefix,
                  derivation_suffix: PAYMENT_SUFFIX,
                  sender_identity_key: sender_identity_key,
                  output_description: 'BRC-29 payment' }
              ],
              accept_delayed_broadcast: accept_delayed,
              no_send: false,
              randomize_outputs: false
            )

            envelope = {
              beef: result[:atomic_beef].unpack1('H*'),
              sender_identity_key: sender_identity_key,
              outputs: [
                { vout: 0, satoshis: sats,
                  derivation_prefix: prefix,
                  derivation_suffix: PAYMENT_SUFFIX }
              ]
            }
            # +redact: false+ — derivation_prefix/suffix are the WHOLE
            # POINT of the envelope; the recipient needs them to recover
            # the key. Default-redact would defeat the BRC-29 protocol.
            emit_json envelope, redact: false

            dtxid = result[:wtxid].reverse.unpack1('H*')
            emit_human 'kind:     identity-key (BRC-29)'
            emit_human "to:       #{identity_key[0..15]}..."
            emit_human "sats:     #{sats}"
            emit_human "broadcast: #{accept_delayed ? 'async (queued)' : 'inline (sync)'}"
            emit_human "dtxid:    #{dtxid}"
            emit_human 'envelope: emitted on stdout for recipient'
          end
        end
      end
    end
  end
end
