# frozen_string_literal: true

# Drop actions.outgoing (#349). The column had no load-bearing consumer:
#   - its only runtime reader, pending_proofs, conjoined `outgoing: true`
#     with `broadcast_intent != 'none'`, which already implies it (every
#     outgoing:false action is created broadcast_intent:'none'); the sibling
#     reap query selects the same set on broadcast_intent alone;
#   - its only echo, action_to_hash, fed an interface field no caller or
#     spec consumes — now derived as `broadcast_intent != 'none'`.
#
# Its only hard dependency was the nlocktime_range CHECK, dropped here too:
# it guarded actions.nlocktime, a value the builder never reads (lock_time
# is threaded in-memory and baked into raw_tx) and which is the trailing
# four bytes of raw_tx anyway — a constraint on an unused, derivable value.
#
# See ADR-022 (state-as-a-fk-row) and reference/state-representations.md.

Sequel.migration do
  up do
    if database_type == :postgres
      run 'ALTER TABLE actions DROP CONSTRAINT IF EXISTS nlocktime_range'
      run 'ALTER TABLE actions DROP COLUMN outgoing'
    else
      alter_table(:actions) do
        drop_constraint :nlocktime_range
        drop_column :outgoing
      end
    end
  end

  down do
    # Approximate: per-row authored/ingested intent cannot be reconstructed,
    # so all rows default to outgoing = true (the original column default).
    if database_type == :postgres
      run 'ALTER TABLE actions ADD COLUMN outgoing boolean NOT NULL DEFAULT true'
      run 'ALTER TABLE actions ADD CONSTRAINT nlocktime_range ' \
          'CHECK (NOT outgoing OR (nlocktime IS NOT NULL AND nlocktime >= 0))'
    else
      alter_table(:actions) do
        add_column :outgoing, :boolean, null: false, default: true
        add_constraint(:nlocktime_range,
                       'NOT outgoing OR (nlocktime IS NOT NULL AND nlocktime >= 0)')
      end
    end
  end
end
