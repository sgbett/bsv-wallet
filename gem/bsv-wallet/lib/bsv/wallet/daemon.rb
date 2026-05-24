# frozen_string_literal: true

require 'async'
require 'omq'
require_relative 'engine/broadcast'
require_relative 'engine/tx_proof'
require_relative 'scheduler'

module BSV
  module Wallet
    # Persistent process host for background wallet tasks.
    #
    # Boots logical models (Engine::Broadcast, Engine::TxProof) with
    # OMQ sockets and a Scheduler with discovery loops inside an
    # Async reactor. This is the runtime for walletd.
    #
    # Usage:
    #   daemon = BSV::Wallet::Daemon.new(store: store, services: services)
    #   daemon.run!  # blocks until stopped
    class Daemon
      def initialize(store:, services:, wallet: nil, network: nil)
        @store = store
        @services = services
        @wallet_name = wallet
        @network = network
        @task = nil
      end

      # Start the Async reactor. Blocks until stop! is called or interrupted.
      def run!
        Async do |task|
          @task = task

          setup_signal_traps

          broadcast = Engine::Broadcast.new(store: @store, services: @services)
          broadcast.pull!(task: task)
          broadcast.reply!(task: task)

          tx_proof = Engine::TxProof.new(store: @store, services: @services)
          tx_proof.pull!(task: task)

          scheduler = Scheduler.new(store: @store)
          scheduler.run!(task: task)

          BSV::Wallet.emit('daemon.started', wallet: @wallet_name, network: @network)
        end
      end

      # Signal the reactor to stop.
      def stop!
        BSV::Wallet.emit('daemon.stopped', reason: 'signal')
        @task&.stop
      end

      private

      def setup_signal_traps
        %w[INT TERM].each do |signal|
          Signal.trap(signal) { stop! }
        end
      end
    end
  end
end
