# frozen_string_literal: true

module BSV
  module Wallet
    class Engine
      # Normalise an ARC-returned +merkle_path+ value into BRC-74 binary
      # format. Used by +Engine::Broadcast+ (eager proof linking when ARC
      # returns proof material with the 202 response) and +Engine::TxProof+
      # (proof acquisition cycle).
      #
      # ARC may return merkle_path as:
      #   - Binary (ASCII-8BIT)        — already BRC-74, pass through.
      #   - Hex string                 — decode to binary.
      #   - TSC-format hash            — convert via +MerklePath.from_tsc+.
      module MerklePathNormaliser
        module_function

        def normalize(merkle_path, wtxid)
          return normalize_tsc(merkle_path, wtxid) if merkle_path.is_a?(Hash)
          return merkle_path if merkle_path.encoding == Encoding::ASCII_8BIT
          return [merkle_path].pack('H*') if merkle_path.match?(/\A[0-9a-fA-F]+\z/)

          merkle_path.b
        end

        def normalize_tsc(tsc, wtxid)
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
