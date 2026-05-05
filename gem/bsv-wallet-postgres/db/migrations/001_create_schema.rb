# frozen_string_literal: true

Sequel.migration do
  up do
    extension :pg_enum

    # Enum: broadcast intent for actions
    create_enum(:broadcast_intent, %w[delayed inline none])

    # 1. tx_proofs — merkle inclusion proofs (settlement evidence)
    create_table(:tx_proofs) do
      column :id, :bigint, primary_key: true, identity: :always
      column :wtxid, :bytea, null: false, unique: true
      column :height, :integer
      column :block_index, :integer
      column :merkle_path, :bytea
      column :raw_tx, :bytea
      column :block_hash, :bytea
      column :merkle_root, :bytea
      column :created_at, :timestamptz, null: false, default: Sequel.function(:now)
      column :updated_at, :timestamptz, null: false, default: Sequel.function(:now)
    end

    # 2. actions — transaction lifecycle
    create_table(:actions) do
      column :id, :bigint, primary_key: true, identity: :always
      foreign_key :tx_proof_id, :tx_proofs, type: :bigint
      column :wtxid, :bytea
      column :reference, :text, unique: true, default: Sequel.function(:gen_random_uuid)
      column :outgoing, :boolean, null: false, default: true
      column :satoshis, :bigint
      column :description, :text
      column :version, :integer
      column :nlocktime, :bigint, null: false, default: 0
      column :broadcast, :broadcast_intent, null: false, default: 'delayed'
      column :raw_tx, :bytea
      column :input_beef, :bytea
      column :created_at, :timestamptz, null: false, default: Sequel.function(:now)
      column :updated_at, :timestamptz, null: false, default: Sequel.function(:now)

      index :wtxid, unique: true, where: Sequel.lit('wtxid IS NOT NULL')
      index :broadcast
    end

    # 3. broadcasts — ARC lifecycle
    create_table(:broadcasts) do
      column :id, :bigint, primary_key: true, identity: :always
      foreign_key :action_id, :actions, type: :bigint, null: false, unique: true
      column :broadcast_at, :timestamptz
      column :tx_status, :text
      column :arc_status, :integer
      column :block_hash, :bytea
      column :block_height, :integer
      column :merkle_path, :bytea
      column :extra_info, :text
      column :competing_txs, 'text[]'
      column :created_at, :timestamptz, null: false, default: Sequel.function(:now)
      column :updated_at, :timestamptz, null: false, default: Sequel.function(:now)
    end

    # 4. baskets — output grouping with replenishment policy
    create_table(:baskets) do
      column :id, :bigint, primary_key: true, identity: :always
      column :name, :text, null: false
      column :target_count, :integer
      column :target_value, :integer
      column :created_at, :timestamptz, null: false, default: Sequel.function(:now)
      column :updated_at, :timestamptz, null: false, default: Sequel.function(:now)
      column :deleted_at, :timestamptz

      index :name, unique: true, where: Sequel.lit('deleted_at IS NULL')
    end

    # 5. outputs — immutable append-only log
    create_table(:outputs) do
      column :id, :bigint, primary_key: true, identity: :always
      foreign_key :action_id, :actions, type: :bigint, null: false
      column :satoshis, :bigint, null: false
      column :created_at, :timestamptz, null: false, default: Sequel.function(:now)
      column :locking_script, :bytea
      column :vout, :integer, null: false
      column :sender_identity_key, :text
      column :derivation_prefix, :text
      column :derivation_suffix, :text

      unique %i[action_id vout]
    end

    # 6. spendable — the UTXO set (~28 bytes/row)
    create_table(:spendable) do
      column :id, :bigint, primary_key: true, identity: :always
      foreign_key :output_id, :outputs, type: :bigint, null: false, unique: true
    end

    # 7. output_details — display and application metadata
    create_table(:output_details) do
      column :id, :bigint, primary_key: true, identity: :always
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

    # 8. output_baskets — basket membership
    create_table(:output_baskets) do
      column :id, :bigint, primary_key: true, identity: :always
      foreign_key :output_id, :outputs, type: :bigint, null: false, unique: true
      foreign_key :basket_id, :baskets, type: :bigint, null: false
      column :created_at, :timestamptz, null: false, default: Sequel.function(:now)
      column :updated_at, :timestamptz, null: false, default: Sequel.function(:now)

      index :basket_id
    end

    # 9. inputs — structural lock mechanism
    create_table(:inputs) do
      column :id, :bigint, primary_key: true, identity: :always
      foreign_key :action_id, :actions, type: :bigint, null: false, on_delete: :cascade
      foreign_key :output_id, :outputs, type: :bigint, null: false
      column :vin, :integer, null: false
      column :nsequence, :bigint, null: false, default: 4_294_967_295
      column :description, :text
      column :created_at, :timestamptz, null: false, default: Sequel.function(:now)
      column :updated_at, :timestamptz, null: false, default: Sequel.function(:now)

      unique :output_id
      unique %i[action_id vin]
    end

    # 10. labels — label definitions
    create_table(:labels) do
      column :id, :bigint, primary_key: true, identity: :always
      column :label, :text, null: false
      column :created_at, :timestamptz, null: false, default: Sequel.function(:now)
      column :updated_at, :timestamptz, null: false, default: Sequel.function(:now)
      column :deleted_at, :timestamptz

      index :label, unique: true, where: Sequel.lit('deleted_at IS NULL')
    end

    # 11. action_labels — join table
    create_table(:action_labels) do
      column :id, :bigint, primary_key: true, identity: :always
      foreign_key :action_id, :actions, type: :bigint, null: false
      foreign_key :label_id, :labels, type: :bigint, null: false
      column :created_at, :timestamptz, null: false, default: Sequel.function(:now)
      column :updated_at, :timestamptz, null: false, default: Sequel.function(:now)
      column :deleted_at, :timestamptz

      unique %i[action_id label_id]
      index :label_id
    end

    # 12. tags — tag definitions
    create_table(:tags) do
      column :id, :bigint, primary_key: true, identity: :always
      column :tag, :text, null: false
      column :created_at, :timestamptz, null: false, default: Sequel.function(:now)
      column :updated_at, :timestamptz, null: false, default: Sequel.function(:now)
      column :deleted_at, :timestamptz

      index :tag, unique: true, where: Sequel.lit('deleted_at IS NULL')
    end

    # 13. output_tags — join table
    create_table(:output_tags) do
      column :id, :bigint, primary_key: true, identity: :always
      foreign_key :output_id, :outputs, type: :bigint, null: false
      foreign_key :tag_id, :tags, type: :bigint, null: false
      column :created_at, :timestamptz, null: false, default: Sequel.function(:now)
      column :updated_at, :timestamptz, null: false, default: Sequel.function(:now)
      column :deleted_at, :timestamptz

      unique %i[output_id tag_id]
      index :tag_id
    end

    # 14. certificates — identity certificates (BRC-52)
    create_table(:certificates) do
      column :id, :bigint, primary_key: true, identity: :always
      column :type, :text, null: false
      column :subject, :text
      column :serial_number, :text, null: false
      column :certifier, :text, null: false
      column :verifier, :text
      column :revocation_outpoint, :text
      column :signature, :text
      column :created_at, :timestamptz, null: false, default: Sequel.function(:now)
      column :updated_at, :timestamptz, null: false, default: Sequel.function(:now)
      column :deleted_at, :timestamptz

      unique %i[type serial_number certifier]
      index :certifier
      index :subject
    end

    # 15. certificate_fields — per-field encryption for selective revelation
    create_table(:certificate_fields) do
      column :id, :bigint, primary_key: true, identity: :always
      foreign_key :certificate_id, :certificates, type: :bigint, null: false, on_delete: :cascade
      column :name, :text, null: false
      column :value, :text
      column :master_key, :text
      column :created_at, :timestamptz, null: false, default: Sequel.function(:now)
      column :updated_at, :timestamptz, null: false, default: Sequel.function(:now)

      unique %i[certificate_id name]
    end

    # 16. tx_reqs — proof-harvesting work queue
    create_table(:tx_reqs) do
      column :id, :bigint, primary_key: true, identity: :always
      foreign_key :tx_proof_id, :tx_proofs, type: :bigint
      column :wtxid, :bytea, null: false, unique: true
      column :status, :text, null: false, default: 'unmined'
      column :attempts, :integer, null: false, default: 0
      column :notified, :boolean, null: false, default: false
      column :history, :text
      column :notify, :text
      column :batch, :text
      column :raw_tx, :bytea
      column :input_beef, :bytea
      column :created_at, :timestamptz, null: false, default: Sequel.function(:now)
      column :updated_at, :timestamptz, null: false, default: Sequel.function(:now)

      index :status
    end

    # 17. settings — key-value wallet configuration
    create_table(:settings) do
      column :id, :bigint, primary_key: true, identity: :always
      column :key, :text, null: false, unique: true
      column :value, :text
      column :created_at, :timestamptz, null: false, default: Sequel.function(:now)
      column :updated_at, :timestamptz, null: false, default: Sequel.function(:now)
    end
  end

  down do
    drop_table :settings, :tx_reqs, :certificate_fields, :certificates,
               :output_tags, :tags, :action_labels, :labels, :inputs,
               :output_baskets, :output_details, :spendable, :outputs,
               :baskets, :broadcasts, :actions, :tx_proofs

    extension :pg_enum
    drop_enum(:broadcast_intent)
  end
end
