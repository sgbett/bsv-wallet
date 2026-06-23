# frozen_string_literal: true

require_relative 'shared_context'

RSpec.describe 'Schema migration', :store do
  let(:expected_tables) do
    %i[
      blocks tx_proofs actions broadcasts baskets outputs spendable
      output_details output_baskets inputs labels action_labels
      tags output_tags certificates certificate_fields settings
      promotions sse_cursors transmissions transmission_txids
    ]
  end

  describe 'tables' do
    it 'creates all 21 tables' do
      expected_tables.each do |table|
        expect(db.table_exists?(table)).to be(true), "expected table #{table} to exist"
      end
    end
  end

  describe 'value restrictions', :postgres do
    it 'rejects invalid broadcast_intent values' do
      expect do
        db.transaction(savepoint: true) do
          db[:actions].insert(description: 'test action 12345', reference: SecureRandom.uuid, broadcast_intent: 'bogus')
        end
      end.to raise_error(Sequel::DatabaseError)
    end

    it 'rejects invalid output_type values' do
      action_id = insert_action(description: 'test action 12345')
      expect do
        db.transaction(savepoint: true) do
          db[:outputs].insert(
            action_id: action_id, satoshis: 1000, vout: 0,
            locking_script: Sequel.blob(valid_locking_script),
            output_type: 'bogus'
          )
        end
      end.to raise_error(Sequel::DatabaseError)
    end

    it 'rejects invalid tx_status values' do
      action_id = insert_action(description: 'test action 12345')
      expect do
        db.transaction(savepoint: true) do
          db[:broadcasts].insert(action_id: action_id, intent: 'delayed', tx_status: 'BOGUS')
        end
      end.to raise_error(Sequel::DatabaseError)
    end
  end

  describe 'enums', :postgres do
    it 'broadcast_intent has the correct values' do
      values = db.from(
        Sequel.lit("pg_enum e JOIN pg_type t ON e.enumtypid = t.oid WHERE t.typname = 'broadcast_intent'")
      ).select_map(:enumlabel)
      expect(values).to eq(%w[delayed inline none])
    end

    it 'output_type has the correct values' do
      values = db.from(
        Sequel.lit("pg_enum e JOIN pg_type t ON e.enumtypid = t.oid WHERE t.typname = 'output_type'")
      ).select_map(:enumlabel)
      expect(values).to eq(%w[root outbound])
    end

    # ARC's metamorph Status enum + IMMUTABLE (wallet's ArcStatus::TERMINAL).
    # See #198/#220 — the canonical source is ARC's metamorph_api.proto.
    it 'tx_status has the correct values' do
      # ORDER BY enumsortorder so the declared enum lifecycle order
      # (e.g. SEEN_MULTIPLE_NODES sits between SEEN_ON_NETWORK and
      # DOUBLE_SPEND_ATTEMPTED) is preserved regardless of how the value
      # was added — matters for live Postgres databases where the value
      # arrived later via ALTER TYPE ADD VALUE ... AFTER (#272).
      values = db.from(
        Sequel.lit("pg_enum e JOIN pg_type t ON e.enumtypid = t.oid WHERE t.typname = 'tx_status' ORDER BY e.enumsortorder")
      ).select_map(:enumlabel)
      expect(values).to eq(
        %w[
          UNKNOWN QUEUED RECEIVED STORED
          ANNOUNCED_TO_NETWORK REQUESTED_BY_NETWORK SENT_TO_NETWORK
          ACCEPTED_BY_NETWORK SEEN_IN_ORPHAN_MEMPOOL SEEN_ON_NETWORK
          SEEN_MULTIPLE_NODES
          DOUBLE_SPEND_ATTEMPTED REJECTED MINED_IN_STALE_BLOCK MINED IMMUTABLE
        ]
      )
    end
  end

  describe 'blob columns' do
    it 'stores and retrieves binary data on tx_proofs' do
      db[:tx_proofs].insert(wtxid: Sequel.blob(valid_wtxid), raw_tx: Sequel.blob(valid_raw_tx))
      row = db[:tx_proofs].first
      expect(row[:wtxid].encoding).to eq(Encoding::BINARY)
      expect(row[:wtxid]).to eq(valid_wtxid)
    end

    it 'stores and retrieves binary locking_script on outputs' do
      action_id = insert_action(description: 'bytea test 12345')
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
      expect do
        db.transaction(savepoint: true) do
          db[:tx_proofs].insert(wtxid: Sequel.blob(valid_wtxid), raw_tx: Sequel.blob(valid_raw_tx))
        end
      end.to raise_error(Sequel::UniqueConstraintViolation)
    end

    it 'rejects tx_proofs.merkle_path without block_id (path_requires_block)' do
      expect do
        db.transaction(savepoint: true) do
          db[:tx_proofs].insert(
            wtxid: Sequel.blob(SecureRandom.random_bytes(32)),
            raw_tx: Sequel.blob(valid_raw_tx),
            merkle_path: Sequel.blob(SecureRandom.random_bytes(64))
          )
        end
      end.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'allows tx_proofs.block_id without merkle_path (confirmed but unproven)' do
      block_id = db[:blocks].insert(height: 800_000, merkle_root: Sequel.blob(SecureRandom.random_bytes(32)))
      expect do
        db[:tx_proofs].insert(
          wtxid: Sequel.blob(SecureRandom.random_bytes(32)),
          raw_tx: Sequel.blob(valid_raw_tx),
          block_id: block_id
        )
      end.not_to raise_error
    end

    it 'enforces UNIQUE on inputs.output_id (structural lock)' do
      action_id = insert_action(description: 'lock test source')
      output_id = db[:outputs].insert(
        action_id: action_id, satoshis: 1000, vout: 0,
        locking_script: Sequel.blob(valid_locking_script),
        output_type: 'root'
      )
      action2_id = insert_action(description: 'lock test consumer')
      db[:inputs].insert(action_id: action_id, output_id: output_id, vin: 0)
      expect do
        db.transaction(savepoint: true) do
          db[:inputs].insert(action_id: action2_id, output_id: output_id, vin: 0)
        end
      end.to raise_error(Sequel::UniqueConstraintViolation)
    end

    it 'enforces UNIQUE on baskets.name' do
      db[:baskets].insert(name: 'test-basket')
      expect do
        db.transaction(savepoint: true) { db[:baskets].insert(name: 'test-basket') }
      end.to raise_error(Sequel::UniqueConstraintViolation)
    end

    it 'CASCADE deletes inputs when action is deleted' do
      action_id = insert_action(description: 'cascade test src')
      output_id = db[:outputs].insert(
        action_id: action_id, satoshis: 1000, vout: 0,
        locking_script: Sequel.blob(valid_locking_script),
        output_type: 'root'
      )
      lock_action_id = insert_action(description: 'cascade test lock')
      db[:inputs].insert(action_id: lock_action_id, output_id: output_id, vin: 0)

      expect(db[:inputs].where(action_id: lock_action_id).count).to eq(1)
      db[:actions].where(id: lock_action_id).delete
      expect(db[:inputs].where(action_id: lock_action_id).count).to eq(0)
    end

    it 'CASCADE deletes certificate_fields when certificate is deleted' do
      certifier_hex = "02#{'a' * 64}"
      cert_id = db[:certificates].insert(type: 'test', serial_number: 'sn1', certifier: certifier_hex)
      db[:certificate_fields].insert(certificate_id: cert_id, name: 'email', value: 'encrypted')

      expect(db[:certificate_fields].where(certificate_id: cert_id).count).to eq(1)
      db[:certificates].where(id: cert_id).delete
      expect(db[:certificate_fields].where(certificate_id: cert_id).count).to eq(0)
    end

    it 'generates reference UUID by default on actions' do
      action = BSV::Wallet::Store::Models::Action.create(description: 'uuid test 12345')
      expect(action.reference.to_s).to match(/\A[0-9a-f]{8}-[0-9a-f]{4}-/)
    end

    it 'defaults broadcast_intent to delayed' do
      action_id = insert_action(description: 'broadcast test 1')
      row = db[:actions].where(id: action_id).first
      expect(row[:broadcast_intent]).to eq('delayed')
    end
  end

  describe '#380 CHECK constraints' do
    let(:subject_pubkey)   { "02#{'a' * 64}" }
    let(:certifier_pubkey) { "03#{'b' * 64}" }
    let(:verifier_pubkey)  { "02#{'c' * 64}" }

    describe 'broadcasts.path_requires_block' do
      let(:proof_fields) do
        {
          block_hash: Sequel.blob('h' * 32),
          block_height: 100,
          merkle_path: Sequel.blob('m' * 50)
        }
      end

      it 'accepts all-NULL (pre-mining state)' do
        action_id = insert_action(description: 'parity null test')
        expect do
          db[:broadcasts].insert(action_id: action_id, intent: 'delayed')
        end.not_to raise_error
      end

      it 'accepts all-set (post-mining state)' do
        action_id = insert_action(description: 'parity set test')
        expect do
          db[:broadcasts].insert(action_id: action_id, intent: 'delayed', **proof_fields)
        end.not_to raise_error
      end

      it 'accepts block context without merkle_path (confirmed-but-unproven intermediate)' do
        action_id = insert_action(description: 'confirmed unproven test')
        expect do
          db[:broadcasts].insert(action_id: action_id, intent: 'delayed',
                                 block_hash: Sequel.blob('h' * 32), block_height: 100)
        end.not_to raise_error
      end

      it 'rejects merkle_path without block_hash' do
        action_id = insert_action(description: 'parity mp test')
        expect do
          db.transaction(savepoint: true) do
            db[:broadcasts].insert(action_id: action_id, intent: 'delayed',
                                   merkle_path: Sequel.blob('m' * 50), block_height: 100)
          end
        end.to raise_error(Sequel::CheckConstraintViolation)
      end

      it 'rejects merkle_path without block_height' do
        action_id = insert_action(description: 'parity bh-no-height test')
        expect do
          db.transaction(savepoint: true) do
            db[:broadcasts].insert(action_id: action_id, intent: 'delayed',
                                   merkle_path: Sequel.blob('m' * 50),
                                   block_hash: Sequel.blob('h' * 32))
          end
        end.to raise_error(Sequel::CheckConstraintViolation)
      end
    end

    describe 'actions.raw_tx_min_length' do
      it 'accepts NULL raw_tx (per wtxid_raw_tx_parity rule)' do
        expect { insert_action(description: 'raw_tx null test') }.not_to raise_error
      end

      it 'accepts raw_tx >= 20 bytes' do
        expect do
          insert_action(description: 'raw_tx 20-byte test',
                        wtxid: Sequel.blob('w' * 32), raw_tx: Sequel.blob('x' * 20))
        end.not_to raise_error
      end

      # Postgres-only: subsequent alter_table on actions (NOT-NULL reference)
      # forces a SQLite table rebuild that drops this CHECK
      # (project_sqlite_schema_under_enforces).
      it 'rejects raw_tx < 20 bytes', :postgres do
        expect do
          db.transaction(savepoint: true) do
            insert_action(description: 'raw_tx 19-byte test',
                          wtxid: Sequel.blob('w' * 32), raw_tx: Sequel.blob('x' * 19))
          end
        end.to raise_error(Sequel::CheckConstraintViolation)
      end
    end

    describe 'certificates pubkey-shape CHECKs' do
      it 'accepts valid 66-char compressed-hex pubkeys' do
        expect do
          db[:certificates].insert(type: 'test', serial_number: 'sn-ok',
                                   subject: subject_pubkey, certifier: certifier_pubkey,
                                   verifier: verifier_pubkey)
        end.not_to raise_error
      end

      it 'accepts NULL verifier (self-issued certificates)' do
        expect do
          db[:certificates].insert(type: 'test', serial_number: 'sn-no-verifier',
                                   subject: subject_pubkey, certifier: certifier_pubkey)
        end.not_to raise_error
      end

      it 'rejects subject with wrong prefix (04-uncompressed)' do
        expect do
          db.transaction(savepoint: true) do
            db[:certificates].insert(type: 'test', serial_number: 'sn-04',
                                     subject: "04#{'a' * 64}", certifier: subject_pubkey)
          end
        end.to raise_error(Sequel::CheckConstraintViolation)
      end

      it 'rejects certifier with wrong length' do
        expect do
          db.transaction(savepoint: true) do
            db[:certificates].insert(type: 'test', serial_number: 'sn-short',
                                     subject: subject_pubkey, certifier: '02deadbeef')
          end
        end.to raise_error(Sequel::CheckConstraintViolation)
      end

      # Postgres-only: SQLite fallback uses length + 02/03-prefix only
      # (GLOB negation syntax varies across SQLite versions and isn't
      # portable); hex-content enforcement is canonical only on Postgres.
      it 'rejects verifier with non-hex content', :postgres do
        expect do
          db.transaction(savepoint: true) do
            db[:certificates].insert(type: 'test', serial_number: 'sn-nonhex',
                                     subject: subject_pubkey, certifier: certifier_pubkey,
                                     verifier: "02#{'Z' * 64}")
          end
        end.to raise_error(Sequel::CheckConstraintViolation)
      end
    end
  end

  describe 'broadcasts.provider' do
    it 'exists as a nullable text column with no default' do
      schema = db.schema(:broadcasts).to_h
      column = schema[:provider]
      expect(column).not_to be_nil
      expect(column[:allow_null]).to be(true)
      expect(column[:ruby_default]).to be_nil
    end

    # Full down/up round-trip via the migrator to prove every migration's
    # down block reverses cleanly on both backends.
    it 'round-trips up/down/up via the migrator' do
      Sequel.extension :migration
      migrations_path = File.expand_path('../../../../db/migrations', __dir__)

      # SQLite migrations that rebuild a table (to drop a column/CHECK) rewrite
      # the FKs that reference it — unless foreign_keys / legacy_alter_table are
      # toggled, and those PRAGMAs are no-ops *inside a transaction*. The :store
      # wrapper runs each example in a rollback transaction, so the SQLite
      # round-trip needs a dedicated connection outside it (this is how
      # production migrate! runs). Postgres uses native DDL with no rebuild, so
      # the shared, in-transaction db is fine there.
      if db.database_type == :sqlite
        rt = BSV::Wallet::Store.connect('sqlite::memory:').db
        Sequel::Migrator.run(rt, migrations_path)
      else
        rt = db
      end

      expect(rt.schema(:broadcasts).to_h).to have_key(:provider)

      Sequel::Migrator.run(rt, migrations_path, target: 0)
      expected_tables.each do |table|
        expect(rt.table_exists?(table)).to be(false), "expected table #{table} to be gone after target: 0"
      end

      Sequel::Migrator.run(rt, migrations_path)
      expect(rt.schema(:broadcasts).to_h).to have_key(:provider)

      rt.disconnect unless rt.equal?(db)
    end
  end
end
