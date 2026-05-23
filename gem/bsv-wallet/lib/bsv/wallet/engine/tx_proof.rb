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
                BSV.logger&.error { "[Engine::TxProof] pull error: #{e.message}" }
              end
            end
          end
          self
        end

        # Process a single proof acquisition — fetch status, save proof if mined.
        def process(action_id)
          action = @store.find_action(id: action_id)
          return unless action && action[:wtxid]

          dtxid = action[:wtxid].reverse.unpack1('H*')
          response = @services.call(:get_tx_status, txid: dtxid)
          return unless response.http_success?

          data = response.data
          return unless data[:merkle_path] && data[:block_height]

          merkle_path = normalize_merkle_path(data[:merkle_path], action[:wtxid])

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
