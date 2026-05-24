# frozen_string_literal: true

require 'omq'

module BSV
  module Wallet
    class Engine
      # Background proof acquisition handler — logical model for walletd.
      #
      # Fetches transaction status from ARC. When a tx is mined (has
      # merkle_path + block_height), saves the proof and links it to
      # the action.
      class TxProof
        def initialize(store:, services:)
          @store = store
          @services = services
        end

        # Background queue — Scheduler pushes action IDs here.
        def pull!(task:)
          task.async do
            pull = OMQ::PULL.bind('inproc://proofs.pull')
            while (msg = pull.receive)
              begin
                process(msg.first.to_i)
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
            BSV::Wallet.emit('task.skipped', task: 'proof_acquisition', id: action_id, reason: 'action_not_found')
            return
          end
          unless action[:wtxid]
            BSV::Wallet.emit('task.skipped', task: 'proof_acquisition', id: action_id, reason: 'no_wtxid')
            return
          end

          dtxid = action[:wtxid].reverse.unpack1('H*')
          response = @services.call(:get_tx_status, txid: dtxid)
          latency_ms = ((Time.now - started_at) * 1000).round

          unless response.http_success?
            BSV::Wallet.emit('task.failed', task: 'proof_acquisition', id: action_id,
                                            latency_ms: latency_ms, reason: 'transport_error')
            return
          end

          data = response.data
          unless data['merklePath'] && data['blockHeight']
            BSV::Wallet.emit('task.succeeded', task: 'proof_acquisition', id: action_id,
                                               latency_ms: latency_ms, outcome: :not_yet_mined)
            return
          end

          merkle_path = normalize_merkle_path(data['merklePath'], action[:wtxid])

          proof_id = @store.save_proof(
            wtxid: action[:wtxid],
            proof: {
              height: data['blockHeight'],
              block_hash: data['blockHash'],
              merkle_path: merkle_path,
              raw_tx: action[:raw_tx]
            }
          )
          @store.link_proof(action_id: action_id, tx_proof_id: proof_id)
          BSV::Wallet.emit('task.succeeded', task: 'proof_acquisition', id: action_id,
                                             latency_ms: latency_ms, outcome: :acquired)
        end

        # Discovery query — returns action IDs needing proofs.
        def self.pending(store, limit: 10)
          store.pending_proofs(limit: limit).map { |a| a[:id] }
        end

        private

        # Normalize a merkle_path value to BRC-74 binary format.
        #
        # ARC may return merkle_path as:
        # - Binary (ASCII-8BIT) — already in BRC-74 format, pass through
        # - Hex string — decode to binary
        # - TSC format hash — convert via MerklePath.from_tsc
        def normalize_merkle_path(merkle_path, wtxid)
          return normalize_tsc_merkle_path(merkle_path, wtxid) if merkle_path.is_a?(Hash)
          return merkle_path if merkle_path.encoding == Encoding::ASCII_8BIT
          return [merkle_path].pack('H*') if merkle_path.match?(/\A[0-9a-fA-F]+\z/)

          merkle_path.b
        end

        # Convert a TSC-format merkle proof hash to BRC-74 binary.
        def normalize_tsc_merkle_path(tsc, wtxid)
          BSV::Primitives::Hex.validate_wtxid!(wtxid, name: 'normalize_tsc wtxid')
          dtxid = wtxid.reverse.unpack1('H*')
          BSV::Transaction::MerklePath.from_tsc(
            dtxid_hex: tsc[:txOrId] || tsc[:tx_or_id] || dtxid,
            index: tsc[:index],
            nodes: tsc[:nodes],
            block_height: tsc[:blockHeight] || tsc[:block_height]
          ).to_binary
        end
      end
    end
  end
end
