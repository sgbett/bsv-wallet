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
          # +self_built+ is intentionally excluded from short-circuit trust
          # (BeefImporter Sub 5). See docs/reference/verification-cache.md.
          VERIFIED_VIA_TRUSTED = [VERIFIED_VIA_SPV, VERIFIED_VIA_BROADCAST_ACK].freeze

          plugin :timestamps, update_on_create: true

          many_to_one :block, class: 'BSV::Wallet::Store::Models::Block'
          one_to_many :actions, class: 'BSV::Wallet::Store::Models::Action'
        end
      end
    end
  end
end
