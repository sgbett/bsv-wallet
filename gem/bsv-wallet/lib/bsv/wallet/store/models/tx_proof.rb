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
          # rows are trusted for the SDK's +verified:+ pre-seed today.
          #
          # An +'spv'+ row can be either ANCHORED (carries a merkle proof
          # and a +block_id+) or UNANCHORED (intermediate ancestor visited by
          # a prior +Tx#verify+ walk that terminated at a proven leaf
          # further down the chain). Both classes are safe to pre-seed:
          # anchored rows are re-verified directly by Sub 6.1's anchor-
          # liveness pass (join on +blocks.id+); unanchored rows are
          # cleared transitively by Sub 6.2's descendant walk when the
          # anchor they depend on invalidates. Together they cover the
          # re-org invalidation surface for the read path. Copilot on #537.
          #
          # +'broadcast_ack'+ is deliberately EXCLUDED even though HLR #516
          # synthesis originally included it: it doesn't fit either class
          # above. +broadcast_ack+ rows carry +block_id = NULL+ AND are
          # not necessarily downstream of any anchored ancestor (ARC
          # accepted a submission that may never mine), so neither the
          # direct nor the transitive invalidation path reaches them.
          # Trusting an unanchored row without a liveness mechanism would
          # leave orphaned / RBF'd broadcast_ack ancestors as permanent
          # trust sources — a phantom-balance vector. Re-admitting
          # +VERIFIED_VIA_BROADCAST_ACK+ must land WITH its liveness
          # design (proof-acquisition escalation, TTL, or equivalent).
          # White-hat on #537 (I1); see #522 discussion for the trace.
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
