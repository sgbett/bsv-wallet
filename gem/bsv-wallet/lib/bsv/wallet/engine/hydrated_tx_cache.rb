# frozen_string_literal: true

module BSV
  module Wallet
    class Engine
      # Bounded in-process LRU cache for *hydrated* +Transaction::Tx+
      # objects, keyed by +action_id+. "Hydrated" here means every
      # input has +source_transaction+ populated with the full parent
      # +Transaction::Tx+, which is what lets the cached object serialise
      # to EF (for broadcast) or BEEF (for p2p hand-off) without
      # touching the DB. Populated by parsing the producer-side
      # Atomic BEEF that +Engine#create_action+ already builds, so
      # this comes for free.
      #
      # Hit on +#get+ saves +Engine::Broadcast#submit+ from the
      # +Store#resolve_inputs_for_signing+ JOIN; miss falls through to
      # #252's reconstruction path. Correctness rides on the DB;
      # performance rides on the cache. See #269.
      #
      # Populated in two ways:
      #   - Daemon's own +Engine#create_action+ calls (intra-process producer
      #     and consumer in the same daemon).
      #   - OMQ hint receiver fiber pulling pushes from out-of-process
      #     producers (CLI tools, API/ABI server, wallet UI).
      #
      # Evicted in two ways:
      #   - +Engine::Broadcast+ explicitly evicts on terminal broadcast
      #     outcomes (record_broadcast_result success / reject_action).
      #   - LRU evicts least-recently-used entries when +#put+ pushes past
      #     the configured capacity. Backstop for entries that never
      #     reach a terminal state.
      #
      # Implementation: Ruby's +Hash+ preserves insertion order from
      # MRI 1.9+, so a +#delete+-then-+#[]=+ on read moves the entry to
      # the MRU end; LRU eviction is a simple +#shift+ on the oldest
      # entries when over capacity. +Mutex+ guards every operation; the
      # daemon's Async reactor is fiber-safe under Mutex because Mutex
      # in MRI doesn't park the reactor for uncontended acquires.
      class HydratedTxCache
        DEFAULT_CAPACITY = 1000

        attr_reader :capacity

        # Construct from the central config (+BSV::Wallet.config.tx_cache_size+).
        # The default constructor used by +Engine::Broadcast+; CLI tools
        # and specs can call +new+ directly with a specific capacity. #277.
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

        # @return [Transaction::Tx, nil]
        def get(action_id)
          @lock.synchronize do
            value = @entries.delete(action_id)
            @entries[action_id] = value if value
            value
          end
        end

        # @param action_id [Integer]
        # @param transaction [Transaction::Tx]
        def put(action_id, transaction)
          return if @capacity.zero?

          @lock.synchronize do
            @entries.delete(action_id)
            @entries[action_id] = transaction
            @entries.shift while @entries.size > @capacity
          end
        end

        # @param action_id [Integer]
        def evict(action_id)
          @lock.synchronize { @entries.delete(action_id) }
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
