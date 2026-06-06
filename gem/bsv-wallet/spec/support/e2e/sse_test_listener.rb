# frozen_string_literal: true

require 'async'
require 'bsv/network/sse_listener'

module E2E
  # Threaded wrapper around +BSV::Network::SSEListener+ for the
  # SSE-driven broadcast scenarios in +spec/e2e/broadcast_spec.rb+
  # (HLR #251 / #267).
  #
  # Each scenario instantiates one listener per +callback_token+ it
  # cares about; the wrapper spins an Async reactor on a worker
  # thread, registers an +on_event+ block that pushes decoded events
  # into two queues (one for ordered consumption via +wait_for+, one
  # raw log for ground-truth assertions like E8), and offers a
  # +start+/+stop+ lifecycle that's safe to drive from the rspec
  # main thread.
  #
  # Why a thread + nested +Async+ reactor: rspec examples are
  # synchronous; the +BSV::Network::SSEListener+ expects to run as
  # an Async task. Wrapping it in a thread that owns its reactor
  # keeps the spec body straightforward (broadcast, sleep, assert)
  # without bleeding fiber semantics into every assertion.
  #
  # MINED-class frames are filtered out per plan Sec.6.1 (block
  # timing is out of scope for #267).
  class SSETestListener
    # Convenience accessor: the raw frame log (post-decode, pre-filter).
    # E8 reads this directly to dump ground-truth payloads.
    attr_reader :raw_events

    def initialize(token:, store:)
      @token = token
      @store = store
      @events = Queue.new
      @raw_events = []
      @raw_mutex = Mutex.new
      @stopped = false
    end

    # Start the listener fiber. Blocks until the inner Async task has
    # set up, then sleeps briefly so Arcade has time to register the
    # subscription before the spec broadcasts -- subscribing AFTER the
    # broadcast often misses the SEEN frame entirely.
    def start
      ready = Queue.new
      @thread = Thread.new do
        Async do |task|
          @listener = BSV::Network::SSEListener.new(token: @token, store: @store) do |event|
            @raw_mutex.synchronize { @raw_events << event }
            @events << event
          end
          ready << :ready
          @listener.run!(task: task)
        end
      end
      ready.pop
      sleep 2.0
    end

    # Cooperative shutdown: signal the listener, then wait up to 5s
    # for the wrapper thread to exit. Idempotent.
    def stop
      return if @stopped

      @stopped = true
      @listener&.stop!
      @thread&.join(5)
      @thread&.kill if @thread&.alive?
    end

    # Drain decoded events matching +wtxid+ within +deadline+, ignoring
    # MINED-class frames. Optionally filters on +status_filter+ (an
    # array of upcased ARC status strings). Returns the matched events
    # in arrival order; empty array if the deadline expires first.
    #
    # @param wtxid [String] 32-byte wire-order wtxid
    # @param deadline [Float] CLOCK_MONOTONIC absolute deadline
    # @param count [Integer] return after this many matches
    # @param status_filter [Array<String>, nil] upcased tx_status whitelist
    # @return [Array<Hash>]
    def wait_for(wtxid:, deadline:, count: 1, status_filter: nil)
      matches = []
      until matches.length >= count
        remaining = deadline - monotonic_now
        break if remaining <= 0

        begin
          event = @events.pop(timeout: remaining)
        rescue ThreadError
          break
        end
        next unless event
        next if mined?(event)
        next unless event[:wtxid] == wtxid
        next if status_filter && !status_filter.include?(event[:tx_status].to_s.upcase)

        matches << event
      end
      matches
    end

    private

    def mined?(event)
      %w[MINED IMMUTABLE].include?(event[:tx_status].to_s.upcase)
    end

    def monotonic_now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
