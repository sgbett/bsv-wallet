# frozen_string_literal: true

module BSV
  module Wallet
    module Interface
      # Ingress of an incoming BEEF: parse it, SPV-verify the subject
      # transaction, persist ancestor proofs, and resolve the caller-named
      # outputs into the canonical UTXO set.
      #
      # The BeefImporter is the fourth extraction under the #291 Engine
      # decomposition (after +FundingStrategy+, +TxBuilder+, and
      # +Hydrator+). Where +Hydrator+ wires our own proofs *out* into the
      # Atomic BEEF the wallet ships to peers, BeefImporter ingests an
      # incoming BEEF *in* — the ingress counterpart to the egress
      # service.
      #
      # ## Pre-Action by design
      #
      # The whole ingress flow runs *before* an action row exists in the
      # database. The action row that +#import+ ultimately creates
      # (+broadcast_intent 'none'+) is an artefact of the persistence
      # step, not the subject of the process. This is why +Action+ is
      # the wrong home for the work, and why the row-less
      # +helper = new(engine:, row: { id: nil })+ delegator hack that
      # used to dispatch the privates existed at all. +createAction+ is
      # not the only consumer either: +internalizeAction+ runs through
      # here today, and a future daemon background BEEF prefetch will
      # too — all paths import BEEFs with no outbound action in play.
      #
      # ## Store-reading (same shape as Hydrator)
      #
      # Like +Interface::Hydrator+ — and in deliberate contrast to
      # +Interface::TxBuilder+'s store-free shape — BeefImporter is
      # **store-reading**. The injected +store:+ handle is read during
      # ancestor proof persistence (+save_proof+, +link_proof+) and
      # during TXID-only trimming (+proof_exists?+), and written through
      # via +create_action+ / +sign_action+ / +promote_action+ as the
      # subject lands. Two further dependencies attach: a
      # +chain_tracker:+ for the SPV verify step (the incoming graph is
      # untrusted, so a real tracker is required — there is no
      # egress-style +TrustedSelfChainTracker+ shortcut), and a
      # +hydrator:+ for the trustSelf hydration step.
      #
      # ## One-way Hydrator dependency
      #
      # BeefImporter consumes +Hydrator#wire_ancestor+ to fill in
      # TXID-only entries from the local ProofStore before SPV
      # verification — the trustSelf "the sender skipped ancestors they
      # know we already have" path. The dependency is **one-way**:
      # ingress depends on Hydrator, never the reverse. +Hydrator+ holds
      # no reference to BeefImporter.
      #
      # ## Not the BeefImporter's concern
      #
      # The +wbikd+ receive path (+Engine#internalize_wbikd_utxo+) is a
      # different ingress shape — raw tx plus derivation params, no BEEF
      # parse and no SPV verify — and is *not* a BeefImporter consumer.
      # +#import+ takes a BEEF; wbikd has neither. The two paths share
      # the +create_action+ / +sign_action+ / +save_proof+ /
      # +promote_action+ Store primitives, but not the orchestration.
      module BeefImporter
        # Ingest an incoming BEEF end-to-end and surface BRC-100
        # +internalizeAction+'s response shape.
        #
        # Owns the full ingress sequence: parse the +tx+ binary as
        # Atomic BEEF, optionally hydrate trustSelf TXID-only entries
        # from the local ProofStore, run full SPV verification against
        # the injected chain tracker, persist the subject as an
        # incoming (+broadcast_intent 'none'+) action row with its
        # +wtxid+ and +raw_tx+, attach labels, save every ancestor's
        # proof, optionally trim known ancestors back to TXID-only, and
        # finally promote the caller-named outputs into the canonical
        # UTXO set.
        #
        # The ordering above is contractual: +save_beef_proofs+ runs
        # *before* +replace_known_ancestors!+ so TXID-only trimming
        # never discards a proof not yet persisted; SPV verification
        # runs before any persistence so a structurally invalid graph
        # never reaches the database.
        #
        # @param tx [String] binary Atomic BEEF (BRC-95) carrying the
        #   subject transaction and its ancestor closure
        # @param outputs [Array<Hash>] caller-named outputs to promote;
        #   each entry carries +:output_index+, +:protocol+
        #   (+:wallet_payment+ or +:basket_insertion+), +:satoshis+, and
        #   the protocol-specific remittance hash
        # @param description [String] action description (BRC-100)
        # @param labels [Array<String>, nil] labels to attach to the
        #   action row; +nil+ or empty is a no-op
        # @param trust_self ['known', nil] when +'known'+, TXID-only
        #   entries the sender skipped get hydrated from the local
        #   ProofStore before verify, and known ancestors get trimmed
        #   back to TXID-only after save
        # @param known_txids [Array<String>, nil] wire-order wtxids the
        #   sender asserts we hold proofs for; trimmed back to TXID-only
        #   after save (BRC-100 spec name; values are wire-order)
        # @return [Hash] +{ accepted: true }+ — the BRC-100
        #   +internalizeAction+ response
        # @raise [BSV::Wallet::InvalidBeefError] BEEF is malformed,
        #   missing its subject, lacking a chain tracker, or fails SPV
        # @raise [BSV::Wallet::InvalidParameterError] a caller output
        #   names a non-existent vout or declares a satoshi mismatch
        #
        # +seek_permission:+ and +originator:+ are BRC-100 vocabulary;
        # they stop at the BRC100 wrap layer (ADR-026 decision 7) and
        # do not appear on this Engine-internal contract.
        def import(tx:, outputs:, description:, labels: nil,
                   trust_self: nil, known_txids: nil)
          raise NotImplementedError
        end
      end
    end
  end
end
