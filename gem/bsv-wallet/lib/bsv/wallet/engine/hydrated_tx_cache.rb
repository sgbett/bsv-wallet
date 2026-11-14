# frozen_string_literal: true

module BSV
  module Wallet
    class Engine
      # Bounded in-process LRU cache for hydration bytes, keyed by
      # +wtxid+ (wire-order, 32-byte binary). Each entry is an immutable
      # +{ raw_tx:, merkle_path: }+ pair — the same shape a +tx_proofs+
      # row carries — *not* a +Transaction::Tx+ object. Bytes (not
      # objects) sidestep the mutation hazard of sharing a wired
      # +source_transaction+ graph across concurrent reactor fibers.
      #
      # Both egress paths read through one shared instance:
      #
      #   - +Hydrator#wire_ancestor+ (deep, BEEF): a hit whose
      #     +merkle_path+ is present is treated as a proven terminal —
      #     return without descending. A hit without one is recursed over.
      #     A miss reads +Store#find_proof+ and populates the entry.
      #   - +Broadcast#hydrated_transaction_for+ (shallow, EF): a hit on an
      #     input's parent wtxid supplies that input's source satoshis +
      #     locking script (from +outputs[vout]+) without the
      #     +resolve_inputs_for_signing+ JOIN — which stays the floor on a
      #     miss. A Broadcast miss doesn't fill the cache.
      #
      # ## Keys
      #
      # Nothing here hashes +raw_tx+ against its key; the pairing is the
      # writer's. Hint, ingress and import entries
      # (+Broadcast#cache_beef_transactions+, +BeefInternalizer#save_beef_proofs+,
      # +Engine#import_utxo+, +Engine#internalize_wbikd_utxo+) are keyed by
      # the wtxid of the transaction parsed from their own bytes. Store
      # refills (+Hydrator#wire_ancestor+) and the proof puts from
      # +Engine::TxProof+ and Broadcast's eager broadcast-response proof are
      # keyed by the wtxid stored beside those bytes in +tx_proofs+ or
      # +actions+.
      #
      # ## Enrichment, no invalidation
      #
      # Entries are added, and leave only by LRU age-out under memory
      # pressure. +put+ keeps an entry's +merkle_path+ when given +nil+, so
      # a caller holding only +raw_tx+ cannot clear a proven terminal; a
      # non-nil path replaces whatever is there. There are no lifecycle
      # eviction hooks — broadcast outcome is irrelevant to the cache
      # (cf. #269, which this inverts).
      #
      # ## Principle of state
      #
      # A cached +merkle_path+ is not self-authenticating: +wire_ancestor+
      # trusts whatever path it finds. An entry filled from +tx_proofs+, or
      # put once the wallet has committed the proof, mirrors that row, and
      # dropping it and rebuilding from the DB gives the same behaviour.
      # +Engine#import_utxo+ is the exception for now: it puts its entry
      # inside the transaction that saves the proof, so a rollback leaves
      # an entry with no row (#558). Hint-fed entries carry +raw_tx+ only,
      # keyed by the hash of those bytes, so a hint can add a transaction
      # but cannot alter one, and never adds or replaces a path (#556). See
      # +docs/reference/principle-of-state.md+.
      #
      # Warning: a hint entry for a proven transaction has no path until a
      # proof put fills one, so +wire_ancestor+ treats it as unproven and
      # walks on past it rather than reading +tx_proofs+. Nothing in
      # +walletd+ walks ancestry today.
      #
      # Implementation: Ruby's +Hash+ preserves insertion order (MRI 1.9+),
      # so +#delete+-then-+#[]=+ moves an entry to the MRU end; LRU eviction
      # is a +#shift+ of the oldest entries when over capacity. A +Mutex+
      # guards every operation; under the daemon's Async reactor an
      # uncontended Mutex acquire does not park the reactor.
      class HydratedTxCache
        DEFAULT_CAPACITY = 20_000

        attr_reader :capacity

        # Construct from the central config (+BSV::Wallet.config.tx_cache_size+).
        def self.from_config
          new(capacity: BSV::Wallet.config.tx_cache_size)
        end

        # @param capacity [Integer] maximum number of entries; 0 disables
        #   storage (always-miss cache, useful for tests).
        def initialize(capacity: DEFAULT_CAPACITY)
          raise ArgumentError, "capacity must be >= 0 (got #{capacity})" if capacity.negative?

          @capacity = capacity
          @entries = {}
          @lock = Mutex.new
        end

        # Insert or update the entry for +wtxid+ and promote it to MRU. A
        # +nil+ +merkle_path+ keeps the path already present, so callers
        # that only hold +raw_tx+ (an unconfirmed wire-up) cannot clear a
        # proven terminal; a non-nil one replaces it. +raw_tx+ is always
        # replaced, which is harmless only while every writer keys by the
        # wtxid of the bytes it passes — not checked here.
        #
        # @param wtxid [String] 32-byte wire-order wtxid
        # @param raw_tx [String] transaction bytes (wire format)
        # @param merkle_path [String, nil] serialized merkle path, or nil
        def put(wtxid, raw_tx:, merkle_path: nil)
          return if @capacity.zero?

          @lock.synchronize do
            existing = @entries.delete(wtxid)
            kept_path = merkle_path || existing&.fetch(:merkle_path, nil)
            # +dup.freeze+ the String values so a caller that retains a
            # reference and later mutates in place cannot corrupt cached
            # bytes across fibers — Hash#freeze alone freezes the wrapper
            # but not its contents. Entries returning through #get are
            # cross-fiber-safe by construction.
            @entries[wtxid] = {
              raw_tx: raw_tx.dup.freeze,
              merkle_path: kept_path&.dup&.freeze
            }.freeze
            @entries.shift while @entries.size > @capacity
          end
        end

        # @param wtxid [String] 32-byte wire-order wtxid
        # @return [Hash, nil] frozen +{ raw_tx:, merkle_path: }+ or nil on miss
        def get(wtxid)
          @lock.synchronize do
            value = @entries.delete(wtxid)
            @entries[wtxid] = value if value
            value
          end
        end

        # @return [Integer] current entry count.
        def size
          @lock.synchronize { @entries.size }
        end

        # @return [Boolean]
        def empty?
          @lock.synchronize { @entries.empty? }
        end
      end
    end
  end
end
