# frozen_string_literal: true

module BSV
  module Wallet
    module Interface
      # Hydration over the persisted proof store: turn a signed
      # transaction (plus its action context) into the Atomic BEEF the
      # wallet ships to a peer.
      #
      # The Hydrator is the third extraction under the #291 Engine
      # decomposition (after +FundingStrategy+ and +TxBuilder+) and owns
      # the *deep* hydration — the recursive proof walk that wires each
      # input's +source_transaction+ until every branch terminates at a
      # merkle-proven leaf, then assembles the Atomic BEEF and proves it
      # valid before handoff.
      #
      # ## Store-reading (deliberate contrast with TxBuilder)
      #
      # Unlike +Interface::TxBuilder+ — which is store-free, taking
      # resolved inputs *by value* and never reaching back — the Hydrator
      # is **store-reading**. Hydration is inherently a read over
      # persisted proofs: +wire_ancestor+ recurses through
      # +Store#find_proof+ following each input's +prev_wtxid+, and
      # +build_atomic_beef+ calls +Store#resolve_inputs_for_signing+ to
      # learn the subject transaction's source set. The +store:+ handle
      # is the *only* dependency — there is no +chain_tracker+ injection
      # (+validate_for_handoff!+ self-constructs its own
      # +TrustedSelfChainTracker+, the egress self-trust model the
      # Hydrator owns).
      #
      # ## One-way seam (+wire_ancestor+ is public)
      #
      # +wire_ancestor+ is exposed as the public primitive +BeefImporter+
      # (ingress) consumes — incoming-BEEF trustSelf hydration depends on
      # this method to fill TXID-only entries from the local ProofStore
      # before verification. The dependency is one-way: ingress depends
      # on Hydrator, never the reverse.
      #
      # ## The shared hydration cache (#296 Phase D)
      #
      # The Hydrator owns the +HydratedTxCache+ — a wtxid-keyed,
      # immutable-bytes, LRU-only substrate (no broadcast-lifecycle
      # eviction; superseded the action_id-keyed #269 cache). +wire_ancestor+
      # reads through it (a cached merkle terminal stops the walk) and
      # +proof_arrived+ enriches it monotonically when a proof lands. The
      # same instance is injected into +Engine::Broadcast+, whose shallow EF
      # path (+hydrated_transaction_for+) attaches per-input source data from
      # cached parent bytes — so one substrate serves both egress shapes.
      # +InputSource+ remains a standalone shared module (TxBuilder +
      # +apply_spends+ + Broadcast all depend on it).
      module Hydrator
        # Recursive ProofStore→Tx wiring primitive.
        #
        # Loads the transaction at +wtxid+ from the proof store; if its
        # proof carries a +merkle_path+, attaches it and returns
        # immediately (proven terminal — no recursion). Otherwise recurses
        # into each input's +prev_wtxid+, wiring +source_transaction+ for
        # any ancestor proof present. The +visited+ set guards against
        # circular references (genuine Bitcoin transactions cannot form
        # cycles, but ProofStore entries can).
        #
        # Public surface: +BeefImporter+ (ingress) consumes this directly
        # for trustSelf hydration of incoming BEEFs whose TXID-only
        # entries we already hold proofs for.
        #
        # @param wtxid [String] 32-byte wire-order wtxid
        # @param visited [Set] cycle-guard accumulator
        # @return [BSV::Transaction::Tx, nil] +nil+ when no proof, or the
        #   proof's +raw_tx+ is too short to deserialise
        def wire_ancestor(wtxid, visited: Set.new)
          raise NotImplementedError
        end

        # Assemble the Atomic BEEF the wallet ships to peers.
        #
        # Deserialises +raw_tx+ into a +Transaction::Tx+, resolves the
        # action's input set via +Store#resolve_inputs_for_signing+, wires
        # each input's +source_transaction+ via +#wire_ancestor+, then
        # builds an Atomic BEEF (BRC-95) keyed on the subject's wtxid.
        #
        # Store-reading by design — Hydrator already needs the store for
        # +find_proof+ during +wire_ancestor+, so resolving inputs by
        # +action_id+ in-method (rather than taking them by value the
        # way +TxBuilder+ does) is the simpler shape.
        #
        # @param raw_tx [String] signed transaction binary (wire format)
        # @param action_id [Integer] the action whose inputs to resolve
        # @return [String] Atomic BEEF binary
        def build_atomic_beef(raw_tx, action_id)
          raise NotImplementedError
        end

        # Monotonic substrate-enrichment hook (#296 Phase D).
        #
        # Called whenever the wallet learns durable information about a
        # +wtxid+: at minimum the +raw_tx+ bytes; additionally a
        # +merkle_path+ when (and only when) a proof has landed. Sites that
        # call this include +Engine::TxProof+ (daemon proof acquisition),
        # +Engine::Broadcast+ (eager broadcast-response proof),
        # +Engine::BeefImporter+ (every BEEF entry, merkle-bearing or not),
        # and +Engine#import_utxo+ (root UTXO import). The shared cache
        # then short-circuits future +wire_ancestor+ walks: through the
        # +wtxid+ as a proven terminal when +merkle_path+ is present, or
        # at minimum serving the +raw_tx+ on cache hit.
        #
        # Enrichment is monotonic — never invalidates. A +merkle_path+
        # already present is never cleared; +nil+ in this call is a
        # no-op for the merkle slot of an existing entry.
        #
        # @param wtxid [String] 32-byte wire-order wtxid
        # @param raw_tx [String] transaction bytes (wire format)
        # @param merkle_path [String, nil] serialized merkle path, or +nil+
        #   when the call is enriching only the +raw_tx+
        def proof_arrived(wtxid:, raw_tx:, merkle_path:)
          raise NotImplementedError
        end

        # Egress SPV honesty contract (#296 Phase B): refuse to ship a
        # structurally invalid BEEF.
        #
        # Self-constructs a +TrustedSelfChainTracker+ (the wallet trusts
        # its own persisted proofs because they were validated against a
        # real chain tracker at proof-arrival time). The verification
        # walks the BEEF graph and passes iff every leaf terminates at a
        # +merkle_path+ or wires through to one.
        #
        # No +chain_tracker+ injection — the tracker used here is an
        # egress-specific trust model the Hydrator owns, not an engine
        # dependency.
        #
        # @param atomic_beef [String] BEEF binary as built by
        #   +#build_atomic_beef+
        # @param subject_wtxid [String] 32-byte wire-order wtxid of the
        #   subject transaction (the action's own tx)
        # @raise [BSV::Wallet::EgressBeefInvalidError] when the subject
        #   is missing from the constructed BEEF, or when verification
        #   fails (almost always an upstream proof-closure gap that
        #   should have been caught at import / +save_beef_proofs+ time)
        def validate_for_handoff!(atomic_beef, subject_wtxid)
          raise NotImplementedError
        end
      end
    end
  end
end
