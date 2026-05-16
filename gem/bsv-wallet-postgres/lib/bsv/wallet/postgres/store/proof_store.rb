# frozen_string_literal: true

module BSV
  module Wallet
    module Postgres
      module Store
        # Merkle proof manager backed by tx_proofs table.
        class ProofStore
          include BSV::Wallet::Interface::ProofStore

          def initialize(db: nil)
            @db = db || Connection.db
          end

          def save_proof(wtxid:, proof:)
            BSV::Primitives::Hex.validate_wtxid!(wtxid, name: 'save_proof wtxid')
            BSV.logger&.debug { "[ProofStore] save_proof: dtxid=#{wtxid.reverse.unpack1('H*')} height=#{proof[:height]}" }

            block_id = find_or_create_block(proof) if proof[:height]

            existing = TxProof.first(wtxid: Sequel.blob(wtxid))
            cols = proof_columns(proof).merge(block_id ? { block_id: block_id } : {})
            if existing
              existing.update(cols)
              existing.id
            else
              TxProof.create({ wtxid: wtxid }.merge(cols)).id
            end
          end

          def find_proof(wtxid:)
            BSV::Primitives::Hex.validate_wtxid!(wtxid, name: 'find_proof wtxid')
            record = TxProof.first(wtxid: Sequel.blob(wtxid))
            return unless record

            proof_to_hash(record)
          end

          def proof_exists?(wtxid:)
            BSV::Primitives::Hex.validate_wtxid!(wtxid, name: 'proof_exists? wtxid')
            TxProof.where(wtxid: Sequel.blob(wtxid)).any?
          end

          private

          def proof_columns(proof)
            cols = {}
            cols[:block_index] = proof[:block_index] if proof.key?(:block_index)
            cols[:merkle_path] = proof[:merkle_path] ? Sequel.blob(proof[:merkle_path]) : nil if proof.key?(:merkle_path)
            cols[:raw_tx]      = proof[:raw_tx]      ? Sequel.blob(proof[:raw_tx]) : nil      if proof.key?(:raw_tx)
            cols
          end

          def proof_to_hash(record)
            block = record.block
            {
              id:           record.id,
              wtxid:        record.wtxid,
              block_id:     record.block_id,
              height:       block&.height,
              block_index:  record.block_index,
              merkle_path:  record.merkle_path,
              raw_tx:       record.raw_tx,
              block_hash:   block&.block_hash,
              merkle_root:  block&.merkle_root
            }
          end

          # Returns block ID if a block can be found or created, nil otherwise.
          # Derives merkle_root from merkle_path when not provided explicitly.
          # Returns nil only when neither merkle_root nor merkle_path is available.
          def find_or_create_block(proof)
            height = proof[:height]
            return unless height

            existing = Block.first(height: height)
            return existing.id if existing

            merkle_root = proof[:merkle_root] || derive_merkle_root(proof[:merkle_path])
            return unless merkle_root

            Block.create(
              height:      height,
              merkle_root: merkle_root,
              block_hash:  proof[:block_hash]
            ).id
          rescue Sequel::UniqueConstraintViolation
            Block.first!(height: height).id
          end

          def derive_merkle_root(merkle_path_binary)
            return unless merkle_path_binary

            paths = BSV::Transaction::MerklePath.from_binary(merkle_path_binary)
            mp = paths.is_a?(Array) ? paths.first : paths
            mp&.compute_root
          rescue StandardError
            nil
          end

          def decode_hex(hex)
            return unless hex
            return hex if hex.encoding == Encoding::BINARY

            [hex].pack('H*')
          end
        end
      end
    end
  end
end
