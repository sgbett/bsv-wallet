# frozen_string_literal: true

require 'bsv/wallet/engine/reaper'

RSpec.describe BSV::Wallet::Engine::Reaper do
  subject(:reaper) { described_class.new(store: store) }

  let(:store) { double('Store') }
  let(:action_id) { 42 }

  # Capture all emit calls for assertion.
  let(:emitted_events) { [] }

  before do
    allow(BSV::Wallet).to receive(:emit) { |name, **payload| emitted_events << { name: name, **payload } }
  end

  describe '.pending' do
    it 'delegates to Store#stale_action_ids' do
      allow(store).to receive(:stale_action_ids).with(threshold: 3600, limit: 50).and_return([1, 2])

      expect(described_class.pending(store, limit: 50, threshold: 3600)).to eq([1, 2])
      expect(store).to have_received(:stale_action_ids).with(threshold: 3600, limit: 50)
    end
  end

  describe '#process' do
    it 'emits dispatched then succeeded when the action is reclaimed' do
      allow(store).to receive(:reap_action).with(action_id: action_id).and_return(true)

      reaper.process(action_id)

      expect(emitted_events.map { |e| e[:name] }).to eq(%w[task.dispatched task.succeeded])
      expect(emitted_events.last).to include(task: 'reaper', id: action_id)
    end

    it 'emits dispatched then skipped when the action is no longer reapable' do
      allow(store).to receive(:reap_action).with(action_id: action_id).and_return(false)

      reaper.process(action_id)

      expect(emitted_events.map { |e| e[:name] }).to eq(%w[task.dispatched task.skipped])
      expect(emitted_events.last).to include(task: 'reaper', id: action_id, reason: :not_reapable)
    end

    it 'emits dispatched then failed when reap_action raises (drain contract holds)' do
      allow(store).to receive(:reap_action).and_raise(StandardError, 'boom')

      reaper.process(action_id)

      expect(emitted_events.map { |e| e[:name] }).to eq(%w[task.dispatched task.failed])
      expect(emitted_events.last).to include(task: 'reaper', id: action_id, error: 'boom')
    end
  end
end
