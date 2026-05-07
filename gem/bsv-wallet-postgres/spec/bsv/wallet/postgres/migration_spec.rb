# frozen_string_literal: true

RSpec.describe 'Schema migration' do
  let(:db) { BSV::Wallet::Postgres.db }

  let(:valid_wtxid) { SecureRandom.random_bytes(32) }
  let(:valid_raw_tx) { SecureRandom.random_bytes(191) }
  let(:valid_locking_script) { SecureRandom.random_bytes(25) }

  describe 'tables' do
    let(:expected_tables) do
      %i[
        tx_proofs actions broadcasts baskets outputs spendable
        output_details output_baskets inputs labels action_labels
        tags output_tags certificates certificate_fields tx_reqs settings
      ]
    end

    it 'creates all 17 tables' do
      expected_tables.each do |table|
        expect(db.table_exists?(table)).to be(true), "expected table #{table} to exist"
      end
    end
  end

  describe 'enums' do
    it 'broadcast_intent has the correct values' do
      values = db.from(Sequel.lit(
        "pg_enum e JOIN pg_type t ON e.enumtypid = t.oid WHERE t.typname = 'broadcast_intent'"
      )).select_map(:enumlabel)
      expect(values).to eq(%w[delayed inline none])
    end

    it 'output_type has the correct values' do
      values = db.from(Sequel.lit(
        "pg_enum e JOIN pg_type t ON e.enumtypid = t.oid WHERE t.typname = 'output_type'"
      )).select_map(:enumlabel)
      expect(values).to eq(%w[root outbound])
    end
  end

  describe 'bytea columns' do
    it 'stores and retrieves binary data on tx_proofs' do
      db[:tx_proofs].insert(wtxid: Sequel.blob(valid_wtxid), raw_tx: Sequel.blob(valid_raw_tx))
      row = db[:tx_proofs].first
      expect(row[:wtxid].encoding).to eq(Encoding::BINARY)
      expect(row[:wtxid]).to eq(valid_wtxid)
    end

    it 'stores and retrieves binary locking_script on outputs' do
      action_id = db[:actions].insert(description: 'bytea test 12345', outgoing: true, nlocktime: 0)
      db[:outputs].insert(
        action_id: action_id, satoshis: 1000, vout: 0,
        locking_script: Sequel.blob(valid_locking_script),
        output_type: 'root'
      )
      row = db[:outputs].first
      expect(row[:locking_script].encoding).to eq(Encoding::BINARY)
      expect(row[:locking_script]).to eq(valid_locking_script)
    end
  end

  describe 'structural constraints' do
    it 'enforces UNIQUE on tx_proofs.wtxid' do
      db[:tx_proofs].insert(wtxid: Sequel.blob(valid_wtxid), raw_tx: Sequel.blob(valid_raw_tx))
      expect {
        db.transaction(savepoint: true) do
          db[:tx_proofs].insert(wtxid: Sequel.blob(valid_wtxid), raw_tx: Sequel.blob(valid_raw_tx))
        end
      }.to raise_error(Sequel::UniqueConstraintViolation)
    end

    it 'enforces UNIQUE on inputs.output_id (structural lock)' do
      action_id = db[:actions].insert(description: 'lock test source', outgoing: true, nlocktime: 0)
      output_id = db[:outputs].insert(
        action_id: action_id, satoshis: 1000, vout: 0,
        locking_script: Sequel.blob(valid_locking_script),
        output_type: 'root'
      )
      action2_id = db[:actions].insert(description: 'lock test consumer', outgoing: true, nlocktime: 0)
      db[:inputs].insert(action_id: action_id, output_id: output_id, vin: 0)
      expect {
        db.transaction(savepoint: true) do
          db[:inputs].insert(action_id: action2_id, output_id: output_id, vin: 0)
        end
      }.to raise_error(Sequel::UniqueConstraintViolation)
    end

    it 'enforces UNIQUE on baskets.name' do
      db[:baskets].insert(name: 'test-basket')
      expect {
        db.transaction(savepoint: true) { db[:baskets].insert(name: 'test-basket') }
      }.to raise_error(Sequel::UniqueConstraintViolation)
    end

    it 'CASCADE deletes inputs when action is deleted' do
      action_id = db[:actions].insert(description: 'cascade test src', outgoing: true, nlocktime: 0)
      output_id = db[:outputs].insert(
        action_id: action_id, satoshis: 1000, vout: 0,
        locking_script: Sequel.blob(valid_locking_script),
        output_type: 'root'
      )
      lock_action_id = db[:actions].insert(description: 'cascade test lock', outgoing: true, nlocktime: 0)
      db[:inputs].insert(action_id: lock_action_id, output_id: output_id, vin: 0)

      expect(db[:inputs].where(action_id: lock_action_id).count).to eq(1)
      db[:actions].where(id: lock_action_id).delete
      expect(db[:inputs].where(action_id: lock_action_id).count).to eq(0)
    end

    it 'CASCADE deletes certificate_fields when certificate is deleted' do
      cert_id = db[:certificates].insert(type: 'test', serial_number: 'sn1', certifier: 'c1')
      db[:certificate_fields].insert(certificate_id: cert_id, name: 'email', value: 'encrypted')

      expect(db[:certificate_fields].where(certificate_id: cert_id).count).to eq(1)
      db[:certificates].where(id: cert_id).delete
      expect(db[:certificate_fields].where(certificate_id: cert_id).count).to eq(0)
    end

    it 'generates reference UUID by default on actions' do
      action_id = db[:actions].insert(description: 'uuid test 12345', outgoing: true, nlocktime: 0)
      row = db[:actions].where(id: action_id).first
      expect(row[:reference].to_s).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-/)
    end

    it 'defaults broadcast to delayed' do
      action_id = db[:actions].insert(description: 'broadcast test 1', outgoing: true, nlocktime: 0)
      row = db[:actions].where(id: action_id).first
      expect(row[:broadcast]).to eq('delayed')
    end
  end
end
