# frozen_string_literal: true

require 'spec_helper'
require 'bsv/wallet/cli/commands/reject'

RSpec.describe BSV::Wallet::CLI::Commands::Reject do
  let(:engine) { instance_double(BSV::Wallet::Engine) }
  let(:ctx) { { engine: engine } }
  let(:global_options) { BSV::Wallet::CLI::GlobalOptions.default }
  let(:command) { described_class.new(ctx: ctx, global_options: global_options) }

  describe 'argument parsing' do
    it 'rejects missing <action_id>' do
      expect { command.call([]) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /requires <action_id>/)
    end

    it 'rejects non-integer <action_id>' do
      expect { command.call(['abc']) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /must be a positive integer/)
    end

    it 'rejects zero <action_id>' do
      expect { command.call(['0']) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /must be a positive integer/)
    end

    it 'rejects negative <action_id> (intercepted by OptionParser leading-dash heuristic)' do
      # OptionParser sees '-1' as an unknown flag — the dispatcher's
      # natural rescue path translates that to exit 2. Pure-negative
      # positionals are an operator-error case caught one layer up.
      expect { command.call(['-1']) }.to raise_error(OptionParser::InvalidOption)
    end

    it 'rejects extra positional arguments' do
      allow(engine).to receive(:reject_action)
      expect { command.call(%w[42 extra]) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /unexpected extra arguments/)
    end

    it 'accepts valid positive integer' do
      allow(engine).to receive(:reject_action).and_return(rejected: true, action_id: 42)
      expect { command.call(['42']) }.not_to raise_error
      expect(engine).to have_received(:reject_action).with(action_id: 42)
    end
  end

  describe 'engine integration' do
    it 'reports the rejected action id to stderr' do
      allow(engine).to receive(:reject_action).and_return(rejected: true, action_id: 7)
      expect { command.call(['7']) }.to output(/rejected:\s+action 7/).to_stderr
    end

    it 'lets engine InvalidParameterError bubble (handled by dispatcher Wallet::Error rescue)' do
      allow(engine).to receive(:reject_action)
        .and_raise(BSV::Wallet::InvalidParameterError, 'action_id=99 not found')
      expect { command.call(['99']) }
        .to raise_error(BSV::Wallet::InvalidParameterError)
    end
  end
end
