# frozen_string_literal: true

Sequel.migration do
  up do
    postgres = database_type == :postgres

    c = {}
    c[:output_type] = postgres ? :output_type : :text

    if postgres
      extension :pg_enum
      create_enum(:output_type, %w[root outbound])
    end

    # --- 1. blocks ---
    alter_table(:blocks) do
      add_constraint(:height_range) { height >= 0 }
      add_constraint(:merkle_root_length) { length(merkle_root) =~ 32 }
      add_constraint(:block_hash_length, 'block_hash IS NULL OR length(block_hash) = 32')
    end

    # --- 2. tx_proofs ---
    alter_table(:tx_proofs) do
      set_column_not_null :raw_tx
      add_constraint(:wtxid_length)       { length(wtxid) =~ 32 }
      add_constraint(:raw_tx_min_length)  { length(raw_tx) >= 20 }
      # A merkle_path without block context is unverifiable — no root to
      # check against. The reverse is fine (#198/#219): height-known +
      # path-pending is the "confirmed but unproven" intermediate state.
      add_constraint(:path_requires_block, 'merkle_path IS NULL OR block_id IS NOT NULL')
    end

    # --- 3. actions ---
    alter_table(:actions) do
      drop_column :satoshis
      set_column_not_null :description
      add_constraint(:wtxid_length, 'wtxid IS NULL OR length(wtxid) = 32')
      add_constraint(:description_length, 'length(description) BETWEEN 5 AND 50')
      add_constraint(:nlocktime_range, 'NOT outgoing OR (nlocktime IS NOT NULL AND nlocktime >= 0)')
      add_constraint(:wtxid_raw_tx_parity, '(wtxid IS NULL) = (raw_tx IS NULL)')
      add_constraint(:broadcast_intent_values, "broadcast_intent IN ('delayed', 'inline', 'none')") if !postgres
    end

    if postgres
      # Convert reference from text to uuid
      run 'ALTER TABLE actions ALTER COLUMN reference SET NOT NULL'
      run 'ALTER TABLE actions ALTER COLUMN reference TYPE uuid USING reference::uuid'
      run 'ALTER TABLE actions ALTER COLUMN reference SET DEFAULT gen_random_uuid()'
    else
      alter_table(:actions) do
        set_column_not_null :reference
      end
    end

    # --- 4. broadcasts ---
    alter_table(:broadcasts) do
      add_constraint(:block_hash_length, 'block_hash IS NULL OR length(block_hash) = 32')
      add_constraint(:block_height_range, 'block_height IS NULL OR block_height >= 0')
    end

    # --- 5. baskets ---
    # Drop partial index before dropping the column it references (SQLite
    # rebuilds the table on alter_table and chokes on dangling index refs).
    run 'DROP INDEX IF EXISTS baskets_name_index'
    alter_table(:baskets) do
      drop_column :deleted_at
      add_unique_constraint :name, name: :baskets_name_unique
      add_constraint(:name_length, 'length(name) BETWEEN 1 AND 300')
      add_constraint(:name_not_default, "name != 'default'")
      add_constraint(:target_count_range, 'target_count IS NULL OR target_count >= 0')
      add_constraint(:target_value_range, 'target_value IS NULL OR target_value >= 0')
    end

    # --- 6. outputs ---
    alter_table(:outputs) do
      set_column_not_null :locking_script
      add_column :output_type, c[:output_type]
      add_constraint(:satoshis_range)          { satoshis >= 0 }
      add_constraint(:vout_range)              { vout >= 0 }
      add_constraint(:locking_script_min)      { length(locking_script) >= 1 }
      add_constraint(:typed_no_prefix,   'output_type IS NULL OR derivation_prefix IS NULL')
      add_constraint(:typed_no_suffix,   'output_type IS NULL OR derivation_suffix IS NULL')
      add_constraint(:typed_no_sender,   'output_type IS NULL OR sender_identity_key IS NULL')
      add_constraint(:derived_needs_prefix, 'output_type IS NOT NULL OR derivation_prefix IS NOT NULL')
      add_constraint(:derived_needs_suffix, 'output_type IS NOT NULL OR derivation_suffix IS NOT NULL')
      add_constraint(:derived_needs_sender, 'output_type IS NOT NULL OR sender_identity_key IS NOT NULL')
      add_constraint(:output_type_values, "output_type IS NULL OR output_type IN ('root', 'outbound')") if !postgres
    end

    # --- 7. spendable ---
    alter_table(:spendable) do
      set_column_not_null :action_id
    end

    # Outbound outputs must never have a spendable row.
    if postgres
      run <<~SQL
        CREATE FUNCTION prevent_outbound_spendable() RETURNS trigger AS $$
        BEGIN
          IF EXISTS (SELECT 1 FROM outputs WHERE id = NEW.output_id AND output_type = 'outbound') THEN
            RAISE EXCEPTION 'spendable row forbidden for outbound output %', NEW.output_id
              USING ERRCODE = 'check_violation';
          END IF;
          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
      SQL
      run <<~SQL
        CREATE TRIGGER check_outbound_spendable
          BEFORE INSERT ON spendable
          FOR EACH ROW
          EXECUTE FUNCTION prevent_outbound_spendable();
      SQL
    else
      run <<~SQL
        CREATE TRIGGER check_outbound_spendable
          BEFORE INSERT ON spendable
          FOR EACH ROW
          WHEN (SELECT output_type FROM outputs WHERE id = NEW.output_id) = 'outbound'
        BEGIN
          SELECT RAISE(ABORT, 'spendable row forbidden for outbound output');
        END;
      SQL
    end

    # --- 8. output_details ---
    alter_table(:output_details) do
      set_column_not_null :action_id
    end

    # --- 9. output_baskets ---
    alter_table(:output_baskets) do
      set_column_not_null :action_id
    end

    # --- 10. inputs ---
    alter_table(:inputs) do
      add_constraint(:vin_range) { vin >= 0 }
      add_constraint(:nsequence_range, 'nsequence BETWEEN 0 AND 4294967295')
    end

    # --- 11. labels ---
    run 'DROP INDEX IF EXISTS labels_label_index'
    alter_table(:labels) do
      drop_column :deleted_at
      add_unique_constraint :label, name: :labels_label_unique
      add_constraint(:label_length, 'length(label) BETWEEN 1 AND 300')
    end

    # --- 12. action_labels ---
    alter_table(:action_labels) do
      drop_column :deleted_at
      drop_foreign_key [:action_id]
      add_foreign_key [:action_id], :actions, on_delete: :cascade
    end

    # --- 13. tags ---
    run 'DROP INDEX IF EXISTS tags_tag_index'
    alter_table(:tags) do
      drop_column :deleted_at
      add_unique_constraint :tag, name: :tags_tag_unique
      add_constraint(:tag_length, 'length(tag) BETWEEN 1 AND 300')
    end

    # --- 14. output_tags ---
    alter_table(:output_tags) do
      drop_column :deleted_at
    end

    # --- 15. certificates ---
    alter_table(:certificates) do
      drop_column :deleted_at
    end

    # --- 16. tx_reqs ---
    alter_table(:tx_reqs) do
      add_constraint(:wtxid_length) { length(wtxid) =~ 32 }
      add_constraint(:status_values, "status IN ('unmined', 'completed', 'failed')")
      add_constraint(:attempts_range) { attempts >= 0 }
    end
  end

  down do
    postgres = database_type == :postgres

    c = {}
    c[:timestamptz] = postgres ? :timestamptz : :datetime

    # --- 16. tx_reqs ---
    alter_table(:tx_reqs) do
      drop_constraint :wtxid_length
      drop_constraint :status_values
      drop_constraint :attempts_range
    end

    # --- 15. certificates ---
    alter_table(:certificates) do
      add_column :deleted_at, c[:timestamptz]
    end

    # --- 14. output_tags ---
    alter_table(:output_tags) do
      add_column :deleted_at, c[:timestamptz]
    end

    # --- 13. tags ---
    alter_table(:tags) do
      drop_constraint :tag_length
      drop_constraint :tags_tag_unique, type: :unique
      add_column :deleted_at, c[:timestamptz]
    end
    run 'CREATE UNIQUE INDEX tags_tag_index ON tags (tag) WHERE deleted_at IS NULL'

    # --- 12. action_labels ---
    alter_table(:action_labels) do
      drop_foreign_key [:action_id]
      add_foreign_key [:action_id], :actions
      add_column :deleted_at, c[:timestamptz]
    end

    # --- 11. labels ---
    alter_table(:labels) do
      drop_constraint :label_length
      drop_constraint :labels_label_unique, type: :unique
      add_column :deleted_at, c[:timestamptz]
    end
    run 'CREATE UNIQUE INDEX labels_label_index ON labels (label) WHERE deleted_at IS NULL'

    # --- 10. inputs ---
    alter_table(:inputs) do
      drop_constraint :vin_range
      drop_constraint :nsequence_range
    end

    # --- 9. output_baskets ---
    alter_table(:output_baskets) do
      set_column_allow_null :action_id
    end

    # --- 8. output_details ---
    alter_table(:output_details) do
      set_column_allow_null :action_id
    end

    # --- 7. spendable ---
    if postgres
      run 'DROP TRIGGER IF EXISTS check_outbound_spendable ON spendable'
      run 'DROP FUNCTION IF EXISTS prevent_outbound_spendable()'
    else
      run 'DROP TRIGGER IF EXISTS check_outbound_spendable'
    end
    alter_table(:spendable) do
      set_column_allow_null :action_id
    end

    # --- 6. outputs ---
    alter_table(:outputs) do
      drop_constraint :typed_no_prefix
      drop_constraint :typed_no_suffix
      drop_constraint :typed_no_sender
      drop_constraint :derived_needs_prefix
      drop_constraint :derived_needs_suffix
      drop_constraint :derived_needs_sender
      drop_constraint :satoshis_range
      drop_constraint :vout_range
      drop_constraint :locking_script_min
      drop_column :output_type
      set_column_allow_null :locking_script
    end

    # --- 5. baskets ---
    alter_table(:baskets) do
      drop_constraint :name_length
      drop_constraint :name_not_default
      drop_constraint :target_count_range
      drop_constraint :target_value_range
      drop_constraint :baskets_name_unique, type: :unique
      add_column :deleted_at, c[:timestamptz]
    end
    run 'CREATE UNIQUE INDEX baskets_name_index ON baskets (name) WHERE deleted_at IS NULL'

    # --- 4. broadcasts ---
    alter_table(:broadcasts) do
      drop_constraint :block_hash_length
      drop_constraint :block_height_range
    end

    # --- 3. actions ---
    if postgres
      run 'ALTER TABLE actions ALTER COLUMN reference TYPE text USING reference::text'
      run 'ALTER TABLE actions ALTER COLUMN reference DROP NOT NULL'
    else
      alter_table(:actions) do
        set_column_allow_null :reference
      end
    end
    alter_table(:actions) do
      drop_constraint :wtxid_length
      drop_constraint :description_length
      drop_constraint :nlocktime_range
      drop_constraint :wtxid_raw_tx_parity
      drop_constraint :broadcast_intent_values if !postgres
      set_column_allow_null :description
      add_column :satoshis, :bigint
    end

    # --- 2. tx_proofs ---
    alter_table(:tx_proofs) do
      drop_constraint :wtxid_length
      drop_constraint :raw_tx_min_length
      drop_constraint :path_requires_block
      set_column_allow_null :raw_tx
    end

    # --- 1. blocks ---
    alter_table(:blocks) do
      drop_constraint :height_range
      drop_constraint :merkle_root_length
      drop_constraint :block_hash_length
    end

    drop_enum(:output_type) if postgres
  end
end
