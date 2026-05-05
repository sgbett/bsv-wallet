# frozen_string_literal: true

# Originally added pending_outputs jsonb column to actions.
# That approach was replaced before deployment — migration 003
# adds action_id CASCADE columns to relationship tables instead.
# This placeholder preserves migration numbering continuity.

Sequel.migration do
  up do
    # no-op
  end

  down do
    # no-op
  end
end
