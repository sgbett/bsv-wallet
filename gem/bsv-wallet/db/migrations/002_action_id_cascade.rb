# frozen_string_literal: true

# Denormalised action_id columns + cascade FKs on the per-output relationship
# tables, plus the spendable→promotions cascade FK.
#
# action_id is derivable via output_id → outputs.action_id but lifted here as a
# direct FK so action deletion is a single statement: the action goes, every
# spendable, basket-membership, output-details row dependent on it goes with it.
# Set once at row creation and never mutated. Without this, the reaper would
# need a multi-statement join-driven cleanup.
#
# spendable.action_id additionally references promotions(action_id) so that
# UTXO-set membership cannot exist without authorisation, and reject/reorg
# teardown collapses to a single DELETE FROM promotions that cascades through.

Sequel.migration do
  up do
    postgres = database_type == :postgres

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

      run <<~SQL
        ALTER TABLE spendable
          ADD CONSTRAINT spendable_promotion_fkey
          FOREIGN KEY (action_id) REFERENCES promotions (action_id) ON DELETE CASCADE
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

      alter_table(:spendable) do
        add_foreign_key [:action_id], :promotions, key: [:action_id], on_delete: :cascade
      end
    end
  end

  down do
    postgres = database_type == :postgres

    if postgres
      run 'ALTER TABLE spendable DROP CONSTRAINT IF EXISTS spendable_promotion_fkey'
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
      alter_table(:spendable) { drop_foreign_key [:action_id], name: :spendable_promotion_fkey }
      alter_table(:spendable) { drop_column :action_id }
      alter_table(:output_baskets) { drop_column :action_id }
      alter_table(:output_details) { drop_column :action_id }
    end
  end
end
