# frozen_string_literal: true

Sequel.migration do
  up do
    postgres = database_type == :postgres

    # Add action_id with ON DELETE CASCADE to relationship tables.
    # Denormalized (derivable via output_id -> outputs.action_id) but
    # justified: set once at creation, never changes, enables cascade
    # cleanup — deleting an action automatically removes its spendable
    # entries, basket memberships, and output details.
    if postgres
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
      run <<~SQL
        ALTER TABLE outputs
          DROP CONSTRAINT IF EXISTS outputs_action_id_fkey,
          ALTER COLUMN action_id DROP NOT NULL,
          ADD CONSTRAINT outputs_action_id_fkey
            FOREIGN KEY (action_id) REFERENCES actions (id) ON DELETE SET NULL
      SQL
    else
      # SQLite: Sequel recreates tables internally for alter_table operations.
      alter_table(:spendable) do
        add_foreign_key :action_id, :actions, type: :bigint, on_delete: :cascade
      end

      alter_table(:output_baskets) do
        add_foreign_key :action_id, :actions, type: :bigint, on_delete: :cascade
      end

      alter_table(:output_details) do
        add_foreign_key :action_id, :actions, type: :bigint, on_delete: :cascade
      end

      alter_table(:outputs) do
        set_column_allow_null :action_id
        drop_foreign_key [:action_id]
        add_foreign_key [:action_id], :actions, on_delete: :set_null
      end
    end
  end

  down do
    postgres = database_type == :postgres

    if postgres
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
    else
      alter_table(:outputs) do
        set_column_not_null :action_id
        drop_foreign_key [:action_id]
        add_foreign_key [:action_id], :actions
      end
      alter_table(:spendable) { drop_column :action_id }
      alter_table(:output_baskets) { drop_column :action_id }
      alter_table(:output_details) { drop_column :action_id }
    end
  end
end
