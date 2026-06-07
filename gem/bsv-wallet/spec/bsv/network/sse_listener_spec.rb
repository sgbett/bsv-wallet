# frozen_string_literal: true

require 'async'
require 'async/queue'
require 'logger'
require 'stringio'
require_relative '../wallet/store/shared_context'

# Stub HTTP client substituted for +Async::HTTP::Internet+ in tests.
# Records the URL and headers of each +get+ call and dispenses a
# scripted +StubResponse+ from a queue. The listener owns the response
# object's lifecycle (calls +close+), so a fresh response is needed per
# call.
class StubInternet
  attr_reader :calls

  def initialize(responses:)
    @responses = responses.dup
    @calls = []
    @notify = Async::Notification.new
  end

  def get(url, headers)
    @calls << { url: url, headers: header_hash(headers) }
    @notify.signal
    @responses.shift || raise("StubInternet: no more scripted responses (call ##{@calls.length})")
  end

  def close; end

  # Wait until at least +count+ get calls have been made.
  def wait_for_call_count(count)
    @notify.wait while @calls.size < count
  end

  private

  def header_hash(headers)
    headers.each_with_object({}) { |(k, v), h| h[k] = v }
  end
end

# Streaming body backed by an +Async::Queue+ so the listener's +read+
# integrates with the reactor (proper fiber suspension rather than
# blocking the thread). Mirrors the surface area of
# +Async::HTTP::Body::Writable+ used by the listener.
class StubBody
  def initialize
    @queue = Async::Queue.new
    @closed = false
  end

  def write(chunk)
    @queue.enqueue(chunk)
  end

  def close_write
    @queue.enqueue(nil)
  end

  def read
    return nil if @closed

    @queue.dequeue
  end

  def close(_error = nil)
    @closed = true
  end
end

# Stub for +Async::HTTP::Protocol::Response+ that the listener treats
# as a streaming body. Exposes +status+, +success?+, +body+, and
# +close+ -- the full surface the listener touches.
class StubResponse
  attr_reader :body, :status

  def initialize(status: 200, body: StubBody.new)
    @status = status
    @body = body
    @closed = false
  end

  def success?
    @status >= 200 && @status < 300
  end

  def close
    return if @closed

    @closed = true
    @body.close
  end
end

# Helper: assemble a fully-formed SSE frame from its parts.
def sse_frame(id:, data:, event: 'status')
  data_lines = data.split("\n").map { |line| "data: #{line}" }.join("\n")
  "id: #{id}\nevent: #{event}\n#{data_lines}\n\n"
end

# Helper: build a JSON status body in Arcade's wire shape
# (camelCase + hex txid).
def arcade_event_body(dtxid: '11' * 32, tx_status: 'SEEN_ON_NETWORK', status: 200,
                      extra_info: nil, block_height: nil, block_hash: nil,
                      merkle_path: nil, competing_txs: nil)
  body = { txid: dtxid, txStatus: tx_status, status: status }
  body[:extraInfo] = extra_info if extra_info
  body[:blockHeight] = block_height if block_height
  body[:blockHash] = block_hash if block_hash
  body[:merklePath] = merkle_path if merkle_path
  body[:competingTxs] = competing_txs if competing_txs
  JSON.generate(body)
end

RSpec.describe BSV::Network::SSEListener, :store do
  include_context 'store setup'

  let(:token) { "test-token-#{SecureRandom.hex(4)}" }
  let(:base_url) { 'https://arcade.example.test' }
  let(:silent_logger) { Logger.new(StringIO.new) }
  let(:captured) { Async::Queue.new }
  let(:on_event) { ->(event) { captured.enqueue(event) } }
  let(:dtxid) { 'aa' * 32 }
  let(:expected_wtxid) { ['aa' * 32].pack('H*').reverse }

  # Build a listener wired to a +StubInternet+ scripted with the given
  # bodies. Returns the listener, the +StubInternet+ (so the test can
  # assert on request headers), and the bodies (for feeding chunks).
  def build_listener(bodies:, idle_timeout: 30.0, on_event: nil)
    callback = on_event || self.on_event
    responses = bodies.map { |b| StubResponse.new(body: b) }
    internet = StubInternet.new(responses: responses)
    listener = described_class.new(
      token: token, store: store, base_url: base_url,
      logger: silent_logger, idle_timeout: idle_timeout,
      internet: internet, &callback
    )
    [listener, internet, bodies]
  end

  # Drive the listener inside an Async reactor. Yields the supplied
  # block with the +task+ -- the block is responsible for feeding chunks
  # and waiting for the desired events to land. The listener is stopped
  # and joined when the block returns.
  def with_listener(listener, bodies)
    Sync do |task|
      runner = task.async { listener.run!(task: task) }
      yield task
    ensure
      listener.stop!
      bodies.each(&:close_write)
      runner&.wait
    end
  end

  describe '#initialize' do
    it 'requires a non-empty token' do
      expect do
        described_class.new(token: '', store: store) { |_| }
      end.to raise_error(ArgumentError, /token is required/)
    end

    it 'requires a store' do
      expect do
        described_class.new(token: 'x', store: nil) { |_| }
      end.to raise_error(ArgumentError, /store is required/)
    end

    it 'requires an on_event block' do
      expect do
        described_class.new(token: 'x', store: store)
      end.to raise_error(ArgumentError, /on_event block is required/)
    end
  end

  describe 'L1.1 frame parsing' do
    it 'parses a well-formed frame into the expected event hash' do
      listener, _, bodies = build_listener(bodies: [StubBody.new])
      with_listener(listener, bodies) do
        bodies.first.write(sse_frame(id: '1', data: arcade_event_body(dtxid: dtxid)))
        event = captured.dequeue
        expect(event).to include(
          wtxid: expected_wtxid,
          tx_status: 'SEEN_ON_NETWORK',
          status: 200
        )
      end
    end

    it 'handles a frame split across multiple chunks' do
      listener, _, bodies = build_listener(bodies: [StubBody.new])
      frame = sse_frame(id: '42', data: arcade_event_body(dtxid: dtxid))
      midpoint = frame.length / 2

      with_listener(listener, bodies) do
        bodies.first.write(frame[0...midpoint])
        bodies.first.write(frame[midpoint..])
        event = captured.dequeue
        expect(event[:wtxid]).to eq(expected_wtxid)
      end
    end

    it 'concatenates multi-line data fields' do
      listener, _, bodies = build_listener(bodies: [StubBody.new])
      multiline_data = "{\n  \"txid\": \"#{dtxid}\",\n  \"txStatus\": \"SEEN_ON_NETWORK\",\n  \"status\": 200\n}"

      with_listener(listener, bodies) do
        bodies.first.write(sse_frame(id: '1', data: multiline_data))
        event = captured.dequeue
        expect(event[:wtxid]).to eq(expected_wtxid)
      end
    end

    it 'ignores keepalive comment frames silently' do
      listener, _, bodies = build_listener(bodies: [StubBody.new])

      with_listener(listener, bodies) do
        bodies.first.write(": keepalive\n\n")
        bodies.first.write(sse_frame(id: '7', data: arcade_event_body(dtxid: dtxid)))
        event = captured.dequeue
        expect(event[:wtxid]).to eq(expected_wtxid)
      end
    end

    it 'parses several events in arrival order' do
      listener, _, bodies = build_listener(bodies: [StubBody.new])
      chunks = (1..3).map do |i|
        sse_frame(id: i.to_s, data: arcade_event_body(dtxid: format('%064x', i)))
      end

      seen = []
      with_listener(listener, bodies) do
        chunks.each { |c| bodies.first.write(c) }
        3.times { seen << captured.dequeue }
      end

      expect(seen.map { |e| e[:wtxid].reverse.unpack1('H*') })
        .to eq(%w[0000000000000000000000000000000000000000000000000000000000000001
                  0000000000000000000000000000000000000000000000000000000000000002
                  0000000000000000000000000000000000000000000000000000000000000003])
    end
  end

  describe 'L1.2 reconnect with Last-Event-ID' do
    it 'sends no Last-Event-ID header on first connect (no cursor)' do
      listener, internet, bodies = build_listener(bodies: [StubBody.new])

      with_listener(listener, bodies) do
        bodies.first.write(sse_frame(id: '5', data: arcade_event_body(dtxid: dtxid)))
        captured.dequeue
      end

      first_call = internet.calls.first
      expect(first_call[:headers]).not_to have_key('last-event-id')
      expect(first_call[:url]).to include("callbackToken=#{token}")
    end

    it 'sends Last-Event-ID header from persisted cursor on reconnect' do
      listener, internet, bodies = build_listener(bodies: [StubBody.new, StubBody.new])

      with_listener(listener, bodies) do
        bodies[0].write(sse_frame(id: '100', data: arcade_event_body(dtxid: dtxid)))
        captured.dequeue
        bodies[0].close_write
        bodies[1].write(sse_frame(id: '101', data: arcade_event_body(dtxid: 'bb' * 32)))
        captured.dequeue
      end

      expect(internet.calls.size).to be >= 2
      expect(internet.calls[1][:headers]['last-event-id']).to eq('100')
    end
  end

  describe 'L1.3 cursor survives listener restart' do
    it 'reads the persisted cursor on a fresh listener instance' do
      first_listener, _, first_bodies = build_listener(bodies: [StubBody.new])

      with_listener(first_listener, first_bodies) do
        first_bodies.first.write(sse_frame(id: '99', data: arcade_event_body(dtxid: dtxid)))
        captured.dequeue
      end

      expect(store.load_sse_cursor(token: token)).to eq(99)

      second_listener, second_internet, second_bodies = build_listener(bodies: [StubBody.new])

      with_listener(second_listener, second_bodies) do
        second_bodies.first.write(sse_frame(id: '100', data: arcade_event_body(dtxid: 'bb' * 32)))
        captured.dequeue
      end

      expect(second_internet.calls.first[:headers]['last-event-id']).to eq('99')
    end
  end

  describe 'L1.4 slow consumer / drop recovery via cursor' do
    it 'reconnects with cursor after a stream drop and resumes' do
      listener, internet, bodies = build_listener(bodies: [StubBody.new, StubBody.new])

      with_listener(listener, bodies) do
        bodies[0].write(sse_frame(id: '50', data: arcade_event_body(dtxid: dtxid)))
        captured.dequeue
        bodies[0].close_write
        bodies[1].write(sse_frame(id: '51', data: arcade_event_body(dtxid: 'bb' * 32)))
        captured.dequeue
      end

      expect(internet.calls.size).to be >= 2
      expect(internet.calls[1][:headers]['last-event-id']).to eq('50')
    end
  end

  describe 'L1.5 token-scoped URL' do
    it 'includes the callbackToken query param on every connect' do
      listener, internet, bodies = build_listener(bodies: [StubBody.new, StubBody.new])

      with_listener(listener, bodies) do
        bodies[0].write(sse_frame(id: '1', data: arcade_event_body(dtxid: dtxid)))
        captured.dequeue
        bodies[0].close_write
        bodies[1].write(sse_frame(id: '2', data: arcade_event_body(dtxid: 'bb' * 32)))
        captured.dequeue
      end

      internet.calls.each do |call|
        expect(call[:url]).to include("callbackToken=#{token}")
      end
    end
  end

  describe 'L1.6 malformed frames do not crash' do
    it 'skips a frame with invalid JSON and continues with the next' do
      listener, _, bodies = build_listener(bodies: [StubBody.new])

      with_listener(listener, bodies) do
        bodies.first.write("id: 1\nevent: status\ndata: {not json\n\n")
        bodies.first.write(sse_frame(id: '2', data: arcade_event_body(dtxid: dtxid)))
        event = captured.dequeue
        expect(event[:wtxid]).to eq(expected_wtxid)
      end
    end

    it 'skips a frame with invalid dtxid hex and continues' do
      listener, _, bodies = build_listener(bodies: [StubBody.new])
      bad = JSON.generate(txid: 'nothex', txStatus: 'SEEN_ON_NETWORK', status: 200)

      with_listener(listener, bodies) do
        bodies.first.write("id: 1\nevent: status\ndata: #{bad}\n\n")
        bodies.first.write(sse_frame(id: '2', data: arcade_event_body(dtxid: dtxid)))
        event = captured.dequeue
        expect(event[:wtxid]).to eq(expected_wtxid)
      end
    end

    it 'does not save a cursor for an undecodable frame' do
      listener, internet, bodies = build_listener(bodies: [StubBody.new, StubBody.new])

      with_listener(listener, bodies) do
        # Send only a malformed frame, then trigger reconnect so we know
        # the frame has been processed (the second get is observable
        # proof the first stream drained).
        bodies[0].write("id: 1\nevent: status\ndata: {not json\n\n")
        bodies[0].close_write
        internet.wait_for_call_count(2)
      end

      expect(store.load_sse_cursor(token: token)).to be_nil
    end
  end

  describe 'keepalive watchdog' do
    it 'tears down and reconnects when idle longer than the watchdog window' do
      listener, internet, bodies = build_listener(
        bodies: [StubBody.new, StubBody.new], idle_timeout: 0.1
      )

      with_listener(listener, bodies) do |task|
        # Feed nothing on the first body -- the watchdog should fire and
        # trigger a reconnect. Then feed an event on the second body to
        # confirm the reconnect succeeded.
        task.async do
          internet.wait_for_call_count(2)
          bodies[1].write(sse_frame(id: '7', data: arcade_event_body(dtxid: dtxid)))
        end
        captured.dequeue
      end

      expect(internet.calls.size).to be >= 2
    end

    it 'keepalive comment frames reset the watchdog' do
      listener, internet, bodies = build_listener(bodies: [StubBody.new], idle_timeout: 0.3)

      with_listener(listener, bodies) do |task|
        # Drip keepalives for ~0.6s -- twice the watchdog window --
        # then send a real event. If the watchdog had fired, the test
        # would either time out (no event) or see a second get call.
        feeder = task.async do
          6.times do
            bodies.first.write(": keepalive\n\n")
            task.sleep 0.1
          end
          bodies.first.write(sse_frame(id: '1', data: arcade_event_body(dtxid: dtxid)))
        end
        captured.dequeue
        feeder.wait
      end

      expect(internet.calls.size).to eq(1)
    end
  end

  describe 'cursor write timing' do
    # The cursor must not be observable from inside the +on_event+ block
    # itself -- the contract is "high-water mark of handed-off events",
    # saved AFTER the block returns. To probe this without two fibers
    # racing on the same pg connection, the observer captures the
    # "save_sse_cursor" call sequence relative to the on_event call: the
    # listener invokes +on_event+ first, then +save_sse_cursor+, never
    # the reverse.
    it 'saves the cursor only after the on_event block returns' do
      event_seen_at = nil
      observer = lambda do |_event|
        event_seen_at = Time.now.to_f
        captured.enqueue(:event)
      end

      mutex = Mutex.new
      cursor_save_calls = []
      original_save = store.method(:save_sse_cursor)
      allow(store).to receive(:save_sse_cursor) do |**kwargs|
        mutex.synchronize do
          cursor_save_calls << { at: Time.now.to_f, kwargs: kwargs }
        end
        original_save.call(**kwargs)
      end

      listener, _, bodies = build_listener(bodies: [StubBody.new], on_event: observer)

      with_listener(listener, bodies) do
        bodies.first.write(sse_frame(id: '42', data: arcade_event_body(dtxid: dtxid)))
        captured.dequeue
      end

      expect(cursor_save_calls.size).to eq(1)
      expect(cursor_save_calls.first[:kwargs]).to eq(token: token, last_event_id: 42)
      expect(cursor_save_calls.first[:at]).to be >= event_seen_at
      expect(store.load_sse_cursor(token: token)).to eq(42)
    end
  end
end
