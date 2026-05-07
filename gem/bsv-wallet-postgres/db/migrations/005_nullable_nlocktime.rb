# frozen_string_literal: true

Sequel.migration do
  up do
    alter_table(:actions) do
      drop_constraint :nlocktime_range
      set_column_allow_null :nlocktime
      set_column_default :nlocktime, nil
      add_constraint(:nlocktime_range, 'NOT outgoing OR (nlocktime IS NOT NULL AND nlocktime >= 0)')
    end
  end

  down do
    alter_table(:actions) do
      drop_constraint :nlocktime_range
      # Backfill NULLs before re-adding NOT NULL
      run "UPDATE actions SET nlocktime = 0 WHERE nlocktime IS NULL"
      set_column_not_null :nlocktime
      set_column_default :nlocktime, 0
      add_constraint(:nlocktime_range) { nlocktime >= 0 }
    end
  end
end
