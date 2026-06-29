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
        # protocol and no derivation hints — the locking script matches the
        # wallet's per-instance root P2PKH literal (enforced declaratively
        # by +outputs.spendable_recoverable+; HLR #467). Phase 2 scans the
        # root address only; HD/WBIKD-derived receive addresses are a
        # follow-up.
        #
        # Envelope path: the sender shipped explicit derivation hints. Each
        # listed output gets imported via +engine.import_beef+ with the
        # strict BRC-29 +wallet payment+ protocol carrying the
        # +derivation_prefix+ / +derivation_suffix+ / +sender_identity_key+
        # in the +payment_remittance+ object. The spec's
        # +paymentRemittance+ has no basket; +--basket=<name>+ rides at
        # the top level of the output spec (engine-side sibling of
        # +:protocol+) and applies only where the envelope itself omits
        # a basket — silent override of the sender's intent requires
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

          # Read input from +--file+ or stdin with a bounded read at
          # source: +MAX_INPUT_BYTES + 1+ caps the actual file/stdin
          # consumption, so a 10 GiB adversarial pipe can't OOM the
          # process before the size check fires. If the returned buffer
          # is at the +1+ boundary, the input is larger than the cap
          # (we just don't know how much larger) — that's enough to
          # raise UsageError.
          def read_input
            bytes = read_binary_input(file: @options[:file], max_bytes: MAX_INPUT_BYTES + 1)
            if bytes.bytesize > MAX_INPUT_BYTES
              raise UsageError,
                    "receive input exceeds #{MAX_INPUT_BYTES / (1024 * 1024)} MiB cap"
            end
            bytes
          end

          # Distinguish BRC-29 envelope JSON from raw BEEF bytes by
          # looking at the first non-whitespace byte: JSON envelopes
          # start with +{+ (optionally preceded by whitespace from
          # pretty-printers); BEEF starts with binary version bytes that
          # are never whitespace or +{+. Anchored regex scan — no buffer
          # allocation, bounded at the first non-whitespace byte
          # regardless of input size.
          def detect_input_kind(bytes)
            return :envelope if bytes.match?(/\A\s*\{/)

            :raw_beef
          end

          # Envelope path: parse derivation hints from the JSON, build
          # +engine.import_beef+ output specs with appropriate remittance.
          #
          # All four BRC-29 fields (+sender_identity_key+, +beef+, per-output
          # +derivation_prefix+ / +derivation_suffix+) are required and
          # validated at the CLI boundary. Engine-side defaults silently
          # cover for missing fields (counterparty becomes +'self'+,
          # vout becomes 0) — but those defaults derive the WRONG key,
          # importing outputs the wallet can never spend. Catch it here
          # rather than discovering it on attempted spend.
          def call_envelope(engine, envelope, description)
            beef_hex = envelope[:beef]
            unless beef_hex.is_a?(String) && !beef_hex.empty?
              raise UsageError, 'envelope missing or invalid "beef" field (must be a non-empty hex string)'
            end

            sender_identity_key = envelope[:sender_identity_key]
            unless sender_identity_key.is_a?(String) && sender_identity_key.match?(/\A(02|03)[0-9a-fA-F]{64}\z/)
              raise UsageError,
                    'envelope missing or invalid "sender_identity_key" ' \
                    '(required for BRC-29 key recovery: must be 66-char compressed pubkey hex starting 02/03)'
            end

            pay_outputs = envelope[:outputs]
            unless pay_outputs.is_a?(Array) && !pay_outputs.empty?
              raise UsageError, 'envelope missing or invalid "outputs" (must be a non-empty array)'
            end

            beef_bytes = decode_hex_field!(beef_hex, field: 'envelope "beef"')

            output_specs = pay_outputs.map.with_index do |out, idx|
              validate_envelope_output!(out, idx)
              # BRC-29 +wallet payment+ (HLR #460): the spec's
              # +paymentRemittance+ triple is the derivation
              # prefix/suffix + sender_identity_key. Engine reads
              # +payment_remittance+ (snake_case ingress); +basket+ rides
              # at the top level alongside +:protocol+ — the spec carries
              # no basket on the wire, and the wallet's CLI fallback
              # (+--basket+) stays available via the +effective_basket+
              # resolver.
              {
                output_index: out[:vout],
                protocol: 'wallet payment',
                basket: effective_basket(envelope_basket: out[:basket]),
                payment_remittance: {
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
            emit_human "total sats:  #{pay_outputs.sum { |o| o[:satoshis] }}"
            emit_human "basket:      #{output_specs.first[:basket] || '(unbasketed)'}"
          end

          # Raw BEEF path: parse, scan outputs for P2PKH locks to wallet's
          # root address, import matches as basket insertion with no
          # derivation hints — the engine sets +spendable_intent: 'spendable'+
          # at the import boundary, and the per-wallet +spendable_recoverable+
          # CHECK validates the locking script matches the wallet's root
          # P2PKH literal (HLR #467). Accepts either binary BEEF or its
          # hex-string encoding (the latter is shell-pipe-friendly; binary
          # in pipes is fiddly with locale/encoding pitfalls).
          def call_raw_beef(engine, beef_bytes, description)
            beef_bytes = decode_hex_if_hex(beef_bytes)
            subject_tx = parse_beef_subject(beef_bytes)

            key_deriver = @ctx[:key_deriver]
            root_pubkey_hash = key_deriver.identity_pubkey_hash

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

          # Validate one envelope output's BRC-29 fields. All three
          # (+vout+, +derivation_prefix+, +derivation_suffix+) are
          # required: silent engine-side defaults would derive the
          # wrong key, producing an unspendable import.
          def validate_envelope_output!(out, idx)
            unless out.is_a?(Hash)
              raise UsageError,
                    "envelope output [#{idx}] must be a JSON object " \
                    "(got #{out.class}: #{out.inspect.slice(0, 60)})"
            end

            vout = out[:vout]
            unless vout.is_a?(Integer) && vout >= 0
              raise UsageError,
                    "envelope output [#{idx}] missing or invalid \"vout\" " \
                    '(must be a non-negative integer; engine-side default-to-zero ' \
                    'could silently target the wrong output)'
            end

            # satoshis is informational (engine reads the BEEF's actual
            # value), but the human-readable summary sums it AFTER
            # engine.import_beef has already committed. Validating
            # here means an invalid satoshis can't TypeError post-import
            # and leak the "succeeded but crashed" state.
            sats = out[:satoshis]
            unless sats.is_a?(Integer) && sats >= 0
              raise UsageError,
                    "envelope output [#{idx}] missing or invalid \"satoshis\" " \
                    '(must be a non-negative integer)'
            end

            # Defence in depth — the receive boundary is the untrusted
            # ingress, so validate the BRC-29 derivation tokens against
            # the same contract the send-side helper enforces. Without
            # this, a malformed envelope passes here, propagates into
            # +outputs+ via +import_beef+, and only blows up when the
            # wallet later tries to spend the output (deep in
            # +Engine::TxBuilder#derive_signing_key+) — stranding the
            # UTXO. Translate the helper's exception into a clean
            # boundary +UsageError+.
            { derivation_prefix: out[:derivation_prefix],
              derivation_suffix: out[:derivation_suffix] }.each do |field, value|
              BSV::Wallet::BRC29.validate_derivation_token!(value, role: field.to_s)
            rescue BSV::Wallet::BRC29::InvalidDerivationToken => e
              raise UsageError,
                    "envelope output [#{idx}] invalid \"#{field}\": #{e.message}"
            end
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
