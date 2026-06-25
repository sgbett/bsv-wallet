# frozen_string_literal: true

require_relative 'shared_context'

# Negative tests: verify the database rejects invalid data.
# Every CHECK, NOT NULL, and FK constraint from the migrations is tested here.
# Tagged :postgres because SQLite's ALTER TABLE cannot reliably add CHECK
# constraints to existing tables — the application layer enforces these rules
# on SQLite, the database enforces them on Postgres.

RSpec.describe 'Schema constraints', :postgres, :store do
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

  # --- blocks ---

  describe 'blocks' do
    it 'rejects negative height' do
      expect do
        db.transaction(savepoint: true) do
          db[:blocks].insert(height: -1, merkle_root: Sequel.blob("\x00" * 32))
        end
      end.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects merkle_root not 32 bytes' do
      expect do
        db.transaction(savepoint: true) do
          db[:blocks].insert(height: 1, merkle_root: Sequel.blob("\x00" * 31))
        end
      end.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects block_hash not 32 bytes' do
      expect do
        db.transaction(savepoint: true) do
          db[:blocks].insert(height: 1, merkle_root: Sequel.blob("\x00" * 32),
                             block_hash: Sequel.blob("\x00" * 31))
        end
      end.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'enforces unique height' do
      db[:blocks].insert(height: 800_000, merkle_root: Sequel.blob("\x00" * 32))
      expect do
        db.transaction(savepoint: true) do
          db[:blocks].insert(height: 800_000, merkle_root: Sequel.blob("\x01" * 32))
        end
      end.to raise_error(Sequel::UniqueConstraintViolation)
    end
  end

  # --- tx_proofs ---

  describe 'tx_proofs' do
    it 'rejects wtxid shorter than 32 bytes' do
      expect do
        db.transaction(savepoint: true) do
          db[:tx_proofs].insert(wtxid: Sequel.blob("\x00" * 31), raw_tx: Sequel.blob(valid_raw_tx))
        end
      end.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects wtxid longer than 32 bytes' do
      expect do
        db.transaction(savepoint: true) do
          db[:tx_proofs].insert(wtxid: Sequel.blob("\x00" * 33), raw_tx: Sequel.blob(valid_raw_tx))
        end
      end.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects NULL raw_tx' do
      expect do
        db.transaction(savepoint: true) do
          db[:tx_proofs].insert(wtxid: Sequel.blob(valid_wtxid), raw_tx: nil)
        end
      end.to raise_error(Sequel::NotNullConstraintViolation)
    end

    it 'rejects raw_tx shorter than 20 bytes' do
      expect do
        db.transaction(savepoint: true) do
          db[:tx_proofs].insert(wtxid: Sequel.blob(valid_wtxid), raw_tx: Sequel.blob("\x00" * 19))
        end
      end.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'allows block_id without merkle_path' do
      block_id = db[:blocks].insert(height: 800_000, merkle_root: Sequel.blob("\x00" * 32))
      expect do
        db[:tx_proofs].insert(
          wtxid: Sequel.blob(valid_wtxid), raw_tx: Sequel.blob(valid_raw_tx),
          block_id: block_id, merkle_path: nil
        )
      end.not_to raise_error
    end
  end

  # --- actions ---

  describe 'actions' do
    it 'rejects NULL description' do
      expect do
        db.transaction(savepoint: true) do
          db[:actions].insert(description: nil, reference: SecureRandom.uuid)
        end
      end.to raise_error(Sequel::NotNullConstraintViolation)
    end

    it 'rejects description shorter than 5 characters' do
      expect do
        db.transaction(savepoint: true) do
          db[:actions].insert(description: 'tiny', reference: SecureRandom.uuid)
        end
      end.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects description longer than 50 characters' do
      expect do
        db.transaction(savepoint: true) do
          db[:actions].insert(description: 'x' * 51, reference: SecureRandom.uuid)
        end
      end.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects wtxid not 32 bytes' do
      expect do
        db.transaction(savepoint: true) do
          db[:actions].insert(
            description: 'test action 12345', reference: SecureRandom.uuid,
            wtxid: Sequel.blob("\x00" * 31), raw_tx: Sequel.blob(valid_raw_tx)
          )
        end
      end.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects wtxid set with raw_tx NULL' do
      expect do
        db.transaction(savepoint: true) do
          db[:actions].insert(
            description: 'test action 12345', reference: SecureRandom.uuid,
            wtxid: Sequel.blob(valid_wtxid), raw_tx: nil
          )
        end
      end.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects raw_tx set with wtxid NULL' do
      expect do
        db.transaction(savepoint: true) do
          db[:actions].insert(
            description: 'test action 12345', reference: SecureRandom.uuid,
            wtxid: nil, raw_tx: Sequel.blob(valid_raw_tx)
          )
        end
      end.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'allows both wtxid and raw_tx NULL (unsigned action)' do
      expect do
        db[:actions].insert(
          description: 'test action 12345', reference: SecureRandom.uuid, wtxid: nil, raw_tx: nil
        )
      end.not_to raise_error
    end
  end

  # --- broadcasts ---

  describe 'broadcasts' do
    it 'rejects block_hash not 32 bytes' do
      action_id = insert_action
      expect do
        db.transaction(savepoint: true) do
          db[:broadcasts].insert(action_id: action_id, intent: 'delayed', block_hash: Sequel.blob("\x00" * 31))
        end
      end.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects negative block_height' do
      action_id = insert_action
      expect do
        db.transaction(savepoint: true) do
          db[:broadcasts].insert(action_id: action_id, intent: 'delayed', block_height: -1)
        end
      end.to raise_error(Sequel::CheckConstraintViolation)
    end

    # #198/#221 — broadcasts.intent + composite FK + CHECK intent != 'none'
    # together enforce that an action with broadcast_intent = 'none' cannot
    # have a broadcasts row, without a trigger.
    it "rejects intent = 'none' (intent_not_none CHECK)" do
      action_id = insert_action
      expect do
        db.transaction(savepoint: true) do
          db[:broadcasts].insert(action_id: action_id, intent: 'none')
        end
      end.to raise_error(Sequel::CheckConstraintViolation)
    end

    it "rejects intent mismatching the parent action's broadcast_intent" do
      # Parent action defaults to broadcast_intent = 'delayed'; try to
      # claim 'inline' instead — composite FK to actions(id, broadcast_intent)
      # rejects the mismatch.
      action_id = insert_action
      expect do
        db.transaction(savepoint: true) do
          db[:broadcasts].insert(action_id: action_id, intent: 'inline')
        end
      end.to raise_error(Sequel::DatabaseError, /foreign key/i)
    end
  end

  # --- baskets ---

  describe 'baskets' do
    # BRC-100 basket-name rules live in a dedicated spec
    # (basket_name_validation_spec.rb) that is matrix-aware. This block
    # covers the non-name CHECKs and uses BRC-100-conformant names
    # ('tester' is 6 chars, lowercase ASCII, not reserved) so the new
    # name_length rule (≥ 5) doesn't pre-empt the target_count / target_value
    # CHECKs under test here.
    it 'rejects negative target_count' do
      expect do
        db.transaction(savepoint: true) { db[:baskets].insert(name: 'tester', target_count: -1) }
      end.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects negative target_value' do
      expect do
        db.transaction(savepoint: true) { db[:baskets].insert(name: 'tester', target_value: -1) }
      end.to raise_error(Sequel::CheckConstraintViolation)
    end
  end

  # --- outputs ---

  describe 'outputs' do
    it 'rejects NULL locking_script' do
      action_id = insert_action
      expect do
        db.transaction(savepoint: true) do
          db[:outputs].insert(action_id: action_id, satoshis: 1000, vout: 0, locking_script: nil)
        end
      end.to raise_error(Sequel::NotNullConstraintViolation)
    end

    it 'rejects negative satoshis' do
      action_id = insert_action
      expect do
        db.transaction(savepoint: true) do
          db[:outputs].insert(
            action_id: action_id, satoshis: -1, vout: 0,
            locking_script: Sequel.blob(valid_locking_script)
          )
        end
      end.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects negative vout' do
      action_id = insert_action
      expect do
        db.transaction(savepoint: true) do
          db[:outputs].insert(
            action_id: action_id, satoshis: 1000, vout: -1,
            locking_script: Sequel.blob(valid_locking_script)
          )
        end
      end.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'allows zero satoshis (OP_RETURN)' do
      action_id = insert_action
      expect do
        db[:outputs].insert(
          action_id: action_id, satoshis: 0, vout: 0,
          locking_script: Sequel.blob("\x6a".b),
          output_type: 'root'
        )
      end.not_to raise_error
    end
  end

  # --- outputs (derivation cross-column constraints) ---

  describe 'outputs derivation constraints' do
    it 'rejects derived output (NULL output_type) without derivation_prefix' do
      action_id = insert_action
      expect do
        db.transaction(savepoint: true) do
          create_output(action_id: action_id, output_type: nil,
                        derivation_prefix: nil, derivation_suffix: 'suffix',
                        sender_identity_key: 'self')
        end
      end.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects derived output (NULL output_type) without sender_identity_key' do
      action_id = insert_action
      expect do
        db.transaction(savepoint: true) do
          create_output(action_id: action_id, output_type: nil,
                        derivation_prefix: 'prefix', derivation_suffix: 'suffix',
                        sender_identity_key: nil)
        end
      end.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects root output with derivation_prefix set' do
      action_id = insert_action
      expect do
        db.transaction(savepoint: true) do
          create_output(action_id: action_id, output_type: 'root',
                        derivation_prefix: 'should not be here')
        end
      end.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects root output with sender_identity_key set' do
      action_id = insert_action
      expect do
        db.transaction(savepoint: true) do
          create_output(action_id: action_id, output_type: 'root',
                        sender_identity_key: 'should not be here')
        end
      end.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'allows root output with no derivation fields' do
      action_id = insert_action
      expect do
        create_output(action_id: action_id, output_type: 'root')
      end.not_to raise_error
    end

    it 'allows derived output with all derivation fields' do
      action_id = insert_action
      expect do
        create_output(action_id: action_id, output_type: nil,
                      derivation_prefix: 'prefix', derivation_suffix: 'suffix',
                      sender_identity_key: 'self')
      end.not_to raise_error
    end

    it 'allows outbound output with no derivation fields' do
      action_id = insert_action
      expect do
        create_output(action_id: action_id, output_type: 'outbound')
      end.not_to raise_error
    end

    it 'rejects outbound output with derivation_prefix set' do
      action_id = insert_action
      expect do
        db.transaction(savepoint: true) do
          create_output(action_id: action_id, output_type: 'outbound',
                        derivation_prefix: 'should not be here')
        end
      end.to raise_error(Sequel::CheckConstraintViolation)
    end
  end

  # --- spendable (pure membership) ---

  describe 'spendable' do
    # spendable.action_id is FK'd to promotions(action_id) (#307) — a spendable
    # row cannot exist without a promotions row for the same action. These
    # use an internal-path promotion (intent='none', NULL status).
    it 'allows thin spendable row for root output' do
      action_id = insert_action(broadcast_intent: 'none')
      output_id = create_output(action_id: action_id, output_type: 'root')
      db[:promotions].insert(action_id: action_id, intent: 'none', authorising_status: nil)
      expect do
        db[:spendable].insert(output_id: output_id, action_id: action_id)
      end.not_to raise_error
    end

    it 'allows thin spendable row for derived output' do
      action_id = insert_action(broadcast_intent: 'none')
      output_id = create_output(action_id: action_id, output_type: nil,
                                derivation_prefix: 'prefix', derivation_suffix: 'suffix',
                                sender_identity_key: 'self')
      db[:promotions].insert(action_id: action_id, intent: 'none', authorising_status: nil)
      expect do
        db[:spendable].insert(output_id: output_id, action_id: action_id)
      end.not_to raise_error
    end

    it 'rejects a spendable row with no promotions row (FK to promotions)' do
      action_id = insert_action(broadcast_intent: 'none')
      output_id = create_output(action_id: action_id, output_type: 'root')
      expect do
        db.transaction(savepoint: true) do
          db[:spendable].insert(output_id: output_id, action_id: action_id)
        end
      end.to raise_error(Sequel::ForeignKeyConstraintViolation)
    end

    it 'rejects spendable row for outbound output' do
      action_id = insert_action(broadcast_intent: 'none')
      output_id = create_output(action_id: action_id, output_type: 'outbound')
      db[:promotions].insert(action_id: action_id, intent: 'none', authorising_status: nil)
      expect do
        db.transaction(savepoint: true) do
          db[:spendable].insert(output_id: output_id, action_id: action_id)
        end
      end.to raise_error(Sequel::DatabaseError, /spendable row forbidden for outbound output/)
    end
  end

  # --- promotions (promotion-as-a-row, #307) ---
  #
  # The promotions row is the canonical-state fact that an action's outputs
  # are spendable. Its gating constraints are the heart of the feature.

  describe 'promotions' do
    # promo_path: internal => NULL status; send => a status.
    it 'rejects an internal promotion (intent=none) carrying a status (promo_path)' do
      # intent='none' with a non-NULL status violates promo_path. (An action
      # with broadcast_intent='none' can't have a broadcasts row either, so the
      # composite FK is moot — promo_path is the gate under test.)
      action_id = insert_action(broadcast_intent: 'none')
      expect do
        db.transaction(savepoint: true) do
          db[:promotions].insert(action_id: action_id, intent: 'none', authorising_status: 'QUEUED')
        end
      end.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects a send promotion (intent<>none) with a NULL status (promo_path)' do
      action_id = insert_action(broadcast_intent: 'delayed')
      expect do
        db.transaction(savepoint: true) do
          db[:promotions].insert(action_id: action_id, intent: 'delayed', authorising_status: nil)
        end
      end.to raise_error(Sequel::CheckConstraintViolation)
    end

    # auth_not_rejected: a present status must not be terminal-rejected.
    it "rejects authorising_status = 'REJECTED' (auth_not_rejected)" do
      action_id = insert_action(broadcast_intent: 'delayed')
      db[:broadcasts].insert(action_id: action_id, intent: 'delayed', tx_status: 'REJECTED')
      expect do
        db.transaction(savepoint: true) do
          db[:promotions].insert(action_id: action_id, intent: 'delayed', authorising_status: 'REJECTED')
        end
      end.to raise_error(Sequel::CheckConstraintViolation)
    end

    # composite FK (action_id, authorising_status) -> broadcasts(action_id, tx_status):
    # a send promotion requires a broadcasts row holding that status.
    it 'rejects a send promotion when no broadcasts row holds that tx_status (composite FK)' do
      action_id = insert_action(broadcast_intent: 'delayed')
      db[:broadcasts].insert(action_id: action_id, intent: 'delayed', tx_status: 'QUEUED')
      expect do
        db.transaction(savepoint: true) do
          # SEEN_ON_NETWORK is non-rejected (passes the CHECKs) but no broadcasts
          # row holds it — the composite FK must reject.
          db[:promotions].insert(action_id: action_id, intent: 'delayed', authorising_status: 'SEEN_ON_NETWORK')
        end
      end.to raise_error(Sequel::ForeignKeyConstraintViolation)
    end

    # spendable.action_id -> promotions(action_id) ON DELETE CASCADE: deleting
    # the promotions row removes the dependent spendable row.
    it 'cascades to spendable when the promotions row is deleted (ON DELETE CASCADE)' do
      action_id = insert_action(broadcast_intent: 'none')
      output_id = create_output(action_id: action_id, output_type: 'root')
      db[:promotions].insert(action_id: action_id, intent: 'none', authorising_status: nil)
      db[:spendable].insert(output_id: output_id, action_id: action_id)
      expect(db[:spendable].where(output_id: output_id).count).to eq(1)

      db[:promotions].where(action_id: action_id).delete

      expect(db[:promotions].where(action_id: action_id).count).to eq(0)
      expect(db[:spendable].where(output_id: output_id).count).to eq(0)
    end

    # ON UPDATE CASCADE on the broadcasts composite FK: advancing tx_status
    # among non-rejected values syncs promotions.authorising_status...
    it 'cascades authorising_status when broadcasts.tx_status advances (ON UPDATE CASCADE)' do
      action_id = insert_action(broadcast_intent: 'delayed')
      db[:broadcasts].insert(action_id: action_id, intent: 'delayed', tx_status: 'QUEUED')
      db[:promotions].insert(action_id: action_id, intent: 'delayed', authorising_status: 'QUEUED')

      db[:broadcasts].where(action_id: action_id).update(tx_status: 'SEEN_ON_NETWORK')

      expect(db[:promotions].where(action_id: action_id).get(:authorising_status)).to eq('SEEN_ON_NETWORK')
    end

    # ...but flipping tx_status to REJECTED while a promotions row exists is
    # rejected: the ON UPDATE CASCADE would set authorising_status='REJECTED',
    # which violates auth_not_rejected. reject_action must delete the promotions
    # row first.
    it 'rejects flipping broadcasts.tx_status to REJECTED while a promotions row exists (cascade hits auth_not_rejected)' do
      action_id = insert_action(broadcast_intent: 'delayed')
      db[:broadcasts].insert(action_id: action_id, intent: 'delayed', tx_status: 'QUEUED')
      db[:promotions].insert(action_id: action_id, intent: 'delayed', authorising_status: 'QUEUED')

      expect do
        db.transaction(savepoint: true) do
          db[:broadcasts].where(action_id: action_id).update(tx_status: 'REJECTED')
        end
      end.to raise_error(Sequel::CheckConstraintViolation)
    end
  end

  # --- internal-action delete guard (008) ---

  describe 'prevent_internal_action_delete' do
    it 'forbids deleting an internal action that has a promotions row (received UTXO history)' do
      action_id = insert_action(broadcast_intent: 'none')
      create_output(action_id: action_id)
      # The promotions row (intent='none') is now what marks the internal
      # action's outputs canonical (#307) — the trigger reads promotions, not
      # outputs.promoted.
      db[:promotions].insert(action_id: action_id, intent: 'none', authorising_status: nil)
      expect do
        db.transaction(savepoint: true) { db[:actions].where(id: action_id).delete }
      end.to raise_error(Sequel::DatabaseError, /cannot delete internal action/)
    end

    it 'allows deleting a zero-output internal action (WBIKD address lock)' do
      action_id = insert_action(broadcast_intent: 'none')
      expect do
        db.transaction(savepoint: true) { db[:actions].where(id: action_id).delete }
      end.not_to raise_error
    end

    it 'allows deleting an action with a non-none broadcast_intent' do
      action_id = insert_action(broadcast_intent: 'delayed')
      expect do
        db.transaction(savepoint: true) { db[:actions].where(id: action_id).delete }
      end.not_to raise_error
    end
  end

  # --- inputs ---

  describe 'inputs' do
    it 'rejects negative vin' do
      action_id = insert_action
      output_id = create_output(action_id: action_id)
      expect do
        db.transaction(savepoint: true) do
          db[:inputs].insert(action_id: action_id, output_id: output_id, vin: -1)
        end
      end.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects nsequence above 4294967295' do
      action_id = insert_action
      output_id = create_output(action_id: action_id)
      expect do
        db.transaction(savepoint: true) do
          db[:inputs].insert(action_id: action_id, output_id: output_id, vin: 0, nsequence: 4_294_967_296)
        end
      end.to raise_error(Sequel::CheckConstraintViolation)
    end
  end

  # --- labels ---

  describe 'labels' do
    it 'rejects empty label' do
      expect do
        db.transaction(savepoint: true) { db[:labels].insert(label: '') }
      end.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects label longer than 300 characters' do
      expect do
        db.transaction(savepoint: true) { db[:labels].insert(label: 'x' * 301) }
      end.to raise_error(Sequel::CheckConstraintViolation)
    end
  end

  # --- tags ---

  describe 'tags' do
    it 'rejects empty tag' do
      expect do
        db.transaction(savepoint: true) { db[:tags].insert(tag: '') }
      end.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects tag longer than 300 characters' do
      expect do
        db.transaction(savepoint: true) { db[:tags].insert(tag: 'x' * 301) }
      end.to raise_error(Sequel::CheckConstraintViolation)
    end
  end

  # --- action_labels CASCADE ---

  describe 'action_labels' do
    it 'CASCADE deletes when action is deleted' do
      action_id = insert_action
      label_id = db[:labels].insert(label: 'test-label')
      db[:action_labels].insert(action_id: action_id, label_id: label_id)

      expect(db[:action_labels].where(action_id: action_id).count).to eq(1)
      db[:actions].where(id: action_id).delete
      expect(db[:action_labels].where(action_id: action_id).count).to eq(0)
    end
  end
end
