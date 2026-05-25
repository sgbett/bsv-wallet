# frozen_string_literal: true

require 'spec_helper'
require 'logger'
require 'stringio'
require 'bsv/wallet/scheduler'
require 'bsv/wallet/engine/broadcast'
require 'bsv/wallet/engine/tx_proof'

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

  describe '#run!' do
    before do
      allow(BSV::Wallet::Engine::Broadcast).to receive(:pending_pushes).with(store, limit: 10).and_return([])
    end

    it 'pushes pending broadcast IDs to the broadcast endpoint' do
      allow(BSV::Wallet::Engine::Broadcast).to receive(:pending_polls).with(store, limit: 10).and_return([1, 2])
      allow(BSV::Wallet::Engine::TxProof).to receive(:pending).with(store, limit: 10).and_return([])

      Async do |task|
        broadcast_pull = OMQ::PULL.bind('inproc://broadcasts.pull')
        OMQ::PULL.bind('inproc://proofs.pull')

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
      allow(BSV::Wallet::Engine::Broadcast).to receive(:pending_polls).with(store, limit: 10).and_return([])
      allow(BSV::Wallet::Engine::Broadcast).to receive(:pending_pushes).with(store, limit: 10).and_return([3, 4])
      allow(BSV::Wallet::Engine::TxProof).to receive(:pending).with(store, limit: 10).and_return([])

      Async do |task|
        broadcast_pull = OMQ::PULL.bind('inproc://broadcasts.pull')
        OMQ::PULL.bind('inproc://proofs.pull')

        scheduler.run!(task: task)

        messages = []
        2.times { messages << broadcast_pull.receive.first }

        expect(messages).to eq(%w[3 4])
      ensure
        task.stop
      end
    end

    it 'emits task.discovered with task=broadcast_push_submission when pushes are queued' do
      allow(BSV::Wallet::Engine::Broadcast).to receive(:pending_polls).with(store, limit: 10).and_return([])
      allow(BSV::Wallet::Engine::Broadcast).to receive(:pending_pushes).with(store, limit: 10).and_return([3, 4])
      allow(BSV::Wallet::Engine::TxProof).to receive(:pending).with(store, limit: 10).and_return([])

      Async do |task|
        broadcast_pull = OMQ::PULL.bind('inproc://broadcasts.pull')
        OMQ::PULL.bind('inproc://proofs.pull')

        scheduler.run!(task: task)
        2.times { broadcast_pull.receive }

        expect(log_output.string).to include('[event] task.discovered task=broadcast_push_submission count=2')
      ensure
        task.stop
      end
    end

    it 'pushes pending proof IDs to the proof endpoint' do
      allow(BSV::Wallet::Engine::Broadcast).to receive(:pending_polls).with(store, limit: 10).and_return([])
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

    it 'continues when a discovery query raises' do
      call_count = 0
      allow(BSV::Wallet::Engine::Broadcast).to receive(:pending_polls) do
        call_count += 1
        raise 'db error' if call_count == 1

        [42]
      end
      allow(BSV::Wallet::Engine::TxProof).to receive(:pending).with(store, limit: 10).and_return([])

      Async do |task|
        broadcast_pull = OMQ::PULL.bind('inproc://broadcasts.pull')
        OMQ::PULL.bind('inproc://proofs.pull')

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
      allow(BSV::Wallet::Engine::Broadcast).to receive(:pending_polls).with(store, limit: 10).and_return([])
      allow(BSV::Wallet::Engine::TxProof).to receive(:pending).with(store, limit: 10).and_return([])

      Async do |task|
        OMQ::PULL.bind('inproc://broadcasts.pull')
        OMQ::PULL.bind('inproc://proofs.pull')

        scheduler.run!(task: task)

        # Give the loops time to run one cycle
        sleep 0.05

        expect(BSV::Wallet::Engine::Broadcast).to have_received(:pending_polls).at_least(:once)
        expect(BSV::Wallet::Engine::TxProof).to have_received(:pending).at_least(:once)
      ensure
        task.stop
      end
    end

    it 'emits task.discovered with count=2 when two ids are returned' do
      allow(BSV::Wallet::Engine::Broadcast).to receive(:pending_polls).with(store, limit: 10).and_return([1, 2])
      allow(BSV::Wallet::Engine::TxProof).to receive(:pending).with(store, limit: 10).and_return([])

      Async do |task|
        broadcast_pull = OMQ::PULL.bind('inproc://broadcasts.pull')
        OMQ::PULL.bind('inproc://proofs.pull')

        scheduler.run!(task: task)

        # Wait for messages to be pushed (confirms the loop ran)
        2.times { broadcast_pull.receive }

        expect(log_output.string).to include('[event] task.discovered task=broadcast_push count=2')
      ensure
        task.stop
      end
    end

    it 'emits one task.enqueued per id' do
      allow(BSV::Wallet::Engine::Broadcast).to receive(:pending_polls).with(store, limit: 10).and_return([5, 7])
      allow(BSV::Wallet::Engine::TxProof).to receive(:pending).with(store, limit: 10).and_return([])

      Async do |task|
        broadcast_pull = OMQ::PULL.bind('inproc://broadcasts.pull')
        OMQ::PULL.bind('inproc://proofs.pull')

        scheduler.run!(task: task)

        2.times { broadcast_pull.receive }

        log = log_output.string
        expect(log).to include('[event] task.enqueued task=broadcast_push id=5')
        expect(log).to include('[event] task.enqueued task=broadcast_push id=7')
      ensure
        task.stop
      end
    end

    it 'emits neither when discovery returns []' do
      allow(BSV::Wallet::Engine::Broadcast).to receive(:pending_polls).with(store, limit: 10).and_return([])
      allow(BSV::Wallet::Engine::TxProof).to receive(:pending).with(store, limit: 10).and_return([])

      Async do |task|
        OMQ::PULL.bind('inproc://broadcasts.pull')
        OMQ::PULL.bind('inproc://proofs.pull')

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
      allow(BSV::Wallet::Engine::Broadcast).to receive(:pending_polls) do
        call_count += 1
        raise 'db error' if call_count == 1

        [42]
      end
      allow(BSV::Wallet::Engine::TxProof).to receive(:pending).with(store, limit: 10).and_return([])

      Async do |task|
        broadcast_pull = OMQ::PULL.bind('inproc://broadcasts.pull')
        OMQ::PULL.bind('inproc://proofs.pull')

        scheduler.run!(task: task)

        # Wait for the retry cycle to push a message
        broadcast_pull.receive

        expect(log_output.string).to include('[event] fiber.crashed task=broadcast_push error=db error')
      ensure
        task.stop
      end
    end
  end
end
