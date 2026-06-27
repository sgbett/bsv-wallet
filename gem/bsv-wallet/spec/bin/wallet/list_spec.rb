# frozen_string_literal: true

require 'spec_helper'
require 'bsv/wallet/cli/commands/list'

RSpec.describe BSV::Wallet::CLI::Commands::List do
  let(:engine) { instance_double(BSV::Wallet::Engine) }
  let(:ctx) { { engine: engine, identity_key: '02abcd' } }
  let(:global_options) { BSV::Wallet::CLI::GlobalOptions.default }
  let(:command) { described_class.new(ctx: ctx, global_options: global_options) }

  describe 'noun validation' do
    it 'raises UsageError when no noun is given' do
      expect { command.call([]) }.to raise_error(BSV::Wallet::CLI::UsageError, /requires a noun/)
    end

    it 'raises UsageError for an unknown noun' do
      expect { command.call(['transactions']) }.to raise_error(BSV::Wallet::CLI::UsageError, /unknown list noun/)
    end
  end

  describe 'list outputs' do
    before do
      allow(engine).to receive(:spendable_outputs).and_return(
        { outputs: [{ id: 1 }, { id: 2 }], total: 2 }
      )
    end

    it 'defaults to --limit=100' do
      command.call(['outputs'])
      expect(engine).to have_received(:spendable_outputs).with(limit: 100, offset: 0)
    end

    it 'forwards --basket' do
      command.call(['outputs', '--basket=received'])
      expect(engine).to have_received(:spendable_outputs).with(
        limit: 100, offset: 0, basket: 'received'
      )
    end

    it 'forwards --basket=none as nil' do
      command.call(['outputs', '--basket=none'])
      expect(engine).to have_received(:spendable_outputs).with(
        limit: 100, offset: 0, basket: nil
      )
    end

    it '--all lifts the limit' do
      command.call(['outputs', '--all'])
      expect(engine).to have_received(:spendable_outputs).with(limit: 10_000, offset: 0)
    end

    it 'emits one NDJSON row per output' do
      expect { command.call(['outputs']) }.to output(/^\{"id":1\}\n\{"id":2\}/).to_stdout
    end
  end

  describe 'list actions' do
    it 'requires at least one --label' do
      expect do
        command.call(['actions'])
      end.to raise_error(BSV::Wallet::CLI::UsageError, /requires at least one --label/)
    end

    it 'forwards labels to engine.list_actions' do
      allow(engine).to receive(:list_actions).and_return({ actions: [], total: 0 })
      command.call(['actions', '--label=foo'])
      expect(engine).to have_received(:list_actions).with(
        labels: ['foo'], label_query_mode: :any, limit: 100, offset: 0
      )
    end

    it 'accepts multiple --label flags' do
      allow(engine).to receive(:list_actions).and_return({ actions: [], total: 0 })
      command.call(['actions', '--label=foo', '--label=bar'])
      expect(engine).to have_received(:list_actions).with(
        labels: %w[foo bar], label_query_mode: :any, limit: 100, offset: 0
      )
    end

    it 'emits one NDJSON row per action' do
      allow(engine).to receive(:list_actions).and_return(
        { actions: [{ ref: 'a' }, { ref: 'b' }], total: 2 }
      )
      expect do
        command.call(['actions', '--label=foo'])
      end.to output(/^\{"ref":"a"\}\n\{"ref":"b"\}/).to_stdout
    end
  end
end
