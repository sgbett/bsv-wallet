# frozen_string_literal: true

require 'spec_helper'
require 'logger'
require 'stringio'
require 'bsv/wallet/scheduler'
require 'bsv/wallet/engine/broadcast'
require 'bsv/wallet/engine/tx_proof'
require 'bsv/wallet/engine/reaper'

RSpec.describe BSV::Wallet::Scheduler do
  let(:store) { double('Store') }
  let(:scheduler) { described_class.new(store: store) }

  let(:log_output) { StringIO.new }

  around do |example|
    original_logger = BSV.logger
    BSV.logger = Logger.new(log_output, level: Logger::INFO)
    example.run
  ensure
    BSV.logger = original_logger
  end

  # The reaper loop runs alongside the others; keep it quiet unless a test
  # exercises it. Individual tests override with a non-empty return.
  before { allow(BSV::Wallet::Engine::Reaper).to receive(:pending).and_return([]) }

  describe '#run!' do
    before do
      allow(BSV::Wallet::Engine::Broadcast).to receive(:pending_submissions).with(store, limit: 10).and_return([])
    end

    it 'pushes pending broadcast IDs to the broadcast endpoint' do
      allow(BSV::Wallet::Engine::Broadcast).to receive(:pending_resolutions).with(store, limit: 10).and_return([1, 2])
      allow(BSV::Wallet::Engine::TxProof).to receive(:pending).with(store, limit: 10).and_return([])

      Async do |task|
        broadcast_pull = OMQ::PULL.bind('inproc://broadcasts.pull')
        OMQ::PULL.bind('inproc://proofs.pull')
        OMQ::PULL.bind('inproc://reaper.pull')

        scheduler.run!(task: task)

        # Collect messages from broadcast pull socket
        messages = []
        2.times { messages << broadcast_pull.receive.first }

        expect(messages).to eq(%w[1 2])
      ensure
        task.stop
      end
    end

    it 'pushes pending push-submission IDs to the broadcast endpoint' do
      allow(BSV::Wallet::Engine::Broadcast).to receive(:pending_resolutions).with(store, limit: 10).and_return([])
      allow(BSV::Wallet::Engine::Broadcast).to receive(:pending_submissions).with(store, limit: 10).and_return([3, 4])
      allow(BSV::Wallet::Engine::TxProof).to receive(:pending).with(store, limit: 10).and_return([])

      Async do |task|
        broadcast_pull = OMQ::PULL.bind('inproc://broadcasts.pull')
        OMQ::PULL.bind('inproc://proofs.pull')
        OMQ::PULL.bind('inproc://reaper.pull')

        scheduler.run!(task: task)

        messages = []
        2.times { messages << broadcast_pull.receive.first }

        expect(messages).to eq(%w[3 4])
      ensure
        task.stop
      end
    end

    it 'emits task.discovered with task=broadcast_submission when pushes are queued' do
      allow(BSV::Wallet::Engine::Broadcast).to receive(:pending_resolutions).with(store, limit: 10).and_return([])
      allow(BSV::Wallet::Engine::Broadcast).to receive(:pending_submissions).with(store, limit: 10).and_return([3, 4])
      allow(BSV::Wallet::Engine::TxProof).to receive(:pending).with(store, limit: 10).and_return([])

      Async do |task|
        broadcast_pull = OMQ::PULL.bind('inproc://broadcasts.pull')
        OMQ::PULL.bind('inproc://proofs.pull')
        OMQ::PULL.bind('inproc://reaper.pull')

        scheduler.run!(task: task)
        2.times { broadcast_pull.receive }

        expect(log_output.string).to include('[event] task.discovered task=broadcast_submission count=2')
      ensure
        task.stop
      end
    end

    it 'pushes pending proof IDs to the proof endpoint' do
      allow(BSV::Wallet::Engine::Broadcast).to receive(:pending_resolutions).with(store, limit: 10).and_return([])
      allow(BSV::Wallet::Engine::TxProof).to receive(:pending).with(store, limit: 10).and_return([10, 20])

      Async do |task|
        OMQ::PULL.bind('inproc://broadcasts.pull')
        proof_pull = OMQ::PULL.bind('inproc://proofs.pull')

        scheduler.run!(task: task)

        messages = []
        2.times { messages << proof_pull.receive.first }

        expect(messages).to eq(%w[10 20])
      ensure
        task.stop
      end
    end

    it 'pushes pending reaper IDs to the reaper endpoint' do
      allow(BSV::Wallet::Engine::Broadcast).to receive(:pending_resolutions).with(store, limit: 10).and_return([])
      allow(BSV::Wallet::Engine::TxProof).to receive(:pending).with(store, limit: 10).and_return([])
      allow(BSV::Wallet::Engine::Reaper).to receive(:pending).and_return([99, 100])

      Async do |task|
        OMQ::PULL.bind('inproc://broadcasts.pull')
        OMQ::PULL.bind('inproc://proofs.pull')
        reaper_pull = OMQ::PULL.bind('inproc://reaper.pull')

        scheduler.run!(task: task)

        messages = []
        2.times { messages << reaper_pull.receive.first }

        expect(messages).to eq(%w[99 100])
      ensure
        task.stop
      end
    end

    it 'continues when a discovery query raises' do
      call_count = 0
      allow(BSV::Wallet::Engine::Broadcast).to receive(:pending_resolutions) do
        call_count += 1
        raise 'db error' if call_count == 1

        [42]
      end
      allow(BSV::Wallet::Engine::TxProof).to receive(:pending).with(store, limit: 10).and_return([])

      Async do |task|
        broadcast_pull = OMQ::PULL.bind('inproc://broadcasts.pull')
        OMQ::PULL.bind('inproc://proofs.pull')
        OMQ::PULL.bind('inproc://reaper.pull')

        scheduler.run!(task: task)

        # The first call raises, the second should succeed after sleep.
        # We receive the message from the retry.
        msg = broadcast_pull.receive.first
        expect(msg).to eq('42')
      ensure
        task.stop
      end
    end

    it 'does not push anything when no pending work' do
      allow(BSV::Wallet::Engine::Broadcast).to receive(:pending_resolutions).with(store, limit: 10).and_return([])
      allow(BSV::Wallet::Engine::TxProof).to receive(:pending).with(store, limit: 10).and_return([])

      Async do |task|
        OMQ::PULL.bind('inproc://broadcasts.pull')
        OMQ::PULL.bind('inproc://proofs.pull')
        OMQ::PULL.bind('inproc://reaper.pull')

        scheduler.run!(task: task)

        # Give the loops time to run one cycle
        sleep 0.05

        expect(BSV::Wallet::Engine::Broadcast).to have_received(:pending_resolutions).at_least(:once)
        expect(BSV::Wallet::Engine::TxProof).to have_received(:pending).at_least(:once)
      ensure
        task.stop
      end
    end

    it 'emits task.discovered with count=2 when two ids are returned' do
      allow(BSV::Wallet::Engine::Broadcast).to receive(:pending_resolutions).with(store, limit: 10).and_return([1, 2])
      allow(BSV::Wallet::Engine::TxProof).to receive(:pending).with(store, limit: 10).and_return([])

      Async do |task|
        broadcast_pull = OMQ::PULL.bind('inproc://broadcasts.pull')
        OMQ::PULL.bind('inproc://proofs.pull')
        OMQ::PULL.bind('inproc://reaper.pull')

        scheduler.run!(task: task)

        # Wait for messages to be pushed (confirms the loop ran)
        2.times { broadcast_pull.receive }

        expect(log_output.string).to include('[event] task.discovered task=broadcast_resolution count=2')
      ensure
        task.stop
      end
    end

    it 'emits one task.enqueued per id' do
      allow(BSV::Wallet::Engine::Broadcast).to receive(:pending_resolutions).with(store, limit: 10).and_return([5, 7])
      allow(BSV::Wallet::Engine::TxProof).to receive(:pending).with(store, limit: 10).and_return([])

      Async do |task|
        broadcast_pull = OMQ::PULL.bind('inproc://broadcasts.pull')
        OMQ::PULL.bind('inproc://proofs.pull')
        OMQ::PULL.bind('inproc://reaper.pull')

        scheduler.run!(task: task)

        2.times { broadcast_pull.receive }

        log = log_output.string
        expect(log).to include('[event] task.enqueued task=broadcast_resolution id=5')
        expect(log).to include('[event] task.enqueued task=broadcast_resolution id=7')
      ensure
        task.stop
      end
    end

    it 'emits neither when discovery returns []' do
      allow(BSV::Wallet::Engine::Broadcast).to receive(:pending_resolutions).with(store, limit: 10).and_return([])
      allow(BSV::Wallet::Engine::TxProof).to receive(:pending).with(store, limit: 10).and_return([])

      Async do |task|
        OMQ::PULL.bind('inproc://broadcasts.pull')
        OMQ::PULL.bind('inproc://proofs.pull')
        OMQ::PULL.bind('inproc://reaper.pull')

        scheduler.run!(task: task)

        sleep 0.05

        log = log_output.string
        expect(log).not_to include('task.discovered')
        expect(log).not_to include('task.enqueued')
      ensure
        task.stop
      end
    end

    it 'emits fiber.crashed when discovery raises' do
      call_count = 0
      allow(BSV::Wallet::Engine::Broadcast).to receive(:pending_resolutions) do
        call_count += 1
        raise 'db error' if call_count == 1

        [42]
      end
      allow(BSV::Wallet::Engine::TxProof).to receive(:pending).with(store, limit: 10).and_return([])

      Async do |task|
        broadcast_pull = OMQ::PULL.bind('inproc://broadcasts.pull')
        OMQ::PULL.bind('inproc://proofs.pull')
        OMQ::PULL.bind('inproc://reaper.pull')

        scheduler.run!(task: task)

        # Wait for the retry cycle to push a message
        broadcast_pull.receive

        expect(log_output.string).to include('[event] fiber.crashed task=broadcast_resolution error=db error')
      ensure
        task.stop
      end
    end
  end

  describe 'in-flight tracking' do
    it 'starts at zero' do
      expect(scheduler.in_flight).to eq(0)
    end

    it 'increments on task.dispatched and decrements on task.succeeded' do
      Async do |task|
        OMQ::PULL.bind('inproc://broadcasts.pull')
        OMQ::PULL.bind('inproc://proofs.pull')
        OMQ::PULL.bind('inproc://reaper.pull')
        allow(BSV::Wallet::Engine::Broadcast).to receive_messages(pending_submissions: [], pending_resolutions: [])
        allow(BSV::Wallet::Engine::TxProof).to receive(:pending).and_return([])

        scheduler.run!(task: task)
        BSV::Wallet.emit('task.dispatched', task: 'broadcast_resolution', id: 1)
        expect(scheduler.in_flight).to eq(1)

        BSV::Wallet.emit('task.succeeded', task: 'broadcast_resolution', id: 1, latency_ms: 10, outcome: :accepted)
        expect(scheduler.in_flight).to eq(0)
      ensure
        task.stop
      end
    end

    %w[task.failed task.aborted task.skipped].each do |terminal|
      it "decrements on #{terminal}" do
        Async do |task|
          OMQ::PULL.bind('inproc://broadcasts.pull')
          OMQ::PULL.bind('inproc://proofs.pull')
          OMQ::PULL.bind('inproc://reaper.pull')
          allow(BSV::Wallet::Engine::Broadcast).to receive_messages(pending_submissions: [], pending_resolutions: [])
          allow(BSV::Wallet::Engine::TxProof).to receive(:pending).and_return([])

          scheduler.run!(task: task)
          BSV::Wallet.emit('task.dispatched', task: 'broadcast_resolution', id: 1)
          BSV::Wallet.emit(terminal, task: 'broadcast_resolution', id: 1)
          expect(scheduler.in_flight).to eq(0)
        ensure
          task.stop
        end
      end
    end

    it 'ignores non-lifecycle events' do
      Async do |task|
        OMQ::PULL.bind('inproc://broadcasts.pull')
        OMQ::PULL.bind('inproc://proofs.pull')
        OMQ::PULL.bind('inproc://reaper.pull')
        allow(BSV::Wallet::Engine::Broadcast).to receive_messages(pending_submissions: [], pending_resolutions: [])
        allow(BSV::Wallet::Engine::TxProof).to receive(:pending).and_return([])

        scheduler.run!(task: task)
        BSV::Wallet.emit('daemon.started', wallet: 'alice', network: 'mainnet')
        BSV::Wallet.emit('task.enqueued', task: 'broadcast_resolution', id: 1)
        BSV::Wallet.emit('task.discovered', task: 'broadcast_resolution', count: 1)
        expect(scheduler.in_flight).to eq(0)
      ensure
        task.stop
      end
    end
  end

  describe '#shutdown' do
    it 'returns true immediately when no work is in flight' do
      Async do |task|
        OMQ::PULL.bind('inproc://broadcasts.pull')
        OMQ::PULL.bind('inproc://proofs.pull')
        OMQ::PULL.bind('inproc://reaper.pull')
        allow(BSV::Wallet::Engine::Broadcast).to receive_messages(pending_submissions: [], pending_resolutions: [])
        allow(BSV::Wallet::Engine::TxProof).to receive(:pending).and_return([])

        scheduler.run!(task: task)
        elapsed_start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        result = scheduler.shutdown(timeout: 5.0)
        elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - elapsed_start

        expect(result).to be(true)
        expect(elapsed).to be < 0.5
      ensure
        task.stop
      end
    end

    it 'waits for in-flight work to drain and returns true' do
      Async do |task|
        OMQ::PULL.bind('inproc://broadcasts.pull')
        OMQ::PULL.bind('inproc://proofs.pull')
        OMQ::PULL.bind('inproc://reaper.pull')
        allow(BSV::Wallet::Engine::Broadcast).to receive_messages(pending_submissions: [], pending_resolutions: [])
        allow(BSV::Wallet::Engine::TxProof).to receive(:pending).and_return([])

        scheduler.run!(task: task)
        BSV::Wallet.emit('task.dispatched', task: 'broadcast_resolution', id: 1)

        # Simulate the in-flight task completing partway through the drain.
        task.async do
          sleep 0.2
          BSV::Wallet.emit('task.succeeded', task: 'broadcast_resolution', id: 1, outcome: :accepted)
        end

        result = scheduler.shutdown(timeout: 2.0)
        expect(result).to be(true)
        expect(scheduler.in_flight).to eq(0)
      ensure
        task.stop
      end
    end

    it 'returns false on timeout when in-flight work never settles' do
      Async do |task|
        OMQ::PULL.bind('inproc://broadcasts.pull')
        OMQ::PULL.bind('inproc://proofs.pull')
        OMQ::PULL.bind('inproc://reaper.pull')
        allow(BSV::Wallet::Engine::Broadcast).to receive_messages(pending_submissions: [], pending_resolutions: [])
        allow(BSV::Wallet::Engine::TxProof).to receive(:pending).and_return([])

        scheduler.run!(task: task)
        BSV::Wallet.emit('task.dispatched', task: 'broadcast_resolution', id: 1)

        result = scheduler.shutdown(timeout: 0.3)
        expect(result).to be(false)
        expect(scheduler.in_flight).to eq(1)
      ensure
        task.stop
      end
    end

    it 'flips stopping? to true' do
      Async do |task|
        OMQ::PULL.bind('inproc://broadcasts.pull')
        OMQ::PULL.bind('inproc://proofs.pull')
        OMQ::PULL.bind('inproc://reaper.pull')
        allow(BSV::Wallet::Engine::Broadcast).to receive_messages(pending_submissions: [], pending_resolutions: [])
        allow(BSV::Wallet::Engine::TxProof).to receive(:pending).and_return([])

        scheduler.run!(task: task)
        expect(scheduler.stopping?).to be(false)
        scheduler.shutdown(timeout: 1.0)
        expect(scheduler.stopping?).to be(true)
      ensure
        task.stop
      end
    end

    it 'deregisters its lifecycle observer (does not leak observers across instances)' do
      Async do |task|
        OMQ::PULL.bind('inproc://broadcasts.pull')
        OMQ::PULL.bind('inproc://proofs.pull')
        OMQ::PULL.bind('inproc://reaper.pull')
        allow(BSV::Wallet::Engine::Broadcast).to receive_messages(pending_submissions: [], pending_resolutions: [])
        allow(BSV::Wallet::Engine::TxProof).to receive(:pending).and_return([])

        baseline = BSV::Wallet.event_observer_count
        scheduler.run!(task: task)
        expect(BSV::Wallet.event_observer_count).to eq(baseline + 1)

        scheduler.shutdown(timeout: 1.0)
        expect(BSV::Wallet.event_observer_count).to eq(baseline)
      ensure
        task.stop
      end
    end
  end
end
