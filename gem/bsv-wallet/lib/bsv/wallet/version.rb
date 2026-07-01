# frozen_string_literal: true

module BSV
  module Wallet
    VERSION = '0.100.0'

    # Semantic version of the wallet's verify path. Bump when +Tx#verify+
    # semantics change — script interpreter, BIP-143 preimage,
    # +MerklePath#verify+, or FORKID sighash rules. Do NOT bump for logging,
    # metrics, error-message wording, or performance-only refactors.
    #
    # Written to +tx_proofs.verifier_version+ on every successful
    # +Store#mark_verified+; rows with lower version are cache misses.
    # Boot refuses if +MAX(tx_proofs.verifier_version)+ exceeds this value —
    # a downgraded binary must not honour hits it can no longer reproduce.
    # See ADR-033 and +docs/reference/verification-cache.md+.
    VERIFIER_VERSION = 1
  end
end
