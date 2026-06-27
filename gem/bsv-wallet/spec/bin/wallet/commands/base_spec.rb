# frozen_string_literal: true

require 'spec_helper'
require 'bsv/wallet/cli/commands/base'

RSpec.describe BSV::Wallet::CLI::Commands::Base do
  let(:ctx) { { engine: double('engine'), identity_key: '02abcd' } }
  let(:global_options) { BSV::Wallet::CLI::GlobalOptions.default }
  let(:command) { described_class.new(ctx: ctx, global_options: global_options) }

  describe '#call' do
    it 'raises NotImplementedError on the base class' do
      expect { command.call([]) }.to raise_error(NotImplementedError)
    end
  end

  describe '#parse_pubkey_hex' do
    it 'accepts 66-char hex with 02 prefix' do
      hex = "02#{'a' * 64}"
      expect(command.send(:parse_pubkey_hex, hex)).to eq(hex)
    end

    it 'accepts 66-char hex with 03 prefix' do
      hex = "03#{'a' * 64}"
      expect(command.send(:parse_pubkey_hex, hex)).to eq(hex)
    end

    it 'rejects wrong prefix' do
      expect do
        command.send(:parse_pubkey_hex, "04#{'a' * 64}")
      end.to raise_error(BSV::Wallet::CLI::UsageError, /invalid public key/)
    end

    it 'rejects wrong length' do
      expect do
        command.send(:parse_pubkey_hex, "02#{'a' * 62}")
      end.to raise_error(BSV::Wallet::CLI::UsageError, /invalid public key/)
    end

    it 'rejects non-hex characters' do
      expect do
        command.send(:parse_pubkey_hex, "02#{'z' * 64}")
      end.to raise_error(BSV::Wallet::CLI::UsageError, /invalid public key/)
    end
  end

  describe '#emit_json (redaction)' do
    it 'redacts sensitive fields before writing' do
      payload = { wif: 'L1xxx', wallet: 'alice' }
      expect { command.send(:emit_json, payload) }.to output(/"\[REDACTED\]"/).to_stdout
    end
  end

  describe '#emit_ndjson_row (redaction)' do
    it 'redacts sensitive fields and writes one JSON object' do
      row = { wif: 'L1xxx', amount: 100 }
      expect { command.send(:emit_ndjson_row, row) }.to output(/^\{.*"\[REDACTED\]".*\}$/).to_stdout
    end
  end

  describe '#read_binary_input' do
    it 'refuses to read from a TTY stdin' do
      allow($stdin).to receive(:tty?).and_return(true)
      expect do
        command.send(:read_binary_input)
      end.to raise_error(BSV::Wallet::CLI::UsageError, /no input on stdin/)
    end

    it 'reads from --file with binmode' do
      Dir.mktmpdir do |dir|
        path = File.join(dir, 'binary.dat')
        File.binwrite(path, "\x00\x01\x02BEEF")
        result = command.send(:read_binary_input, file: path)
        expect(result.bytes.first(4)).to eq([0, 1, 2, 0x42])
      end
    end
  end
end
