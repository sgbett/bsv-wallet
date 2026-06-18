# frozen_string_literal: true

require 'omq'

module BSV
  module Wallet
    class Engine
      # Background reaper — logical model for walletd (#325 / #326).
      #
      # Reclaims abandoned actions: inputs locked but never carried to a
      # terminal state (a crash between +lock_inputs+ and +sign_action+, an
      # abandoned funding-loop top-up). Deleting the action cascades its
      # +inputs+ rows, releasing the locked UTXOs back to the spendable set.
      # Promoted actions are protected; the internal +no_send+ path is left to
      # #327.
      #
      # Follows the same discovery → PULL → +process+ shape as Engine::Broadcast
      # and Engine::TxProof, so it participates in the Scheduler's cooperative
      # drain (one +task.dispatched+ + one terminal event per action) and rides
      # the same OMQ seam rather than being a bespoke loop.
      class Reaper
        include OmqSupport

        ENDPOINT = 'inproc://reaper.pull'

        # Discovery side, called by the Scheduler loop — mirrors
        # +Engine::Broadcast.pending_submissions+ etc.
        #
        # @param store [BSV::Wallet::Store]
        # @param limit [Integer] max IDs per pass
        # @param threshold [Integer] staleness age in seconds
        # @return [Array<Integer>] stale action IDs
        def self.pending(store, limit:, threshold:)
          store.stale_action_ids(threshold: threshold, limit: limit)
        end

        # @param store [BSV::Wallet::Store]
        def initialize(store:)
          @store = store
        end

        # Bind the PULL socket and reap each pushed action ID. Runs as a fiber
        # in the Daemon's Async reactor.
        def pull!(task:)
          task.async do
            pull = bind_or_die('reaper') { OMQ::PULL.bind(ENDPOINT) }
            while (msg = pull.receive)
              begin
                process(msg.first.to_i)
              rescue StandardError => e
                BSV.logger&.error { "[Engine::Reaper] pull error: #{e.message}" }
              end
            end
          end
          self
        end

        # Reap one action. Emits exactly one +task.dispatched+ on entry, then
        # exactly one terminal event: +task.succeeded+ when reclaimed,
        # +task.skipped+ when the action advanced past reapability since
        # discovery, +task.failed+ on error. The single-dispatched/single-
        # terminal pairing is the Scheduler drain contract.
        #
        # @param action_id [Integer]
        def process(action_id)
          BSV::Wallet.emit('task.dispatched', task: 'reaper', id: action_id)
          if @store.reap_action(action_id: action_id)
            BSV::Wallet.emit('task.succeeded', task: 'reaper', id: action_id)
          else
            BSV::Wallet.emit('task.skipped', task: 'reaper', id: action_id, reason: :not_reapable)
          end
        rescue StandardError => e
          BSV::Wallet.emit('task.failed', task: 'reaper', id: action_id,
                                          error: e.message.lines.first&.chomp)
        end
      end
    end
  end
end
