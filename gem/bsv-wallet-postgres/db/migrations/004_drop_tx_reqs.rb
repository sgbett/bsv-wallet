# frozen_string_literal: true

Sequel.migration do
  up do
    drop_table(:tx_reqs)
  end

  down do
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

      # Constraints from migration 003
      constraint(:wtxid_length) { length(wtxid) =~ 32 }
      constraint(:status_values, "status IN ('unmined', 'completed', 'failed')")
      constraint(:attempts_range) { attempts >= 0 }
    end
  end
end
