# frozen_string_literal: true

require 'spec_helper'
require 'bsv/wallet/cli/commands/sweep'

RSpec.describe BSV::Wallet::CLI::Commands::Sweep do
  let(:engine) { instance_double(BSV::Wallet::Engine) }
  let(:ctx) { { engine: engine } }
  let(:global_options) { BSV::Wallet::CLI::GlobalOptions.default }
  let(:command) { described_class.new(ctx: ctx, global_options: global_options) }
  let(:valid_pubkey) { "02#{'a' * 64}" }
  let(:fake_wtxid) { ("\x00" * 32).b }

  describe 'argument parsing' do
    it 'rejects positional arguments' do
      expect { command.call([valid_pubkey, 'unexpected']) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /no positional arguments/)
    end

    it 'rejects missing --to' do
      expect { command.call([]) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /requires --to=/)
    end

    it 'rejects empty --to' do
      expect { command.call(['--to=']) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /requires --to=/)
    end

    it 'rejects --to with invalid pubkey shape' do
      expect { command.call(['--to=not-a-pubkey']) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /invalid public key/)
    end

    it 'rejects --to with wrong prefix byte' do
      expect { command.call(["--to=04#{'a' * 64}"]) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /invalid public key/)
    end

    # Defence-in-depth: an operator pasting a WIF or other long secret
    # into --to should not see it echoed verbatim in the error message
    # (would persist in shell history, CI logs, bug reports). Length
    # threshold is 20 chars — anything longer gets prefix + length.
    it 'truncates long invalid --to values in the error message (no operator-secret echo)' do
      wif_lookalike = "L#{'a' * 51}"
      expect { command.call(["--to=#{wif_lookalike}"]) }
        .to raise_error(BSV::Wallet::CLI::UsageError) do |error|
          expect(error.message).not_to include(wif_lookalike)
          expect(error.message).to include('52 chars')
        end
    end
  end

  describe 'engine integration (happy path)' do
    before do
      allow(engine).to receive(:sweep).and_return(wtxid: fake_wtxid)
    end

    it 'calls engine.sweep with the validated recipient' do
      command.call(["--to=#{valid_pubkey}"])
      expect(engine).to have_received(:sweep).with(
        recipient: valid_pubkey, no_send: false, accept_delayed_broadcast: true
      )
    end

    it '--no-send maps to no_send: true and disables delayed broadcast' do
      command.call(["--to=#{valid_pubkey}", '--no-send'])
      expect(engine).to have_received(:sweep).with(
        recipient: valid_pubkey, no_send: true, accept_delayed_broadcast: false
      )
    end

    it 'reports the dtxid (wire wtxid reversed to display order)' do
      command.call(["--to=#{valid_pubkey}"])
      expect { command.call(["--to=#{valid_pubkey}"]) }
        .to output(/dtxid:\s+[0-9a-f]{64}/).to_stderr
    end

    it 'truncates recipient in human summary (interchange identifier but verbose)' do
      expect { command.call(["--to=#{valid_pubkey}"]) }
        .to output(/swept to: #{valid_pubkey[0..15]}/).to_stderr
    end
  end

  describe 'empty pool path' do
    it 'reports "nothing to sweep" without erroring when engine returns nil' do
      allow(engine).to receive(:sweep).and_return(nil)
      expect { command.call(["--to=#{valid_pubkey}"]) }
        .to output(/no spendable outputs/).to_stderr
    end

    it 'returns 0 (success) on empty pool' do
      allow(engine).to receive(:sweep).and_return(nil)
      expect(command.call(["--to=#{valid_pubkey}"])).to eq(0)
    end
  end
end
