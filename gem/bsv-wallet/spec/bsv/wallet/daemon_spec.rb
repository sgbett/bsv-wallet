# frozen_string_literal: true

RSpec.describe BSV::Wallet::Daemon do
  subject(:daemon) do
    described_class.new(
      services: services,
      pending_pushes: pending_pushes,
      stale_fetches: stale_fetches,
      pending_proofs: pending_proofs,
      interval: 0
    )
  end

  let(:services) { instance_double(BSV::Network::Services) }

  let(:pushable_entity) do
    double(:pushable, push_command: :broadcast, push_payload: 'raw_tx')
  end
  let(:fetchable_broadcast) do
    double(:fetchable_broadcast, fetch_command: :get_tx_status, fetch_args: { txid: 'abc' })
  end
  let(:fetchable_action) do
    double(:fetchable_action, fetch_command: :get_tx_status, fetch_args: { txid: 'def' })
  end

  let(:pending_pushes) { -> { [] } }
  let(:stale_fetches) { -> { [] } }
  let(:pending_proofs) { -> { [] } }

  describe '#run_cycle' do
    context 'with pending pushes' do
      let(:pending_pushes) { -> { [pushable_entity] } }

      it 'calls services.push! for each entity' do
        allow(services).to receive(:push!)
        daemon.run_cycle
        expect(services).to have_received(:push!).with(pushable_entity)
      end
    end

    context 'with stale fetches' do
      let(:stale_fetches) { -> { [fetchable_broadcast] } }

      it 'calls services.fetch! for each stale broadcast' do
        allow(services).to receive(:fetch!)
        daemon.run_cycle
        expect(services).to have_received(:fetch!).with(fetchable_broadcast)
      end
    end

    context 'with pending proofs' do
      let(:pending_proofs) { -> { [fetchable_action] } }

      it 'calls services.fetch! for each action needing proof' do
        allow(services).to receive(:fetch!)
        daemon.run_cycle
        expect(services).to have_received(:fetch!).with(fetchable_action)
      end
    end

    context 'with empty result sets' do
      it 'completes without calling services' do
        expect { daemon.run_cycle }.not_to raise_error
      end
    end

    context 'with mixed entities' do
      let(:pending_pushes) { -> { [pushable_entity] } }
      let(:stale_fetches) { -> { [fetchable_broadcast] } }
      let(:pending_proofs) { -> { [fetchable_action] } }

      it 'processes all entity types in one cycle' do
        allow(services).to receive(:push!)
        allow(services).to receive(:fetch!)

        daemon.run_cycle

        expect(services).to have_received(:push!).with(pushable_entity)
        expect(services).to have_received(:fetch!).with(fetchable_broadcast)
        expect(services).to have_received(:fetch!).with(fetchable_action)
      end
    end
  end

  describe 'per-entity error isolation' do
    let(:failing_entity) do
      double(:failing, push_command: :broadcast, push_payload: 'bad')
    end
    let(:good_entity) do
      double(:good, push_command: :broadcast, push_payload: 'good')
    end
    let(:pending_pushes) { -> { [failing_entity, good_entity] } }

    it 'continues processing after one entity fails' do
      allow(services).to receive(:push!).with(failing_entity).and_raise(StandardError, 'network down')
      allow(services).to receive(:push!).with(good_entity)

      daemon.run_cycle

      expect(services).to have_received(:push!).with(good_entity)
    end

    it 'does not crash the cycle when a fetch fails' do
      fetch_fail = double(:fetch_fail, fetch_command: :get_tx_status, fetch_args: { txid: 'x' })
      fetch_ok = double(:fetch_ok, fetch_command: :get_tx_status, fetch_args: { txid: 'y' })
      daemon_with_fetches = described_class.new(
        services: services,
        stale_fetches: -> { [fetch_fail, fetch_ok] },
        interval: 0
      )

      allow(services).to receive(:fetch!).with(fetch_fail).and_raise(StandardError, 'timeout')
      allow(services).to receive(:fetch!).with(fetch_ok)

      daemon_with_fetches.run_cycle

      expect(services).to have_received(:fetch!).with(fetch_ok)
    end
  end

  describe 'idempotency' do
    it 'is a no-op when called twice with no state changes' do
      allow(services).to receive(:push!)
      allow(services).to receive(:fetch!)

      daemon.run_cycle
      daemon.run_cycle

      # With empty queries, services should not be called at all
      expect(services).not_to have_received(:push!)
      expect(services).not_to have_received(:fetch!)
    end
  end

  describe '#start and #stop' do
    it 'runs cycles until stop is called' do
      call_count = 0
      test_daemon = described_class.new(
        services: services,
        pending_pushes: lambda {
          call_count += 1
          test_daemon.stop if call_count >= 3
          []
        },
        interval: 0
      )

      test_daemon.start

      expect(call_count).to eq(3)
    end

    it 'is not running initially' do
      expect(daemon.running?).to be false
    end
  end

  describe 'cycle-level error handling' do
    it 'does not crash when a query callable raises' do
      broken_daemon = described_class.new(
        services: services,
        pending_pushes: -> { raise StandardError, 'DB connection lost' },
        interval: 0
      )

      expect { broken_daemon.run_cycle }.not_to raise_error
    end
  end
end
