# frozen_string_literal: true

require 'spec_helper'
require 'logger'
require 'stringio'
require 'bsv/wallet/daemon'

RSpec.describe BSV::Wallet::Daemon do
  # Plain double — instance_double(BSV::Wallet::Store) triggers autoloading
  # of Store::Models which requires a live Sequel connection.
  let(:store) { double('store') }
  let(:broadcaster) { instance_double(BSV::Network::Broadcaster) }
  let(:wallet_name) { 'alice' }
  let(:network) { :mainnet }
  let(:daemon) do
    described_class.new(store: store, broadcaster: broadcaster,
                        wallet: wallet_name, network: network)
  end

  let(:broadcast) { instance_double(BSV::Wallet::Engine::Broadcast) }
  let(:tx_proof) { instance_double(BSV::Wallet::Engine::TxProof) }
  let(:scheduler) { instance_double(BSV::Wallet::Scheduler) }

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
      allow(BSV::Wallet::Engine::Broadcast).to receive(:new)
        .with(store: store, broadcaster: broadcaster).and_return(broadcast)
      allow(BSV::Wallet::Engine::TxProof).to receive(:new)
        .with(store: store, broadcaster: broadcaster).and_return(tx_proof)
      allow(BSV::Wallet::Scheduler).to receive(:new)
        .with(store: store).and_return(scheduler)

      allow(broadcast).to receive_messages(pull!: broadcast, reply!: broadcast,
                                           statuses_pull!: broadcast)
      allow(tx_proof).to receive(:pull!).and_return(tx_proof)
      allow(scheduler).to receive(:run!)
    end

    it 'calls statuses_pull! on Broadcast (drains SSE-delivered events)' do
      Async do |task|
        daemon.run!
        task.stop
      end

      expect(broadcast).to have_received(:statuses_pull!)
    end

    it 'does NOT boot the SSE listener when callback_token: is nil (default)' do
      allow(BSV::Network::SSEListener).to receive(:new)

      Async do |task|
        daemon.run!
        task.stop
      end

      expect(BSV::Network::SSEListener).not_to have_received(:new)
    end

    context 'when callback_token: is provided' do
      let(:listener) { instance_double(BSV::Network::SSEListener, run!: nil, stop!: nil) }
      let(:daemon) do
        described_class.new(store: store, broadcaster: broadcaster,
                            wallet: wallet_name, network: network,
                            callback_token: 'tok-abc123')
      end

      before do
        allow(BSV::Network::SSEListener).to receive(:new).and_return(listener)
      end

      # The daemon's PUSH socket connects to +inproc://statuses.pull+ ---
      # OMQ.await_bind waits one reconnect_interval (~100ms) when the
      # endpoint is unbound, which blocks the spawned listener fiber
      # from running through to SSEListener.new within the test window.
      # Real Daemon#run! binds the PULL via Engine::Broadcast#statuses_pull!
      # (also a spawned fiber); in this spec broadcast is mocked so we
      # bind a stand-in PULL here so the PUSH connect completes
      # immediately and the fiber proceeds to construct the listener.
      def bind_statuses_pull!(task)
        task.async { OMQ::PULL.bind('inproc://statuses.pull') }
      end

      it 'constructs SSEListener with the supplied token and the daemon store' do
        captured_kwargs = nil
        allow(BSV::Network::SSEListener).to receive(:new) do |**kwargs, &_block|
          captured_kwargs = kwargs
          listener
        end

        Async do |task|
          bind_statuses_pull!(task)
          daemon.run!
          sleep 0.05
          task.stop
        end

        expect(BSV::Network::SSEListener).to have_received(:new)
        expect(captured_kwargs).to include(token: 'tok-abc123', store: store)
      end

      it 'runs the listener as a peer Async task' do
        Async do |task|
          bind_statuses_pull!(task)
          daemon.run!
          sleep 0.05
          task.stop
        end

        expect(listener).to have_received(:run!)
      end

      it 'stops the listener cooperatively on stop!' do
        Async do |task|
          bind_statuses_pull!(task)
          daemon.run!
          sleep 0.05
          daemon.stop!
        ensure
          task.stop
        end

        expect(listener).to have_received(:stop!)
      end
    end

    it 'creates Engine::Broadcast with store and broadcaster' do
      Async do |task|
        daemon.run!
        task.stop
      end

      expect(BSV::Wallet::Engine::Broadcast).to have_received(:new)
        .with(store: store, broadcaster: broadcaster)
    end

    it 'calls pull! and reply! on Broadcast' do
      Async do |task|
        daemon.run!
        task.stop
      end

      expect(broadcast).to have_received(:pull!)
      expect(broadcast).to have_received(:reply!)
    end

    it 'creates Engine::TxProof with store and broadcaster' do
      Async do |task|
        daemon.run!
        task.stop
      end

      expect(BSV::Wallet::Engine::TxProof).to have_received(:new)
        .with(store: store, broadcaster: broadcaster)
    end

    it 'calls pull! on TxProof' do
      Async do |task|
        daemon.run!
        task.stop
      end

      expect(tx_proof).to have_received(:pull!)
    end

    it 'creates and runs the Scheduler' do
      Async do |task|
        daemon.run!
        task.stop
      end

      expect(BSV::Wallet::Scheduler).to have_received(:new).with(store: store)
      expect(scheduler).to have_received(:run!)
    end

    it 'sets up signal traps for INT and TERM' do
      allow(Signal).to receive(:trap)

      Async do |task|
        daemon.run!
        task.stop
      end

      expect(Signal).to have_received(:trap).with('INT')
      expect(Signal).to have_received(:trap).with('TERM')
    end

    it 'emits daemon.started with wallet and network on run!' do
      Async do |task|
        daemon.run!
        task.stop
      end

      expect(log_output.string).to include('[event] daemon.started wallet=alice network=mainnet')
    end

    it 'omits wallet field when wallet_name is nil' do
      daemon_no_wallet = described_class.new(store: store, broadcaster: broadcaster, network: network)

      Async do |task|
        daemon_no_wallet.run!
        task.stop
      end

      log = log_output.string
      expect(log).to include('[event] daemon.started')
      expect(log).not_to include('wallet=')
    end
  end

  describe '#stop!' do
    it 'stops the root async task' do
      task = instance_double(Async::Task)
      allow(task).to receive(:stop)
      daemon.instance_variable_set(:@task, task)

      daemon.stop!

      expect(task).to have_received(:stop)
    end

    it 'is safe to call before run!' do
      expect { daemon.stop! }.not_to raise_error
    end

    it 'emits daemon.stopped with reason=signal on stop!' do
      task = instance_double(Async::Task)
      allow(task).to receive(:stop)
      daemon.instance_variable_set(:@task, task)

      daemon.stop!

      expect(log_output.string).to include('[event] daemon.stopped reason=signal')
    end

    it 'is idempotent — repeat calls emit daemon.stopped only once' do
      task = instance_double(Async::Task)
      allow(task).to receive(:stop)
      daemon.instance_variable_set(:@task, task)

      daemon.stop!
      daemon.stop!
      daemon.stop!

      expect(log_output.string.scan('daemon.stopped').size).to eq(1)
      expect(task).to have_received(:stop).once
    end
  end

  # Trap handlers run in MRI signal-trap context, where Mutex#synchronize
  # and Kernel#sleep raise ThreadError. Scheduler#shutdown uses both, so
  # the trap only flips @stop_requested and an off-reactor watcher
  # performs the drain.
  describe 'signal handling' do
    let(:trap_blocks) { {} }

    before do
      allow(BSV::Wallet::Engine::Broadcast).to receive(:new)
        .with(store: store, broadcaster: broadcaster).and_return(broadcast)
      allow(BSV::Wallet::Engine::TxProof).to receive(:new)
        .with(store: store, broadcaster: broadcaster).and_return(tx_proof)
      allow(BSV::Wallet::Scheduler).to receive(:new)
        .with(store: store).and_return(scheduler)

      allow(broadcast).to receive_messages(pull!: broadcast, reply!: broadcast,
                                           statuses_pull!: broadcast)
      allow(tx_proof).to receive(:pull!).and_return(tx_proof)
      allow(scheduler).to receive(:run!)
      allow(scheduler).to receive(:shutdown).and_return(true)

      allow(Signal).to receive(:trap) do |signal, &block|
        trap_blocks[signal] = block
      end
    end

    it 'INT trap only flips @stop_requested (trap-context safe)' do
      Async do |task|
        daemon.run!
        trap_blocks.fetch('INT').call

        expect(daemon.instance_variable_get(:@stop_requested)).to be true
      ensure
        task.stop
      end
    end

    it 'TERM trap only flips @stop_requested (trap-context safe)' do
      Async do |task|
        daemon.run!
        trap_blocks.fetch('TERM').call

        expect(daemon.instance_variable_get(:@stop_requested)).to be true
      ensure
        task.stop
      end
    end

    it 'watcher thread drives stop! once @stop_requested is set' do
      Async do |_task|
        daemon.run!
        daemon.instance_variable_set(:@stop_requested, true)

        # Watcher polls every 0.1s. Wait long enough for one tick +
        # the drain emit to land.
        deadline = Time.now + 2
        sleep 0.05 until log_output.string.include?('daemon.stopped') || Time.now > deadline

        expect(scheduler).to have_received(:shutdown)
        expect(log_output.string).to include('[event] daemon.stopped reason=signal')
      end
    end

    it 'watcher thread self-terminates when @task finishes without @stop_requested' do
      thread_count_before = Thread.list.size

      Async do |task|
        daemon.run!
        task.stop
      end

      # Watcher polls every 0.1s. Once @task.finished? becomes true
      # (after the Async block returns) the next tick exits the loop.
      # Give it 3 ticks of headroom.
      deadline = Time.now + 0.5
      sleep 0.05 until Thread.list.size <= thread_count_before || Time.now > deadline

      expect(Thread.list.size).to eq(thread_count_before)
      expect(scheduler).not_to have_received(:shutdown)
    end
  end
end
