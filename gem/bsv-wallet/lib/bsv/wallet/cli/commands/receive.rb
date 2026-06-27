# frozen_string_literal: true

require 'json'
require_relative 'base'

module BSV
  module Wallet
    module CLI
      module Commands
        # +bin/wallet receive+ — accept inbound.
        #
        # Auto-detects input format from +--file=<path>+ or stdin:
        #
        #   raw BEEF                       # scan tx outputs for P2PKH to root key; import matches
        #   BRC-29 envelope (JSON)         # consume per-output derivation hints; import via wallet-payment protocol
        #
        # Raw BEEF path: the wallet doesn't know in advance which outputs
        # belong to it. Parses the subject tx, walks each output, checks if
        # its P2PKH lock targets the wallet's root key's address. Matches
        # are imported via +engine.import_beef+ with the +basket insertion+
        # protocol and no derivation hints (engine marks them +root+ per
        # the schema's output_type semantics). Phase 2 scans the root
        # address only; HD/WBIKD-derived receive addresses are a follow-up.
        #
        # Envelope path: the sender shipped explicit derivation hints. Each
        # listed output gets imported via +engine.import_beef+ with the
        # +wallet payment+ or +basket insertion+ protocol carrying the
        # +derivation_prefix+ / +derivation_suffix+ / +sender_identity_key+
        # in the appropriate remittance object. +--basket=<name>+ applies
        # to envelope outputs only where the envelope itself omits a
        # basket — silent override of the sender's intent requires
        # +--force-basket+.
        class Receive < Base
          MAX_INPUT_BYTES = 32 * 1024 * 1024 # 32 MiB hard refusal

          def name = 'receive'

          def build_parser
            @options = {}
            OptionParser.new do |opts|
              opts.banner = 'Usage: bin/wallet receive [--file=<path>] [--basket=<name>] [--description=<text>] [--force-basket]'

              opts.on('--file=PATH', 'Read input from file (default: stdin)') do |v|
                @options[:file] = v
              end

              opts.on('--basket=NAME',
                      'Basket assignment for incoming outputs (envelope: only where omitted; --force-basket to override)') do |v|
                @options[:basket] = v
              end

              opts.on('--force-basket',
                      'Override envelope-supplied basket assignments') do
                @options[:force_basket] = true
              end

              opts.on('--description=TEXT',
                      "Action description (default: 'cli-receive')") do |v|
                @options[:description] = v
              end
            end
          end

          def call(args)
            parser.parse!(args)
            input_bytes = read_input
            raise UsageError, 'receive input is empty (pipe BEEF bytes or use --file=<path>)' if input_bytes.empty?

            kind = detect_input_kind(input_bytes)
            engine = @ctx[:engine]
            description = @options[:description] || 'cli-receive'

            case kind
            when :envelope
              call_envelope(engine, parse_envelope_json!(input_bytes), description)
            when :raw_beef
              call_raw_beef(engine, input_bytes, description)
            end
            0
          end

          private

          # Read input from +--file+ or stdin, applying the size cap.
          # Binmode throughout — BEEF is raw bytes.
          def read_input
            bytes = read_binary_input(file: @options[:file])
            if bytes.bytesize > MAX_INPUT_BYTES
              raise UsageError,
                    "receive input exceeds #{MAX_INPUT_BYTES / (1024 * 1024)} MiB cap (got #{bytes.bytesize} bytes)"
            end
            bytes
          end

          # Distinguish BRC-29 envelope JSON from raw BEEF bytes. JSON
          # always starts with whitespace or +{+; BEEF begins with a
          # specific 4-byte magic (BRC-62 / BRC-95). A first-byte check is
          # cheap and unambiguous.
          def detect_input_kind(bytes)
            trimmed = bytes.lstrip
            return :envelope if trimmed.start_with?('{')

            :raw_beef
          end

          # Envelope path: parse derivation hints from the JSON, build
          # +engine.import_beef+ output specs with appropriate remittance.
          def call_envelope(engine, envelope, description)
            beef_hex = envelope[:beef]
            raise UsageError, 'envelope missing "beef" field' if beef_hex.nil? || beef_hex.empty?

            sender_identity_key = envelope[:sender_identity_key]
            pay_outputs = envelope[:outputs] || []
            raise UsageError, 'envelope missing "outputs" array' if pay_outputs.empty?

            beef_bytes = decode_hex_field!(beef_hex, field: 'envelope "beef"')

            output_specs = pay_outputs.map.with_index do |out, idx|
              vout = out[:vout]
              unless vout.is_a?(Integer) && vout >= 0
                raise UsageError,
                      "envelope output [#{idx}] missing or invalid \"vout\" " \
                      '(must be a non-negative integer; engine-side default-to-zero ' \
                      'could silently target the wrong output)'
              end

              {
                output_index: vout,
                protocol: 'basket insertion',
                insertion_remittance: {
                  basket: effective_basket(envelope_basket: out[:basket]),
                  derivation_prefix: out[:derivation_prefix],
                  derivation_suffix: out[:derivation_suffix],
                  sender_identity_key: sender_identity_key
                }
              }
            end

            engine.import_beef(
              tx: beef_bytes, outputs: output_specs,
              description: description, labels: ['cli-receive']
            )

            emit_human 'kind:        envelope (BRC-29)'
            emit_human "sender:      #{sender_identity_key&.[](0..15)}..."
            emit_human "outputs:     #{pay_outputs.length}"
            emit_human "total sats:  #{pay_outputs.sum { |o| o[:satoshis] || 0 }}"
            emit_human "basket:      #{output_specs.first[:insertion_remittance][:basket] || '(unbasketed)'}"
          end

          # Raw BEEF path: parse, scan outputs for P2PKH locks to wallet's
          # root address, import matches as basket insertion with no
          # derivation hints (engine marks them root via the output_type
          # shim). Accepts either binary BEEF or its hex-string encoding
          # (the latter is shell-pipe-friendly; binary in pipes is fiddly
          # with locale/encoding pitfalls).
          def call_raw_beef(engine, beef_bytes, description)
            beef_bytes = decode_hex_if_hex(beef_bytes)
            subject_tx = parse_beef_subject(beef_bytes)

            key_deriver = @ctx[:key_deriver]
            root_pubkey_hash = BSV::Primitives::Digest.hash160(
              key_deriver.root_private_key.public_key.compressed
            )

            matches = scan_outputs_for_pubkey_hash(subject_tx, root_pubkey_hash)

            if matches.empty?
              emit_human 'kind:    raw BEEF'
              emit_human "result:  no outputs matching wallet's root address"
              return
            end

            output_specs = matches.map do |idx|
              {
                output_index: idx,
                protocol: 'basket insertion',
                insertion_remittance: {
                  basket: @options[:basket]
                }
              }
            end

            engine.import_beef(
              tx: beef_bytes, outputs: output_specs,
              description: description, labels: ['cli-receive']
            )

            total = matches.sum { |idx| subject_tx.outputs[idx].satoshis }
            emit_human 'kind:        raw BEEF'
            emit_human "outputs:     #{matches.length} (vouts: #{matches.join(', ')})"
            emit_human "total sats:  #{total}"
            emit_human "basket:      #{@options[:basket] || '(unbasketed)'}"
          end

          # Parse a BEEF (binary) and return the subject Tx. The subject
          # tx is the last one in the BEEF per BRC-62. Two failure modes
          # both map to UsageError: parser exceptions (truncated input,
          # bad magic, unsupported version) and parser-tolerated but
          # empty BEEF (parses cleanly with zero txs — the SDK doesn't
          # treat that as an error, but downstream callers would crash
          # on the nil subject).
          def parse_beef_subject(beef_bytes)
            beef = BSV::Transaction::Beef.from_binary(beef_bytes)
            subject = beef.txs.last
            raise UsageError, 'receive input is not valid BEEF: empty (zero transactions)' if subject.nil?

            subject
          rescue UsageError
            raise
          rescue StandardError => e
            raise UsageError, "receive input is not valid BEEF: #{e.message}"
          end

          # Parse JSON envelope input. JSON::ParserError is not a
          # CLI::Error / Wallet::Error / OptionParser::ParseError, so
          # the dispatcher's rescue chain wouldn't catch it — would
          # surface as an uncaught stack trace. Wrap to UsageError.
          def parse_envelope_json!(bytes)
            JSON.parse(bytes, symbolize_names: true)
          rescue JSON::ParserError => e
            raise UsageError, "receive envelope is not valid JSON: #{e.message}"
          end

          # Validate + decode a required hex-string field. Bare
          # +pack('H*')+ silently truncates on non-hex chars or odd
          # length, which would either crash deeper down or pass
          # unexpected bytes to the engine.
          def decode_hex_field!(value, field:)
            unless value.is_a?(String) && !value.empty? && value.bytesize.even? && value.match?(/\A[0-9a-fA-F]+\z/)
              raise UsageError,
                    "#{field} is not valid hex (must be a non-empty even-length " \
                    'string of [0-9a-fA-F])'
            end
            [value].pack('H*')
          end

          # Auto-detect binary BEEF vs hex-encoded BEEF. Hex form is
          # identifiable by being all-ASCII hex characters with even
          # length; binary BEEF contains non-hex bytes within its first
          # few bytes (BRC-62 version magic includes high bits and nulls).
          # The collision risk — binary BEEF whose every byte happens to
          # be an ASCII hex char — is astronomically small.
          def decode_hex_if_hex(bytes)
            trimmed = bytes.strip
            return [trimmed].pack('H*') if trimmed.bytesize.even? && trimmed.match?(/\A[0-9a-fA-F]+\z/)

            bytes
          end

          # Walk subject tx outputs, return the vouts whose locking script
          # is a standard P2PKH paying to the supplied pubkey hash.
          def scan_outputs_for_pubkey_hash(tx, pubkey_hash)
            tx.outputs.each_with_index.filter_map do |output, idx|
              extracted = extract_p2pkh_hash(output.locking_script)
              idx if extracted && extracted == pubkey_hash
            end
          end

          # If the locking script is a standard P2PKH
          # (+OP_DUP OP_HASH160 <20-byte hash> OP_EQUALVERIFY OP_CHECKSIG+,
          # 25 bytes total), return the 20-byte pubkey hash. Otherwise nil.
          def extract_p2pkh_hash(script)
            bytes = script.respond_to?(:to_binary) ? script.to_binary : script.to_s
            return nil unless bytes.bytesize == 25

            return nil unless bytes[0..2].bytes == [0x76, 0xa9, 0x14]
            return nil unless bytes[23..24].bytes == [0x88, 0xac]

            bytes[3..22]
          end

          # Basket resolution: envelope's own basket wins unless
          # +--force-basket+ is set; CLI's +--basket+ fills only where
          # envelope omits.
          def effective_basket(envelope_basket:)
            return @options[:basket] if @options[:force_basket]

            envelope_basket || @options[:basket]
          end
        end
      end
    end
  end
end
