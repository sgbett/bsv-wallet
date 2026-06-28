# frozen_string_literal: true

require 'json'
require_relative 'base'

module BSV
  module Wallet
    module CLI
      module Commands
        # +bin/wallet send <recipient> <sats>+ — pay outbound.
        #
        # Polymorphic on recipient shape:
        #
        #   send <base58_address> <sats>    # P2PKH; no envelope output
        #   send <identity_key_hex> <sats>  # BRC-29 derivation; envelope on stdout
        #
        # Broadcast modes (+--broadcast=MODE+):
        #
        #   inline (default) — sync ARC dispatch
        #   async            — daemon-queued via OMQ hint
        #   none             — no broadcast; action committed, BEEF emitted
        #                      (identity-key path) for peer-to-peer handoff
        #
        # The +none+ mode uses the engine's +no_send: true+ path. The action
        # is still fully persisted in one atomic step — stays consistent with
        # ADR-030 (no cross-CLI intermediate state).
        #
        # Identity-key envelope carries the BEEF, the subject dtxid, the
        # sender identity key, and per-output BRC-29 derivation hints (the
        # recipient needs them to recover the derived private key).
        # Envelope shape is wallet-internal; strict-BRC-29 alignment in #460.
        class Send < Base
          # Wallet-internal payment derivation convention, shared with
          # engine.rb + tx_builder.rb pay-side and receive-side:
          # +protocol_id: [LEVEL, prefix]+, +key_id: SUFFIX+. Internal
          # round-trip works (send here pairs with receive's envelope
          # path). NOT strict BRC-29: the spec mandates
          # +protocol_id: [2, '3241645161d8']+, +key_id: "<prefix> <suffix>"+
          # — wallet-wide alignment tracked in HLR #460.
          BRC29_PROTOCOL_LEVEL = 2
          PAYMENT_SUFFIX = '1'

          # P2PKH address version bytes: mainnet 0x00, testnet 0x6f.
          # P2SH addresses (0x05 mainnet, 0xc4 testnet) are explicitly
          # rejected — Phase 2 only supports P2PKH, and building a P2PKH
          # lock to a P2SH address's embedded hash would create an
          # unspendable output.
          P2PKH_VERSION_BYTES = [0x00, 0x6f].freeze

          # Base58Check P2PKH payload: 1 version byte + 20-byte pubkey hash.
          P2PKH_PAYLOAD_BYTES = 21

          def name = 'send'

          def build_parser
            @options = {}
            OptionParser.new do |opts|
              opts.banner = 'Usage: bin/wallet send <recipient> <sats> [--broadcast=inline|async|none] [--description=<text>]'

              opts.on('--broadcast=MODE', %w[inline async none],
                      'Broadcast mode: inline (sync ARC), async (daemon-queued), or none (commit only). Default: inline') do |v|
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
            no_send = @options[:broadcast] == :none
            description = @options[:description] || 'cli-send'

            case kind
            when :base58
              call_base58(engine, recipient, sats, description, accept_delayed, no_send)
            when :identity_key
              call_identity_key(engine, recipient, sats, description, accept_delayed, no_send)
            end
            0
          end

          BROADCAST_LABELS = {
            async: 'async (queued)',
            none: 'none (no broadcast)',
            inline: 'inline (sync)'
          }.freeze
          private_constant :BROADCAST_LABELS

          private

          # Recipient shape detection. Pubkey identity keys are 66-char hex
          # starting +02+/+03+; P2PKH addresses are Base58Check (26-35 chars,
          # Base58 alphabet, +1+ mainnet / +m+/+n+ testnet leading char).
          # P2SH prefixes ('2'/'3') deliberately excluded — they pass the
          # length+alphabet test but version-byte validation in
          # +decode_base58_p2pkh!+ catches them as a second line of defence.
          def detect_recipient_kind(recipient)
            return :identity_key if recipient.match?(/\A(02|03)[0-9a-fA-F]{64}\z/)
            return :base58 if recipient.match?(/\A[mn1][1-9A-HJ-NP-Za-km-z]{25,34}\z/)

            raise UsageError,
                  "send recipient #{safe_preview(recipient)} not recognised " \
                  '(expected mainnet/testnet P2PKH Base58 address or 66-char hex identity key)'
          end

          def parse_satoshis(arg)
            sats = Integer(arg, 10)
            raise UsageError, "send sats must be > 0 (got #{sats})" if sats <= 0

            sats
          rescue ArgumentError
            raise UsageError, "send sats must be an integer (got #{arg.inspect})"
          end

          # Base58Check decode + version-byte validation. Returns the
          # 20-byte pubkey hash. Three failure modes mapped to UsageError:
          # invalid checksum/encoding (raised by check_decode), wrong
          # payload length (a checksum-valid but non-standard Base58Check
          # could be any byte length; without this check, an empty payload
          # would TypeError on +format('%02x', nil)+ and an oversized
          # payload would build a malformed P2PKH lock with the wrong
          # hash length — misdirecting funds), and non-P2PKH version
          # bytes (P2SH 0x05/0xc4 would otherwise produce an unspendable
          # P2PKH lock).
          def decode_base58_p2pkh!(address)
            payload =
              begin
                BSV::Primitives::Base58.check_decode(address)
              rescue StandardError => e
                # SDK raises +BSV::Primitives::Base58::ChecksumError+ on
                # checksum mismatch and +ArgumentError+ on non-Base58
                # input. Either is operator error; both translate to the
                # same UsageError message.
                raise UsageError, "send recipient #{address.inspect}: #{e.message}"
              end

            unless payload.bytesize == P2PKH_PAYLOAD_BYTES
              raise UsageError,
                    "send recipient #{address.inspect} decoded to #{payload.bytesize}-byte payload " \
                    "(P2PKH requires exactly #{P2PKH_PAYLOAD_BYTES} bytes: 1 version + 20 pubkey-hash)"
            end

            version = payload.bytes.first
            unless P2PKH_VERSION_BYTES.include?(version)
              raise UsageError,
                    "send recipient #{address.inspect} has version byte " \
                    "0x#{format('%02x', version)} — only P2PKH addresses " \
                    '(mainnet 0x00, testnet 0x6f) are supported (Phase 2)'
            end

            payload[1..]
          end

          # No envelope on stdout — the recipient controls the
          # address-resolved key already and finds the output by chain scan.
          def call_base58(engine, address, sats, description, accept_delayed, no_send)
            pubkey_hash = decode_base58_p2pkh!(address)
            locking_script = BSV::Script::Script.p2pkh_lock(pubkey_hash).to_binary

            # +spendable_intent: 'none'+ marks the output as the recipient's,
            # not ours (HLR #467 / +intent-and-outcomes.md+): an outbound
            # payment the wallet must not insert into its UTXO set. Intent
            # is stated explicitly — no inference from the absence of
            # derivation fields. Change outputs (added by
            # +TxBuilder#build_change+) carry +'spendable'+ at their own
            # construction site.
            result = engine.build_action(
              description: description,
              outputs: [
                { satoshis: sats, locking_script: locking_script,
                  spendable_intent: 'none',
                  output_description: 'payment' }
              ],
              accept_delayed_broadcast: accept_delayed,
              no_send: no_send,
              randomize_outputs: false
            )

            dtxid = result[:wtxid].reverse.unpack1('H*')
            emit_human 'kind:     base58'
            emit_human "to:       #{address}"
            emit_human "sats:     #{sats}"
            emit_human "broadcast: #{BROADCAST_LABELS[broadcast_mode(accept_delayed, no_send)]}"
            emit_human "dtxid:    #{dtxid}"
          end

          def call_identity_key(engine, identity_key, sats, description, accept_delayed, no_send)
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

            # +spendable_intent: 'none'+ — outbound BRC-29 payment to the
            # counterparty; the derivation triple is recipient-side material
            # the recipient needs to reconstruct the spending key, not a
            # signal that the wallet owns the output (HLR #467 /
            # +intent-and-outcomes.md+). Derivation columns are retained as
            # provenance and are harmless under the new structural CHECK.
            result = engine.build_action(
              description: description,
              outputs: [
                { satoshis: sats,
                  locking_script: locking_script,
                  spendable_intent: 'none',
                  derivation_prefix: prefix,
                  derivation_suffix: PAYMENT_SUFFIX,
                  sender_identity_key: sender_identity_key,
                  output_description: 'BRC-29 payment' }
              ],
              accept_delayed_broadcast: accept_delayed,
              no_send: no_send,
              randomize_outputs: false
            )

            dtxid = result[:wtxid].reverse.unpack1('H*')

            envelope = {
              beef: result[:atomic_beef].unpack1('H*'),
              dtxid: dtxid,
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

            emit_human 'kind:     identity-key (BRC-29)'
            emit_human "to:       #{identity_key[0..15]}..."
            emit_human "sats:     #{sats}"
            emit_human "broadcast: #{BROADCAST_LABELS[broadcast_mode(accept_delayed, no_send)]}"
            emit_human "dtxid:    #{dtxid}"
            emit_human 'envelope: emitted on stdout for recipient'
          end

          def broadcast_mode(accept_delayed, no_send)
            return :none if no_send
            return :async if accept_delayed

            :inline
          end
        end
      end
    end
  end
end
