# frozen_string_literal: true

module BSV
  module Wallet
    # Structural-only chain tracker for the wallet's own egress validation.
    #
    # Satisfies the SDK's {BSV::Transaction::ChainTracker} duck type by
    # saying "yes" to every merkle root lookup. This is correct, not lax,
    # for one specific use: validating a BEEF the wallet itself just built
    # from its own persisted proofs.
    #
    # The wallet's persisted proofs were validated against a real chain
    # tracker at proof-arrival time (during +import_utxo+ for confirmed
    # ancestors, during incoming BEEF +save_beef_proofs+ for ancestors
    # received from peers). Re-running chain-validity checks at egress
    # would be redundant — what we need at egress is *structural*
    # completeness: every input path in the just-built BEEF terminates at
    # a merkle_path or wires through to one. That check is the verify
    # walk; neutralising the chain_tracker isolates it from network
    # validity.
    #
    # NEVER use this for incoming BEEFs from peers. Untrusted data must
    # be validated against {BSV::Network::ChainTracker} so the merkle
    # roots are checked against real block headers. This tracker exists
    # to express the wallet's confidence in its own state, not as a
    # general validation shortcut.
    #
    # @example At egress (Action#validate_for_handoff!)
    #   subject_tx.verify(chain_tracker: TrustedSelfChainTracker.new)
    #   # passes iff the BEEF is structurally complete; raises otherwise
    class TrustedSelfChainTracker < BSV::Transaction::ChainTracker
      # Sentinel chain tip — high enough that the SDK's coinbase maturity
      # check (offset-0 leaf must be >= 100 blocks deep) always passes.
      # Real height doesn't matter; this tracker is structural-only.
      SENTINEL_HEIGHT = 1_000_000

      def valid_root_for_height?(_root, _height) = true
      def current_height = SENTINEL_HEIGHT
    end
  end
end
