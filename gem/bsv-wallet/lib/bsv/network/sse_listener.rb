# frozen_string_literal: true

require 'async/http/internet'
require 'protocol/http/headers'
require 'json'

module BSV
  module Network
    # Layer 1 of the Arcade SSE push-resolution pipeline (#251 / #264).
    #
    # Long-lived listener that connects to Arcade's +/events+ stream, parses
    # SSE frames, decodes each one into the wallet's internal event hash, and
    # hands it off via the +&on_event+ block supplied at construction. The
    # block is the integration seam: in #264 it is just a test capture, in
    # #265 it becomes an OMQ PUSH onto the statuses bus.
    #
    # Cursor persistence is the resumption contract. The most recent
    # +id:+ value handed off to the block is upserted into +sse_cursors+
    # via +Store#save_sse_cursor+. On reconnect (drop, error, EOF, or
    # watchdog timeout) the listener reads the cursor back and sends it
    # as the +Last-Event-ID+ request header so Arcade replays from the
    # high-water mark. Cursor write happens AFTER the block returns --
    # "high-water mark of handed-off events", not "applied events" --
    # downstream application failures recover via the replay path on the
    # next reconnect.
    #
    # Frame parsing is inline (no SSE gem). The framing grammar is
    # trivial: +<field>: <value>\n+ lines, +\n\n+ separates events,
    # +:+-prefixed lines are comments (keepalive heartbeats, ignored).
    # Malformed frames are logged and skipped; the listener keeps
    # running. See plan 6.2 (L1.1-L1.6) for the test scenarios this
    # design has to satisfy.
    #
    # Constructor signature departs from #264's original draft (which
    # took +push_socket_path:+) -- the listener stays transport-agnostic
    # in this PR and only learns about PUSH in #265. Callers wire the
    # block themselves.
    class SSEListener
      EVENTS_PATH = '/events'

      # Time between reconnect attempts. A constant rather than backoff
      # because Arcade's connection drops are predominantly the keepalive
      # watchdog firing on a wedged TCP socket -- the next connect almost
      # always succeeds. Exponential backoff would slow resumption on the
      # common case to guard against an unlikely thrash.
      RECONNECT_DELAY = 1.0

      # Maximum idle window before tearing down a connection and
      # reconnecting. Arcade emits a +:+ comment keepalive every 15s
      # (PR socketry/arcade#50); 30s is two missed heartbeats, the
      # standard "connection is wedged" threshold for SSE.
      DEFAULT_IDLE_TIMEOUT = 30.0

      # @param token   [String]            Arcade callbackToken (URL query + cursor PK)
      # @param store   [BSV::Wallet::Store] cursor persistence
      # @param base_url [String]           Arcade base URL (path is appended)
      # @param logger  [Logger, nil]       structured-event logger
      # @param idle_timeout [Numeric]      watchdog window in seconds
      # @param internet [#get, nil]        HTTP client (defaults to a fresh +Async::HTTP::Internet+);
      #                                    injection point for tests
      # @yield [event_hash] called once per decoded event
      # @yieldparam event_hash [Hash] internal event shape -- see #decode_event
      def initialize(token:, store:, base_url: 'https://arcade.gorillapool.io',
                     logger: BSV.logger, idle_timeout: DEFAULT_IDLE_TIMEOUT,
                     internet: nil, &on_event)
        raise ArgumentError, 'token is required' if token.nil? || token.empty?
        raise ArgumentError, 'store is required' if store.nil?
        raise ArgumentError, 'on_event block is required' unless block_given?

        @token = token
        @store = store
        @base_url = base_url
        @logger = logger
        @idle_timeout = idle_timeout
        @internet = internet
        @on_event = on_event
        @stopped = false
      end

      # Run the listener loop inside the supplied Async task. Returns when
      # +stop!+ is invoked. Each iteration is one Arcade connection; the
      # loop body owns reconnect-with-cursor on every exit path (clean EOF,
      # exception, watchdog timeout).
      #
      # @param task [Async::Task] reactor task to attach child fibers to
      def run!(task:)
        @task = task
        owns_internet = @internet.nil?
        internet = @internet || Async::HTTP::Internet.new
        begin
          loop do
            break if @stopped

            begin
              stream_once(internet)
            rescue StandardError => e
              log_warn("[SSEListener] stream error: #{e.class}: #{e.message}")
            end

            break if @stopped

            interruptible_sleep(RECONNECT_DELAY)
          end
        ensure
          internet.close if owns_internet
        end
      end

      # Cooperative shutdown signal. The run loop checks +@stopped+ before
      # each connection attempt and between events; closing the in-flight
      # response and stopping any in-progress read unblocks the loop so
      # it can exit without waiting for the next reconnect tick.
      def stop!
        @stopped = true
        @current_response&.close
        @sleep_task&.stop
      end

      private

      def interruptible_sleep(seconds)
        @sleep_task = @task.async do |t|
          t.sleep(seconds)
        end
        @sleep_task.wait
      rescue Async::Stop
        # stop! cancelled the sleep -- expected during shutdown.
      ensure
        @sleep_task = nil
      end

      def stream_once(internet)
        cursor = @store.load_sse_cursor(token: @token)
        url = "#{@base_url}#{EVENTS_PATH}?callbackToken=#{@token}"
        headers = build_headers(cursor)

        log_info("[SSEListener] connecting cursor=#{cursor.inspect}")

        @current_response = internet.get(url, headers)
        begin
          consume_response(@current_response)
        ensure
          @current_response&.close
          @current_response = nil
        end
      end

      def build_headers(cursor)
        headers = [
          ['accept', 'text/event-stream'],
          ['cache-control', 'no-cache']
        ]
        headers << ['last-event-id', cursor.to_s] if cursor
        headers
      end

      def consume_response(response)
        return log_warn("[SSEListener] non-success status=#{response.status}") unless response.success?

        buffer = String.new(encoding: Encoding::ASCII_8BIT)
        body = response.body
        last_activity = monotonic_now

        loop do
          break if @stopped

          chunk = read_chunk_with_timeout(body, last_activity)
          break if chunk.nil?

          last_activity = monotonic_now
          # Async::HTTP streams chunks as ASCII-8BIT; the SSE protocol
          # itself is UTF-8. Don't mutate the chunk in place (it may be
          # frozen). Concatenate as bytes; the JSON parser handles
          # UTF-8 decoding from the data payload itself.
          buffer << chunk.b
          drain_frames(buffer)
        end
      end

      # Read one chunk from the body, enforcing the idle-timeout
      # watchdog. Returns nil if the stream ends, the watchdog fires,
      # or +stop!+ is signalled. Any chunk -- including the +:+ keepalive
      # comment lines that arrive without an enclosing frame -- resets
      # the activity clock; the watchdog only fires on truly silent TCP.
      def read_chunk_with_timeout(body, last_activity)
        deadline = last_activity + @idle_timeout
        remaining = deadline - monotonic_now

        if remaining <= 0
          log_warn('[SSEListener] idle timeout exceeded; reconnecting')
          return nil
        end

        @task.with_timeout(remaining) { body.read }
      rescue Async::TimeoutError
        log_warn('[SSEListener] idle timeout exceeded; reconnecting')
        nil
      end

      # Split the buffer on +\n\n+ frame boundaries, dispatch each
      # complete frame, leave any partial trailing frame in the buffer
      # for the next chunk.
      def drain_frames(buffer)
        while (idx = buffer.index("\n\n"))
          raw_frame = buffer.slice!(0, idx + 2)
          handle_frame(raw_frame)
        end
      end

      def handle_frame(raw_frame)
        frame = parse_frame(raw_frame)
        return if frame.nil?
        return if frame[:comment_only]

        event = decode_event(frame)
        return unless event

        @on_event.call(event)
        save_cursor(frame[:id]) if frame[:id]
      rescue StandardError => e
        log_warn("[SSEListener] frame handler error: #{e.class}: #{e.message}")
      end

      # Per W3C/HTML5 EventSource framing: each non-empty line is
      # +<field>: <value>+ (the leading space after +:+ is optional).
      # Lines beginning with +:+ are comments (keepalive heartbeats).
      # Multiple +data:+ lines in one frame concatenate with +\n+.
      # An empty frame (only comments / blank) is reported back as
      # +comment_only+ so the watchdog can credit it without yielding.
      def parse_frame(raw_frame)
        id = nil
        event = nil
        data_lines = []
        comment_only = true

        raw_frame.each_line do |line|
          line = line.chomp
          next if line.empty?

          next if line.start_with?(':')

          comment_only = false
          field, _, value = line.partition(':')
          value = value.sub(/\A /, '')

          case field
          when 'id'    then id = value
          when 'event' then event = value
          when 'data'  then data_lines << value
          end
        end

        return { comment_only: true } if comment_only

        { id: id, event: event, data: data_lines.join("\n") }
      rescue StandardError => e
        log_warn("[SSEListener] malformed frame: #{e.message}")
        nil
      end

      # Decode an Arcade status frame into the wallet's internal event
      # hash -- the shape +Store::EventApplicator#apply+ consumes. The
      # JSON body carries the txid in display-order hex (per Arcade
      # convention); we reverse it to wire-order binary +wtxid+ here so
      # the bus carries the wallet's canonical representation, not the
      # transport's.
      def decode_event(frame)
        return nil if frame[:data].nil? || frame[:data].empty?

        body = JSON.parse(frame[:data], symbolize_names: true)
        BSV::Primitives::Hex.validate_dtxid_hex!(body[:txid], name: 'SSE event txid') if body[:txid]

        {
          wtxid: decode_hex(body[:txid])&.reverse,
          tx_status: body[:txStatus],
          status: body[:status],
          block_hash: decode_hex(body[:blockHash]),
          block_height: body[:blockHeight],
          merkle_path: decode_hex(body[:merklePath]),
          extra_info: body[:extraInfo],
          competing_txs: body[:competingTxs]
        }
      rescue JSON::ParserError => e
        log_warn("[SSEListener] malformed event data: #{e.message}")
        nil
      end

      def decode_hex(hex)
        return unless hex

        [hex].pack('H*')
      end

      def save_cursor(id)
        @store.save_sse_cursor(token: @token, last_event_id: id.to_i)
      rescue StandardError => e
        log_warn("[SSEListener] cursor write failed: #{e.message}")
      end

      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      def log_info(message)
        @logger&.info { message }
      end

      def log_warn(message)
        @logger&.warn { message }
      end
    end
  end
end
