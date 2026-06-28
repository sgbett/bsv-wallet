# frozen_string_literal: true

require 'spec_helper'
require 'bsv/wallet/cli/commands/import'

RSpec.describe BSV::Wallet::CLI::Commands::Import do
  let(:engine) { instance_double(BSV::Wallet::Engine) }
  let(:ctx) { { engine: engine } }
  let(:global_options) { BSV::Wallet::CLI::GlobalOptions.default }
  let(:command) { described_class.new(ctx: ctx, global_options: global_options) }

  before do
    allow(engine).to receive(:import_wallet).and_return(imported: 3, utxos: [])
  end

  describe 'argument parsing' do
    it 'rejects positional arguments' do
      expect { command.call(['unexpected']) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /no positional arguments/)
    end

    it 'accepts no arguments (defaults: queued for daemon)' do
      expect { command.call([]) }.not_to raise_error
      expect(engine).to have_received(:import_wallet).with(
        basket: nil, no_send: false, accept_delayed_broadcast: true, include_unconfirmed: false
      )
    end

    # --basket= (empty value) would otherwise reach the engine, where
    # the schema CHECK (basket name length 5-300) rejects it as a
    # Sequel::CheckConstraintViolation. Catch at the CLI for an
    # operator-actionable message pointing at the right alternative.
    it 'rejects --basket= (empty) with omit-flag hint' do
      expect { command.call(['--basket=']) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /must be non-empty.*omit --basket/m)
    end
  end

  describe 'flag forwarding' do
    it 'threads --basket to engine.import_wallet(basket:)' do
      command.call(['--basket=incoming'])
      expect(engine).to have_received(:import_wallet).with(
        hash_including(basket: 'incoming')
      )
    end

    it 'maps --no-send to no_send: true' do
      command.call(['--no-send'])
      expect(engine).to have_received(:import_wallet).with(
        hash_including(no_send: true)
      )
    end

    it 'maps --inline to accept_delayed_broadcast: false (sync ARC)' do
      command.call(['--inline'])
      expect(engine).to have_received(:import_wallet).with(
        hash_including(accept_delayed_broadcast: false)
      )
    end

    it 'rejects --inline + --no-send as mutually exclusive' do
      expect { command.call(['--inline', '--no-send']) }
        .to raise_error(BSV::Wallet::CLI::UsageError, /mutually exclusive/)
    end

    it 'maps --include-unconfirmed to include_unconfirmed: true' do
      command.call(['--include-unconfirmed'])
      expect(engine).to have_received(:import_wallet).with(
        hash_including(include_unconfirmed: true)
      )
    end

    it 'combines compatible flags' do
      command.call(['--basket=staging', '--inline', '--include-unconfirmed'])
      expect(engine).to have_received(:import_wallet).with(
        basket: 'staging', no_send: false,
        accept_delayed_broadcast: false, include_unconfirmed: true
      )
    end
  end

  describe 'human summary' do
    it 'reports the imported count' do
      expect { command.call([]) }.to output(/imported:\s+3 UTXOs/).to_stderr
    end

    it 'pluralises singular correctly' do
      allow(engine).to receive(:import_wallet).and_return(imported: 1, utxos: [])
      expect { command.call([]) }.to output(/imported:\s+1 UTXO\b/).to_stderr
    end

    it 'reports zero imports cleanly' do
      allow(engine).to receive(:import_wallet).and_return(imported: 0, utxos: [])
      expect { command.call([]) }.to output(/imported:\s+0 UTXOs/).to_stderr
    end

    it 'reports the basket (or unbasketed pool when omitted)' do
      expect { command.call([]) }.to output(/basket:\s+\(unbasketed pool\)/).to_stderr
    end

    it 'shows the basket name when --basket is set' do
      expect { command.call(['--basket=named']) }
        .to output(/basket:\s+named/).to_stderr
    end
  end
end
