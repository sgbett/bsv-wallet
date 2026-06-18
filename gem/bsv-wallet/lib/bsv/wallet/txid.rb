# frozen_string_literal: true

module BSV
  module Wallet
    # Canonical wtxid (wire-order binary) → dtxid (display-order hex)
    # conversion, exposed as a refinement so call sites read
    # +wtxid.to_dtxid+ rather than re-deriving +reverse.unpack1('H*')+.
    #
    # A refinement, not a global +String+ patch: activate it per file with
    # +using BSV::Wallet::Txid+ and it applies only within that file's
    # lexical scope. Gem consumers (and any code that doesn't opt in) see a
    # vanilla +String+ — no surprise +String#to_dtxid+ leaking into a host
    # application.
    #
    # No length validation: the inputs are trusted internal 32-byte wtxids
    # (Sequel +bytea+ columns, SDK +Tx#wtxid+), and several call sites are
    # inside +BSV.logger&.debug+ blocks where a raise would be worse than a
    # malformed log line. Use +BSV::Primitives::Hex.validate_wtxid!+ at the
    # boundaries that actually need to reject bad input.
    #
    # See the wtxid/dtxid convention in CLAUDE.md.
    module Txid
      refine String do
        # @return [String] 64-char display-order hex transaction ID (dtxid)
        def to_dtxid
          reverse.unpack1('H*')
        end
      end
    end
  end
end
