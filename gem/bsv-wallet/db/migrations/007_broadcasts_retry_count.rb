# frozen_string_literal: true

# Add retry_count to broadcasts — increments only when the resolution
# loop's reject_action raises CannotRejectInternalActionError and the
# outer transaction rolls back. Small numbers expected; counter exists
# to surface stuck rows that hit the invariant guard repeatedly.
#
# Distinct from "how many times have we polled" (that's an operational
# concern; add last_polled_at separately if/when needed).

Sequel.migration do
  change do
    add_column :broadcasts, :retry_count, :integer, null: false, default: 0
  end
end
