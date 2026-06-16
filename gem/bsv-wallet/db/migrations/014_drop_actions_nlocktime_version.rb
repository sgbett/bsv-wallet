# frozen_string_literal: true

# Drop actions.nlocktime and actions.version (#351). Both are stored
# projections of raw_tx — the canonical serialised transaction: nLockTime is
# its trailing four bytes (LE), version its leading four. The builder reads
# neither column; lock_time/version flow in-memory into tx_builder.build and
# are baked into raw_tx at sign time. The only reader, action_to_hash, now
# derives them from raw_tx. No constraint depends on them (the nlocktime_range
# CHECK went with actions.outgoing in #349).
#
# Non-final transactions (#192) are unaffected: the nLockTime *value* stays in
# raw_tx, and the non-final *intent* ("don't broadcast yet") needs its own
# explicit marker, not this value column.
#
# See ADR-022 (state-as-a-fk-row) and reference/state-representations.md.

Sequel.migration do
  up do
    if database_type == :postgres
      run 'ALTER TABLE actions DROP COLUMN nlocktime'
      run 'ALTER TABLE actions DROP COLUMN version'
    else
      alter_table(:actions) do
        drop_column :nlocktime
        drop_column :version
      end
    end
  end

  down do
    # Best-effort: per-row values are not reconstructed (they live in raw_tx).
    if database_type == :postgres
      run 'ALTER TABLE actions ADD COLUMN version integer'
      run 'ALTER TABLE actions ADD COLUMN nlocktime bigint'
    else
      alter_table(:actions) do
        add_column :version, :integer
        add_column :nlocktime, :bigint
      end
    end
  end
end
