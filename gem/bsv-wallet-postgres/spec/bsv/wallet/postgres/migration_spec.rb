# frozen_string_literal: true

RSpec.describe 'Schema migration' do
  let(:db) { BSV::Wallet::Postgres.db }

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

  describe 'broadcast_intent enum' do
    it 'has the correct values' do
      values = db.from(Sequel.lit(
        "pg_enum e JOIN pg_type t ON e.enumtypid = t.oid WHERE t.typname = 'broadcast_intent'"
      )).select_map(:enumlabel)
      expect(values).to eq(%w[delayed inline none])
    end
  end

  describe 'bytea columns' do
    it 'stores and retrieves binary data on tx_proofs' do
      wtxid = SecureRandom.random_bytes(32)
      db[:tx_proofs].insert(wtxid: Sequel.blob(wtxid))
      row = db[:tx_proofs].first
      expect(row[:wtxid].encoding).to eq(Encoding::BINARY)
      expect(row[:wtxid]).to eq(wtxid)
    end

    it 'stores and retrieves binary locking_script on outputs' do
      action_id = db[:actions].insert(outgoing: true)
      script = SecureRandom.random_bytes(25)
      db[:outputs].insert(action_id: action_id, satoshis: 1000, vout: 0, locking_script: Sequel.blob(script))
      row = db[:outputs].first
      expect(row[:locking_script].encoding).to eq(Encoding::BINARY)
      expect(row[:locking_script]).to eq(script)
    end
  end

  describe 'constraints' do
    it 'enforces UNIQUE on tx_proofs.wtxid' do
      wtxid = SecureRandom.random_bytes(32)
      db[:tx_proofs].insert(wtxid: Sequel.blob(wtxid))
      expect {
        db.transaction(savepoint: true) { db[:tx_proofs].insert(wtxid: Sequel.blob(wtxid)) }
      }.to raise_error(Sequel::UniqueConstraintViolation)
    end

    it 'enforces UNIQUE on inputs.output_id (structural lock)' do
      action_id = db[:actions].insert(outgoing: true)
      action2_id = db[:actions].insert(outgoing: true)
      output_id = db[:outputs].insert(action_id: action_id, satoshis: 1000, vout: 0)
      db[:inputs].insert(action_id: action_id, output_id: output_id, vin: 0)
      expect {
        db.transaction(savepoint: true) { db[:inputs].insert(action_id: action2_id, output_id: output_id, vin: 0) }
      }.to raise_error(Sequel::UniqueConstraintViolation)
    end

    it 'enforces partial unique on baskets.name (soft delete)' do
      db[:baskets].insert(name: 'test')
      expect {
        db.transaction(savepoint: true) { db[:baskets].insert(name: 'test') }
      }.to raise_error(Sequel::UniqueConstraintViolation)

      # Soft-delete and re-create should work
      db[:baskets].where(name: 'test').update(deleted_at: Time.now)
      expect { db[:baskets].insert(name: 'test') }.not_to raise_error
    end

    it 'CASCADE deletes inputs when action is deleted' do
      action_id = db[:actions].insert(outgoing: true)
      output_id = db[:outputs].insert(action_id: action_id, satoshis: 1000, vout: 0)
      db[:spendable].insert(output_id: output_id)
      lock_action_id = db[:actions].insert(outgoing: true)
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
      action_id = db[:actions].insert(outgoing: true)
      row = db[:actions].where(id: action_id).first
      expect(row[:reference]).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-/)
    end

    it 'defaults broadcast to delayed' do
      action_id = db[:actions].insert(outgoing: true)
      row = db[:actions].where(id: action_id).first
      expect(row[:broadcast]).to eq('delayed')
    end
  end
end
