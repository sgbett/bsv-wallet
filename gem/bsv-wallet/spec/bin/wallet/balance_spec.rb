# frozen_string_literal: true

require 'spec_helper'
require 'bsv/wallet/cli/commands/balance'

RSpec.describe BSV::Wallet::CLI::Commands::Balance do
  let(:engine) { instance_double(BSV::Wallet::Engine) }
  let(:ctx) { { engine: engine, identity_key: '02abcd' } }
  let(:global_options) { BSV::Wallet::CLI::GlobalOptions.default }
  let(:command) { described_class.new(ctx: ctx, global_options: global_options) }

  describe '#call (scalar mode)' do
    before do
      allow(engine).to receive(:spendable_outputs).with(aggregate: :sum).and_return(12_345)
      allow(engine).to receive(:spendable_outputs).with(aggregate: :count).and_return(7)
    end

    it 'prints the satoshi sum to stdout' do
      expect { command.call([]) }.to output(/^12345$/).to_stdout
    end

    it 'returns exit code 0 on success' do
      expect(command.call([])).to eq(0)
    end

    it 'prints human-readable summary to stderr' do
      expect { command.call([]) }.to output(/identity: 02abcd/).to_stderr
    end
  end

  describe '#call with --basket=<name>' do
    before do
      allow(engine).to receive(:spendable_outputs).with(aggregate: :sum, basket: 'received').and_return(500)
      allow(engine).to receive(:spendable_outputs).with(aggregate: :count, basket: 'received').and_return(3)
    end

    it 'passes the basket filter to engine.spendable_outputs' do
      command.call(['--basket=received'])
      expect(engine).to have_received(:spendable_outputs).with(aggregate: :sum, basket: 'received')
    end

    it 'shows the basket name in the human summary' do
      expect { command.call(['--basket=received']) }.to output(/basket:\s+received/).to_stderr
    end
  end

  describe '#call with --basket=none' do
    before do
      allow(engine).to receive(:spendable_outputs).with(aggregate: :sum, basket: nil).and_return(0)
      allow(engine).to receive(:spendable_outputs).with(aggregate: :count, basket: nil).and_return(0)
    end

    it 'passes nil as the basket (unbasketed)' do
      command.call(['--basket=none'])
      expect(engine).to have_received(:spendable_outputs).with(aggregate: :sum, basket: nil)
    end

    it 'labels the basket as (unbasketed) in the summary' do
      expect { command.call(['--basket=none']) }.to output(/basket:\s+\(unbasketed\)/).to_stderr
    end
  end

  describe '#call with --outputs' do
    before do
      allow(engine).to receive(:spendable_outputs).with(limit: 100).and_return(
        { outputs: [{ satoshis: 100 }, { satoshis: 200 }], total: 2 }
      )
    end

    it 'emits NDJSON rows for each output' do
      expect { command.call(['--outputs']) }.to output(
        /\{"satoshis":100\}\n\{"satoshis":200\}/
      ).to_stdout
    end
  end
end
