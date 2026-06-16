# frozen_string_literal: true

# CHECK constraints, NOT NULL settings, and the two BEFORE-row triggers that
# express invariants the structural schema (001/002) cannot.
#
# Kept distinct from 001 partly because Postgres CHECKs and the SQLite text
# equivalents diverge enough that grouping them with table creation would
# clutter 001, and partly because the SQLite emulation rebuilds the table on
# every alter — keeping the alter_table operations grouped by table here
# minimises rebuild churn relative to mixing them into create_table.

Sequel.migration do
  up do
    postgres = database_type == :postgres

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
      set_column_not_null :description
      add_constraint(:wtxid_length, 'wtxid IS NULL OR length(wtxid) = 32')
      add_constraint(:description_length, 'length(description) BETWEEN 5 AND 50')
      add_constraint(:wtxid_raw_tx_parity, '(wtxid IS NULL) = (raw_tx IS NULL)')
      add_constraint(:broadcast_intent_values, "broadcast_intent IN ('delayed', 'inline', 'none')") if !postgres
    end

    if postgres
      run 'ALTER TABLE actions ALTER COLUMN reference SET NOT NULL'
    else
      alter_table(:actions) do
        set_column_not_null :reference
      end
    end

    # --- 4. broadcasts ---
    alter_table(:broadcasts) do
      add_constraint(:block_hash_length, 'block_hash IS NULL OR length(block_hash) = 32')
      add_constraint(:block_height_range, 'block_height IS NULL OR block_height >= 0')
      # Postgres uses the tx_status ENUM; SQLite gets an equivalent CHECK
      # to keep parity. List mirrors arc_tx_statuses in 001 (ARC's metamorph
      # Status enum plus IMMUTABLE, #198/#220).
      if !postgres
        add_constraint(
          :tx_status_values,
          "tx_status IS NULL OR tx_status IN ('UNKNOWN', 'QUEUED', 'RECEIVED', 'STORED', " \
          "'ANNOUNCED_TO_NETWORK', 'REQUESTED_BY_NETWORK', 'SENT_TO_NETWORK', " \
          "'ACCEPTED_BY_NETWORK', 'SEEN_IN_ORPHAN_MEMPOOL', 'SEEN_ON_NETWORK', " \
          "'SEEN_MULTIPLE_NODES', 'DOUBLE_SPEND_ATTEMPTED', 'REJECTED', " \
          "'MINED_IN_STALE_BLOCK', 'MINED', 'IMMUTABLE')"
        )
      end
    end

    # --- 5. baskets ---
    alter_table(:baskets) do
      add_constraint(:name_length, 'length(name) BETWEEN 1 AND 300')
      add_constraint(:name_not_default, "name != 'default'")
      add_constraint(:target_count_range, 'target_count IS NULL OR target_count >= 0')
      add_constraint(:target_value_range, 'target_value IS NULL OR target_value >= 0')
    end

    # --- 6. outputs ---
    alter_table(:outputs) do
      set_column_not_null :locking_script
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

    # Database-level guard protecting canonical received UTXO history from
    # deletion — defense-in-depth mirroring Store#reject_action's
    # CannotRejectInternalActionError. An internal-path action (broadcast_intent
    # = 'none') with a promotions row owns canonical received UTXO history and
    # must not be deleted. A CHECK cannot express this — CHECKs fire on
    # INSERT/UPDATE, never DELETE — so a BEFORE DELETE trigger is the only
    # mechanism. check_violation ERRCODE → Sequel::CheckConstraintViolation.
    if postgres
      run <<~SQL
        CREATE FUNCTION prevent_internal_action_delete() RETURNS trigger AS $$
        BEGIN
          IF OLD.broadcast_intent = 'none'
             AND EXISTS (SELECT 1 FROM promotions WHERE action_id = OLD.id) THEN
            RAISE EXCEPTION 'cannot delete internal action % (broadcast_intent=none with a promotions row)', OLD.id
              USING ERRCODE = 'check_violation';
          END IF;
          RETURN OLD;
        END;
        $$ LANGUAGE plpgsql;
      SQL
      run <<~SQL
        CREATE TRIGGER check_internal_action_delete
          BEFORE DELETE ON actions
          FOR EACH ROW
          EXECUTE FUNCTION prevent_internal_action_delete();
      SQL
    else
      run <<~SQL
        CREATE TRIGGER check_internal_action_delete
          BEFORE DELETE ON actions
          FOR EACH ROW
          WHEN OLD.broadcast_intent = 'none'
        BEGIN
          SELECT RAISE(ABORT, 'cannot delete internal action (broadcast_intent=none with a promotions row)')
          WHERE EXISTS (SELECT 1 FROM promotions WHERE action_id = OLD.id);
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
    alter_table(:labels) do
      add_constraint(:label_length, 'length(label) BETWEEN 1 AND 300')
    end

    # --- 13. tags ---
    alter_table(:tags) do
      add_constraint(:tag_length, 'length(tag) BETWEEN 1 AND 300')
    end
  end

  down do
    postgres = database_type == :postgres

    # --- 13. tags ---
    alter_table(:tags) do
      drop_constraint :tag_length
    end

    # --- 11. labels ---
    alter_table(:labels) do
      drop_constraint :label_length
    end

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

    # --- internal-action-delete trigger ---
    if postgres
      run 'DROP TRIGGER IF EXISTS check_internal_action_delete ON actions'
      run 'DROP FUNCTION IF EXISTS prevent_internal_action_delete()'
    else
      run 'DROP TRIGGER IF EXISTS check_internal_action_delete'
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
      set_column_allow_null :locking_script
    end

    # --- 5. baskets ---
    alter_table(:baskets) do
      drop_constraint :name_length
      drop_constraint :name_not_default
      drop_constraint :target_count_range
      drop_constraint :target_value_range
    end

    # --- 4. broadcasts ---
    alter_table(:broadcasts) do
      drop_constraint :block_hash_length
      drop_constraint :block_height_range
      drop_constraint :tx_status_values if !postgres
    end

    # --- 3. actions ---
    if postgres
      run 'ALTER TABLE actions ALTER COLUMN reference DROP NOT NULL'
    else
      alter_table(:actions) do
        set_column_allow_null :reference
      end
    end
    alter_table(:actions) do
      drop_constraint :wtxid_length
      drop_constraint :description_length
      drop_constraint :wtxid_raw_tx_parity
      drop_constraint :broadcast_intent_values if !postgres
      set_column_allow_null :description
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
  end
end
