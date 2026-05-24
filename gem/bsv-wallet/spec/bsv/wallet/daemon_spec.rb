# frozen_string_literal: true

require 'spec_helper'
require 'logger'
require 'stringio'
require 'bsv/wallet/daemon'

RSpec.describe BSV::Wallet::Daemon do
  # Plain double — instance_double(BSV::Wallet::Store) triggers autoloading
  # of Store::Models which requires a live Sequel connection.
  let(:store) { double('store') }
  let(:services) { instance_double(BSV::Network::Services) }
  let(:wallet_name) { 'alice' }
  let(:network) { :mainnet }
  let(:daemon) { described_class.new(store: store, services: services, wallet: wallet_name, network: network) }

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
        .with(store: store, services: services).and_return(broadcast)
      allow(BSV::Wallet::Engine::TxProof).to receive(:new)
        .with(store: store, services: services).and_return(tx_proof)
      allow(BSV::Wallet::Scheduler).to receive(:new)
        .with(store: store).and_return(scheduler)

      allow(broadcast).to receive_messages(pull!: broadcast, reply!: broadcast)
      allow(tx_proof).to receive(:pull!).and_return(tx_proof)
      allow(scheduler).to receive(:run!)
    end

    it 'creates Engine::Broadcast with store and services' do
      Async do |task|
        daemon.run!
        task.stop
      end

      expect(BSV::Wallet::Engine::Broadcast).to have_received(:new)
        .with(store: store, services: services)
    end

    it 'calls pull! and reply! on Broadcast' do
      Async do |task|
        daemon.run!
        task.stop
      end

      expect(broadcast).to have_received(:pull!)
      expect(broadcast).to have_received(:reply!)
    end

    it 'creates Engine::TxProof with store and services' do
      Async do |task|
        daemon.run!
        task.stop
      end

      expect(BSV::Wallet::Engine::TxProof).to have_received(:new)
        .with(store: store, services: services)
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
      daemon_no_wallet = described_class.new(store: store, services: services, network: network)

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
  end
end
