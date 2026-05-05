# frozen_string_literal: true

module BSV
  module Wallet
    module Postgres
      # Merkle proof manager backed by tx_proofs and tx_reqs tables.
      class ProofStore
        include BSV::Wallet::Interface::ProofStore

        def initialize(db: nil, arc_client: nil)
          @db = db || BSV::Wallet::Postgres.db
          @arc_client = arc_client
        end

        def save_proof(wtxid:, proof:)
          existing = TxProof.first(wtxid: Sequel.blob(wtxid))
          if existing
            existing.update(proof_columns(proof))
            existing.id
          else
            TxProof.create({ wtxid: wtxid }.merge(proof_columns(proof))).id
          end
        end

        def find_proof(wtxid:)
          record = TxProof.first(wtxid: Sequel.blob(wtxid))
          return unless record

          proof_to_hash(record)
        end

        def proof_exists?(wtxid:)
          TxProof.where(wtxid: Sequel.blob(wtxid)).any?
        end

        def request_proof(wtxid:, raw_tx: nil, input_beef: nil)
          @db[:tx_reqs].insert_conflict(target: :wtxid).insert(
            wtxid:      Sequel.blob(wtxid),
            raw_tx:     raw_tx ? Sequel.blob(raw_tx) : nil,
            input_beef: input_beef ? Sequel.blob(input_beef) : nil
          )
        end

        def process_pending(limit: 100)
          pending = TxReq
            .where(status: 'unmined')
            .where(tx_proof_id: nil)
            .order(:created_at)
            .limit(limit)
            .all

          pending.filter_map do |req|
            next unless @arc_client

            result = @arc_client.call(:get_tx_status, txid: req.dtxid)
            next unless result.success?

            data = result.data
            tx_status = data[:txStatus] || data[:tx_status]

            if tx_status == 'MINED'
              proof_id = save_proof(wtxid: req.wtxid, proof: {
                height:      data[:blockHeight] || data[:block_height],
                block_hash:  decode_hex(data[:blockHash] || data[:block_hash]),
                merkle_path: decode_hex(data[:merklePath] || data[:merkle_path])
              })
              req.update(tx_proof_id: proof_id, status: 'completed')
              { wtxid: req.wtxid, tx_proof_id: proof_id }
            else
              req.update(attempts: req.attempts + 1)
              nil
            end
          end
        end

        private

        def proof_columns(proof)
          cols = {}
          cols[:height]      = proof[:height]      if proof.key?(:height)
          cols[:block_index] = proof[:block_index]  if proof.key?(:block_index)
          cols[:merkle_path] = proof[:merkle_path] ? Sequel.blob(proof[:merkle_path]) : nil if proof.key?(:merkle_path)
          cols[:raw_tx]      = proof[:raw_tx]      ? Sequel.blob(proof[:raw_tx]) : nil      if proof.key?(:raw_tx)
          cols[:block_hash]  = proof[:block_hash]  ? Sequel.blob(proof[:block_hash]) : nil  if proof.key?(:block_hash)
          cols[:merkle_root] = proof[:merkle_root] ? Sequel.blob(proof[:merkle_root]) : nil if proof.key?(:merkle_root)
          cols
        end

        def proof_to_hash(record)
          {
            id:           record.id,
            wtxid:        record.wtxid,
            height:       record.height,
            block_index:  record.block_index,
            merkle_path:  record.merkle_path,
            raw_tx:       record.raw_tx,
            block_hash:   record.block_hash,
            merkle_root:  record.merkle_root
          }
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
