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
      # The cache is the shared substrate both egress paths read through:
      #
      #   - +Hydrator#wire_ancestor+ (deep, BEEF): a hit whose
      #     +merkle_path+ is present is a proven terminal — return without
      #     descending. A hit without one is recursed over. A miss reads
      #     +Store#find_proof+ and populates the entry.
      #   - +Broadcast#hydrated_transaction_for+ (shallow, EF): a hit on an
      #     input's parent wtxid supplies that input's source satoshis +
      #     locking script (from +outputs[vout]+) without the
      #     +resolve_inputs_for_signing+ JOIN — which stays the floor on a
      #     miss.
      #
      # ## Monotonic enrichment, no invalidation
      #
      # State only ever progresses: entries are added; an entry's
      # +merkle_path+ is filled in place when a proof arrives
      # (+Hydrator#proof_arrived+ → +put+); nothing degrades except by LRU
      # age-out under memory pressure. +put+ never clears a +merkle_path+
      # that is already set, so a proven terminal stays proven regardless
      # of call order. There are no lifecycle eviction hooks — broadcast
      # outcome is irrelevant to the cache (cf. #269, which this inverts).
      #
      # ## Principle of state
      #
      # The cache is a pure projection over the proof store: each value
      # mirrors a +tx_proofs+ row. Drop the cache and rebuild from the DB
      # and behaviour is identical — correctness rides on the DB,
      # performance rides on the cache. See +reference/principle-of-state.md+.
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

        # Insert or update the entry for +wtxid+. Monotonic on
        # +merkle_path+: a +nil+ argument never clears an already-present
        # path, so callers that only hold +raw_tx+ (an unconfirmed wire-up)
        # cannot regress a proven terminal. +raw_tx+ is immutable for a
        # given wtxid, so overwriting it is a no-op in practice. Promotes
        # the entry to MRU.
        #
        # @param wtxid [String] 32-byte wire-order wtxid
        # @param raw_tx [String] transaction bytes (wire format)
        # @param merkle_path [String, nil] serialized merkle path, or nil
        def put(wtxid, raw_tx:, merkle_path: nil)
          return if @capacity.zero?

          @lock.synchronize do
            existing = @entries.delete(wtxid)
            # Monotonic: keep an already-present merkle_path when the caller
            # supplies none.
            kept_path = merkle_path || existing&.fetch(:merkle_path, nil)
            @entries[wtxid] = { raw_tx: raw_tx, merkle_path: kept_path }.freeze
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
