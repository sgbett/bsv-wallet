# frozen_string_literal: true

Sequel.migration do
  up do
    # Add action_id with ON DELETE CASCADE to relationship tables.
    # Denormalized (derivable via output_id -> outputs.action_id) but
    # justified: set once at creation, never changes, enables cascade
    # cleanup — deleting an action automatically removes its spendable
    # entries, basket memberships, and output details.
    add_column :spendable, :action_id, :bigint
    run <<~SQL
      ALTER TABLE spendable
        ADD CONSTRAINT spendable_action_id_fkey
        FOREIGN KEY (action_id) REFERENCES actions (id) ON DELETE CASCADE
    SQL

    add_column :output_baskets, :action_id, :bigint
    run <<~SQL
      ALTER TABLE output_baskets
        ADD CONSTRAINT output_baskets_action_id_fkey
        FOREIGN KEY (action_id) REFERENCES actions (id) ON DELETE CASCADE
    SQL

    add_column :output_details, :action_id, :bigint
    run <<~SQL
      ALTER TABLE output_details
        ADD CONSTRAINT output_details_action_id_fkey
        FOREIGN KEY (action_id) REFERENCES actions (id) ON DELETE CASCADE
    SQL

    # Change outputs.action_id FK to ON DELETE SET NULL and make nullable.
    # Outputs are immutable log entries — when an action is deleted (abort,
    # reaper), the output rows survive as orphans with NULL action_id.
    # They have no spendable entry (cascade-deleted), no basket, and are
    # invisible to the wallet.
    run <<~SQL
      ALTER TABLE outputs
        DROP CONSTRAINT IF EXISTS outputs_action_id_fkey,
        ALTER COLUMN action_id DROP NOT NULL,
        ADD CONSTRAINT outputs_action_id_fkey
          FOREIGN KEY (action_id) REFERENCES actions (id) ON DELETE SET NULL
    SQL
  end

  down do
    run <<~SQL
      ALTER TABLE outputs
        DROP CONSTRAINT IF EXISTS outputs_action_id_fkey,
        ALTER COLUMN action_id SET NOT NULL,
        ADD CONSTRAINT outputs_action_id_fkey
          FOREIGN KEY (action_id) REFERENCES actions (id)
    SQL
    alter_table(:spendable) do
      drop_constraint :spendable_action_id_fkey
      drop_column :action_id
    end
    alter_table(:output_baskets) do
      drop_constraint :output_baskets_action_id_fkey
      drop_column :action_id
    end
    alter_table(:output_details) do
      drop_constraint :output_details_action_id_fkey
      drop_column :action_id
    end
  end
end
