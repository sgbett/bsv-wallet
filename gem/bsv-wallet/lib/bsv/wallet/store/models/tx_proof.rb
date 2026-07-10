# frozen_string_literal: true

module BSV
  module Wallet
    class Store
      module Models
        class TxProof < Sequel::Model
          # verification_source enum values (ADR-033 / HLR #516). Referenced
          # by every mark_verified write site — no bare literals.
          VERIFIED_VIA_SELF_BUILT    = 'self_built'
          VERIFIED_VIA_SPV           = 'spv'
          VERIFIED_VIA_BROADCAST_ACK = 'broadcast_ack'
          VERIFIED_VIA_VALUES        = [
            VERIFIED_VIA_SELF_BUILT,
            VERIFIED_VIA_SPV,
            VERIFIED_VIA_BROADCAST_ACK
          ].freeze
          # Short-circuit trust set for BeefImporter Sub 5. Only +'spv'+
          # rows are trusted for the SDK's +verified:+ pre-seed today —
          # they carry a merkle proof + block anchor, so Sub 6's
          # anchor-liveness pass (join on +blocks.id+) can invalidate
          # them on re-org.
          #
          # +'broadcast_ack'+ is deliberately EXCLUDED even though HLR #516
          # synthesis originally included it: the anchor-liveness join
          # requires +block_id IS NOT NULL+, which a +broadcast_ack+ row
          # (ARC accepted, not yet mined) does not carry. Trusting an
          # unanchored row without a liveness mechanism would leave
          # orphaned / RBF'd broadcast_ack ancestors as permanent trust
          # sources — a phantom-balance vector. Adding
          # +VERIFIED_VIA_BROADCAST_ACK+ back must land WITH its liveness
          # design (proof-acquisition escalation, TTL, or equivalent).
          # White-hat on #537 (I1); see #522 discussion for the decision
          # trace.
          #
          # +self_built+ is intentionally excluded from short-circuit
          # trust (see docs/reference/verification-cache.md).
          VERIFIED_VIA_TRUSTED = [VERIFIED_VIA_SPV].freeze

          plugin :timestamps, update_on_create: true

          many_to_one :block, class: 'BSV::Wallet::Store::Models::Block'
          one_to_many :actions, class: 'BSV::Wallet::Store::Models::Action'
        end
      end
    end
  end
end
