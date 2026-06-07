# frozen_string_literal: true

require_relative 'shared_context'

RSpec.describe BSV::Wallet::Store, :store do
  let(:token) { "tok-#{SecureRandom.hex(8)}" }

  describe '#load_sse_cursor' do
    it 'returns nil for an unknown token' do
      expect(store.load_sse_cursor(token: token)).to be_nil
    end

    it 'returns the persisted last_event_id after save' do
      store.save_sse_cursor(token: token, last_event_id: 12_345)

      expect(store.load_sse_cursor(token: token)).to eq(12_345)
    end
  end

  describe '#save_sse_cursor' do
    it 'round-trips the cursor value' do
      store.save_sse_cursor(token: token, last_event_id: 999)

      expect(store.load_sse_cursor(token: token)).to eq(999)
    end

    it 'upserts on duplicate token (second save wins, no PK violation)' do
      store.save_sse_cursor(token: token, last_event_id: 100)
      store.save_sse_cursor(token: token, last_event_id: 200)

      expect(store.load_sse_cursor(token: token)).to eq(200)
    end

    it 'is monotonic — a stale write with a smaller id is a no-op (defends against listener race / dual-flush)' do
      store.save_sse_cursor(token: token, last_event_id: 500)
      store.save_sse_cursor(token: token, last_event_id: 200) # smaller, must not rewind

      expect(store.load_sse_cursor(token: token)).to eq(500)
    end

    it 'is monotonic — equal id is also a no-op (no rewind, no spurious update)' do
      store.save_sse_cursor(token: token, last_event_id: 500)
      store.save_sse_cursor(token: token, last_event_id: 500)

      expect(store.load_sse_cursor(token: token)).to eq(500)
    end

    it 'stamps updated_at on each save' do
      before = Time.now - 60
      store.save_sse_cursor(token: token, last_event_id: 1)
      row1 = BSV::Wallet::Store::Models::SseCursor.first(token: token)
      expect(row1.updated_at).to be >= before

      sleep 0.01
      store.save_sse_cursor(token: token, last_event_id: 2)
      row2 = BSV::Wallet::Store::Models::SseCursor.first(token: token)
      expect(row2.updated_at).to be >= row1.updated_at
    end

    it 'isolates cursors per token' do
      other = "tok-#{SecureRandom.hex(8)}"
      store.save_sse_cursor(token: token, last_event_id: 11)
      store.save_sse_cursor(token: other, last_event_id: 22)

      expect(store.load_sse_cursor(token: token)).to eq(11)
      expect(store.load_sse_cursor(token: other)).to eq(22)
    end

    # Arcade emits SSE ids as nanosecond timestamps (PR #50): 19 digits in
    # the foreseeable future. Bignum -> bigint must accept the full value
    # round-trip without truncation.
    it 'accepts a 19-digit nanosecond timestamp', :postgres do
      ns = 1_700_000_000_123_456_789

      store.save_sse_cursor(token: token, last_event_id: ns)

      expect(store.load_sse_cursor(token: token)).to eq(ns)
    end
  end
end
