# frozen_string_literal: true

# Original Postgres schema with SQLite compatibility guards.
#
# Guard convention:
#   postgres = database_type == :postgres
#   c[:type]  — column type map (Postgres-native, SQLite equivalent)
#   Two-line PK: Postgres BIGINT IDENTITY, SQLite autoincrement

Sequel.migration do
  up do
    postgres = database_type == :postgres

    c = {}
    c[:bytea] = postgres ? :bytea : :blob
    c[:timestamptz] = postgres ? :timestamptz : :datetime
    c[:broadcast_intent] = postgres ? :broadcast_intent : :text
    c[:now] = postgres ? Sequel.function(:now) : Sequel::CURRENT_TIMESTAMP

    if postgres
      extension :pg_enum
      create_enum(:broadcast_intent, %w[delayed inline none])
    end

    # 1. blocks — known block headers (chain tracker's local view)
    create_table(:blocks) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      column :height, :integer, null: false, unique: true
      column :merkle_root, c[:bytea], null: false
      column :block_hash, c[:bytea]
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]
    end

    # 2. tx_proofs — merkle inclusion proofs (settlement evidence)
    create_table(:tx_proofs) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      column :wtxid, c[:bytea], null: false, unique: true
      foreign_key :block_id, :blocks, type: :bigint
      column :block_index, :integer
      column :merkle_path, c[:bytea]
      column :raw_tx, c[:bytea]
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]
    end

    # 3. actions — transaction lifecycle
    create_table(:actions) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      foreign_key :tx_proof_id, :tx_proofs, type: :bigint
      column :wtxid, c[:bytea]
      if postgres
        column :reference, :text, unique: true, default: Sequel.function(:gen_random_uuid)
      else
        column :reference, :text, unique: true
      end
      column :outgoing, :boolean, null: false, default: true
      column :satoshis, :bigint
      column :description, :text
      column :version, :integer
      column :nlocktime, :bigint
      column :broadcast_intent, c[:broadcast_intent], null: false, default: 'delayed'
      column :raw_tx, c[:bytea]
      column :input_beef, c[:bytea]
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]

      index :wtxid, unique: true, where: Sequel.lit('wtxid IS NOT NULL')
      index :broadcast_intent

      # Composite FK target: broadcasts(action_id, intent) → actions(id, broadcast_intent)
      # makes broadcasts.intent track actions.broadcast_intent atomically (#221).
      unique %i[id broadcast_intent]
    end

    # 4. broadcasts — ARC lifecycle
    create_table(:broadcasts) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      foreign_key :action_id, :actions, type: :bigint, null: false, unique: true
      column :broadcast_at, c[:timestamptz]
      column :tx_status, :text
      column :arc_status, :integer
      column :block_hash, c[:bytea]
      column :block_height, :integer
      column :merkle_path, c[:bytea]
      column :extra_info, :text
      column :competing_txs, postgres ? 'text[]' : :text
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]
    end

    # 5. baskets — output grouping with replenishment policy
    create_table(:baskets) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      column :name, :text, null: false
      column :target_count, :integer
      column :target_value, :integer
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]
      column :deleted_at, c[:timestamptz]

      index :name, unique: true, where: Sequel.lit('deleted_at IS NULL')
    end

    # 6. outputs — immutable append-only log
    create_table(:outputs) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      foreign_key :action_id, :actions, type: :bigint, null: false
      column :satoshis, :bigint, null: false
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :locking_script, c[:bytea]
      column :vout, :integer, null: false
      column :sender_identity_key, :text
      column :derivation_prefix, :text
      column :derivation_suffix, :text

      unique %i[action_id vout]
    end

    # 7. spendable — the UTXO set
    create_table(:spendable) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      foreign_key :output_id, :outputs, type: :bigint, null: false, unique: true
    end

    # 8. output_details — display and application metadata
    create_table(:output_details) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      foreign_key :output_id, :outputs, type: :bigint, null: false, unique: true
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
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      foreign_key :output_id, :outputs, type: :bigint, null: false, unique: true
      foreign_key :basket_id, :baskets, type: :bigint, null: false
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]

      index :basket_id
    end

    # 10. inputs — structural lock mechanism
    create_table(:inputs) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      foreign_key :action_id, :actions, type: :bigint, null: false, on_delete: :cascade
      foreign_key :output_id, :outputs, type: :bigint, null: false
      column :vin, :integer, null: false
      column :nsequence, :bigint, null: false, default: 4_294_967_295
      column :description, :text
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]

      unique :output_id
      unique %i[action_id vin]
    end

    # 11. labels — label definitions
    create_table(:labels) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      column :label, :text, null: false
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]
      column :deleted_at, c[:timestamptz]

      index :label, unique: true, where: Sequel.lit('deleted_at IS NULL')
    end

    # 12. action_labels — join table
    create_table(:action_labels) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      foreign_key :action_id, :actions, type: :bigint, null: false
      foreign_key :label_id, :labels, type: :bigint, null: false
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]
      column :deleted_at, c[:timestamptz]

      unique %i[action_id label_id]
      index :label_id
    end

    # 13. tags — tag definitions
    create_table(:tags) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      column :tag, :text, null: false
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]
      column :deleted_at, c[:timestamptz]

      index :tag, unique: true, where: Sequel.lit('deleted_at IS NULL')
    end

    # 14. output_tags — join table
    create_table(:output_tags) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      foreign_key :output_id, :outputs, type: :bigint, null: false
      foreign_key :tag_id, :tags, type: :bigint, null: false
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]
      column :deleted_at, c[:timestamptz]

      unique %i[output_id tag_id]
      index :tag_id
    end

    # 15. certificates — identity certificates (BRC-52)
    create_table(:certificates) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      column :type, :text, null: false
      column :subject, :text
      column :serial_number, :text, null: false
      column :certifier, :text, null: false
      column :verifier, :text
      column :revocation_outpoint, :text
      column :signature, :text
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]
      column :deleted_at, c[:timestamptz]

      unique %i[type serial_number certifier]
      index :certifier
      index :subject
    end

    # 16. certificate_fields — per-field encryption for selective revelation
    create_table(:certificate_fields) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      foreign_key :certificate_id, :certificates, type: :bigint, null: false, on_delete: :cascade
      column :name, :text, null: false
      column :value, :text
      column :master_key, :text
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]

      unique %i[certificate_id name]
    end

    # 17. tx_reqs — proof-harvesting work queue
    create_table(:tx_reqs) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      foreign_key :tx_proof_id, :tx_proofs, type: :bigint
      column :wtxid, c[:bytea], null: false, unique: true
      column :status, :text, null: false, default: 'unmined'
      column :attempts, :integer, null: false, default: 0
      column :notified, :boolean, null: false, default: false
      column :history, :text
      column :notify, :text
      column :batch, :text
      column :raw_tx, c[:bytea]
      column :input_beef, c[:bytea]
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]

      index :status
    end

    # 18. settings — key-value wallet configuration
    create_table(:settings) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      column :key, :text, null: false, unique: true
      column :value, :text
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]
    end
  end

  down do
    postgres = database_type == :postgres

    drop_table :settings, :tx_reqs, :certificate_fields, :certificates,
               :output_tags, :tags, :action_labels, :labels, :inputs,
               :output_baskets, :output_details, :spendable, :outputs,
               :baskets, :broadcasts, :actions, :tx_proofs, :blocks

    if postgres
      extension :pg_enum
      drop_enum(:broadcast_intent)
    end
  end
end
