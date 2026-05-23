# frozen_string_literal: true

Sequel.migration do
  up do
    drop_table(:tx_reqs)
  end

  down do
    postgres = database_type == :postgres

    c = {}
    c[:bytea] = postgres ? :bytea : :blob
    c[:timestamptz] = postgres ? :timestamptz : :datetime
    c[:now] = postgres ? Sequel.function(:now) : Sequel::CURRENT_TIMESTAMP

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

      constraint(:wtxid_length) { length(wtxid) =~ 32 }
      constraint(:status_values, "status IN ('unmined', 'completed', 'failed')")
      constraint(:attempts_range) { attempts >= 0 }
    end
  end
end
