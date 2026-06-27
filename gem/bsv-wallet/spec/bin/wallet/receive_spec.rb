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
            hash_including(protocol: 'basket insertion')
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
      allow(key_deriver).to receive(:root_private_key).and_return(
        instance_double(BSV::Primitives::PrivateKey,
                        public_key: instance_double(BSV::Primitives::PublicKey, compressed: ("\x00" * 33).b))
      )

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
      expect(engine).to have_received(:import_beef).with(
        hash_including(
          tx: [beef_hex].pack('H*'),
          description: 'cli-receive',
          outputs: [
            hash_including(
              output_index: 0,
              protocol: 'basket insertion',
              insertion_remittance: hash_including(
                basket: 'received',
                derivation_prefix: 'p1',
                derivation_suffix: '1',
                sender_identity_key: sender_key
              )
            ),
            hash_including(
              output_index: 1,
              insertion_remittance: hash_including(
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
      call_args = engine.method(:import_beef).receiver # rubocop:disable Lint/UselessAssignment
      engine.method_calls if engine.respond_to?(:method_calls)
      # Direct check on the spy:
      expect(engine).to have_received(:import_beef).with(
        hash_including(
          outputs: [
            hash_including(
              insertion_remittance: hash_including(basket: 'received') # envelope wins
            ),
            hash_including(
              insertion_remittance: hash_including(basket: 'fallback') # envelope omitted; CLI fills
            )
          ]
        )
      )
    end

    it '--force-basket overrides envelope-supplied baskets' do
      command.call(["--file=#{file}", '--basket=override', '--force-basket'])
      expect(engine).to have_received(:import_beef).with(
        hash_including(
          outputs: array_including(
            hash_including(
              insertion_remittance: hash_including(basket: 'override')
            ),
            hash_including(
              insertion_remittance: hash_including(basket: 'override')
            )
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
      allow(BSV::Primitives::Digest).to receive(:hash160).with(matching_pubkey).and_return("\x55" * 20)
      allow(key_deriver).to receive(:root_private_key).and_return(
        instance_double(BSV::Primitives::PrivateKey,
                        public_key: instance_double(BSV::Primitives::PublicKey, compressed: matching_pubkey))
      )
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
  end
end
