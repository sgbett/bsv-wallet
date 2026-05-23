# frozen_string_literal: true

# Unified wallet schema — works on both SQLite and Postgres.
# Derived from reference/schema.md.
#
# Backend-specific differences:
#   - Primary keys: SQLite uses autoincrement integer; Postgres uses BIGINT IDENTITY
#   - Enums: Postgres uses pg_enum; SQLite uses CHECK constraints
#   - Triggers: Syntax differs but enforces the same invariant
#   - competing_txs: Postgres uses text[]; SQLite uses text (JSON)
#   - reference default: Postgres uses gen_random_uuid(); SQLite uses Ruby before_create

Sequel.migration do
  up do
    postgres = database_type == :postgres

    # Helper: backend-appropriate primary key
    pk = lambda { |t|
      if postgres
        t.column :id, :bigint, primary_key: true, identity: :always
      else
        t.primary_key :id
      end
    }

    # Helper: typed foreign key (bigint on Postgres, default on SQLite)
    fk_opts = ->(opts) { postgres ? opts.merge(type: :bigint) : opts }

    if postgres
      extension :pg_enum
      create_enum(:broadcast_intent, %w[delayed inline none])
      create_enum(:output_type, %w[root outbound])
    end

    # 1. blocks — known block headers (chain tracker's local view)
    create_table(:blocks) do
      pk.call(self)
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
      pk.call(self)
      column :wtxid, :blob, null: false, unique: true
      foreign_key :block_id, :blocks, **fk_opts.call({})
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
      pk.call(self)
      foreign_key :tx_proof_id, :tx_proofs, **fk_opts.call({})
      column :wtxid, :blob, unique: true
      if postgres
        column :reference, :uuid, null: false, unique: true, default: Sequel.function(:gen_random_uuid)
      else
        column :reference, :text, null: false, unique: true
      end
      column :outgoing, :boolean, null: false, default: true
      column :description, :text, null: false
      column :version, :integer
      column :nlocktime, :integer
      if postgres
        column :broadcast, :broadcast_intent, null: false, default: 'delayed'
      else
        column :broadcast, :text, null: false, default: 'delayed'
      end
      column :raw_tx, :blob
      column :input_beef, :blob
      column :created_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :updated_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP

      index :broadcast

      constraint(:wtxid_length, 'wtxid IS NULL OR length(wtxid) = 32')
      constraint(:description_length, 'length(description) BETWEEN 5 AND 50')
      constraint(:nlocktime_range, 'NOT outgoing OR (nlocktime IS NOT NULL AND nlocktime >= 0)')
      constraint(:wtxid_raw_tx_parity, '(wtxid IS NULL) = (raw_tx IS NULL)')
      # SQLite needs a CHECK constraint for broadcast values; Postgres uses the enum
      constraint(:broadcast_values, "broadcast IN ('delayed', 'inline', 'none')") unless postgres
    end

    # 4. broadcasts — ARC lifecycle
    create_table(:broadcasts) do
      pk.call(self)
      foreign_key :action_id, :actions, **fk_opts.call(null: false, unique: true)
      column :broadcast_at, :datetime
      column :tx_status, :text
      column :arc_status, :integer
      column :block_hash, :blob
      column :block_height, :integer
      column :merkle_path, :blob
      column :extra_info, :text
      column :competing_txs, postgres ? 'text[]' : :text
      column :created_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :updated_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP

      constraint(:block_hash_length, 'block_hash IS NULL OR length(block_hash) = 32')
      constraint(:block_height_range, 'block_height IS NULL OR block_height >= 0')
    end

    # 5. baskets — output grouping with replenishment policy
    create_table(:baskets) do
      pk.call(self)
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
      pk.call(self)
      foreign_key :action_id, :actions, **fk_opts.call(on_delete: :set_null)
      column :satoshis, :integer, null: false
      column :created_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :locking_script, :blob, null: false
      column :vout, :integer, null: false
      if postgres
        column :output_type, :output_type
      else
        column :output_type, :text
      end
      column :derivation_prefix, :text
      column :derivation_suffix, :text
      column :sender_identity_key, :text

      unique %i[action_id vout]

      constraint(:satoshis_range) { satoshis >= 0 }
      constraint(:vout_range) { vout >= 0 }
      constraint(:locking_script_min) { length(locking_script) >= 1 }
      constraint(:typed_no_prefix, 'output_type IS NULL OR derivation_prefix IS NULL')
      constraint(:typed_no_suffix, 'output_type IS NULL OR derivation_suffix IS NULL')
      constraint(:typed_no_sender, 'output_type IS NULL OR sender_identity_key IS NULL')
      constraint(:derived_needs_prefix, 'output_type IS NOT NULL OR derivation_prefix IS NOT NULL')
      constraint(:derived_needs_suffix, 'output_type IS NOT NULL OR derivation_suffix IS NOT NULL')
      constraint(:derived_needs_sender, 'output_type IS NOT NULL OR sender_identity_key IS NOT NULL')
      # SQLite needs a CHECK for output_type values; Postgres uses the enum
      constraint(:output_type_values, "output_type IS NULL OR output_type IN ('root', 'outbound')") unless postgres
    end

    # 7. spendable — the UTXO set (pure set membership)
    create_table(:spendable) do
      pk.call(self)
      foreign_key :output_id, :outputs, **fk_opts.call(null: false, unique: true)
      foreign_key :action_id, :actions, **fk_opts.call(null: false, on_delete: :cascade)
    end

    # Trigger: outbound outputs must never have a spendable row
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

    # 8. output_details — display and application metadata
    create_table(:output_details) do
      pk.call(self)
      foreign_key :output_id, :outputs, **fk_opts.call(null: false, unique: true)
      foreign_key :action_id, :actions, **fk_opts.call(null: false, on_delete: :cascade)
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
      pk.call(self)
      foreign_key :output_id, :outputs, **fk_opts.call(null: false, unique: true)
      foreign_key :action_id, :actions, **fk_opts.call(null: false, on_delete: :cascade)
      foreign_key :basket_id, :baskets, **fk_opts.call(null: false)
      column :created_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :updated_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP

      index :basket_id
    end

    # 10. inputs — structural lock mechanism
    create_table(:inputs) do
      pk.call(self)
      foreign_key :action_id, :actions, **fk_opts.call(null: false, on_delete: :cascade)
      foreign_key :output_id, :outputs, **fk_opts.call(null: false)
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
      pk.call(self)
      column :label, :text, null: false, unique: true
      column :created_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :updated_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP

      constraint(:label_length, 'length(label) BETWEEN 1 AND 300')
    end

    # 12. action_labels — join table
    create_table(:action_labels) do
      pk.call(self)
      foreign_key :action_id, :actions, **fk_opts.call(null: false, on_delete: :cascade)
      foreign_key :label_id, :labels, **fk_opts.call(null: false)
      column :created_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :updated_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP

      unique %i[action_id label_id]
      index :label_id
    end

    # 13. tags — tag definitions
    create_table(:tags) do
      pk.call(self)
      column :tag, :text, null: false, unique: true
      column :created_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :updated_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP

      constraint(:tag_length, 'length(tag) BETWEEN 1 AND 300')
    end

    # 14. output_tags — join table
    create_table(:output_tags) do
      pk.call(self)
      foreign_key :output_id, :outputs, **fk_opts.call(null: false)
      foreign_key :tag_id, :tags, **fk_opts.call(null: false)
      column :created_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :updated_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP

      unique %i[output_id tag_id]
      index :tag_id
    end

    # 15. certificates — identity certificates (BRC-52)
    create_table(:certificates) do
      pk.call(self)
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
      pk.call(self)
      foreign_key :certificate_id, :certificates, **fk_opts.call(null: false, on_delete: :cascade)
      column :name, :text, null: false
      column :value, :text
      column :master_key, :text
      column :created_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :updated_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP

      unique %i[certificate_id name]
    end

    # 17. settings — key-value wallet configuration
    create_table(:settings) do
      pk.call(self)
      column :key, :text, null: false, unique: true
      column :value, :text
      column :created_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP
      column :updated_at, :datetime, null: false, default: Sequel::CURRENT_TIMESTAMP
    end
  end

  down do
    postgres = database_type == :postgres

    if postgres
      run 'DROP TRIGGER IF EXISTS check_outbound_spendable ON spendable'
      run 'DROP FUNCTION IF EXISTS prevent_outbound_spendable()'
    end

    drop_table :settings, :certificate_fields, :certificates,
               :output_tags, :tags, :action_labels, :labels, :inputs,
               :output_baskets, :output_details, :spendable, :outputs,
               :baskets, :broadcasts, :actions, :tx_proofs, :blocks

    if postgres
      extension :pg_enum
      drop_enum(:output_type)
      drop_enum(:broadcast_intent)
    end
  end
end
