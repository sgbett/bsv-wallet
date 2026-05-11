# frozen_string_literal: true

Sequel.migration do
  up do
    extension :pg_enum

    # --- New enum ---
    # Ternary: root (identity key, no derivation), outbound (payment to
    # others, no derivation), NULL (derived, has keys).
    create_enum(:output_type, %w[root outbound])

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
    end

    # --- 2. actions ---
    alter_table(:actions) do
      drop_column :satoshis
      set_column_not_null :description
      add_constraint(:wtxid_length, 'wtxid IS NULL OR length(wtxid) = 32')
      add_constraint(:description_length, 'length(description) BETWEEN 5 AND 50')
      add_constraint(:nlocktime_range)    { nlocktime >= 0 }
      add_constraint(:wtxid_raw_tx_parity, '(wtxid IS NULL) = (raw_tx IS NULL)')
    end

    # Convert reference from text to uuid
    run 'ALTER TABLE actions ALTER COLUMN reference SET NOT NULL'
    run 'ALTER TABLE actions ALTER COLUMN reference TYPE uuid USING reference::uuid'
    run "ALTER TABLE actions ALTER COLUMN reference SET DEFAULT gen_random_uuid()"

    # --- 3. broadcasts ---
    alter_table(:broadcasts) do
      add_constraint(:block_hash_length, 'block_hash IS NULL OR length(block_hash) = 32')
      add_constraint(:block_height_range, 'block_height IS NULL OR block_height >= 0')
    end

    # --- 4. baskets ---
    alter_table(:baskets) do
      drop_column :deleted_at
      add_constraint(:name_length, 'length(name) BETWEEN 1 AND 300')
      add_constraint(:name_not_default, "name != 'default'")
      add_constraint(:target_count_range, 'target_count IS NULL OR target_count >= 0')
      add_constraint(:target_value_range, 'target_value IS NULL OR target_value >= 0')
    end
    # Replace partial unique with plain unique
    run 'DROP INDEX IF EXISTS baskets_name_index'
    alter_table(:baskets) do
      add_unique_constraint :name, name: :baskets_name_unique
    end

    # --- 5. outputs ---
    # The immutable log. Derivation data lives here — it's a fact about the
    # output, recorded when the key is derived. Spendable is pure membership.
    alter_table(:outputs) do
      set_column_not_null :locking_script
      add_column :output_type, :output_type
      add_constraint(:satoshis_range)          { satoshis >= 0 }
      add_constraint(:vout_range)              { vout >= 0 }
      add_constraint(:locking_script_min)      { length(locking_script) >= 1 }
      # Typed outputs (root, outbound) use identity key or belong to
      # others — no derivation fields allowed
      add_constraint(:typed_no_prefix,   'output_type IS NULL OR derivation_prefix IS NULL')
      add_constraint(:typed_no_suffix,   'output_type IS NULL OR derivation_suffix IS NULL')
      add_constraint(:typed_no_sender,   'output_type IS NULL OR sender_identity_key IS NULL')
      # Derived outputs (NULL type) must have all derivation fields
      add_constraint(:derived_needs_prefix, 'output_type IS NOT NULL OR derivation_prefix IS NOT NULL')
      add_constraint(:derived_needs_suffix, 'output_type IS NOT NULL OR derivation_suffix IS NOT NULL')
      add_constraint(:derived_needs_sender, 'output_type IS NOT NULL OR sender_identity_key IS NOT NULL')
    end

    # --- 6. spendable ---
    # Pure set membership — a row's existence IS the wallet.
    alter_table(:spendable) do
      set_column_not_null :action_id
    end

    # Outbound outputs are payments to others — they must never have a
    # spendable row. Cross-table CHECK constraints aren't possible in
    # PostgreSQL, so a trigger enforces this invariant.
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

    # --- 7. output_details ---
    # change column stays — cosmetic flag for display, not structural
    alter_table(:output_details) do
      set_column_not_null :action_id
    end

    # --- 8. output_baskets ---
    alter_table(:output_baskets) do
      set_column_not_null :action_id
    end

    # --- 9. inputs ---
    alter_table(:inputs) do
      add_constraint(:vin_range)      { vin >= 0 }
      add_constraint(:nsequence_range, 'nsequence BETWEEN 0 AND 4294967295')
    end

    # --- 10. labels ---
    alter_table(:labels) do
      drop_column :deleted_at
      add_constraint(:label_length, 'length(label) BETWEEN 1 AND 300')
    end
    run 'DROP INDEX IF EXISTS labels_label_index'
    alter_table(:labels) do
      add_unique_constraint :label, name: :labels_label_unique
    end

    # --- 11. action_labels ---
    alter_table(:action_labels) do
      drop_column :deleted_at
      # Replace FK without cascade with cascading FK
      drop_foreign_key [:action_id]
      add_foreign_key [:action_id], :actions, on_delete: :cascade
    end

    # --- 12. tags ---
    alter_table(:tags) do
      drop_column :deleted_at
      add_constraint(:tag_length, 'length(tag) BETWEEN 1 AND 300')
    end
    run 'DROP INDEX IF EXISTS tags_tag_index'
    alter_table(:tags) do
      add_unique_constraint :tag, name: :tags_tag_unique
    end

    # --- 13. output_tags ---
    alter_table(:output_tags) do
      drop_column :deleted_at
    end

    # --- 14. certificates ---
    alter_table(:certificates) do
      drop_column :deleted_at
    end

    # --- 15. tx_reqs ---
    alter_table(:tx_reqs) do
      add_constraint(:wtxid_length) { length(wtxid) =~ 32 }
      add_constraint(:status_values, "status IN ('unmined', 'completed', 'failed')")
      add_constraint(:attempts_range) { attempts >= 0 }
    end
  end

  down do
    extension :pg_enum

    # --- 15. tx_reqs ---
    alter_table(:tx_reqs) do
      drop_constraint :wtxid_length
      drop_constraint :status_values
      drop_constraint :attempts_range
    end

    # --- 14. certificates ---
    alter_table(:certificates) do
      add_column :deleted_at, :timestamptz
    end

    # --- 13. output_tags ---
    alter_table(:output_tags) do
      add_column :deleted_at, :timestamptz
    end

    # --- 12. tags ---
    alter_table(:tags) do
      drop_constraint :tag_length
      drop_constraint :tags_tag_unique, type: :unique
      add_column :deleted_at, :timestamptz
    end
    run "CREATE UNIQUE INDEX tags_tag_index ON tags (tag) WHERE deleted_at IS NULL"

    # --- 11. action_labels ---
    alter_table(:action_labels) do
      drop_foreign_key [:action_id]
      add_foreign_key [:action_id], :actions
      add_column :deleted_at, :timestamptz
    end

    # --- 10. labels ---
    alter_table(:labels) do
      drop_constraint :label_length
      drop_constraint :labels_label_unique, type: :unique
      add_column :deleted_at, :timestamptz
    end
    run "CREATE UNIQUE INDEX labels_label_index ON labels (label) WHERE deleted_at IS NULL"

    # --- 9. inputs ---
    alter_table(:inputs) do
      drop_constraint :vin_range
      drop_constraint :nsequence_range
    end

    # --- 8. output_baskets ---
    alter_table(:output_baskets) do
      set_column_allow_null :action_id
    end

    # --- 7. output_details ---
    alter_table(:output_details) do
      set_column_allow_null :action_id
    end

    # --- 6. spendable ---
    run 'DROP TRIGGER IF EXISTS check_outbound_spendable ON spendable'
    run 'DROP FUNCTION IF EXISTS prevent_outbound_spendable()'
    alter_table(:spendable) do
      set_column_allow_null :action_id
    end

    # --- 5. outputs ---
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

    # --- 4. baskets ---
    alter_table(:baskets) do
      drop_constraint :name_length
      drop_constraint :name_not_default
      drop_constraint :target_count_range
      drop_constraint :target_value_range
      drop_constraint :baskets_name_unique, type: :unique
      add_column :deleted_at, :timestamptz
    end
    run "CREATE UNIQUE INDEX baskets_name_index ON baskets (name) WHERE deleted_at IS NULL"

    # --- 3. broadcasts ---
    alter_table(:broadcasts) do
      drop_constraint :block_hash_length
      drop_constraint :block_height_range
    end

    # --- 2. actions ---
    run "ALTER TABLE actions ALTER COLUMN reference TYPE text USING reference::text"
    run "ALTER TABLE actions ALTER COLUMN reference DROP NOT NULL"
    alter_table(:actions) do
      drop_constraint :wtxid_length
      drop_constraint :description_length
      drop_constraint :nlocktime_range
      drop_constraint :wtxid_raw_tx_parity
      set_column_allow_null :description
      add_column :satoshis, :bigint
    end

    # --- 2. tx_proofs ---
    alter_table(:tx_proofs) do
      drop_constraint :wtxid_length
      drop_constraint :raw_tx_min_length
      set_column_allow_null :raw_tx
    end

    # --- 1. blocks ---
    alter_table(:blocks) do
      drop_constraint :height_range
      drop_constraint :merkle_root_length
      drop_constraint :block_hash_length
    end

    drop_enum(:output_type)
  end
end
