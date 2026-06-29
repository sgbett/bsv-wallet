# frozen_string_literal: true

# Wallet-specific error classes.
#
# BRC-100 contract errors (Error, InvalidParameterError, InvalidHmacError,
# InvalidSignatureError, UnsupportedActionError) are defined in bsv-sdk
# and inherited via the gem dependency.

module BSV
  module Wallet
    class InsufficientFundsError < Error
      attr_reader :required, :available

      def initialize(message = nil, required: nil, available: nil)
        @required = required
        @available = available
        super(message || "insufficient funds: need #{required}, have #{available}")
      end
    end

    class PoolDepletedError < Error
      def initialize(pool_name)
        super("UTXO pool '#{pool_name}' is depleted; no outputs available for acquisition")
      end
    end

    class InvalidBeefError < Error
      def initialize(message = 'invalid BEEF data')
        super(message, code: 7)
      end
    end

    # Raised by Engine::Hydrator#validate_for_handoff! when the wallet's
    # just-built outgoing BEEF would not verify against a peer's view.
    # Distinct from {InvalidBeefError} (incoming peer data) — this one
    # means the wallet's *own* state cannot produce a valid BEEF, almost
    # always an upstream proof-closure gap (see #296).
    class EgressBeefInvalidError < Error
      def initialize(message = 'wallet cannot produce a valid BEEF for handoff')
        super
      end
    end

    class LimpModeError < Error
      attr_reader :balance, :threshold

      def initialize(balance:, threshold:)
        @balance = balance
        @threshold = threshold
        super("wallet is in limp mode: balance #{balance} sats is below " \
              "operating threshold #{threshold} sats — receive funds to restore normal operations")
      end
    end

    # Raised by Store#abort_action when the target action has any promoted
    # outputs. Aborting such an action would delete canonical UTXOs and
    # their history. abortAction is for unfinished work, not for rewinding
    # already-committed (internal-path or post-broadcast) actions.
    class CannotAbortPromotedActionError < Error
      def initialize(message = 'cannot abort action with promoted outputs')
        super
      end
    end

    # Raised by Store#reject_action when the target (or any cascade
    # descendant) has broadcast_intent='none'. Internal-path actions
    # produce canonical wallet state by design — reject_action exists
    # for inline/delayed actions whose speculative promotion has been
    # contradicted by the network. Encountering a no_send on the cascade
    # walk means an invariant was violated upstream (a broadcast action
    # had a no_send descendant); rolling back keeps the row alive for
    # the resolution loop to retry and surfaces the problem loudly.
    class CannotRejectInternalActionError < Error
      def initialize(action_id)
        super("cannot reject internal-path action_id=#{action_id} " \
              "(broadcast_intent='none'); cascade rolled back")
      end
    end

    # Raised by Store#reject_action when the target (or any cascade
    # descendant) has a broadcast row whose tx_status is in
    # +BSV::Wallet::ArcStatus::ACCEPTED+. That tx_status means the
    # network told us the tx was accepted (SEEN_ON_NETWORK, MINED, etc.)
    # — rejecting the action would delete the wallet's record of an
    # on-chain artefact, compounding a wallet-vs-chain divergence rather
    # than recovering from it. The right response is operator
    # investigation, not unwind.
    class CannotRejectAcceptedActionError < Error
      def initialize(action_id, tx_status)
        super("cannot reject action_id=#{action_id} with accepted " \
              "tx_status=#{tx_status}; chain considers this accepted, " \
              'wallet-vs-chain divergence — cascade rolled back')
      end
    end

    # Raised by Store#verify_schema! when the per-wallet
    # +outputs.spendable_recoverable+ CHECK literal recovered from the
    # database does not match the WIF currently driving the wallet (HLR
    # #467). Catches schema drift, restore-to-wrong-DB, and WIF rotation
    # — any of which would let the wallet sign spends against a CHECK
    # that no longer mirrors its identity.
    class SchemaIntegrityError < Error
      def initialize(message = 'schema integrity check failed')
        super
      end
    end

    # Raised by Store#record_block_header when a validated (header-bearing)
    # +blocks+ row already exists at the target height carrying a
    # *different* 80-byte header (HLR #335). The wallet's locally-validated
    # header chain is append-or-reject: a competing header at an occupied,
    # already-validated height is fork / reorg evidence to preserve and
    # investigate (#245), never an upsert to silently overwrite.
    class CompetingBlockHeaderError < Error
      attr_reader :height

      def initialize(height)
        @height = height
        super("competing block header at already-validated height #{height}; " \
              'append-or-reject refused the overwrite (reorg evidence preserved)')
      end
    end
  end
end
