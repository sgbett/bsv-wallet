# frozen_string_literal: true

# Negative tests: verify the database rejects invalid data.
# Every CHECK, NOT NULL, and FK constraint from migration 004 is tested here.

RSpec.describe 'Schema constraints' do
  let(:db) { BSV::Wallet::Postgres.db }

  # Valid 32-byte binary for wtxid/block_hash fields
  let(:valid_wtxid) { SecureRandom.random_bytes(32) }
  let(:valid_raw_tx) { SecureRandom.random_bytes(191) }
  let(:valid_locking_script) { SecureRandom.random_bytes(25) }

  # Helper: create a valid action for FK references
  def create_action(description: 'test action 12345')
    db[:actions].insert(description: description, outgoing: true, nlocktime: 0)
  end

  # Helper: create a valid output for FK references.
  # Defaults to root output (no derivation fields). Pass derivation
  # fields and output_type: nil for a derived output.
  def create_output(action_id:, satoshis: 1000, vout: 0, output_type: 'root',
                    derivation_prefix: nil, derivation_suffix: nil, sender_identity_key: nil)
    db[:outputs].insert(
      action_id: action_id, satoshis: satoshis, vout: vout,
      locking_script: Sequel.blob(valid_locking_script),
      output_type: output_type,
      derivation_prefix: derivation_prefix,
      derivation_suffix: derivation_suffix,
      sender_identity_key: sender_identity_key
    )
  end

  # --- tx_proofs ---

  describe 'tx_proofs' do
    it 'rejects wtxid shorter than 32 bytes' do
      expect {
        db.transaction(savepoint: true) do
          db[:tx_proofs].insert(wtxid: Sequel.blob("\x00" * 31), raw_tx: Sequel.blob(valid_raw_tx))
        end
      }.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects wtxid longer than 32 bytes' do
      expect {
        db.transaction(savepoint: true) do
          db[:tx_proofs].insert(wtxid: Sequel.blob("\x00" * 33), raw_tx: Sequel.blob(valid_raw_tx))
        end
      }.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects NULL raw_tx' do
      expect {
        db.transaction(savepoint: true) do
          db[:tx_proofs].insert(wtxid: Sequel.blob(valid_wtxid), raw_tx: nil)
        end
      }.to raise_error(Sequel::NotNullConstraintViolation)
    end

    it 'rejects raw_tx shorter than 20 bytes' do
      expect {
        db.transaction(savepoint: true) do
          db[:tx_proofs].insert(wtxid: Sequel.blob(valid_wtxid), raw_tx: Sequel.blob("\x00" * 19))
        end
      }.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects merkle_path without height' do
      expect {
        db.transaction(savepoint: true) do
          db[:tx_proofs].insert(
            wtxid: Sequel.blob(valid_wtxid), raw_tx: Sequel.blob(valid_raw_tx),
            merkle_path: Sequel.blob("\x00" * 10), height: nil
          )
        end
      }.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'allows height without merkle_path' do
      expect {
        db[:tx_proofs].insert(
          wtxid: Sequel.blob(valid_wtxid), raw_tx: Sequel.blob(valid_raw_tx),
          height: 800_000, merkle_path: nil
        )
      }.not_to raise_error
    end

    it 'rejects block_hash not 32 bytes' do
      expect {
        db.transaction(savepoint: true) do
          db[:tx_proofs].insert(
            wtxid: Sequel.blob(valid_wtxid), raw_tx: Sequel.blob(valid_raw_tx),
            block_hash: Sequel.blob("\x00" * 31)
          )
        end
      }.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects merkle_root not 32 bytes' do
      expect {
        db.transaction(savepoint: true) do
          db[:tx_proofs].insert(
            wtxid: Sequel.blob(valid_wtxid), raw_tx: Sequel.blob(valid_raw_tx),
            merkle_root: Sequel.blob("\x00" * 31)
          )
        end
      }.to raise_error(Sequel::CheckConstraintViolation)
    end
  end

  # --- actions ---

  describe 'actions' do
    it 'rejects NULL description' do
      expect {
        db.transaction(savepoint: true) do
          db[:actions].insert(outgoing: true, description: nil, nlocktime: 0)
        end
      }.to raise_error(Sequel::NotNullConstraintViolation)
    end

    it 'rejects description shorter than 5 characters' do
      expect {
        db.transaction(savepoint: true) do
          db[:actions].insert(outgoing: true, description: 'tiny', nlocktime: 0)
        end
      }.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects description longer than 50 characters' do
      expect {
        db.transaction(savepoint: true) do
          db[:actions].insert(outgoing: true, description: 'x' * 51, nlocktime: 0)
        end
      }.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects wtxid not 32 bytes' do
      expect {
        db.transaction(savepoint: true) do
          db[:actions].insert(
            outgoing: true, description: 'test action 12345', nlocktime: 0,
            wtxid: Sequel.blob("\x00" * 31), raw_tx: Sequel.blob(valid_raw_tx)
          )
        end
      }.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects wtxid set with raw_tx NULL' do
      expect {
        db.transaction(savepoint: true) do
          db[:actions].insert(
            outgoing: true, description: 'test action 12345', nlocktime: 0,
            wtxid: Sequel.blob(valid_wtxid), raw_tx: nil
          )
        end
      }.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects raw_tx set with wtxid NULL' do
      expect {
        db.transaction(savepoint: true) do
          db[:actions].insert(
            outgoing: true, description: 'test action 12345', nlocktime: 0,
            wtxid: nil, raw_tx: Sequel.blob(valid_raw_tx)
          )
        end
      }.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'allows both wtxid and raw_tx NULL (unsigned action)' do
      expect {
        db[:actions].insert(
          outgoing: true, description: 'test action 12345', nlocktime: 0,
          wtxid: nil, raw_tx: nil
        )
      }.not_to raise_error
    end

    it 'rejects negative nlocktime' do
      expect {
        db.transaction(savepoint: true) do
          db[:actions].insert(outgoing: true, description: 'test action 12345', nlocktime: -1)
        end
      }.to raise_error(Sequel::CheckConstraintViolation)
    end
  end

  # --- broadcasts ---

  describe 'broadcasts' do
    it 'rejects block_hash not 32 bytes' do
      action_id = create_action
      expect {
        db.transaction(savepoint: true) do
          db[:broadcasts].insert(action_id: action_id, block_hash: Sequel.blob("\x00" * 31))
        end
      }.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects negative block_height' do
      action_id = create_action
      expect {
        db.transaction(savepoint: true) do
          db[:broadcasts].insert(action_id: action_id, block_height: -1)
        end
      }.to raise_error(Sequel::CheckConstraintViolation)
    end
  end

  # --- baskets ---

  describe 'baskets' do
    it 'rejects empty name' do
      expect {
        db.transaction(savepoint: true) { db[:baskets].insert(name: '') }
      }.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects name longer than 300 characters' do
      expect {
        db.transaction(savepoint: true) { db[:baskets].insert(name: 'x' * 301) }
      }.to raise_error(Sequel::CheckConstraintViolation)
    end

    it "rejects name 'default'" do
      expect {
        db.transaction(savepoint: true) { db[:baskets].insert(name: 'default') }
      }.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects negative target_count' do
      expect {
        db.transaction(savepoint: true) { db[:baskets].insert(name: 'test', target_count: -1) }
      }.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects negative target_value' do
      expect {
        db.transaction(savepoint: true) { db[:baskets].insert(name: 'test', target_value: -1) }
      }.to raise_error(Sequel::CheckConstraintViolation)
    end
  end

  # --- outputs ---

  describe 'outputs' do
    it 'rejects NULL locking_script' do
      action_id = create_action
      expect {
        db.transaction(savepoint: true) do
          db[:outputs].insert(action_id: action_id, satoshis: 1000, vout: 0, locking_script: nil)
        end
      }.to raise_error(Sequel::NotNullConstraintViolation)
    end

    it 'rejects negative satoshis' do
      action_id = create_action
      expect {
        db.transaction(savepoint: true) do
          db[:outputs].insert(
            action_id: action_id, satoshis: -1, vout: 0,
            locking_script: Sequel.blob(valid_locking_script)
          )
        end
      }.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects negative vout' do
      action_id = create_action
      expect {
        db.transaction(savepoint: true) do
          db[:outputs].insert(
            action_id: action_id, satoshis: 1000, vout: -1,
            locking_script: Sequel.blob(valid_locking_script)
          )
        end
      }.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'allows zero satoshis (OP_RETURN)' do
      action_id = create_action
      expect {
        db[:outputs].insert(
          action_id: action_id, satoshis: 0, vout: 0,
          locking_script: Sequel.blob("\x6a".b),
          output_type: 'root'
        )
      }.not_to raise_error
    end
  end

  # --- outputs (derivation cross-column constraints) ---

  describe 'outputs derivation constraints' do
    it 'rejects derived output (NULL output_type) without derivation_prefix' do
      action_id = create_action
      expect {
        db.transaction(savepoint: true) do
          create_output(action_id: action_id, output_type: nil,
                        derivation_prefix: nil, derivation_suffix: 'suffix',
                        sender_identity_key: 'self')
        end
      }.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects derived output (NULL output_type) without sender_identity_key' do
      action_id = create_action
      expect {
        db.transaction(savepoint: true) do
          create_output(action_id: action_id, output_type: nil,
                        derivation_prefix: 'prefix', derivation_suffix: 'suffix',
                        sender_identity_key: nil)
        end
      }.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects root output with derivation_prefix set' do
      action_id = create_action
      expect {
        db.transaction(savepoint: true) do
          create_output(action_id: action_id, output_type: 'root',
                        derivation_prefix: 'should not be here')
        end
      }.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects root output with sender_identity_key set' do
      action_id = create_action
      expect {
        db.transaction(savepoint: true) do
          create_output(action_id: action_id, output_type: 'root',
                        sender_identity_key: 'should not be here')
        end
      }.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'allows root output with no derivation fields' do
      action_id = create_action
      expect {
        create_output(action_id: action_id, output_type: 'root')
      }.not_to raise_error
    end

    it 'allows derived output with all derivation fields' do
      action_id = create_action
      expect {
        create_output(action_id: action_id, output_type: nil,
                      derivation_prefix: 'prefix', derivation_suffix: 'suffix',
                      sender_identity_key: 'self')
      }.not_to raise_error
    end

    it 'allows outbound output with no derivation fields' do
      action_id = create_action
      expect {
        create_output(action_id: action_id, output_type: 'outbound')
      }.not_to raise_error
    end

    it 'rejects outbound output with derivation_prefix set' do
      action_id = create_action
      expect {
        db.transaction(savepoint: true) do
          create_output(action_id: action_id, output_type: 'outbound',
                        derivation_prefix: 'should not be here')
        end
      }.to raise_error(Sequel::CheckConstraintViolation)
    end
  end

  # --- spendable (pure membership) ---

  describe 'spendable' do
    it 'allows thin spendable row for root output' do
      action_id = create_action
      output_id = create_output(action_id: action_id, output_type: 'root')
      expect {
        db[:spendable].insert(output_id: output_id, action_id: action_id)
      }.not_to raise_error
    end

    it 'allows thin spendable row for derived output' do
      action_id = create_action
      output_id = create_output(action_id: action_id, output_type: nil,
                                derivation_prefix: 'prefix', derivation_suffix: 'suffix',
                                sender_identity_key: 'self')
      expect {
        db[:spendable].insert(output_id: output_id, action_id: action_id)
      }.not_to raise_error
    end

    it 'rejects spendable row for outbound output' do
      action_id = create_action
      output_id = create_output(action_id: action_id, output_type: 'outbound')
      expect {
        db.transaction(savepoint: true) do
          db[:spendable].insert(output_id: output_id, action_id: action_id)
        end
      }.to raise_error(Sequel::DatabaseError, /outbound/)
    end
  end

  # --- inputs ---

  describe 'inputs' do
    it 'rejects negative vin' do
      action_id = create_action
      output_id = create_output(action_id: action_id)
      expect {
        db.transaction(savepoint: true) do
          db[:inputs].insert(action_id: action_id, output_id: output_id, vin: -1)
        end
      }.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects nsequence above 4294967295' do
      action_id = create_action
      output_id = create_output(action_id: action_id)
      expect {
        db.transaction(savepoint: true) do
          db[:inputs].insert(action_id: action_id, output_id: output_id, vin: 0, nsequence: 4_294_967_296)
        end
      }.to raise_error(Sequel::CheckConstraintViolation)
    end
  end

  # --- labels ---

  describe 'labels' do
    it 'rejects empty label' do
      expect {
        db.transaction(savepoint: true) { db[:labels].insert(label: '') }
      }.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects label longer than 300 characters' do
      expect {
        db.transaction(savepoint: true) { db[:labels].insert(label: 'x' * 301) }
      }.to raise_error(Sequel::CheckConstraintViolation)
    end
  end

  # --- tags ---

  describe 'tags' do
    it 'rejects empty tag' do
      expect {
        db.transaction(savepoint: true) { db[:tags].insert(tag: '') }
      }.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects tag longer than 300 characters' do
      expect {
        db.transaction(savepoint: true) { db[:tags].insert(tag: 'x' * 301) }
      }.to raise_error(Sequel::CheckConstraintViolation)
    end
  end

  # --- action_labels CASCADE ---

  describe 'action_labels' do
    it 'CASCADE deletes when action is deleted' do
      action_id = create_action
      label_id = db[:labels].insert(label: 'test-label')
      db[:action_labels].insert(action_id: action_id, label_id: label_id)

      expect(db[:action_labels].where(action_id: action_id).count).to eq(1)
      db[:actions].where(id: action_id).delete
      expect(db[:action_labels].where(action_id: action_id).count).to eq(0)
    end
  end

  # --- tx_reqs ---

  describe 'tx_reqs' do
    it 'rejects wtxid not 32 bytes' do
      expect {
        db.transaction(savepoint: true) do
          db[:tx_reqs].insert(wtxid: Sequel.blob("\x00" * 31))
        end
      }.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects invalid status' do
      expect {
        db.transaction(savepoint: true) do
          db[:tx_reqs].insert(wtxid: Sequel.blob(valid_wtxid), status: 'invalid')
        end
      }.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects negative attempts' do
      expect {
        db.transaction(savepoint: true) do
          db[:tx_reqs].insert(wtxid: Sequel.blob(valid_wtxid), attempts: -1)
        end
      }.to raise_error(Sequel::CheckConstraintViolation)
    end
  end
end
