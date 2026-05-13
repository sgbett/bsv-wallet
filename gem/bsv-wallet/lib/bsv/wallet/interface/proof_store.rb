# frozen_string_literal: true

module BSV
  module Wallet
    module Interface
      # Merkle proof storage and retrieval for SPV validation (BRC-67).
      #
      # Proofs confirm that a transaction is included in a block.
      # They arrive via three routes:
      #   1. Broadcast response (ARC returns MINED with merklePath)
      #   2. ARC SSE events or polling
      #   3. Incoming BEEF data (internaliseAction)
      #
      # Backed by the tx_proofs table. Proofs are independent of
      # whether a wallet action references them — ancestor proofs
      # exist for BEEF construction.
      module ProofStore
        # Store a merkle proof for a transaction.
        #
        # Upserts — if a proof already exists for this wtxid, updates it.
        #
        # @param wtxid [String] 32-byte binary wtxid (wire byte order)
        # @param proof [Hash] :height, :block_index, :merkle_path (binary),
        #   :raw_tx (binary), :block_hash (binary), :merkle_root (binary)
        # @return [Integer] the tx_proof ID
        def save_proof(wtxid:, proof:)
          raise NotImplementedError
        end

        # Retrieve a proof by wtxid.
        #
        # @param wtxid [String] 32-byte binary wtxid (wire byte order)
        # @return [Hash, nil] proof data, or nil if not stored
        def find_proof(wtxid:)
          raise NotImplementedError
        end

        # Check whether a proof exists for a transaction.
        # Used by the trustSelf mechanism — "wtxids known to this wallet."
        #
        # @param wtxid [String] 32-byte binary wtxid (wire byte order)
        # @return [Boolean]
        def proof_exists?(wtxid:)
          raise NotImplementedError
        end
      end
    end
  end
end
