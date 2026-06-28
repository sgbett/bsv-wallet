# frozen_string_literal: true

require 'spec_helper'
require 'bsv/wallet/cli/commands/consolidate'

RSpec.describe BSV::Wallet::CLI::Commands::Consolidate do
  let(:engine) { instance_double(BSV::Wallet::Engine) }
  let(:ctx) { { engine: engine } }
  let(:global_options) { BSV::Wallet::CLI::GlobalOptions.default }
  let(:command) { described_class.new(ctx: ctx, global_options: global_options) }
  let(:fake_wtxid) { ("\x00" * 32).b }

  describe 'argument parsing' do
    it 'rejects positional arguments' do
      expect { command.call(['unexpected']) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /no positional arguments/)
    end

    it 'rejects --target-inputs=1 (below MIN_TARGET_INPUTS)' do
      expect { command.call(['--target-inputs=1']) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /must be >= 2/)
    end

    it 'rejects --target-inputs=0' do
      expect { command.call(['--target-inputs=0']) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /must be >= 2/)
    end

    it 'rejects non-integer --target-inputs (OptionParser layer)' do
      expect { command.call(['--target-inputs=lots']) }
        .to raise_error(OptionParser::InvalidArgument)
    end

    it 'accepts --target-inputs=2 (boundary)' do
      allow(engine).to receive(:consolidate_step).and_return(wtxid: fake_wtxid)
      expect { command.call(['--target-inputs=2']) }.not_to raise_error
      expect(engine).to have_received(:consolidate_step).with(
        hash_including(target_inputs: 2)
      )
    end
  end

  describe 'engine integration (happy path)' do
    before { allow(engine).to receive(:consolidate_step).and_return(wtxid: fake_wtxid) }

    it 'defaults --target-inputs to 20' do
      command.call([])
      expect(engine).to have_received(:consolidate_step).with(
        target_inputs: 20, no_send: false, accept_delayed_broadcast: true
      )
    end

    it '--no-send maps to no_send: true and disables delayed broadcast' do
      command.call(['--no-send'])
      expect(engine).to have_received(:consolidate_step).with(
        hash_including(no_send: true, accept_delayed_broadcast: false)
      )
    end

    it 'reports the dtxid in human summary' do
      expect { command.call([]) }.to output(/dtxid:\s+[0-9a-f]{64}/).to_stderr
    end
  end

  describe 'pool-too-small path' do
    it 'reports "pool too small" without erroring when engine returns nil' do
      allow(engine).to receive(:consolidate_step).and_return(nil)
      expect { command.call([]) }.to output(/pool too small/).to_stderr
    end

    it 'returns 0 (success) when pool too small' do
      allow(engine).to receive(:consolidate_step).and_return(nil)
      expect(command.call([])).to eq(0)
    end
  end
end
