# frozen_string_literal: true

# Cursor persistence for Arcade's SSE /events stream. One row per
# callbackToken; the row records the high-water Last-Event-ID so a
# reconnecting listener can resume without replaying frames the wallet
# has already pushed onto the in-proc bus (see #251 plan, §3 / L1.2-L1.3).
#
# Token has no FK -- it is an Arcade-issued identifier, not derived from
# any wallet table. last_event_id is the SSE id field, a nanosecond
# timestamp emitted by Arcade (PR #50): bigint accommodates the full
# 19-digit value.

Sequel.migration do
  change do
    create_table :sse_cursors do
      String :token, primary_key: true
      Bignum :last_event_id, null: false
      Time   :updated_at, null: false
    end
  end
end
