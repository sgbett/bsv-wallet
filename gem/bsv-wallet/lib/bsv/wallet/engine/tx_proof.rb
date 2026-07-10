# frozen_string_literal: true

require 'omq'

using BSV::Wallet::Txid

module BSV
  module Wallet
    class Engine
      # Background proof acquisition handler — logical model for walletd.
      #
      # Fetches transaction status from ARC. When a tx is mined (has
      # merkle_path + block_height), saves the proof and links it to
      # the action.
      class TxProof
        include OmqSupport

        # +hydrator+ (optional) is the shared-cache owner notified on a
        # fresh proof via +proof_arrived+ (#296 Phase D). The daemon injects
        # the same Hydrator instance whose cache +Engine::Broadcast+ reads,
        # so a newly mined ancestor becomes a terminal for future
        # +wire_ancestor+ walks without a store round-trip. Nil-tolerant:
        # configurations without the shared cache simply skip enrichment.
        def initialize(store:, broadcaster:, hydrator: nil)
          @store = store
          @broadcaster = broadcaster
          @hydrator = hydrator
        end

        # Background queue — Scheduler pushes action IDs here.
        def pull!(task:)
          task.async do
            pull = bind_or_die('proof_acquisition') { OMQ::PULL.bind('inproc://proofs.pull') }
            while (msg = pull.receive)
              begin
                process(msg.first.to_i)
              rescue BSV::Wallet::CompetingBlockHeaderError => e
                # Distinct signal — the acquired proof's header disagrees
                # with the wallet's cached +blocks+ row (re-org detected via
                # proof acquisition). Surface as +task.failed+ with a
                # dedicated reason so the daemon can distinguish this from
                # a generic worker crash and, when Sub 5's read gate is
                # wired, trigger an anchor-liveness sweep at that height.
                # #533 code-review.
                BSV::Wallet.emit('task.failed', task: 'proof_acquisition',
                                                id: msg.first.to_i,
                                                reason: :reorg_detected,
                                                height: e.height)
              rescue StandardError => e
                BSV::Wallet.emit('fiber.crashed', task: 'proof_acquisition', error: e.message.lines.first&.chomp)
              end
            end
          end
          self
        end

        # Process a single proof acquisition — fetch status, save proof if mined.
        #
        # Emits exactly one task.dispatched on entry, then exactly one of
        # task.succeeded / task.failed / task.skipped.
        def process(action_id)
          BSV::Wallet.emit('task.dispatched', task: 'proof_acquisition', id: action_id)
          started_at = Time.now

          action = @store.find_action(id: action_id)
          unless action
            BSV::Wallet.emit('task.skipped', task: 'proof_acquisition', id: action_id, reason: :action_not_found)
            return
          end
          unless action[:wtxid]
            BSV::Wallet.emit('task.skipped', task: 'proof_acquisition', id: action_id, reason: :no_wtxid)
            return
          end
          if action[:tx_proof_id]
            # Defence-in-depth: the daemon's pending_proofs discovery query
            # filters WHERE tx_proof_id IS NULL, so this branch only fires
            # on the race window where a proof arrives between discovery
            # and dispatch. Per #177.
            BSV::Wallet.emit('task.skipped', task: 'proof_acquisition', id: action_id, reason: :already_proven)
            return
          end

          dtxid = action[:wtxid].to_dtxid
          response = @broadcaster.get_tx_status(wtxid: action[:wtxid], dtxid: dtxid)
          latency_ms = ((Time.now - started_at) * 1000).round

          unless response.http_success?
            BSV::Wallet.emit('task.failed', task: 'proof_acquisition', id: action_id,
                                            latency_ms: latency_ms, reason: :transport_error)
            return
          end

          # Success responses are normalized by BSV::Network::Services
          # to symbol + snake_case keys.
          data = response.data
          unless data[:merkle_path] && data[:block_height]
            BSV::Wallet.emit('task.succeeded', task: 'proof_acquisition', id: action_id,
                                               latency_ms: latency_ms, outcome: :not_yet_mined)
            return
          end

          merkle_path = MerklePathNormaliser.normalize(data[:merkle_path], action[:wtxid])

          proof_id = @store.save_proof(
            wtxid: action[:wtxid],
            proof: {
              height: data[:block_height],
              block_hash: data[:block_hash],
              merkle_path: merkle_path,
              raw_tx: action[:raw_tx]
            }
          )
          @store.link_proof(action_id: action_id, tx_proof_id: proof_id)
          # Monotonic cache enrichment: this wtxid is now a proven terminal.
          @hydrator&.proof_arrived(wtxid: action[:wtxid], raw_tx: action[:raw_tx], merkle_path: merkle_path)
          BSV::Wallet.emit('task.succeeded', task: 'proof_acquisition', id: action_id,
                                             latency_ms: latency_ms, outcome: :acquired)
        end

        # Discovery query — returns action IDs needing proofs.
        def self.pending(store, limit: 10)
          store.pending_proofs(limit: limit).map { |a| a[:id] }
        end
      end
    end
  end
end
