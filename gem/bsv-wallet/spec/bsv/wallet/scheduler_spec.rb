# frozen_string_literal: true

require 'bsv/wallet/scheduler'
require 'bsv/wallet/engine/broadcast'
require 'bsv/wallet/engine/tx_proof'

RSpec.describe BSV::Wallet::Scheduler do
  let(:store) { double('Store') }
  let(:scheduler) { described_class.new(store: store) }

  describe '#run!' do
    it 'pushes pending broadcast IDs to the broadcast endpoint' do
      allow(BSV::Wallet::Engine::Broadcast).to receive(:pending).with(store, limit: 10).and_return([1, 2])
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

    it 'pushes pending proof IDs to the proof endpoint' do
      allow(BSV::Wallet::Engine::Broadcast).to receive(:pending).with(store, limit: 10).and_return([])
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
      allow(BSV::Wallet::Engine::Broadcast).to receive(:pending) do
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
      allow(BSV::Wallet::Engine::Broadcast).to receive(:pending).with(store, limit: 10).and_return([])
      allow(BSV::Wallet::Engine::TxProof).to receive(:pending).with(store, limit: 10).and_return([])

      Async do |task|
        OMQ::PULL.bind('inproc://broadcasts.pull')
        OMQ::PULL.bind('inproc://proofs.pull')

        scheduler.run!(task: task)

        # Give the loops time to run one cycle
        sleep 0.05

        expect(BSV::Wallet::Engine::Broadcast).to have_received(:pending).at_least(:once)
        expect(BSV::Wallet::Engine::TxProof).to have_received(:pending).at_least(:once)
      ensure
        task.stop
      end
    end
  end
end
