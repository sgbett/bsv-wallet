# frozen_string_literal: true

require 'spec_helper'
require 'json'
require 'tmpdir'
require 'fileutils'
require 'bsv/wallet/cli/commands/receive'

RSpec.describe BSV::Wallet::CLI::Commands::Receive do
  let(:engine) { instance_double(BSV::Wallet::Engine) }
  let(:key_deriver) { instance_double(BSV::Wallet::KeyDeriver) }
  let(:ctx) do
    { engine: engine, key_deriver: key_deriver, identity_key: "02#{'a' * 64}" }
  end
  let(:global_options) { BSV::Wallet::CLI::GlobalOptions.default }
  let(:command) { described_class.new(ctx: ctx, global_options: global_options) }
  let(:tmpdir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(tmpdir) }

  describe 'file IO errors' do
    it 'raises UsageError (not Errno::ENOENT) on missing --file' do
      expect { command.call(["--file=#{tmpdir}/does-not-exist.beef"]) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /input file not found/)
    end

    it 'raises UsageError (not Errno::EISDIR) when --file points to a directory' do
      expect { command.call(["--file=#{tmpdir}"]) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /input file/)
    end
  end

  describe 'input guard rails' do
    it 'raises UsageError on empty input' do
      empty = File.join(tmpdir, 'empty.beef')
      File.binwrite(empty, '')
      expect { command.call(["--file=#{empty}"]) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /empty/)
    end

    it 'raises UsageError on invalid JSON (envelope shape but unparseable)' do
      bad = File.join(tmpdir, 'bad.json')
      File.write(bad, '{ this: is, not: valid JSON }')
      expect { command.call(["--file=#{bad}"]) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /not valid JSON/)
    end

    it 'raises UsageError on malformed BEEF (parser failure mapped to UsageError, not crash)' do
      bad = File.join(tmpdir, 'bad.beef')
      # Truncated: a single byte cannot encode a valid BEEF preamble. The
      # parser either raises or returns an empty BEEF; both paths map to
      # UsageError so the dispatcher's never-raises-uncaught contract
      # holds.
      File.binwrite(bad, "\x00")
      expect { command.call(["--file=#{bad}"]) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /not valid BEEF/)
    end
  end

  describe 'input format detection' do
    let(:envelope) do
      JSON.generate(
        beef: 'aabbcc', sender_identity_key: "02#{'b' * 64}",
        outputs: [
          { vout: 0, satoshis: 100, derivation_prefix: 'p', derivation_suffix: '1' }
        ]
      )
    end

    before do
      allow(engine).to receive(:import_beef).and_return({})
    end

    it 'detects JSON envelope when input starts with {' do
      file = File.join(tmpdir, 'envelope.json')
      File.write(file, envelope)
      command.call(["--file=#{file}"])
      expect(engine).to have_received(:import_beef).with(
        hash_including(
          outputs: array_including(
            hash_including(protocol: 'wallet payment')
          )
        )
      )
    end

    it 'detects raw BEEF when input does not start with {' do
      # No engine.import_beef call unless there's a match — for this
      # test we stub the BEEF parser too and assert detection branched
      # correctly via the no-matches message.
      file = File.join(tmpdir, 'raw.beef')
      File.binwrite(file, "\x01\x02\x03BEEF")
      allow(command).to receive(:parse_beef_subject).and_return(
        instance_double(BSV::Transaction::Tx, outputs: [])
      )
      # HLR #467: the CLI consumes +KeyDeriver#identity_pubkey_hash+
      # (the wallet's root P2PKH hash) directly — no more inline
      # +hash160(compressed)+ round-trip.
      allow(key_deriver).to receive(:identity_pubkey_hash)
        .and_return(("\x00" * 20).b)

      expect { command.call(["--file=#{file}"]) }.to output(/no outputs matching/).to_stderr
    end
  end

  describe 'envelope path' do
    let(:beef_hex) { 'deadbeef' }
    let(:sender_key) { "02#{'b' * 64}" }
    let(:envelope) do
      JSON.generate(
        beef: beef_hex, sender_identity_key: sender_key,
        outputs: [
          { vout: 0, satoshis: 500, derivation_prefix: 'p1', derivation_suffix: '1', basket: 'received' },
          { vout: 1, satoshis: 300, derivation_prefix: 'p2', derivation_suffix: '2' }
        ]
      )
    end
    let(:file) do
      path = File.join(tmpdir, 'envelope.json')
      File.write(path, envelope)
      path
    end

    before do
      allow(engine).to receive(:import_beef).and_return({})
    end

    it 'forwards per-output derivation hints to engine.import_beef' do
      command.call(["--file=#{file}"])
      # Strict BRC-29 (HLR #460): the +paymentRemittance+ triple stays in
      # +payment_remittance+ (snake_case ingress); basket rides at the
      # top level — the spec's +wallet payment+ carries no basket on the
      # wire.
      expect(engine).to have_received(:import_beef).with(
        hash_including(
          tx: [beef_hex].pack('H*'),
          description: 'cli-receive',
          outputs: [
            hash_including(
              output_index: 0,
              protocol: 'wallet payment',
              basket: 'received',
              payment_remittance: hash_including(
                derivation_prefix: 'p1',
                derivation_suffix: '1',
                sender_identity_key: sender_key
              )
            ),
            hash_including(
              output_index: 1,
              payment_remittance: hash_including(
                derivation_prefix: 'p2',
                derivation_suffix: '2'
              )
            )
          ]
        )
      )
    end

    it '--basket fills envelope outputs only where envelope omits a basket' do
      command.call(["--file=#{file}", '--basket=fallback'])
      expect(engine).to have_received(:import_beef).with(
        hash_including(
          outputs: [
            hash_including(basket: 'received'),  # envelope wins
            hash_including(basket: 'fallback')   # envelope omitted; CLI fills
          ]
        )
      )
    end

    it '--force-basket overrides envelope-supplied baskets' do
      command.call(["--file=#{file}", '--basket=override', '--force-basket'])
      expect(engine).to have_received(:import_beef).with(
        hash_including(
          outputs: array_including(
            hash_including(basket: 'override'),
            hash_including(basket: 'override')
          )
        )
      )
    end

    it 'raises UsageError when envelope is missing beef' do
      bad = JSON.generate(sender_identity_key: sender_key, outputs: [])
      path = File.join(tmpdir, 'bad.json')
      File.write(path, bad)
      expect { command.call(["--file=#{path}"]) }.to raise_error(BSV::Wallet::CLI::UsageError, /beef/)
    end

    it 'raises UsageError when envelope is missing outputs' do
      bad = JSON.generate(beef: beef_hex, sender_identity_key: sender_key)
      path = File.join(tmpdir, 'bad.json')
      File.write(path, bad)
      expect { command.call(["--file=#{path}"]) }.to raise_error(BSV::Wallet::CLI::UsageError, /outputs/)
    end

    it 'raises UsageError when envelope.beef is not valid hex (odd length)' do
      bad = JSON.generate(beef: 'abc',
                          sender_identity_key: sender_key,
                          outputs: [{ vout: 0, satoshis: 100,
                                      derivation_prefix: 'p', derivation_suffix: '1' }])
      path = File.join(tmpdir, 'bad.json')
      File.write(path, bad)
      expect { command.call(["--file=#{path}"]) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /not valid hex/)
    end

    it 'raises UsageError when envelope.beef contains non-hex characters' do
      bad = JSON.generate(beef: 'zzzz',
                          sender_identity_key: sender_key,
                          outputs: [{ vout: 0, satoshis: 100,
                                      derivation_prefix: 'p', derivation_suffix: '1' }])
      path = File.join(tmpdir, 'bad.json')
      File.write(path, bad)
      expect { command.call(["--file=#{path}"]) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /not valid hex/)
    end

    it 'raises UsageError when an envelope output is missing vout (engine would default to 0)' do
      bad = JSON.generate(beef: beef_hex,
                          sender_identity_key: sender_key,
                          outputs: [{ satoshis: 100,
                                      derivation_prefix: 'p', derivation_suffix: '1' }])
      path = File.join(tmpdir, 'bad.json')
      File.write(path, bad)
      expect { command.call(["--file=#{path}"]) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /missing or invalid "vout"/)
    end

    it 'raises UsageError when an envelope output has non-integer vout' do
      bad = JSON.generate(beef: beef_hex,
                          sender_identity_key: sender_key,
                          outputs: [{ vout: 'first', satoshis: 100,
                                      derivation_prefix: 'p', derivation_suffix: '1' }])
      path = File.join(tmpdir, 'bad.json')
      File.write(path, bad)
      expect { command.call(["--file=#{path}"]) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /missing or invalid "vout"/)
    end

    it 'raises UsageError when envelope is missing sender_identity_key' do
      bad = JSON.generate(beef: beef_hex,
                          outputs: [{ vout: 0, satoshis: 100,
                                      derivation_prefix: 'p', derivation_suffix: '1' }])
      path = File.join(tmpdir, 'bad.json')
      File.write(path, bad)
      expect { command.call(["--file=#{path}"]) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /sender_identity_key/)
    end

    it 'raises UsageError when sender_identity_key is not a 66-char compressed pubkey hex' do
      bad = JSON.generate(beef: beef_hex,
                          sender_identity_key: 'not-a-pubkey',
                          outputs: [{ vout: 0, satoshis: 100,
                                      derivation_prefix: 'p', derivation_suffix: '1' }])
      path = File.join(tmpdir, 'bad.json')
      File.write(path, bad)
      expect { command.call(["--file=#{path}"]) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /sender_identity_key/)
    end

    it 'raises UsageError when an envelope output is missing derivation_prefix' do
      bad = JSON.generate(beef: beef_hex,
                          sender_identity_key: sender_key,
                          outputs: [{ vout: 0, satoshis: 100,
                                      derivation_suffix: '1' }])
      path = File.join(tmpdir, 'bad.json')
      File.write(path, bad)
      expect { command.call(["--file=#{path}"]) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /invalid "derivation_prefix".*must be a String/)
    end

    it 'raises UsageError when an envelope output is missing derivation_suffix' do
      bad = JSON.generate(beef: beef_hex,
                          sender_identity_key: sender_key,
                          outputs: [{ vout: 0, satoshis: 100,
                                      derivation_prefix: 'p' }])
      path = File.join(tmpdir, 'bad.json')
      File.write(path, bad)
      expect { command.call(["--file=#{path}"]) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /invalid "derivation_suffix".*must be a String/)
    end

    it 'raises UsageError when derivation_prefix is empty string' do
      bad = JSON.generate(beef: beef_hex,
                          sender_identity_key: sender_key,
                          outputs: [{ vout: 0, satoshis: 100,
                                      derivation_prefix: '', derivation_suffix: '1' }])
      path = File.join(tmpdir, 'bad.json')
      File.write(path, bad)
      expect { command.call(["--file=#{path}"]) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /invalid "derivation_prefix".*must not be empty/)
    end

    it 'raises UsageError when derivation_prefix contains whitespace' do
      bad = JSON.generate(beef: beef_hex,
                          sender_identity_key: sender_key,
                          outputs: [{ vout: 0, satoshis: 100,
                                      derivation_prefix: 'abc def', derivation_suffix: '1' }])
      path = File.join(tmpdir, 'bad.json')
      File.write(path, bad)
      expect { command.call(["--file=#{path}"]) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /invalid "derivation_prefix".*outside the base64url subset/)
    end

    it 'raises UsageError when derivation_suffix contains a control byte' do
      bad = JSON.generate(beef: beef_hex,
                          sender_identity_key: sender_key,
                          outputs: [{ vout: 0, satoshis: 100,
                                      derivation_prefix: 'p', derivation_suffix: "x\x01y" }])
      path = File.join(tmpdir, 'bad.json')
      File.write(path, bad)
      expect { command.call(["--file=#{path}"]) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /invalid "derivation_suffix".*outside the base64url subset/)
    end

    it 'raises UsageError when derivation_prefix exceeds the byte cap' do
      bad = JSON.generate(beef: beef_hex,
                          sender_identity_key: sender_key,
                          outputs: [{ vout: 0, satoshis: 100,
                                      derivation_prefix: 'A' * 129, derivation_suffix: '1' }])
      path = File.join(tmpdir, 'bad.json')
      File.write(path, bad)
      expect { command.call(["--file=#{path}"]) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /invalid "derivation_prefix".*exceeds 128-byte limit/)
    end

    # JSON faithfully decodes whatever shape the operator supplies —
    # numbers, arrays, strings where Hashes are expected. Without explicit
    # type checks at the CLI boundary, the dispatcher's never-raises-uncaught
    # contract breaks (NoMethodError / TypeError instead of UsageError).
    it 'raises UsageError when "beef" is a number (not a string)' do
      bad = JSON.generate(beef: 42,
                          sender_identity_key: sender_key,
                          outputs: [{ vout: 0, satoshis: 100,
                                      derivation_prefix: 'p', derivation_suffix: '1' }])
      path = File.join(tmpdir, 'bad.json')
      File.write(path, bad)
      expect { command.call(["--file=#{path}"]) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /missing or invalid "beef"/)
    end

    it 'raises UsageError when "outputs" is a string (not an array)' do
      bad = JSON.generate(beef: beef_hex,
                          sender_identity_key: sender_key,
                          outputs: 'not-an-array')
      path = File.join(tmpdir, 'bad.json')
      File.write(path, bad)
      expect { command.call(["--file=#{path}"]) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /missing or invalid "outputs"/)
    end

    it 'raises UsageError when "outputs" is a hash (not an array)' do
      bad = JSON.generate(beef: beef_hex,
                          sender_identity_key: sender_key,
                          outputs: { vout: 0 })
      path = File.join(tmpdir, 'bad.json')
      File.write(path, bad)
      expect { command.call(["--file=#{path}"]) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /missing or invalid "outputs"/)
    end

    it 'raises UsageError when an outputs element is not a JSON object' do
      bad = JSON.generate(beef: beef_hex,
                          sender_identity_key: sender_key,
                          outputs: ['oops'])
      path = File.join(tmpdir, 'bad.json')
      File.write(path, bad)
      expect { command.call(["--file=#{path}"]) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /must be a JSON object/)
    end

    # satoshis is informational (engine reads BEEF), but the human
    # summary sums it AFTER engine.import_beef has committed. Without
    # up-front validation, a non-integer satoshis TypeErrors post-import,
    # leaving the wallet in a "succeeded but crashed" state.
    it 'raises UsageError when an envelope output is missing satoshis (fails before engine.import_beef)' do
      bad = JSON.generate(beef: beef_hex,
                          sender_identity_key: sender_key,
                          outputs: [{ vout: 0,
                                      derivation_prefix: 'p', derivation_suffix: '1' }])
      path = File.join(tmpdir, 'bad.json')
      File.write(path, bad)
      expect { command.call(["--file=#{path}"]) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /missing or invalid "satoshis"/)
      expect(engine).not_to have_received(:import_beef)
    end

    it 'raises UsageError when satoshis is a string' do
      bad = JSON.generate(beef: beef_hex,
                          sender_identity_key: sender_key,
                          outputs: [{ vout: 0, satoshis: 'hundred',
                                      derivation_prefix: 'p', derivation_suffix: '1' }])
      path = File.join(tmpdir, 'bad.json')
      File.write(path, bad)
      expect { command.call(["--file=#{path}"]) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /missing or invalid "satoshis"/)
      expect(engine).not_to have_received(:import_beef)
    end

    it 'raises UsageError when satoshis is negative' do
      bad = JSON.generate(beef: beef_hex,
                          sender_identity_key: sender_key,
                          outputs: [{ vout: 0, satoshis: -100,
                                      derivation_prefix: 'p', derivation_suffix: '1' }])
      path = File.join(tmpdir, 'bad.json')
      File.write(path, bad)
      expect { command.call(["--file=#{path}"]) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /missing or invalid "satoshis"/)
    end
  end

  describe 'raw BEEF path' do
    let(:p2pkh_lock) do
      hash = "\x55" * 20
      "v\xA9\u0014#{hash}\x88\xAC".b
    end
    let(:matching_pubkey) { "\u0002#{"\x33" * 32}".b } # any compressed pubkey
    let(:beef_file) do
      path = File.join(tmpdir, 'raw.beef')
      File.binwrite(path, "\x01\x02\x03BEEF")
      path
    end

    before do
      allow(engine).to receive(:import_beef).and_return({})
      # HLR #467: the CLI consumes +KeyDeriver#identity_pubkey_hash+ —
      # the canonical 20-byte wallet root hash, set to +matching_pubkey+'s
      # hash160 so the scanner recognises matching outputs.
      allow(key_deriver).to receive(:identity_pubkey_hash).and_return("\x55" * 20)
    end

    it 'imports outputs whose P2PKH lock matches the wallet root pubkey hash' do
      output = instance_double(BSV::Transaction::TransactionOutput,
                               locking_script: instance_double(BSV::Script::Script, to_binary: p2pkh_lock),
                               satoshis: 1234)
      subject_tx = instance_double(BSV::Transaction::Tx, outputs: [output])
      allow(command).to receive(:parse_beef_subject).and_return(subject_tx)

      command.call(["--file=#{beef_file}"])

      expect(engine).to have_received(:import_beef).with(
        hash_including(
          outputs: [
            hash_including(
              output_index: 0,
              protocol: 'basket insertion',
              insertion_remittance: hash_including(basket: nil)
            )
          ]
        )
      )
    end

    it 'forwards --basket to matched outputs' do
      output = instance_double(BSV::Transaction::TransactionOutput,
                               locking_script: instance_double(BSV::Script::Script, to_binary: p2pkh_lock),
                               satoshis: 1234)
      subject_tx = instance_double(BSV::Transaction::Tx, outputs: [output])
      allow(command).to receive(:parse_beef_subject).and_return(subject_tx)

      command.call(["--file=#{beef_file}", '--basket=incoming'])

      expect(engine).to have_received(:import_beef).with(
        hash_including(
          outputs: array_including(
            hash_including(insertion_remittance: hash_including(basket: 'incoming'))
          )
        )
      )
    end

    it 'accepts hex-encoded BEEF (auto-detects ASCII-hex input and decodes)' do
      hex_file = File.join(tmpdir, 'raw.hex')
      File.write(hex_file, "\x01\x02\x03BEEF".unpack1('H*'))

      output = instance_double(BSV::Transaction::TransactionOutput,
                               locking_script: instance_double(BSV::Script::Script, to_binary: p2pkh_lock),
                               satoshis: 1234)
      subject_tx = instance_double(BSV::Transaction::Tx, outputs: [output])
      # Assert decode_hex_if_hex actually unhexed before parse_beef_subject sees it.
      allow(command).to receive(:parse_beef_subject).with("\x01\x02\x03BEEF".b).and_return(subject_tx)

      command.call(["--file=#{hex_file}"])
      expect(command).to have_received(:parse_beef_subject).with("\x01\x02\x03BEEF".b)
    end

    it 'reports no-matches to stderr without calling engine when no outputs match' do
      non_matching_lock = "v\xA9\u0014#{"\xff" * 20}\x88\xAC".b
      output = instance_double(BSV::Transaction::TransactionOutput,
                               locking_script: instance_double(BSV::Script::Script, to_binary: non_matching_lock),
                               satoshis: 1234)
      subject_tx = instance_double(BSV::Transaction::Tx, outputs: [output])
      allow(command).to receive(:parse_beef_subject).and_return(subject_tx)

      expect { command.call(["--file=#{beef_file}"]) }.to output(/no outputs matching/).to_stderr
      expect(engine).not_to have_received(:import_beef)
    end
  end

  describe 'input size cap' do
    it 'refuses oversized input' do
      big = File.join(tmpdir, 'big.beef')
      File.binwrite(big, "\x00" * (33 * 1024 * 1024))
      expect { command.call(["--file=#{big}"]) }.to raise_error(BSV::Wallet::CLI::UsageError, /exceeds 32 MiB cap/)
    end

    # Cap must be enforced AT THE READ, not after — a 10 GiB adversarial
    # pipe would otherwise OOM the process before the size check runs.
    # File.binread(path, n) honours the limit; assert that what gets
    # read is bounded at MAX_INPUT_BYTES + 1.
    it 'reads at most MAX_INPUT_BYTES + 1 bytes from a file (bounded read at source)' do
      huge = File.join(tmpdir, 'huge.beef')
      File.binwrite(huge, "\x00" * (50 * 1024 * 1024))
      cap = described_class::MAX_INPUT_BYTES
      allow(File).to receive(:binread).and_call_original
      expect { command.call(["--file=#{huge}"]) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /exceeds 32 MiB cap/)
      expect(File).to have_received(:binread).with(huge, cap + 1)
    end
  end
end
