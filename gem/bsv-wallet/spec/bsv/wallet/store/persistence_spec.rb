# frozen_string_literal: true

require_relative 'shared_context'

RSpec.describe BSV::Wallet::Store, :store do
  # Helpers
  def create_funded_output(satoshis: 1000, vout: 0, basket: nil)
    source = BSV::Wallet::Store::Models::Action.create(outgoing: false, description: 'test action',
                                                       wtxid: SecureRandom.random_bytes(32),
                                                       raw_tx: SecureRandom.random_bytes(100))
    output = BSV::Wallet::Store::Models::Output.create(action_id: source.id, satoshis: satoshis, vout: vout,
                                                       locking_script: SecureRandom.random_bytes(25),
                                                       derivation_prefix: SecureRandom.uuid,
                                                       derivation_suffix: '1',
                                                       sender_identity_key: 'self')
    BSV::Wallet::Store::Models::Spendable.create(output_id: output.id, action_id: source.id)
    if basket
      basket_id = store.find_or_create_basket(name: basket)
      BSV::Wallet::Store::Models::OutputBasket.create(output_id: output.id, basket_id: basket_id, action_id: source.id)
    end
    output
  end

  describe 'Interface conformance' do
    it 'includes BSV::Wallet::Interface::Store' do
      expect(described_class.ancestors).to include(BSV::Wallet::Interface::Store)
    end
  end

  # --- Action Lifecycle ---

  describe '#create_action' do
    it 'creates an action with no inputs' do
      result = store.create_action(action: { description: 'test action', nlocktime: 0 })
      expect(result).to include(:id, :reference, :status)
      expect(result[:status]).to eq(:unsigned)
      expect(result[:broadcast]).to eq('delayed')
    end

    it 'creates an action and locks inputs atomically' do
      output = create_funded_output(satoshis: 1000)

      result = store.create_action(
        action: { description: 'spending', nlocktime: 0 },
        inputs: [{ output_id: output.id, vin: 0 }]
      )

      expect(result).to include(:id)
      expect(BSV::Wallet::Store::Models::Input.where(action_id: result[:id]).count).to eq(1)
    end

    it 'returns nil when an input is already locked (contention)' do
      output = create_funded_output(satoshis: 1000)

      # First caller locks it
      store.create_action(
        action: { description: 'first', nlocktime: 0 },
        inputs: [{ output_id: output.id, vin: 0 }]
      )

      # Second caller tries the same output — rollback
      result = store.create_action(
        action: { description: 'second', nlocktime: 0 },
        inputs: [{ output_id: output.id, vin: 0 }]
      )
      expect(result).to be_nil
    end

    it 'sets broadcast intent' do
      result = store.create_action(action: { description: 'nosend', nlocktime: 0, broadcast: :none })
      expect(result[:broadcast]).to eq('none')
    end

    it 'preserves binary input_beef' do
      beef = SecureRandom.random_bytes(100)
      result = store.create_action(action: { description: 'with beef', nlocktime: 0, input_beef: beef })
      action = BSV::Wallet::Store::Models::Action[result[:id]]
      expect(action.input_beef.encoding).to eq(Encoding::BINARY)
      expect(action.input_beef).to eq(beef)
    end
  end

  describe '#sign_action' do
    it 'attaches wtxid and raw_tx' do
      result = store.create_action(action: { description: 'to sign', nlocktime: 0 })
      wtxid = SecureRandom.random_bytes(32)
      raw_tx = SecureRandom.random_bytes(200)

      store.sign_action(action_id: result[:id], wtxid: wtxid, raw_tx: raw_tx)

      action = BSV::Wallet::Store::Models::Action[result[:id]]
      expect(action.wtxid).to eq(wtxid)
      expect(action.raw_tx).to eq(raw_tx)
      expect(action.derived_status).to eq(:unprocessed)
    end
  end

  describe '#promote_action' do
    it 'writes outputs, spendable, baskets, details, and tags atomically' do
      result = store.create_action(action: { description: 'to promote', nlocktime: 0 })

      store.promote_action(action_id: result[:id], outputs: [
                             {
                               satoshis: 800, vout: 0,
                               locking_script: SecureRandom.random_bytes(25),
                               basket: 'change', tags: %w[auto], description: 'change output',
                               derivation_prefix: SecureRandom.uuid, derivation_suffix: '1',
                               sender_identity_key: 'self'
                             },
                             {
                               satoshis: 200, vout: 1,
                               locking_script: SecureRandom.random_bytes(25),
                               basket: 'payments', tags: %w[payment outgoing], description: 'payment',
                               output_type: 'root'
                             }
                           ])

      outputs = BSV::Wallet::Store::Models::Output.where(action_id: result[:id]).all
      expect(outputs.size).to eq(2)

      # Spendable entries
      expect(BSV::Wallet::Store::Models::Spendable.where(output_id: outputs.map(&:id)).count).to eq(2)

      # Basket memberships
      change_output = outputs.find { |o| o.vout == 0 }
      expect(change_output.basket&.name).to eq('change')

      # Output details
      expect(change_output.detail.description).to eq('change output')

      # Tags
      payment_output = outputs.find { |o| o.vout == 1 }
      expect(payment_output.tags.map(&:tag).sort).to eq(%w[outgoing payment])
    end

    it 'does not create spendable rows for outbound outputs' do
      result = store.create_action(action: { description: 'with outbound', nlocktime: 0 })

      store.promote_action(action_id: result[:id], outputs: [
                             {
                               satoshis: 500, vout: 0,
                               locking_script: SecureRandom.random_bytes(25),
                               derivation_prefix: SecureRandom.uuid, derivation_suffix: '1',
                               sender_identity_key: 'self'
                             },
                             {
                               satoshis: 300, vout: 1,
                               locking_script: SecureRandom.random_bytes(25),
                               output_type: 'outbound'
                             }
                           ])

      outputs = BSV::Wallet::Store::Models::Output.where(action_id: result[:id]).all
      expect(outputs.size).to eq(2)

      # Only the derived output gets a spendable row, not the outbound one
      spendable_ids = BSV::Wallet::Store::Models::Spendable.where(output_id: outputs.map(&:id)).select_map(:output_id)
      derived_output = outputs.find { |o| o.vout == 0 }
      outbound_output = outputs.find { |o| o.vout == 1 }
      expect(spendable_ids).to include(derived_output.id)
      expect(spendable_ids).not_to include(outbound_output.id)
    end
  end

  describe '#link_proof' do
    it 'marks an action as completed' do
      result = store.create_action(action: { description: 'to prove', nlocktime: 0 })
      wtxid = SecureRandom.random_bytes(32)
      store.sign_action(action_id: result[:id], wtxid: wtxid, raw_tx: SecureRandom.random_bytes(100))

      proof = BSV::Wallet::Store::Models::TxProof.first(wtxid: Sequel.blob(wtxid))
      store.link_proof(action_id: result[:id], tx_proof_id: proof.id)

      action = BSV::Wallet::Store::Models::Action[result[:id]]
      expect(action.derived_status).to eq(:completed)
    end
  end

  describe '#abort_action' do
    it 'deletes the action and releases locked inputs via CASCADE' do
      output = create_funded_output(satoshis: 1000)
      result = store.create_action(
        action: { description: 'to abort', nlocktime: 0 },
        inputs: [{ output_id: output.id, vin: 0 }]
      )

      expect(output.reload.spendable?).to be false

      store.abort_action(action_id: result[:id])

      expect(BSV::Wallet::Store::Models::Action[result[:id]]).to be_nil
      expect(output.reload.spendable?).to be true
    end

    it 'refuses to abort a broadcast action' do
      result = store.create_action(action: { description: 'broadcast', nlocktime: 0 })
      store.sign_action(action_id: result[:id], wtxid: SecureRandom.random_bytes(32),
                        raw_tx: SecureRandom.random_bytes(100))

      # Create a broadcast entry — simulates having been submitted to ARC
      BSV::Wallet::Store::Models::Broadcast.create(action_id: result[:id])

      store.abort_action(action_id: result[:id])

      # Action should still exist — the broadcast guard prevented deletion
      expect(BSV::Wallet::Store::Models::Action[result[:id]]).not_to be_nil
    end

    it 'allows aborting a signed but not-broadcast action (deferred)' do
      result = store.create_action(action: { description: 'deferred', nlocktime: 0 })
      store.sign_action(action_id: result[:id], wtxid: SecureRandom.random_bytes(32),
                        raw_tx: SecureRandom.random_bytes(100))

      # No broadcast entry — this is a deferred action with unsigned tx
      store.abort_action(action_id: result[:id])

      expect(BSV::Wallet::Store::Models::Action[result[:id]]).to be_nil
    end
  end

  # --- Queries ---

  describe '#find_action' do
    it 'finds by id' do
      result = store.create_action(action: { description: 'find me', nlocktime: 0 })
      found = store.find_action(id: result[:id])
      expect(found[:id]).to eq(result[:id])
      expect(found[:status]).to eq(:unsigned)
    end

    it 'finds by wtxid' do
      result = store.create_action(action: { description: 'find by wtxid', nlocktime: 0 })
      wtxid = SecureRandom.random_bytes(32)
      store.sign_action(action_id: result[:id], wtxid: wtxid, raw_tx: SecureRandom.random_bytes(100))

      found = store.find_action(wtxid: wtxid)
      expect(found[:id]).to eq(result[:id])
    end

    it 'finds by reference' do
      result = store.create_action(action: { description: 'find by ref', nlocktime: 0 })
      found = store.find_action(reference: result[:reference])
      expect(found[:id]).to eq(result[:id])
    end

    it 'returns nil when not found' do
      expect(store.find_action(id: 999_999)).to be_nil
    end
  end

  describe '#find_output' do
    it 'returns output hash with action_id, vout, and satoshis' do
      action = store.create_action(action: { description: 'output source', nlocktime: 0 })
      wtxid = SecureRandom.random_bytes(32)
      store.sign_action(action_id: action[:id], wtxid: wtxid, raw_tx: SecureRandom.random_bytes(100))
      output_ids = store.promote_action(
        action_id: action[:id],
        outputs: [{ satoshis: 500, vout: 0, locking_script: "\x51".b,
                    derivation_prefix: 'test', derivation_suffix: '1',
                    sender_identity_key: 'self' }]
      )

      found = store.find_output(id: output_ids.first)

      expect(found[:id]).to eq(output_ids.first)
      expect(found[:action_id]).to eq(action[:id])
      expect(found[:satoshis]).to eq(500)
      expect(found[:vout]).to eq(0)
    end

    it 'returns nil when not found' do
      expect(store.find_output(id: 999_999)).to be_nil
    end
  end

  describe '#query_actions' do
    before do
      # Create 3 actions with different label combos
      a1 = store.create_action(action: { description: 'action one', nlocktime: 0 })
      a2 = store.create_action(action: { description: 'action two', nlocktime: 0 })
      a3 = store.create_action(action: { description: 'action three', nlocktime: 0 })

      labels = store.find_or_create_labels(names: %w[payment transfer])
      store.label_action(action_id: a1[:id], label_ids: [labels[0]])           # payment only
      store.label_action(action_id: a2[:id], label_ids: labels)                # payment + transfer
      store.label_action(action_id: a3[:id], label_ids: [labels[1]])           # transfer only
    end

    it 'filters by any label (OR)' do
      result = store.query_actions(labels: ['payment'])
      expect(result[:total]).to eq(2) # a1, a2
    end

    it 'filters by all labels (AND)' do
      result = store.query_actions(labels: %w[payment transfer], label_query_mode: :all)
      expect(result[:total]).to eq(1) # a2 only
    end

    it 'paginates' do
      result = store.query_actions(labels: ['payment'], limit: 1, offset: 0)
      expect(result[:actions].size).to eq(1)
      expect(result[:total]).to eq(2)
    end

    it 'includes labels when requested' do
      result = store.query_actions(labels: %w[payment transfer], label_query_mode: :all,
                                   include_labels: true)
      expect(result[:actions].first[:labels].sort).to eq(%w[payment transfer])
    end

    it 'returns empty when no labels match' do
      result = store.query_actions(labels: ['nonexistent'])
      expect(result[:total]).to eq(0)
      expect(result[:actions]).to eq([])
    end
  end

  describe '#query_outputs' do
    before do
      action = store.create_action(action: { description: 'source', nlocktime: 0 })
      store.promote_action(action_id: action[:id], outputs: [
                             { satoshis: 500, vout: 0, locking_script: SecureRandom.random_bytes(25), basket: 'wallet', tags: %w[payment],
                               derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' },
                             { satoshis: 300, vout: 1, locking_script: SecureRandom.random_bytes(25), basket: 'wallet', tags: %w[change],
                               derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' },
                             { satoshis: 100, vout: 2, locking_script: SecureRandom.random_bytes(25), basket: 'other',
                               derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
                           ])
    end

    it 'filters by basket' do
      result = store.query_outputs(basket: 'wallet')
      expect(result[:total]).to eq(2)
    end

    it 'filters by basket and tag (any)' do
      result = store.query_outputs(basket: 'wallet', tags: ['payment'])
      expect(result[:total]).to eq(1)
    end

    it 'paginates' do
      result = store.query_outputs(basket: 'wallet', limit: 1)
      expect(result[:outputs].size).to eq(1)
      expect(result[:total]).to eq(2)
    end

    it 'includes tags when requested' do
      result = store.query_outputs(basket: 'wallet', tags: ['payment'], include_tags: true)
      expect(result[:outputs].first[:tags]).to eq(['payment'])
    end
  end

  # --- Outputs ---

  describe '#relinquish_output' do
    it 'removes from spendable and basket but keeps the output row' do
      action = store.create_action(action: { description: 'source', nlocktime: 0 })
      store.promote_action(action_id: action[:id], outputs: [
                             { satoshis: 500, vout: 0, locking_script: SecureRandom.random_bytes(25), basket: 'wallet',
                               derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
                           ])
      output = BSV::Wallet::Store::Models::Output.where(action_id: action[:id]).first

      store.relinquish_output(output_id: output.id)

      expect(output.reload.spendable?).to be false
      expect(output.output_basket).to be_nil
      # The output row still exists (immutable log)
      expect(BSV::Wallet::Store::Models::Output[output.id]).not_to be_nil
    end
  end

  # --- Labels, Tags, Baskets ---

  describe '#find_or_create_labels' do
    it 'creates new labels and returns IDs' do
      ids = store.find_or_create_labels(names: %w[payment transfer])
      expect(ids.size).to eq(2)
      expect(ids).to all(be_a(Integer))
    end

    it 'returns existing IDs for known labels' do
      ids1 = store.find_or_create_labels(names: ['payment'])
      ids2 = store.find_or_create_labels(names: ['payment'])
      expect(ids1).to eq(ids2)
    end
  end

  describe '#find_or_create_basket' do
    it 'creates a basket and returns its ID' do
      id = store.find_or_create_basket(name: 'tokens')
      expect(id).to be_a(Integer)
      expect(BSV::Wallet::Store::Models::Basket[id].name).to eq('tokens')
    end
  end

  # --- Certificates ---

  describe '#save_certificate' do
    it 'persists a certificate with fields' do
      cert = store.save_certificate(
        type: 'identity', certifier: 'certifier_key', serial_number: 'sn001',
        subject: 'subject_key', signature: 'sig_hex',
        fields: { 'name' => 'Alice', 'email' => 'alice@example.com' }
      )

      expect(cert[:id]).to be_a(Integer)
      expect(cert[:fields]).to eq({ 'name' => 'Alice', 'email' => 'alice@example.com' })
    end
  end

  describe '#query_certificates' do
    before do
      store.save_certificate(type: 'id', certifier: 'c1', serial_number: 'sn1',
                             fields: { 'name' => 'Alice' })
      store.save_certificate(type: 'id', certifier: 'c2', serial_number: 'sn2',
                             fields: { 'name' => 'Bob' })
      store.save_certificate(type: 'email', certifier: 'c1', serial_number: 'sn3',
                             fields: { 'email' => 'a@b.com' })
    end

    it 'filters by certifiers and types' do
      result = store.query_certificates(certifiers: ['c1'], types: ['id'])
      expect(result[:total]).to eq(1)
      expect(result[:certificates].first[:fields]['name']).to eq('Alice')
    end
  end

  describe '#delete_certificate' do
    it 'soft-deletes a certificate' do
      store.save_certificate(type: 'id', certifier: 'c1', serial_number: 'sn1',
                             fields: { 'name' => 'Alice' })
      store.delete_certificate(type: 'id', serial_number: 'sn1', certifier: 'c1')

      result = store.query_certificates(certifiers: ['c1'], types: ['id'])
      expect(result[:total]).to eq(0)
    end
  end

  # --- Settings ---

  describe '#get_setting / #set_setting' do
    it 'stores and retrieves settings' do
      store.set_setting(key: 'network', value: 'mainnet')
      expect(store.get_setting(key: 'network')).to eq('mainnet')
    end

    it 'updates existing settings' do
      store.set_setting(key: 'network', value: 'mainnet')
      store.set_setting(key: 'network', value: 'testnet')
      expect(store.get_setting(key: 'network')).to eq('testnet')
    end
  end

  # --- Input Resolution ---

  describe '#resolve_inputs_for_signing' do
    let(:first_source_wtxid) { SecureRandom.random_bytes(32) }
    let(:second_source_wtxid) { SecureRandom.random_bytes(32) }
    let(:first_locking_script) { SecureRandom.random_bytes(25) }
    let(:second_locking_script) { SecureRandom.random_bytes(25) }

    def create_source_output(wtxid:, satoshis:, vout:, locking_script: nil,
                             derivation_prefix: nil, derivation_suffix: nil,
                             sender_identity_key: nil)
      locking_script ||= SecureRandom.random_bytes(25)
      source_action = BSV::Wallet::Store::Models::Action.create(outgoing: false, description: 'test action',
                                                                wtxid: wtxid, raw_tx: SecureRandom.random_bytes(100))
      output = BSV::Wallet::Store::Models::Output.create(
        action_id: source_action.id,
        satoshis: satoshis,
        vout: vout,
        locking_script: locking_script,
        derivation_prefix: derivation_prefix,
        derivation_suffix: derivation_suffix,
        sender_identity_key: sender_identity_key,
        output_type: derivation_prefix ? nil : 'root'
      )
      BSV::Wallet::Store::Models::Spendable.create(
        output_id: output.id,
        action_id: source_action.id
      )
      output
    end

    it 'returns resolved input data for an action with inputs' do
      output1 = create_source_output(
        wtxid: first_source_wtxid, satoshis: 1000, vout: 0,
        locking_script: first_locking_script,
        derivation_prefix: 'prefix1', derivation_suffix: 'suffix1',
        sender_identity_key: 'sender_key_1'
      )
      output2 = create_source_output(
        wtxid: second_source_wtxid, satoshis: 2000, vout: 3,
        locking_script: second_locking_script,
        derivation_prefix: 'prefix2', derivation_suffix: 'suffix2',
        sender_identity_key: 'sender_key_2'
      )

      action = store.create_action(
        action: { description: 'spending', nlocktime: 0 },
        inputs: [
          { output_id: output1.id, vin: 0 },
          { output_id: output2.id, vin: 1, nsequence: 0xFFFFFFFE }
        ]
      )

      resolved = store.resolve_inputs_for_signing(action_id: action[:id])

      expect(resolved.size).to eq(2)

      expect(resolved[0]).to eq({
                                  vin: 0,
                                  sequence: 4_294_967_295,
                                  source_wtxid: first_source_wtxid,
                                  source_vout: 0,
                                  source_satoshis: 1000,
                                  source_locking_script: first_locking_script,
                                  derivation_prefix: 'prefix1',
                                  derivation_suffix: 'suffix1',
                                  sender_identity_key: 'sender_key_1'
                                })

      expect(resolved[1]).to eq({
                                  vin: 1,
                                  sequence: 0xFFFFFFFE,
                                  source_wtxid: second_source_wtxid,
                                  source_vout: 3,
                                  source_satoshis: 2000,
                                  source_locking_script: second_locking_script,
                                  derivation_prefix: 'prefix2',
                                  derivation_suffix: 'suffix2',
                                  sender_identity_key: 'sender_key_2'
                                })
    end

    it 'orders results by vin' do
      output1 = create_source_output(wtxid: first_source_wtxid, satoshis: 500, vout: 0)
      output2 = create_source_output(wtxid: second_source_wtxid, satoshis: 300, vout: 1)

      action = store.create_action(
        action: { description: 'ordering test', nlocktime: 0 },
        inputs: [
          { output_id: output2.id, vin: 5 },
          { output_id: output1.id, vin: 2 }
        ]
      )

      resolved = store.resolve_inputs_for_signing(action_id: action[:id])
      expect(resolved.map { |r| r[:vin] }).to eq([2, 5])
    end

    it 'returns source wtxid from the action that created the output' do
      output = create_source_output(wtxid: first_source_wtxid, satoshis: 1000, vout: 7)

      # Create a spending action — this action's wtxid is NOT what we want
      spending_action = store.create_action(
        action: { description: 'spender', nlocktime: 0 },
        inputs: [{ output_id: output.id, vin: 0 }]
      )
      store.sign_action(
        action_id: spending_action[:id],
        wtxid: SecureRandom.random_bytes(32),
        raw_tx: SecureRandom.random_bytes(100)
      )

      resolved = store.resolve_inputs_for_signing(action_id: spending_action[:id])
      expect(resolved.first[:source_wtxid]).to eq(first_source_wtxid)
      expect(resolved.first[:source_vout]).to eq(7)
    end

    it 'returns empty array for action with no inputs' do
      action = store.create_action(action: { description: 'no inputs', nlocktime: 0 })

      resolved = store.resolve_inputs_for_signing(action_id: action[:id])
      expect(resolved).to eq([])
    end

    it 'raises when source action has nil wtxid' do
      # Create a source output whose parent action has no wtxid
      source_action = BSV::Wallet::Store::Models::Action.create(outgoing: false, description: 'test action')
      output = BSV::Wallet::Store::Models::Output.create(
        action_id: source_action.id, satoshis: 500, vout: 0,
        locking_script: SecureRandom.random_bytes(25),
        output_type: 'root'
      )
      BSV::Wallet::Store::Models::Spendable.create(output_id: output.id, action_id: source_action.id)

      action = store.create_action(
        action: { description: 'nil wtxid source', nlocktime: 0 },
        inputs: [{ output_id: output.id, vin: 0 }]
      )

      expect do
        store.resolve_inputs_for_signing(action_id: action[:id])
      end.to raise_error(RuntimeError, /nil wtxid/)
    end

    it 'rejects corrupt wtxid (hex instead of binary) at database level', :postgres do
      # A 64-char hex string is 64 bytes, not 32 — the wtxid_length CHECK
      # constraint catches this before the application ever sees it.
      hex_wtxid = 'a' * 64
      expect do
        BSV::Wallet::Store::Models::Action.create(outgoing: false, description: 'test action',
                                                  wtxid: Sequel.blob(hex_wtxid),
                                                  raw_tx: SecureRandom.random_bytes(100))
      end.to raise_error(Sequel::CheckConstraintViolation, /wtxid_length/)
    end
  end

  # --- UTXO Selection ---

  describe '#find_spendable' do
    before do
      create_funded_output(satoshis: 100, vout: 0)
      create_funded_output(satoshis: 500, vout: 0)
      create_funded_output(satoshis: 1000, vout: 0)
      create_funded_output(satoshis: 200, vout: 0, basket: 'other')
    end

    it 'returns candidates ordered by satoshis descending' do
      candidates = store.find_spendable(satoshis: 600, basket: 'default')
      expect(candidates.map { |c| c[:satoshis] }).to eq([1000])
    end

    it 'returns multiple candidates when needed' do
      candidates = store.find_spendable(satoshis: 1200, basket: 'default')
      expect(candidates.map { |c| c[:satoshis] }).to eq([1000, 500])
    end

    it 'stops scanning once target is reached' do
      candidates = store.find_spendable(satoshis: 1, basket: 'default')
      expect(candidates.size).to eq(1)
    end

    it 'filters by basket' do
      candidates = store.find_spendable(satoshis: 1, basket: 'other')
      expect(candidates.size).to eq(1)
      expect(candidates.first[:satoshis]).to eq(200)
    end

    it 'excludes specified output IDs' do
      all = store.find_spendable(satoshis: 99_999, basket: 'default')
      biggest_id = all.first[:id]

      filtered = store.find_spendable(satoshis: 99_999, basket: 'default', exclude: [biggest_id])
      expect(filtered.map { |c| c[:id] }).not_to include(biggest_id)
    end

    it 'excludes outputs locked by inputs' do
      output = create_funded_output(satoshis: 9999, vout: 0)
      lock_action = BSV::Wallet::Store::Models::Action.create(outgoing: true, description: 'test action', nlocktime: 0)
      BSV::Wallet::Store::Models::Input.create(action_id: lock_action.id, output_id: output.id, vin: 0)

      candidates = store.find_spendable(satoshis: 9999, basket: 'default')
      expect(candidates.map { |c| c[:id] }).not_to include(output.id)
    end
  end

  # --- Reaper ---

  describe '#reap_stale_actions' do
    it 'deletes stale signed actions with no outputs' do
      result = store.create_action(action: { description: 'stale', nlocktime: 0 })
      store.sign_action(action_id: result[:id], wtxid: SecureRandom.random_bytes(32),
                        raw_tx: SecureRandom.random_bytes(100))

      # Backdate the action
      BSV::Wallet::Store::Models::Action.where(id: result[:id]).update(created_at: Time.now - 600)

      count = store.reap_stale_actions(threshold: 300)
      expect(count).to eq(1)
      expect(BSV::Wallet::Store::Models::Action[result[:id]]).to be_nil
    end

    it 'does not reap nosend actions' do
      result = store.create_action(action: { description: 'nosend', nlocktime: 0, broadcast: :none })
      store.sign_action(action_id: result[:id], wtxid: SecureRandom.random_bytes(32),
                        raw_tx: SecureRandom.random_bytes(100))
      BSV::Wallet::Store::Models::Action.where(id: result[:id]).update(created_at: Time.now - 600)

      store.reap_stale_actions(threshold: 300)
      expect(BSV::Wallet::Store::Models::Action[result[:id]]).not_to be_nil
    end

    it 'does not reap actions with outputs (promoted)' do
      result = store.create_action(action: { description: 'promoted', nlocktime: 0 })
      store.sign_action(action_id: result[:id], wtxid: SecureRandom.random_bytes(32),
                        raw_tx: SecureRandom.random_bytes(100))
      store.promote_action(action_id: result[:id], outputs: [
                             { satoshis: 500, vout: 0, locking_script: SecureRandom.random_bytes(25),
                               derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
                           ])
      BSV::Wallet::Store::Models::Action.where(id: result[:id]).update(created_at: Time.now - 600)

      store.reap_stale_actions(threshold: 300)
      expect(BSV::Wallet::Store::Models::Action[result[:id]]).not_to be_nil
    end
  end
end
