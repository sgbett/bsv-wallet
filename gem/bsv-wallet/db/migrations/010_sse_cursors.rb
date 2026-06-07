# frozen_string_literal: true

# Cursor persistence for Arcade's SSE /events stream. One row per
# callbackToken; the row records the high-water Last-Event-ID so a
# reconnecting listener can resume without replaying frames the wallet
# has already pushed onto the in-proc bus (see #251 plan, §3 / L1.2-L1.3).
#
# Token has no FK -- it is a wallet-derived identifier (HMAC-from-WIF
# via +BSV::Wallet::CallbackToken#derive+) that the wallet supplies to
# Arcade for callback scoping, not a row in any other wallet table.
# last_event_id is the SSE id field, a nanosecond timestamp emitted by
# Arcade (PR #50): bigint accommodates the full 19-digit value.
#
# updated_at follows the schema-wide +c[:timestamptz]+ convention from
# 001_create_schema.rb (timestamptz on Postgres, datetime on SQLite)
# with a +now()+ default so cursor writes always stamp consistently.
# Explicit +up+/+down+ because Sequel's +change+ reverser cannot
# introspect the +database_type+ branch.

Sequel.migration do
  up do
    postgres = database_type == :postgres
    timestamptz_type = postgres ? :timestamptz : :datetime
    now_default = postgres ? Sequel.function(:now) : Sequel::CURRENT_TIMESTAMP

    create_table :sse_cursors do
      String :token, primary_key: true
      Bignum :last_event_id, null: false
      column :updated_at, timestamptz_type, null: false, default: now_default
    end
  end

  down do
    drop_table :sse_cursors
  end
end
