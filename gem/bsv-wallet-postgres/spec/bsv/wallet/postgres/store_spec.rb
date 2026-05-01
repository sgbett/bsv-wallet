# frozen_string_literal: true

RSpec.describe BSV::Wallet::Postgres::Store do
  subject(:store) { described_class.new }

  # Helpers
  def create_funded_output(satoshis: 1000, vout: 0, basket: nil)
    source = BSV::Wallet::Postgres::Action.create(outgoing: false, txid: SecureRandom.random_bytes(32))
    output = BSV::Wallet::Postgres::Output.create(action_id: source.id, satoshis: satoshis, vout: vout,
                                                  locking_script: SecureRandom.random_bytes(25))
    BSV::Wallet::Postgres::Spendable.create(output_id: output.id)
    if basket
      basket_id = store.find_or_create_basket(name: basket)
      BSV::Wallet::Postgres::OutputBasket.create(output_id: output.id, basket_id: basket_id)
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
      result = store.create_action(action: { description: 'test action' })
      expect(result).to include(:id, :reference, :status)
      expect(result[:status]).to eq(:unsigned)
      expect(result[:broadcast]).to eq('delayed')
    end

    it 'creates an action and locks inputs atomically' do
      output = create_funded_output(satoshis: 1000)

      result = store.create_action(
        action: { description: 'spending' },
        inputs: [{ output_id: output.id, vin: 0 }]
      )

      expect(result).to include(:id)
      expect(BSV::Wallet::Postgres::Input.where(action_id: result[:id]).count).to eq(1)
    end

    it 'returns nil when an input is already locked (contention)' do
      output = create_funded_output(satoshis: 1000)

      # First caller locks it
      store.create_action(
        action: { description: 'first' },
        inputs: [{ output_id: output.id, vin: 0 }]
      )

      # Second caller tries the same output — rollback
      result = store.create_action(
        action: { description: 'second' },
        inputs: [{ output_id: output.id, vin: 0 }]
      )
      expect(result).to be_nil
    end

    it 'sets broadcast intent' do
      result = store.create_action(action: { description: 'nosend', broadcast: :none })
      expect(result[:broadcast]).to eq('none')
    end

    it 'preserves binary input_beef' do
      beef = SecureRandom.random_bytes(100)
      result = store.create_action(action: { description: 'with beef', input_beef: beef })
      action = BSV::Wallet::Postgres::Action[result[:id]]
      expect(action.input_beef.encoding).to eq(Encoding::BINARY)
      expect(action.input_beef).to eq(beef)
    end
  end

  describe '#sign_action' do
    it 'attaches txid and raw_tx' do
      result = store.create_action(action: { description: 'to sign' })
      txid = SecureRandom.random_bytes(32)
      raw_tx = SecureRandom.random_bytes(200)

      store.sign_action(action_id: result[:id], txid: txid, raw_tx: raw_tx)

      action = BSV::Wallet::Postgres::Action[result[:id]]
      expect(action.txid).to eq(txid)
      expect(action.raw_tx).to eq(raw_tx)
      expect(action.derived_status).to eq(:unprocessed)
    end
  end

  describe '#promote_action' do
    it 'writes outputs, spendable, baskets, details, and tags atomically' do
      result = store.create_action(action: { description: 'to promote' })

      store.promote_action(action_id: result[:id], outputs: [
        {
          satoshis: 800, vout: 0,
          locking_script: SecureRandom.random_bytes(25),
          basket: 'change', tags: %w[auto], description: 'change output', change: true
        },
        {
          satoshis: 200, vout: 1,
          locking_script: SecureRandom.random_bytes(25),
          basket: 'payments', tags: %w[payment outgoing], description: 'payment'
        }
      ])

      outputs = BSV::Wallet::Postgres::Output.where(action_id: result[:id]).all
      expect(outputs.size).to eq(2)

      # Spendable entries
      expect(BSV::Wallet::Postgres::Spendable.where(output_id: outputs.map(&:id)).count).to eq(2)

      # Basket memberships
      change_output = outputs.find { |o| o.vout == 0 }
      expect(change_output.basket&.name).to eq('change')

      # Output details
      expect(change_output.detail.change).to be true
      expect(change_output.detail.description).to eq('change output')

      # Tags
      payment_output = outputs.find { |o| o.vout == 1 }
      expect(payment_output.tags.map(&:tag).sort).to eq(%w[outgoing payment])
    end
  end

  describe '#link_proof' do
    it 'marks an action as completed' do
      result = store.create_action(action: { description: 'to prove' })
      txid = SecureRandom.random_bytes(32)
      store.sign_action(action_id: result[:id], txid: txid, raw_tx: SecureRandom.random_bytes(100))

      proof = BSV::Wallet::Postgres::TxProof.create(txid: txid)
      store.link_proof(action_id: result[:id], tx_proof_id: proof.id)

      action = BSV::Wallet::Postgres::Action[result[:id]]
      expect(action.derived_status).to eq(:completed)
    end
  end

  describe '#abort_action' do
    it 'deletes the action and releases locked inputs via CASCADE' do
      output = create_funded_output(satoshis: 1000)
      result = store.create_action(
        action: { description: 'to abort' },
        inputs: [{ output_id: output.id, vin: 0 }]
      )

      expect(output.reload.spendable?).to be false

      store.abort_action(action_id: result[:id])

      expect(BSV::Wallet::Postgres::Action[result[:id]]).to be_nil
      expect(output.reload.spendable?).to be true
    end

    it 'refuses to abort a signed action' do
      result = store.create_action(action: { description: 'signed' })
      store.sign_action(action_id: result[:id], txid: SecureRandom.random_bytes(32),
                        raw_tx: SecureRandom.random_bytes(100))

      store.abort_action(action_id: result[:id])

      # Action should still exist — the WHERE txid IS NULL guard prevented deletion
      expect(BSV::Wallet::Postgres::Action[result[:id]]).not_to be_nil
    end
  end

  # --- Queries ---

  describe '#find_action' do
    it 'finds by id' do
      result = store.create_action(action: { description: 'find me' })
      found = store.find_action(id: result[:id])
      expect(found[:id]).to eq(result[:id])
      expect(found[:status]).to eq(:unsigned)
    end

    it 'finds by txid' do
      result = store.create_action(action: { description: 'find by txid' })
      txid = SecureRandom.random_bytes(32)
      store.sign_action(action_id: result[:id], txid: txid, raw_tx: "\x00".b)

      found = store.find_action(txid: txid)
      expect(found[:id]).to eq(result[:id])
    end

    it 'finds by reference' do
      result = store.create_action(action: { description: 'find by ref' })
      found = store.find_action(reference: result[:reference])
      expect(found[:id]).to eq(result[:id])
    end

    it 'returns nil when not found' do
      expect(store.find_action(id: 999_999)).to be_nil
    end
  end

  describe '#query_actions' do
    before do
      # Create 3 actions with different label combos
      a1 = store.create_action(action: { description: 'action one' })
      a2 = store.create_action(action: { description: 'action two' })
      a3 = store.create_action(action: { description: 'action three' })

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
      action = store.create_action(action: { description: 'source' })
      store.promote_action(action_id: action[:id], outputs: [
        { satoshis: 500, vout: 0, basket: 'wallet', tags: %w[payment] },
        { satoshis: 300, vout: 1, basket: 'wallet', tags: %w[change] },
        { satoshis: 100, vout: 2, basket: 'other' }
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
      action = store.create_action(action: { description: 'source' })
      store.promote_action(action_id: action[:id], outputs: [
        { satoshis: 500, vout: 0, basket: 'wallet' }
      ])
      output = BSV::Wallet::Postgres::Output.where(action_id: action[:id]).first

      store.relinquish_output(output_id: output.id)

      expect(output.reload.spendable?).to be false
      expect(output.output_basket).to be_nil
      # The output row still exists (immutable log)
      expect(BSV::Wallet::Postgres::Output[output.id]).not_to be_nil
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
      expect(BSV::Wallet::Postgres::Basket[id].name).to eq('tokens')
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

  # --- UTXO Selection ---

  describe '#find_spendable' do
    before do
      create_funded_output(satoshis: 100, vout: 0, basket: 'default')
      create_funded_output(satoshis: 500, vout: 0, basket: 'default')
      create_funded_output(satoshis: 1000, vout: 0, basket: 'default')
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
      output = create_funded_output(satoshis: 9999, vout: 0, basket: 'default')
      lock_action = BSV::Wallet::Postgres::Action.create(outgoing: true)
      BSV::Wallet::Postgres::Input.create(action_id: lock_action.id, output_id: output.id, vin: 0)

      candidates = store.find_spendable(satoshis: 9999, basket: 'default')
      expect(candidates.map { |c| c[:id] }).not_to include(output.id)
    end
  end

  # --- Reaper ---

  describe '#reap_stale_actions' do
    it 'deletes stale signed actions with no outputs' do
      result = store.create_action(action: { description: 'stale' })
      store.sign_action(action_id: result[:id], txid: SecureRandom.random_bytes(32),
                        raw_tx: SecureRandom.random_bytes(100))

      # Backdate the action
      BSV::Wallet::Postgres::Action.where(id: result[:id]).update(created_at: Time.now - 600)

      count = store.reap_stale_actions(threshold: 300)
      expect(count).to eq(1)
      expect(BSV::Wallet::Postgres::Action[result[:id]]).to be_nil
    end

    it 'does not reap nosend actions' do
      result = store.create_action(action: { description: 'nosend', broadcast: :none })
      store.sign_action(action_id: result[:id], txid: SecureRandom.random_bytes(32),
                        raw_tx: SecureRandom.random_bytes(100))
      BSV::Wallet::Postgres::Action.where(id: result[:id]).update(created_at: Time.now - 600)

      store.reap_stale_actions(threshold: 300)
      expect(BSV::Wallet::Postgres::Action[result[:id]]).not_to be_nil
    end

    it 'does not reap actions with outputs (promoted)' do
      result = store.create_action(action: { description: 'promoted' })
      store.sign_action(action_id: result[:id], txid: SecureRandom.random_bytes(32),
                        raw_tx: SecureRandom.random_bytes(100))
      store.promote_action(action_id: result[:id], outputs: [{ satoshis: 500, vout: 0 }])
      BSV::Wallet::Postgres::Action.where(id: result[:id]).update(created_at: Time.now - 600)

      store.reap_stale_actions(threshold: 300)
      expect(BSV::Wallet::Postgres::Action[result[:id]]).not_to be_nil
    end
  end
end
