# frozen_string_literal: true

module BSV
  module Wallet
    # Canonical ARC tx_status classification sets — the single source of
    # truth for which statuses count as accepted, rejected, or terminal.
    #
    # Deliberately dependency-free (no Sequel, no OMQ): the Engine, the
    # background Engine::Broadcast worker, and the Sequel-backed
    # Models::Broadcast all reference these from different points in the
    # load graph. Keeping the sets here — required eagerly from wallet.rb —
    # lets every layer share one definition without a load-order coupling.
    #
    # BRC-100's ARC status enum is the upstream source; update here only.
    module ArcStatus
      # Network has formally accepted the broadcast (drives Phase 4
      # output promotion). ACCEPTED_BY_NETWORK is an interim accepted
      # state some ARC configs report before SEEN_ON_NETWORK.
      ACCEPTED = %w[SEEN_ON_NETWORK ACCEPTED_BY_NETWORK MINED IMMUTABLE].freeze

      # Definitive, non-recoverable rejection. Used as the negative
      # predicate for speculative promotion: anything NOT in this set
      # means "the tx is on its way" (e.g. RECEIVED / STORED / QUEUED),
      # so the wallet promotes its outputs. The resolution loop +
      # Store#reject_action is the safety net if a non-rejected status
      # later flips to REJECTED (#240).
      #
      # These are persistable ARC tx_status values. A malformed tx is NOT
      # one of them: ARC reports malformation as an HTTP 461/463 error
      # ("Malformed transaction"), never as a txStatus — see the failure
      # path in Engine::Broadcast, where it surfaces as a reason bucket.
      REJECTED = %w[REJECTED DOUBLE_SPEND_ATTEMPTED].freeze

      # Polling stops here. Every REJECTED status is terminal, plus the
      # accepted statuses that are final (SEEN_ON_NETWORK / MINED /
      # IMMUTABLE). Two accepted statuses are deliberately NOT terminal:
      #   - ACCEPTED_BY_NETWORK — an interim accepted state ARC reports
      #     before SEEN_ON_NETWORK; promote, but keep polling for proof.
      #   - MINED_IN_STALE_BLOCK — valid but on a fork; keep polling until
      #     it re-enters the main chain (HLR #182).
      #
      # Every member is a valid tx_status enum value: this set is matched
      # against the persisted broadcasts.tx_status column in
      # Store#pending_resolutions, so a non-enum value here would make
      # Postgres reject the query.
      TERMINAL = %w[
        SEEN_ON_NETWORK MINED IMMUTABLE
        REJECTED DOUBLE_SPEND_ATTEMPTED
      ].freeze
    end
  end
end
