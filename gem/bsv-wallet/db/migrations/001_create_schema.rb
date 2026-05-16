# frozen_string_literal: true

# Default wallet schema — derived from reference/schema.md.
# All tables, constraints, indexes, and triggers in a single migration.

Sequel.migration do
  up do
    # 1. blocks — known block headers (chain tracker's local view)
    create_table(:blocks) do
      primary_key :id
      column :height, :integer, null: false, unique: true
      column :merkle_root, :blob, null: false
      column :block_hash, :blob
      column :created_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :updated_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP

      constraint(:height_range) { height >= 0 }
      constraint(:merkle_root_length) { length(merkle_root) =~ 32 }
      constraint(:block_hash_length, 'block_hash IS NULL OR length(block_hash) = 32')
    end

    # 2. tx_proofs — merkle inclusion proofs (settlement evidence)
    create_table(:tx_proofs) do
      primary_key :id
      column :wtxid, :blob, null: false, unique: true
      foreign_key :block_id, :blocks
      column :block_index, :integer
      column :merkle_path, :blob
      column :raw_tx, :blob, null: false
      column :created_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :updated_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP

      constraint(:wtxid_length) { length(wtxid) =~ 32 }
      constraint(:raw_tx_min_length) { length(raw_tx) >= 20 }
    end

    # 3. actions — transaction lifecycle
    create_table(:actions) do
      primary_key :id
      foreign_key :tx_proof_id, :tx_proofs
      column :wtxid, :blob, unique: true
      column :reference, :text, null: false, unique: true
      column :outgoing, :boolean, null: false, default: true
      column :description, :text, null: false
      column :version, :integer
      column :nlocktime, :integer
      column :broadcast, :text, null: false, default: 'delayed'
      column :raw_tx, :blob
      column :input_beef, :blob
      column :created_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :updated_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP

      index :broadcast

      constraint(:wtxid_length, 'wtxid IS NULL OR length(wtxid) = 32')
      constraint(:description_length, 'length(description) BETWEEN 5 AND 50')
      constraint(:nlocktime_range, 'NOT outgoing OR (nlocktime IS NOT NULL AND nlocktime >= 0)')
      constraint(:wtxid_raw_tx_parity, '(wtxid IS NULL) = (raw_tx IS NULL)')
      constraint(:broadcast_values, "broadcast IN ('delayed', 'inline', 'none')")
    end

    # 4. broadcasts — ARC lifecycle
    create_table(:broadcasts) do
      primary_key :id
      foreign_key :action_id, :actions, null: false, unique: true
      column :broadcast_at, :datetime
      column :tx_status, :text
      column :arc_status, :integer
      column :block_hash, :blob
      column :block_height, :integer
      column :merkle_path, :blob
      column :extra_info, :text
      column :competing_txs, :text
      column :created_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :updated_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP

      constraint(:block_hash_length, 'block_hash IS NULL OR length(block_hash) = 32')
      constraint(:block_height_range, 'block_height IS NULL OR block_height >= 0')
    end

    # 5. baskets — output grouping with replenishment policy
    create_table(:baskets) do
      primary_key :id
      column :name, :text, null: false, unique: true
      column :target_count, :integer
      column :target_value, :integer
      column :created_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :updated_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP

      constraint(:name_length, 'length(name) BETWEEN 1 AND 300')
      constraint(:name_not_default, "name != 'default'")
      constraint(:target_count_range, 'target_count IS NULL OR target_count >= 0')
      constraint(:target_value_range, 'target_value IS NULL OR target_value >= 0')
    end

    # 6. outputs — immutable append-only log
    create_table(:outputs) do
      primary_key :id
      foreign_key :action_id, :actions, on_delete: :set_null
      column :satoshis, :integer, null: false
      column :created_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :locking_script, :blob, null: false
      column :vout, :integer, null: false
      column :output_type, :text
      column :derivation_prefix, :text
      column :derivation_suffix, :text
      column :sender_identity_key, :text

      unique %i[action_id vout]

      constraint(:satoshis_range) { satoshis >= 0 }
      constraint(:vout_range) { vout >= 0 }
      constraint(:locking_script_min) { length(locking_script) >= 1 }
      constraint(:output_type_values, "output_type IS NULL OR output_type IN ('root', 'outbound')")
      constraint(:typed_no_prefix, 'output_type IS NULL OR derivation_prefix IS NULL')
      constraint(:typed_no_suffix, 'output_type IS NULL OR derivation_suffix IS NULL')
      constraint(:typed_no_sender, 'output_type IS NULL OR sender_identity_key IS NULL')
      constraint(:derived_needs_prefix, 'output_type IS NOT NULL OR derivation_prefix IS NOT NULL')
      constraint(:derived_needs_suffix, 'output_type IS NOT NULL OR derivation_suffix IS NOT NULL')
      constraint(:derived_needs_sender, 'output_type IS NOT NULL OR sender_identity_key IS NOT NULL')
    end

    # 7. spendable — the UTXO set (pure set membership)
    create_table(:spendable) do
      primary_key :id
      foreign_key :output_id, :outputs, null: false, unique: true
      foreign_key :action_id, :actions, null: false, on_delete: :cascade
    end

    # Trigger: outbound outputs must never have a spendable row
    run <<~SQL
      CREATE TRIGGER check_outbound_spendable
        BEFORE INSERT ON spendable
        FOR EACH ROW
        WHEN (SELECT output_type FROM outputs WHERE id = NEW.output_id) = 'outbound'
      BEGIN
        SELECT RAISE(ABORT, 'spendable row forbidden for outbound output');
      END;
    SQL

    # 8. output_details — display and application metadata
    create_table(:output_details) do
      primary_key :id
      foreign_key :output_id, :outputs, null: false, unique: true
      foreign_key :action_id, :actions, null: false, on_delete: :cascade
      column :change, :boolean, null: false, default: false
      column :type, :text
      column :purpose, :text
      column :provided_by, :text
      column :description, :text
      column :custom_instructions, :text
      column :script_length, :integer
      column :script_offset, :integer
    end

    # 9. output_baskets — basket membership
    create_table(:output_baskets) do
      primary_key :id
      foreign_key :output_id, :outputs, null: false, unique: true
      foreign_key :action_id, :actions, null: false, on_delete: :cascade
      foreign_key :basket_id, :baskets, null: false
      column :created_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :updated_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP

      index :basket_id
    end

    # 10. inputs — structural lock mechanism
    create_table(:inputs) do
      primary_key :id
      foreign_key :action_id, :actions, null: false, on_delete: :cascade
      foreign_key :output_id, :outputs, null: false
      column :vin, :integer, null: false
      column :nsequence, :integer, null: false, default: 4_294_967_295
      column :description, :text
      column :created_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :updated_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP

      unique :output_id
      unique %i[action_id vin]

      constraint(:vin_range) { vin >= 0 }
      constraint(:nsequence_range, 'nsequence BETWEEN 0 AND 4294967295')
    end

    # 11. labels — label definitions
    create_table(:labels) do
      primary_key :id
      column :label, :text, null: false, unique: true
      column :created_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :updated_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP

      constraint(:label_length, 'length(label) BETWEEN 1 AND 300')
    end

    # 12. action_labels — join table
    create_table(:action_labels) do
      primary_key :id
      foreign_key :action_id, :actions, null: false, on_delete: :cascade
      foreign_key :label_id, :labels, null: false
      column :created_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :updated_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP

      unique %i[action_id label_id]
      index :label_id
    end

    # 13. tags — tag definitions
    create_table(:tags) do
      primary_key :id
      column :tag, :text, null: false, unique: true
      column :created_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :updated_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP

      constraint(:tag_length, 'length(tag) BETWEEN 1 AND 300')
    end

    # 14. output_tags — join table
    create_table(:output_tags) do
      primary_key :id
      foreign_key :output_id, :outputs, null: false
      foreign_key :tag_id, :tags, null: false
      column :created_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :updated_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP

      unique %i[output_id tag_id]
      index :tag_id
    end

    # 15. certificates — identity certificates (BRC-52)
    create_table(:certificates) do
      primary_key :id
      column :type, :text, null: false
      column :subject, :text
      column :serial_number, :text, null: false
      column :certifier, :text, null: false
      column :verifier, :text
      column :revocation_outpoint, :text
      column :signature, :text
      column :created_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :updated_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP

      unique %i[type serial_number certifier]
      index :certifier
      index :subject
    end

    # 16. certificate_fields — per-field encryption for selective revelation
    create_table(:certificate_fields) do
      primary_key :id
      foreign_key :certificate_id, :certificates, null: false, on_delete: :cascade
      column :name, :text, null: false
      column :value, :text
      column :master_key, :text
      column :created_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :updated_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP

      unique %i[certificate_id name]
    end

    # 17. settings — key-value wallet configuration
    create_table(:settings) do
      primary_key :id
      column :key, :text, null: false, unique: true
      column :value, :text
      column :created_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :updated_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP
    end
  end

  down do
    drop_table :settings, :certificate_fields, :certificates,
               :output_tags, :tags, :action_labels, :labels, :inputs,
               :output_baskets, :output_details, :spendable, :outputs,
               :baskets, :broadcasts, :actions, :tx_proofs, :blocks
  end
end
