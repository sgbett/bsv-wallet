# frozen_string_literal: true

require_relative 'shared_context'

RSpec.describe BSV::Wallet::Store, :store do
  # Helpers
  def create_funded_output(satoshis: 1000, vout: 0, basket: nil)
    source = BSV::Wallet::Store::Models::Action.create(description: 'test action',
                                                       broadcast_intent: 'none',
                                                       wtxid: SecureRandom.random_bytes(32),
                                                       raw_tx: SecureRandom.random_bytes(100))
    output = BSV::Wallet::Store::Models::Output.create(action_id: source.id, satoshis: satoshis, vout: vout,
                                                       locking_script: SecureRandom.random_bytes(25),
                                                       derivation_prefix: SecureRandom.uuid,
                                                       derivation_suffix: '1',
                                                       sender_identity_key: 'self')
    # The promotions row (intent='none') authorises the spendable row — this
    # funded source is an internal/incoming fixture (#307).
    BSV::Wallet::Store::Models::Promotion.create(action_id: source.id, intent: 'none', authorising_status: nil)
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
      expect(result[:broadcast_intent]).to eq('delayed')
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
      result = store.create_action(action: { description: 'nosend', nlocktime: 0, broadcast_intent: :none })
      expect(result[:broadcast_intent]).to eq('none')
    end

    it 'preserves binary input_beef' do
      beef = SecureRandom.random_bytes(100)
      result = store.create_action(action: { description: 'with beef', nlocktime: 0, input_beef: beef })
      action = BSV::Wallet::Store::Models::Action[result[:id]]
      expect(action.input_beef.encoding).to eq(Encoding::BINARY)
      expect(action.input_beef).to eq(beef)
    end
  end

  describe '#lock_inputs' do
    it 'locks multiple inputs against an existing action' do
      action = store.create_action(action: { description: 'parent', nlocktime: 0 })
      o1 = create_funded_output(satoshis: 1000)
      o2 = create_funded_output(satoshis: 2000, vout: 1)

      count = store.lock_inputs(
        action_id: action[:id],
        inputs: [
          { output_id: o1.id, vin: 0, nsequence: nil, description: 'first' },
          { output_id: o2.id, vin: 1, nsequence: nil, description: 'second' }
        ]
      )

      expect(count).to eq(2)
      rows = BSV::Wallet::Store::Models::Input.where(action_id: action[:id]).order(:vin).all
      expect(rows.map(&:output_id)).to eq([o1.id, o2.id])
      expect(rows.map(&:vin)).to eq([0, 1])
      expect(rows.map(&:description)).to eq(%w[first second])
    end

    it 'returns 0 and locks nothing for empty inputs' do
      action = store.create_action(action: { description: 'no top-up', nlocktime: 0 })

      count = store.lock_inputs(action_id: action[:id], inputs: [])

      expect(count).to eq(0)
      expect(BSV::Wallet::Store::Models::Input.where(action_id: action[:id]).count).to eq(0)
    end

    it 'returns 0 when a single requested output is already locked by another action' do
      output = create_funded_output(satoshis: 1000)
      store.create_action(
        action: { description: 'first owner', nlocktime: 0 },
        inputs: [{ output_id: output.id, vin: 0 }]
      )
      action = store.create_action(action: { description: 'second', nlocktime: 0 })

      count = store.lock_inputs(
        action_id: action[:id],
        inputs: [{ output_id: output.id, vin: 0, nsequence: nil, description: nil }]
      )

      expect(count).to eq(0)
      expect(BSV::Wallet::Store::Models::Input.where(action_id: action[:id]).count).to eq(0)
    end

    it 'rolls back the whole batch when one input in a multi-input call is already locked' do
      contested = create_funded_output(satoshis: 1000)
      fresh = create_funded_output(satoshis: 2000, vout: 1)
      store.create_action(
        action: { description: 'first owner', nlocktime: 0 },
        inputs: [{ output_id: contested.id, vin: 0 }]
      )
      action = store.create_action(action: { description: 'second', nlocktime: 0 })

      count = store.lock_inputs(
        action_id: action[:id],
        inputs: [
          { output_id: fresh.id, vin: 0, nsequence: nil, description: nil },
          { output_id: contested.id, vin: 1, nsequence: nil, description: nil }
        ]
      )

      expect(count).to eq(0)
      expect(BSV::Wallet::Store::Models::Input.where(action_id: action[:id]).count).to eq(0)
      # The fresh output is still free for another action to claim.
      another = store.create_action(
        action: { description: 'reclaim', nlocktime: 0 },
        inputs: [{ output_id: fresh.id, vin: 0 }]
      )
      expect(another).not_to be_nil
    end

    it 'raises when action_id does not exist' do
      output = create_funded_output(satoshis: 1000)
      missing_id = (BSV::Wallet::Store::Models::Action.max(:id) || 0) + 1_000_000

      expect do
        store.lock_inputs(
          action_id: missing_id,
          inputs: [{ output_id: output.id, vin: 0, nsequence: nil, description: nil }]
        )
      end.to raise_error(Sequel::DatabaseError)
    end

    it 'defaults nsequence to 0xFFFFFFFF when nil is passed' do
      action = store.create_action(action: { description: 'default seq', nlocktime: 0 })
      output = create_funded_output(satoshis: 1000)

      store.lock_inputs(
        action_id: action[:id],
        inputs: [{ output_id: output.id, vin: 0, nsequence: nil, description: nil }]
      )

      row = BSV::Wallet::Store::Models::Input.first(action_id: action[:id])
      expect(row.nsequence).to eq(4_294_967_295)
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
    end

    it 'atomically creates a broadcasts row when broadcast intent is delayed' do
      result = store.create_action(action: { description: 'delayed', nlocktime: 0, broadcast_intent: :delayed })

      store.sign_action(action_id: result[:id], wtxid: SecureRandom.random_bytes(32),
                        raw_tx: SecureRandom.random_bytes(100))

      broadcast = BSV::Wallet::Store::Models::Broadcast.first(action_id: result[:id])
      expect(broadcast).not_to be_nil
      expect(broadcast.broadcast_at).to be_nil
      expect(broadcast.tx_status).to be_nil
    end

    it 'atomically creates a broadcasts row when broadcast intent is inline' do
      result = store.create_action(action: { description: 'inline', nlocktime: 0, broadcast_intent: :inline })

      store.sign_action(action_id: result[:id], wtxid: SecureRandom.random_bytes(32),
                        raw_tx: SecureRandom.random_bytes(100))

      broadcast = BSV::Wallet::Store::Models::Broadcast.first(action_id: result[:id])
      expect(broadcast).not_to be_nil
      expect(broadcast.broadcast_at).to be_nil
    end

    it 'does NOT create a broadcasts row when broadcast intent is none' do
      result = store.create_action(action: { description: 'nosend', nlocktime: 0, broadcast_intent: :none })

      store.sign_action(action_id: result[:id], wtxid: SecureRandom.random_bytes(32),
                        raw_tx: SecureRandom.random_bytes(100))

      expect(BSV::Wallet::Store::Models::Broadcast.first(action_id: result[:id])).to be_nil
    end

    it 'rolls back the action update if the broadcasts insert fails' do
      result = store.create_action(action: { description: 'atomic', nlocktime: 0, broadcast_intent: :delayed })

      # Force a failure on the broadcasts dataset access (the idempotent insert
      # path goes via Models::Broadcast.dataset.insert_conflict(...).insert(...)).
      allow(BSV::Wallet::Store::Models::Broadcast).to receive(:dataset).and_raise(Sequel::DatabaseError)

      expect do
        store.sign_action(action_id: result[:id], wtxid: SecureRandom.random_bytes(32),
                          raw_tx: SecureRandom.random_bytes(100))
      end.to raise_error(Sequel::DatabaseError)

      action = BSV::Wallet::Store::Models::Action[result[:id]]
      expect(action.wtxid).to be_nil
      expect(action.raw_tx).to be_nil
    end

    it 'is idempotent on the broadcasts row insert (second call does not raise)' do
      result = store.create_action(action: { description: 'idempotent', nlocktime: 0, broadcast_intent: :delayed })
      wtxid = SecureRandom.random_bytes(32)
      raw_tx = SecureRandom.random_bytes(100)

      store.sign_action(action_id: result[:id], wtxid: wtxid, raw_tx: raw_tx)
      expect { store.sign_action(action_id: result[:id], wtxid: wtxid, raw_tx: raw_tx) }.not_to raise_error

      expect(BSV::Wallet::Store::Models::Broadcast.where(action_id: result[:id]).count).to eq(1)
    end

    it 'writes send-path outputs with no promotions row and no spendable row' do
      result = store.create_action(action: { description: 'send path', broadcast_intent: :delayed, nlocktime: 0 })
      store.sign_action(
        action_id: result[:id], wtxid: SecureRandom.random_bytes(32), raw_tx: SecureRandom.random_bytes(100),
        outputs: [
          { satoshis: 500, vout: 0, locking_script: SecureRandom.random_bytes(25),
            derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self',
            basket: 'inbox', description: 'pending output' }
        ]
      )

      output = BSV::Wallet::Store::Models::Output.first(action_id: result[:id])
      expect(BSV::Wallet::Store::Models::Promotion.where(action_id: result[:id]).any?).to be(false)
      expect(BSV::Wallet::Store::Models::Spendable.where(output_id: output.id).count).to eq(0)

      # Associations (basket, detail) still written so the metadata survives
      # the sign → broadcast acceptance gap.
      expect(output.basket&.name).to eq('inbox')
      expect(output.detail.description).to eq('pending output')
    end

    it 'writes change outputs with no promotions row on the send path' do
      result = store.create_action(action: { description: 'change path', broadcast_intent: :delayed, nlocktime: 0 })
      store.sign_action(
        action_id: result[:id], wtxid: SecureRandom.random_bytes(32), raw_tx: SecureRandom.random_bytes(100),
        change_outputs: [
          { satoshis: 100, vout: 0, locking_script: SecureRandom.random_bytes(25),
            derivation_prefix: SecureRandom.uuid, derivation_suffix: 'c1', sender_identity_key: 'self' }
        ]
      )
      expect(BSV::Wallet::Store::Models::Promotion.where(action_id: result[:id]).any?).to be(false)
    end

    # The internal path (broadcast_intent='none') doesn't promote at sign_action
    # time — write_change_outputs is a plain INSERT. The promotions row arrives
    # via promote_change_to_spendable. So sign_action alone leaves no promotions
    # row even on the internal path.
    it 'writes change outputs with no promotions row on the internal path until promote_change_to_spendable' do
      result = store.create_action(action: { description: 'internal change', broadcast_intent: :none, nlocktime: 0 })
      store.sign_action(
        action_id: result[:id], wtxid: SecureRandom.random_bytes(32), raw_tx: SecureRandom.random_bytes(100),
        change_outputs: [
          { satoshis: 100, vout: 0, locking_script: SecureRandom.random_bytes(25),
            derivation_prefix: SecureRandom.uuid, derivation_suffix: 'c1', sender_identity_key: 'self' }
        ]
      )
      output = BSV::Wallet::Store::Models::Output.first(action_id: result[:id])
      expect(BSV::Wallet::Store::Models::Promotion.where(action_id: result[:id]).any?).to be(false)

      store.promote_change_to_spendable(action_id: result[:id])
      expect(BSV::Wallet::Store::Models::Promotion.where(action_id: result[:id]).any?).to be(true)
      expect(BSV::Wallet::Store::Models::Spendable.where(output_id: output.id).count).to eq(1)
    end
  end

  describe '#stage_action' do
    it 'attaches wtxid and raw_tx' do
      result = store.create_action(action: { description: 'to stage', nlocktime: 0 })
      wtxid = SecureRandom.random_bytes(32)
      raw_tx = SecureRandom.random_bytes(200)

      store.stage_action(action_id: result[:id], wtxid: wtxid, raw_tx: raw_tx)

      action = BSV::Wallet::Store::Models::Action[result[:id]]
      expect(action.wtxid).to eq(wtxid)
      expect(action.raw_tx).to eq(raw_tx)
    end

    it 'does NOT create a broadcasts row even when broadcast intent is delayed' do
      result = store.create_action(action: { description: 'staged delayed', nlocktime: 0, broadcast_intent: :delayed })

      store.stage_action(action_id: result[:id], wtxid: SecureRandom.random_bytes(32),
                         raw_tx: SecureRandom.random_bytes(100))

      expect(BSV::Wallet::Store::Models::Broadcast.first(action_id: result[:id])).to be_nil
    end

    it 'rejects display-order hex as wtxid' do
      result = store.create_action(action: { description: 'validation', nlocktime: 0 })
      hex_dtxid = 'a' * 64
      expect do
        store.stage_action(action_id: result[:id], wtxid: hex_dtxid, raw_tx: SecureRandom.random_bytes(100))
      end.to raise_error(ArgumentError, /stage_action wtxid/)
    end

    it 'persists outputs with no promotions row and their metadata' do
      result = store.create_action(action: { description: 'staged outputs', broadcast_intent: :delayed, nlocktime: 0 })
      store.stage_action(
        action_id: result[:id], wtxid: SecureRandom.random_bytes(32), raw_tx: SecureRandom.random_bytes(100),
        outputs: [
          { satoshis: 750, vout: 0, locking_script: SecureRandom.random_bytes(25),
            derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self',
            basket: 'staged', tags: %w[awaiting], description: 'awaiting signAction' }
        ]
      )
      output = BSV::Wallet::Store::Models::Output.first(action_id: result[:id])
      expect(output).not_to be_nil
      expect(BSV::Wallet::Store::Models::Promotion.where(action_id: result[:id]).any?).to be(false)
      expect(output.satoshis).to eq(750)
      expect(output.basket&.name).to eq('staged')
      expect(output.tags.map(&:tag)).to eq(['awaiting'])
      expect(output.detail.description).to eq('awaiting signAction')
      expect(BSV::Wallet::Store::Models::Spendable.where(output_id: output.id).count).to eq(0)
    end
  end

  describe '#promote_action' do
    it 'writes outputs, spendable, baskets, details, and tags atomically' do
      result = store.create_action(action: { description: 'to promote', broadcast_intent: :none, nlocktime: 0 })

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
      result = store.create_action(action: { description: 'with outbound', broadcast_intent: :none, nlocktime: 0 })

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

    it 'records a promotions row for the action (internal-path lifecycle)' do
      result = store.create_action(action: { description: 'internal promote', broadcast_intent: :none, nlocktime: 0 })
      store.promote_action(action_id: result[:id], outputs: [
                             {
                               satoshis: 500, vout: 0,
                               locking_script: SecureRandom.random_bytes(25),
                               derivation_prefix: SecureRandom.uuid, derivation_suffix: '1',
                               sender_identity_key: 'self'
                             }
                           ])
      output = BSV::Wallet::Store::Models::Output.first(action_id: result[:id])
      promotion = BSV::Wallet::Store::Models::Promotion.first(action_id: result[:id])
      expect(promotion).not_to be_nil
      expect(promotion.intent).to eq('none')
      expect(promotion.authorising_status).to be_nil
      expect(output.spendable?).to be(true)
    end
  end

  describe '#promote_action_outputs' do
    # The send path's broadcasts row holds the authorising tx_status; the
    # promotions row's composite FK (action_id, authorising_status) ties to it.
    # These tests set the broadcasts row to QUEUED, then promote with the
    # matching authorising_status.
    it 'records a promotions row and inserts spendable rows for wallet-owned outputs' do
      result = store.create_action(action: { description: 'send path action', broadcast_intent: :delayed, nlocktime: 0 })
      store.sign_action(
        action_id: result[:id], wtxid: SecureRandom.random_bytes(32), raw_tx: SecureRandom.random_bytes(100),
        outputs: [
          { satoshis: 500, vout: 0, locking_script: SecureRandom.random_bytes(25),
            derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self',
            basket: 'inbox' }
        ]
      )
      BSV::Wallet::Store::Models::Broadcast.where(action_id: result[:id]).update(tx_status: 'QUEUED')

      output = BSV::Wallet::Store::Models::Output.first(action_id: result[:id])
      expect(BSV::Wallet::Store::Models::Promotion.where(action_id: result[:id]).any?).to be(false)
      expect(BSV::Wallet::Store::Models::Spendable.where(output_id: output.id).count).to eq(0)

      promoted_ids = store.promote_action_outputs(action_id: result[:id], authorising_status: 'QUEUED')
      expect(promoted_ids).to eq([output.id])

      expect(BSV::Wallet::Store::Models::Promotion.where(action_id: result[:id]).any?).to be(true)
      expect(BSV::Wallet::Store::Models::Spendable.where(output_id: output.id).count).to eq(1)
    end

    it 'is idempotent — second call is a no-op' do
      result = store.create_action(action: { description: 'idempotent test', broadcast_intent: :delayed, nlocktime: 0 })
      store.sign_action(
        action_id: result[:id], wtxid: SecureRandom.random_bytes(32), raw_tx: SecureRandom.random_bytes(100),
        outputs: [
          { satoshis: 500, vout: 0, locking_script: SecureRandom.random_bytes(25),
            derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
        ]
      )
      BSV::Wallet::Store::Models::Broadcast.where(action_id: result[:id]).update(tx_status: 'QUEUED')

      first = store.promote_action_outputs(action_id: result[:id], authorising_status: 'QUEUED')
      expect(first.size).to eq(1)

      second = store.promote_action_outputs(action_id: result[:id], authorising_status: 'QUEUED')
      expect(second).to eq([])

      output = BSV::Wallet::Store::Models::Output.first(action_id: result[:id])
      expect(BSV::Wallet::Store::Models::Spendable.where(output_id: output.id).count).to eq(1)
    end

    it 'skips spendable creation for outbound (non-wallet-owned) outputs' do
      result = store.create_action(action: { description: 'outbound payment', broadcast_intent: :delayed, nlocktime: 0 })
      store.sign_action(
        action_id: result[:id], wtxid: SecureRandom.random_bytes(32), raw_tx: SecureRandom.random_bytes(100),
        outputs: [
          { satoshis: 500, vout: 0, locking_script: SecureRandom.random_bytes(25), output_type: 'outbound' }
        ]
      )
      BSV::Wallet::Store::Models::Broadcast.where(action_id: result[:id]).update(tx_status: 'QUEUED')

      output = BSV::Wallet::Store::Models::Output.first(action_id: result[:id])
      store.promote_action_outputs(action_id: result[:id], authorising_status: 'QUEUED')

      expect(BSV::Wallet::Store::Models::Promotion.where(action_id: result[:id]).any?).to be(true)
      expect(BSV::Wallet::Store::Models::Spendable.where(output_id: output.id).count).to eq(0)
    end

    it 'promotes change outputs and creates their spendable rows' do
      result = store.create_action(action: { description: 'with change', broadcast_intent: :delayed, nlocktime: 0 })
      store.sign_action(
        action_id: result[:id], wtxid: SecureRandom.random_bytes(32), raw_tx: SecureRandom.random_bytes(100),
        change_outputs: [
          { satoshis: 250, vout: 1, locking_script: SecureRandom.random_bytes(25),
            derivation_prefix: SecureRandom.uuid, derivation_suffix: 'c1', sender_identity_key: 'self' }
        ]
      )
      BSV::Wallet::Store::Models::Broadcast.where(action_id: result[:id]).update(tx_status: 'QUEUED')

      change_output = BSV::Wallet::Store::Models::Output.first(action_id: result[:id])
      expect(BSV::Wallet::Store::Models::Promotion.where(action_id: result[:id]).any?).to be(false)

      store.promote_action_outputs(action_id: result[:id], authorising_status: 'QUEUED')

      expect(BSV::Wallet::Store::Models::Promotion.where(action_id: result[:id]).any?).to be(true)
      expect(BSV::Wallet::Store::Models::Spendable.where(output_id: change_output.id).count).to eq(1)
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
      # sign_action atomically creates the broadcasts row when intent != 'none'
      result = store.create_action(action: { description: 'broadcast', nlocktime: 0 })
      store.sign_action(action_id: result[:id], wtxid: SecureRandom.random_bytes(32),
                        raw_tx: SecureRandom.random_bytes(100))

      store.abort_action(action_id: result[:id])

      # Action should still exist — the broadcast guard prevented deletion
      expect(BSV::Wallet::Store::Models::Action[result[:id]]).not_to be_nil
    end

    it 'allows aborting a staged action (deferred signing, no broadcast row yet)' do
      result = store.create_action(action: { description: 'deferred', nlocktime: 0 })
      store.stage_action(action_id: result[:id], wtxid: SecureRandom.random_bytes(32),
                         raw_tx: SecureRandom.random_bytes(100))

      # stage_action does NOT create a broadcasts row — abort is still permitted
      store.abort_action(action_id: result[:id])

      expect(BSV::Wallet::Store::Models::Action[result[:id]]).to be_nil
    end
  end

  describe '#reject_action' do
    it 'deletes the broadcast row and the action, releasing locked inputs via CASCADE' do
      output = create_funded_output(satoshis: 1000)
      result = store.create_action(
        action: { description: 'to fail', nlocktime: 0 },
        inputs: [{ output_id: output.id, vin: 0 }]
      )
      # sign_action atomically creates the broadcasts row (broadcast_intent != 'none').
      store.sign_action(action_id: result[:id], wtxid: SecureRandom.random_bytes(32),
                        raw_tx: SecureRandom.random_bytes(100))
      BSV::Wallet::Store::Models::Broadcast.where(action_id: result[:id]).update(tx_status: 'REJECTED')

      expect(output.reload.spendable?).to be false

      store.reject_action(action_id: result[:id])

      expect(BSV::Wallet::Store::Models::Action[result[:id]]).to be_nil
      expect(BSV::Wallet::Store::Models::Broadcast.first(action_id: result[:id])).to be_nil
      expect(output.reload.spendable?).to be true
    end

    it 'deletes unpromoted outputs and their associations before the action' do
      input_output = create_funded_output(satoshis: 1000)
      result = store.create_action(
        action: { description: 'to fail with outputs', nlocktime: 0 },
        inputs: [{ output_id: input_output.id, vin: 0 }]
      )
      pending_outputs = [{
        satoshis: 500, vout: 0, locking_script: SecureRandom.random_bytes(25),
        derivation_prefix: SecureRandom.uuid, derivation_suffix: '1',
        sender_identity_key: 'self', basket: 'my-basket', tags: %w[urgent]
      }]
      change_outputs = [{
        satoshis: 400, vout: 1, locking_script: SecureRandom.random_bytes(25),
        derivation_prefix: SecureRandom.uuid, derivation_suffix: '2',
        sender_identity_key: 'self'
      }]
      store.sign_action(
        action_id: result[:id], wtxid: SecureRandom.random_bytes(32),
        raw_tx: SecureRandom.random_bytes(100),
        outputs: pending_outputs, change_outputs: change_outputs
      )

      output_ids = BSV::Wallet::Store::Models::Output.where(action_id: result[:id]).select_map(:id)
      expect(output_ids.length).to eq(2)
      expect(BSV::Wallet::Store::Models::Promotion.where(action_id: result[:id]).any?).to be false
      expect(BSV::Wallet::Store::Models::OutputBasket.where(action_id: result[:id]).any?).to be true
      expect(BSV::Wallet::Store::Models::OutputDetail.where(action_id: result[:id]).any?).to be true
      expect(BSV::Wallet::Store::Models::OutputTag.where(output_id: output_ids).any?).to be true

      store.reject_action(action_id: result[:id])

      expect(BSV::Wallet::Store::Models::Action[result[:id]]).to be_nil
      expect(BSV::Wallet::Store::Models::Output.where(id: output_ids).any?).to be false
      expect(BSV::Wallet::Store::Models::OutputBasket.where(action_id: result[:id]).any?).to be false
      expect(BSV::Wallet::Store::Models::OutputDetail.where(action_id: result[:id]).any?).to be false
      expect(BSV::Wallet::Store::Models::OutputTag.where(output_id: output_ids).any?).to be false
      expect(input_output.reload.spendable?).to be true
    end

    it 'is idempotent (no-op when neither row exists)' do
      expect { store.reject_action(action_id: 999_999) }.not_to raise_error
    end

    it 'unwinds promoted outputs of an inline action whose speculative promotion is being rolled back' do
      # Simulates the #240 scenario: Engine speculatively promoted on a
      # non-rejected ARC response, then the resolution loop discovered
      # a definitive REJECTED status. The promoted-output guard previously
      # blocked unwind; reject_action explicitly supports this path.
      input_output = create_funded_output(satoshis: 1000)
      result = store.create_action(
        action: { description: 'inline speculative', nlocktime: 0 },
        inputs: [{ output_id: input_output.id, vin: 0 }]
      )
      pending_outputs = [{
        satoshis: 500, vout: 0, locking_script: SecureRandom.random_bytes(25),
        derivation_prefix: SecureRandom.uuid, derivation_suffix: '1',
        sender_identity_key: 'self'
      }]
      store.sign_action(
        action_id: result[:id], wtxid: SecureRandom.random_bytes(32),
        raw_tx: SecureRandom.random_bytes(100), outputs: pending_outputs
      )
      # Simulate the speculative-promote that happens on a non-rejected
      # ARC response. QUEUED is non-rejected (so it promotes) and not in the
      # ACCEPTED set (so reject_action can still unwind it).
      store.record_broadcast_result(action_id: result[:id], tx_status: 'QUEUED')
      output_ids = BSV::Wallet::Store::Models::Output.where(action_id: result[:id]).select_map(:id)
      expect(BSV::Wallet::Store::Models::Promotion.where(action_id: result[:id]).any?).to be true
      expect(BSV::Wallet::Store::Models::Spendable.where(output_id: output_ids).count).to eq(1)

      store.reject_action(action_id: result[:id])

      expect(BSV::Wallet::Store::Models::Action[result[:id]]).to be_nil
      expect(BSV::Wallet::Store::Models::Output.where(id: output_ids).any?).to be false
      expect(BSV::Wallet::Store::Models::Spendable.where(output_id: output_ids).any?).to be false
      expect(input_output.reload.spendable?).to be true
    end

    it 'cascades through a three-level chain (X -> Y -> Z), tearing down Z and Y before X' do
      # Build a chain: X creates output, Y consumes X's output (and creates
      # its own), Z consumes Y's output. Rejecting X must cascade forward.
      input_output = create_funded_output(satoshis: 1000)

      x = store.create_action(action: { description: 'X tx node', nlocktime: 0 },
                              inputs: [{ output_id: input_output.id, vin: 0 }])
      store.sign_action(
        action_id: x[:id], wtxid: SecureRandom.random_bytes(32),
        raw_tx: SecureRandom.random_bytes(100),
        outputs: [{ satoshis: 800, vout: 0, locking_script: SecureRandom.random_bytes(25),
                    derivation_prefix: SecureRandom.uuid, derivation_suffix: '1',
                    sender_identity_key: 'self' }]
      )
      store.record_broadcast_result(action_id: x[:id], tx_status: 'QUEUED')
      x_output_id = BSV::Wallet::Store::Models::Output.where(action_id: x[:id]).select_map(:id).first

      y = store.create_action(action: { description: 'Y tx node', nlocktime: 0 },
                              inputs: [{ output_id: x_output_id, vin: 0 }])
      store.sign_action(
        action_id: y[:id], wtxid: SecureRandom.random_bytes(32),
        raw_tx: SecureRandom.random_bytes(100),
        outputs: [{ satoshis: 700, vout: 0, locking_script: SecureRandom.random_bytes(25),
                    derivation_prefix: SecureRandom.uuid, derivation_suffix: '2',
                    sender_identity_key: 'self' }]
      )
      store.record_broadcast_result(action_id: y[:id], tx_status: 'QUEUED')
      y_output_id = BSV::Wallet::Store::Models::Output.where(action_id: y[:id]).select_map(:id).first

      z = store.create_action(action: { description: 'Z tx node', nlocktime: 0 },
                              inputs: [{ output_id: y_output_id, vin: 0 }])
      store.sign_action(action_id: z[:id], wtxid: SecureRandom.random_bytes(32),
                        raw_tx: SecureRandom.random_bytes(100))

      store.reject_action(action_id: x[:id])

      expect(BSV::Wallet::Store::Models::Action[x[:id]]).to be_nil
      expect(BSV::Wallet::Store::Models::Action[y[:id]]).to be_nil
      expect(BSV::Wallet::Store::Models::Action[z[:id]]).to be_nil
      expect(input_output.reload.spendable?).to be true
    end

    it 'cascades through a diamond (A -> {B, C} -> D) without misfiring the cycle guard' do
      # A has two outputs; B spends one, C the other; D consumes an output
      # of BOTH B and C, so the forward walk reaches D twice (once per
      # path). The second visit must no-op, not raise -- a real DAG shape,
      # not a cycle. Regression for the diamond false-positive.
      input_output = create_funded_output(satoshis: 2000)

      a = store.create_action(action: { description: 'A diamond root', nlocktime: 0 },
                              inputs: [{ output_id: input_output.id, vin: 0 }])
      store.sign_action(
        action_id: a[:id], wtxid: SecureRandom.random_bytes(32),
        raw_tx: SecureRandom.random_bytes(100),
        outputs: [
          { satoshis: 900, vout: 0, locking_script: SecureRandom.random_bytes(25),
            derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' },
          { satoshis: 900, vout: 1, locking_script: SecureRandom.random_bytes(25),
            derivation_prefix: SecureRandom.uuid, derivation_suffix: '2', sender_identity_key: 'self' }
        ]
      )
      store.record_broadcast_result(action_id: a[:id], tx_status: 'QUEUED')
      a_outputs = BSV::Wallet::Store::Models::Output.where(action_id: a[:id]).order(:vout).select_map(:id)

      b = store.create_action(action: { description: 'B diamond left', nlocktime: 0 },
                              inputs: [{ output_id: a_outputs[0], vin: 0 }])
      store.sign_action(
        action_id: b[:id], wtxid: SecureRandom.random_bytes(32),
        raw_tx: SecureRandom.random_bytes(100),
        outputs: [{ satoshis: 800, vout: 0, locking_script: SecureRandom.random_bytes(25),
                    derivation_prefix: SecureRandom.uuid, derivation_suffix: '3', sender_identity_key: 'self' }]
      )
      store.record_broadcast_result(action_id: b[:id], tx_status: 'QUEUED')
      b_output_id = BSV::Wallet::Store::Models::Output.where(action_id: b[:id]).select_map(:id).first

      c = store.create_action(action: { description: 'C diamond right', nlocktime: 0 },
                              inputs: [{ output_id: a_outputs[1], vin: 0 }])
      store.sign_action(
        action_id: c[:id], wtxid: SecureRandom.random_bytes(32),
        raw_tx: SecureRandom.random_bytes(100),
        outputs: [{ satoshis: 800, vout: 0, locking_script: SecureRandom.random_bytes(25),
                    derivation_prefix: SecureRandom.uuid, derivation_suffix: '4', sender_identity_key: 'self' }]
      )
      store.record_broadcast_result(action_id: c[:id], tx_status: 'QUEUED')
      c_output_id = BSV::Wallet::Store::Models::Output.where(action_id: c[:id]).select_map(:id).first

      d = store.create_action(action: { description: 'D diamond sink', nlocktime: 0 },
                              inputs: [{ output_id: b_output_id, vin: 0 }, { output_id: c_output_id, vin: 1 }])
      store.sign_action(action_id: d[:id], wtxid: SecureRandom.random_bytes(32),
                        raw_tx: SecureRandom.random_bytes(100))

      expect { store.reject_action(action_id: a[:id]) }.not_to raise_error

      [a, b, c, d].each do |node|
        expect(BSV::Wallet::Store::Models::Action[node[:id]]).to be_nil
      end
      expect(input_output.reload.spendable?).to be true
    end

    it 'raises CannotRejectInternalActionError on a no_send target and rolls back the cascade' do
      input_output = create_funded_output(satoshis: 1000)
      result = store.create_action(
        action: { description: 'internal', broadcast_intent: :none, nlocktime: 0 },
        inputs: [{ output_id: input_output.id, vin: 0 }]
      )
      expect do
        store.reject_action(action_id: result[:id])
      end.to raise_error(BSV::Wallet::CannotRejectInternalActionError)

      # Rollback: row intact.
      expect(BSV::Wallet::Store::Models::Action[result[:id]]).not_to be_nil
      expect(input_output.reload.spendable?).to be false
    end

    it 'raises and rolls back the entire cascade if any descendant has broadcast_intent=none' do
      # Parent (inline) -> child (no_send). Rejecting the parent walks
      # into the no_send child and must raise; the parent must remain.
      input_output = create_funded_output(satoshis: 1000)
      parent = store.create_action(action: { description: 'parent', nlocktime: 0 },
                                   inputs: [{ output_id: input_output.id, vin: 0 }])
      store.sign_action(
        action_id: parent[:id], wtxid: SecureRandom.random_bytes(32),
        raw_tx: SecureRandom.random_bytes(100),
        outputs: [{ satoshis: 900, vout: 0, locking_script: SecureRandom.random_bytes(25),
                    derivation_prefix: SecureRandom.uuid, derivation_suffix: '1',
                    sender_identity_key: 'self' }]
      )
      store.record_broadcast_result(action_id: parent[:id], tx_status: 'QUEUED')
      parent_output_id = BSV::Wallet::Store::Models::Output.where(action_id: parent[:id]).select_map(:id).first

      child = store.create_action(action: { description: 'child', broadcast_intent: :none, nlocktime: 0 },
                                  inputs: [{ output_id: parent_output_id, vin: 0 }])

      expect do
        store.reject_action(action_id: parent[:id])
      end.to raise_error(BSV::Wallet::CannotRejectInternalActionError)

      # Rollback: both rows survive.
      expect(BSV::Wallet::Store::Models::Action[parent[:id]]).not_to be_nil
      expect(BSV::Wallet::Store::Models::Action[child[:id]]).not_to be_nil
      expect(input_output.reload.spendable?).to be false
    end

    it 'raises CannotRejectAcceptedActionError when target tx_status is in ArcStatus::ACCEPTED' do
      result = store.create_action(action: { description: 'mined target', nlocktime: 0 })
      store.sign_action(action_id: result[:id], wtxid: SecureRandom.random_bytes(32),
                        raw_tx: SecureRandom.random_bytes(100))
      BSV::Wallet::Store::Models::Broadcast.where(action_id: result[:id]).update(tx_status: 'MINED')

      expect do
        store.reject_action(action_id: result[:id])
      end.to raise_error(BSV::Wallet::CannotRejectAcceptedActionError, /tx_status=MINED/)

      # Rollback: row still exists.
      expect(BSV::Wallet::Store::Models::Action[result[:id]]).not_to be_nil
    end

    it 'raises CannotRejectAcceptedActionError when a descendant has accepted tx_status' do
      input_output = create_funded_output(satoshis: 1000)
      parent = store.create_action(action: { description: 'rejected parent', nlocktime: 0 },
                                   inputs: [{ output_id: input_output.id, vin: 0 }])
      store.sign_action(
        action_id: parent[:id], wtxid: SecureRandom.random_bytes(32),
        raw_tx: SecureRandom.random_bytes(100),
        outputs: [{ satoshis: 900, vout: 0, locking_script: SecureRandom.random_bytes(25),
                    derivation_prefix: SecureRandom.uuid, derivation_suffix: '1',
                    sender_identity_key: 'self' }]
      )
      store.record_broadcast_result(action_id: parent[:id], tx_status: 'QUEUED')
      parent_output_id = BSV::Wallet::Store::Models::Output.where(action_id: parent[:id]).select_map(:id).first

      child = store.create_action(action: { description: 'accepted child', nlocktime: 0 },
                                  inputs: [{ output_id: parent_output_id, vin: 0 }])
      store.sign_action(action_id: child[:id], wtxid: SecureRandom.random_bytes(32),
                        raw_tx: SecureRandom.random_bytes(100))
      BSV::Wallet::Store::Models::Broadcast.where(action_id: child[:id]).update(tx_status: 'SEEN_ON_NETWORK')

      expect do
        store.reject_action(action_id: parent[:id])
      end.to raise_error(BSV::Wallet::CannotRejectAcceptedActionError, /tx_status=SEEN_ON_NETWORK/)

      # Rollback: both rows survive.
      expect(BSV::Wallet::Store::Models::Action[parent[:id]]).not_to be_nil
      expect(BSV::Wallet::Store::Models::Action[child[:id]]).not_to be_nil
    end
  end

  describe '#child_actions_of' do
    it 'returns action_ids whose inputs consume the given action\'s outputs' do
      input_output = create_funded_output(satoshis: 1000)
      parent = store.create_action(action: { description: 'parent', nlocktime: 0 },
                                   inputs: [{ output_id: input_output.id, vin: 0 }])
      store.sign_action(
        action_id: parent[:id], wtxid: SecureRandom.random_bytes(32),
        raw_tx: SecureRandom.random_bytes(100),
        outputs: [{ satoshis: 900, vout: 0, locking_script: SecureRandom.random_bytes(25),
                    derivation_prefix: SecureRandom.uuid, derivation_suffix: '1',
                    sender_identity_key: 'self' }]
      )
      store.record_broadcast_result(action_id: parent[:id], tx_status: 'QUEUED')
      parent_output_id = BSV::Wallet::Store::Models::Output.where(action_id: parent[:id]).select_map(:id).first

      child = store.create_action(action: { description: 'child', nlocktime: 0 },
                                  inputs: [{ output_id: parent_output_id, vin: 0 }])

      expect(store.child_actions_of(action_id: parent[:id])).to contain_exactly(child[:id])
      expect(store.child_actions_of(action_id: child[:id])).to be_empty
    end
  end

  describe '#increment_broadcast_retry' do
    it 'increments the retry_count column for an action\'s broadcast row' do
      result = store.create_action(action: { description: 'retry test', nlocktime: 0 })
      store.sign_action(action_id: result[:id], wtxid: SecureRandom.random_bytes(32),
                        raw_tx: SecureRandom.random_bytes(100))

      expect(BSV::Wallet::Store::Models::Broadcast.first(action_id: result[:id]).retry_count).to eq(0)
      store.increment_broadcast_retry(action_id: result[:id])
      store.increment_broadcast_retry(action_id: result[:id])
      expect(BSV::Wallet::Store::Models::Broadcast.first(action_id: result[:id]).retry_count).to eq(2)
    end
  end

  describe 'outputs.action_id FK (RESTRICT)' do
    it 'blocks deleting an action that has promoted outputs' do
      # A send action (intent != 'none') so the RESTRICT FK on outputs.action_id
      # — not the prevent_internal_action_delete trigger — is the blocker under
      # test. Promote via the broadcast path so a promotions/spendable row
      # exists alongside the output.
      result = store.create_action(action: { description: 'with outputs', broadcast_intent: :delayed, nlocktime: 0 })
      store.sign_action(
        action_id: result[:id], wtxid: SecureRandom.random_bytes(32),
        raw_tx: SecureRandom.random_bytes(100),
        outputs: [{
          satoshis: 1000, vout: 0, locking_script: SecureRandom.random_bytes(25),
          derivation_prefix: SecureRandom.uuid, derivation_suffix: '1',
          sender_identity_key: 'self'
        }]
      )
      store.record_broadcast_result(action_id: result[:id], tx_status: 'QUEUED')

      # Postgres aborts the whole tx on a FK violation; isolate the failing
      # delete in its own savepoint so the surrounding shared_context tx
      # stays usable for the post-condition assertion.
      #
      # Match on Sequel::DatabaseError + message: Postgres 18 reports RESTRICT
      # violations with SQLSTATE 23001 (PG::RestrictViolation), which Sequel
      # doesn't map to ForeignKeyConstraintViolation.
      store.db.transaction(savepoint: true) do
        expect { BSV::Wallet::Store::Models::Action.where(id: result[:id]).delete }
          .to raise_error(Sequel::DatabaseError, /foreign key/i)
        raise Sequel::Rollback
      end
      expect(BSV::Wallet::Store::Models::Action[result[:id]]).not_to be_nil
    end

    it 'rejects inserting an output with NULL action_id' do
      expect do
        BSV::Wallet::Store::Models::Output.create(
          action_id: nil, satoshis: 100, vout: 0,
          locking_script: SecureRandom.random_bytes(25),
          derivation_prefix: SecureRandom.uuid, derivation_suffix: '1',
          sender_identity_key: 'self'
        )
      end.to raise_error(Sequel::NotNullConstraintViolation)
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
      action = store.create_action(action: { description: 'output source', broadcast_intent: :none, nlocktime: 0 })
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
      action = store.create_action(action: { description: 'source', broadcast_intent: :none, nlocktime: 0 })
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
      action = store.create_action(action: { description: 'source', broadcast_intent: :none, nlocktime: 0 })
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

  # --- Proofs ---

  describe '#save_proof' do
    let(:wtxid) { SecureRandom.random_bytes(32) }
    let(:proof_data) do
      {
        height: 800_000,
        block_index: 42,
        merkle_path: SecureRandom.random_bytes(64),
        raw_tx: SecureRandom.random_bytes(100),
        block_hash: SecureRandom.random_bytes(32),
        merkle_root: SecureRandom.random_bytes(32)
      }
    end

    it 'creates a new proof' do
      id = store.save_proof(wtxid: wtxid, proof: proof_data)
      expect(id).to be_a(Integer)
    end

    it 'upserts an existing proof' do
      id1 = store.save_proof(wtxid: wtxid, proof: proof_data)
      new_merkle_root = SecureRandom.random_bytes(32)
      id2 = store.save_proof(wtxid: wtxid, proof: proof_data.merge(
        height: 800_001, merkle_root: new_merkle_root
      ))

      expect(id2).to eq(id1)
      record = BSV::Wallet::Store::Models::TxProof[id1]
      expect(record.block.height).to eq(800_001)
    end

    it 'preserves binary data' do
      store.save_proof(wtxid: wtxid, proof: proof_data)
      record = BSV::Wallet::Store::Models::TxProof.first(wtxid: Sequel.blob(wtxid))

      expect(record.wtxid.encoding).to eq(Encoding::BINARY)
      expect(record.merkle_path.encoding).to eq(Encoding::BINARY)
      expect(record.block.block_hash.encoding).to eq(Encoding::BINARY)
      expect(record.merkle_path).to eq(proof_data[:merkle_path])
    end

    it 'reuses an existing block for proofs at the same height' do
      wtxid2 = SecureRandom.random_bytes(32)
      id1 = store.save_proof(wtxid: wtxid, proof: proof_data)
      id2 = store.save_proof(wtxid: wtxid2, proof: proof_data.merge(
        raw_tx: SecureRandom.random_bytes(100)
      ))

      proof1 = BSV::Wallet::Store::Models::TxProof[id1]
      proof2 = BSV::Wallet::Store::Models::TxProof[id2]
      expect(proof1.block_id).to eq(proof2.block_id)
      expect(BSV::Wallet::Store::Models::Block.where(height: 800_000).count).to eq(1)
    end

    it 'rejects a proof with merkle_path but no resolvable block (#219)' do
      # path_requires_block CHECK: a merkle_path without block context is
      # unverifiable (no root to check against). Without merkle_root,
      # find_or_create_block returns nil — the DB rejects the insert.
      #
      # Use a deterministic, unparseable merkle_path so this test can't
      # flake on the astronomically-rare chance that random 64 bytes
      # decode as a valid BUMP and let find_or_create_block derive a root.
      proof_without_root = proof_data
                           .except(:merkle_root, :block_hash)
                           .merge(merkle_path: "\x00".b)
      expect { store.save_proof(wtxid: wtxid, proof: proof_without_root) }
        .to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'saves a proof with block_id but no merkle_path (confirmed but unproven)' do
      proof_block_only = proof_data.except(:merkle_path)
      id = store.save_proof(wtxid: wtxid, proof: proof_block_only)

      record = BSV::Wallet::Store::Models::TxProof[id]
      expect(record.block_id).not_to be_nil
      expect(record.merkle_path).to be_nil
    end

    it 'derives the merkle root in wire-order bytes (chain_tracker alignment)' do
      # Two writers touch the blocks table:
      #   - find_or_create_block (this path) via derive_merkle_root
      #   - chain_tracker.persist_block via WoC's display-order hex
      # Both must agree on the DB's canonical byte order: wire-order
      # (the wtxid convention — display-order conversion happens at the
      # ChainTracker boundary on ingress and on SDK-output comparison).
      # Regression for the bug surfaced by HLR #129's 3-wallet cascade:
      # the chain_tracker's WoC path was storing display-order bytes
      # while this writer stored wire-order. ChainTracker now converts
      # both at ingress, so both writers now agree on wire-order in DB.
      wtxid_bin = SecureRandom.random_bytes(32)
      sibling = SecureRandom.random_bytes(32)
      mp = BSV::Transaction::MerklePath.new(
        block_height: 800_000,
        path: [[
          BSV::Transaction::MerklePath::PathElement.new(offset: 0, hash: wtxid_bin, txid: true),
          BSV::Transaction::MerklePath::PathElement.new(offset: 1, hash: sibling)
        ]]
      )

      proof_with_path = proof_data
                        .except(:merkle_root)
                        .merge(merkle_path: mp.to_binary, height: 800_000)
      store.save_proof(wtxid: wtxid, proof: proof_with_path)

      record = BSV::Wallet::Store::Models::Block.first(height: 800_000)
      # Mirror Store#derive_merkle_root's call shape: compute_root with no args,
      # which picks the first hashed leaf from path[0] (matches production).
      expect(record.merkle_root).to eq(mp.compute_root)
    end
  end

  describe '#find_proof' do
    let(:wtxid) { SecureRandom.random_bytes(32) }
    let(:proof_data) do
      {
        height: 800_000,
        block_index: 42,
        merkle_path: SecureRandom.random_bytes(64),
        raw_tx: SecureRandom.random_bytes(100),
        block_hash: SecureRandom.random_bytes(32),
        merkle_root: SecureRandom.random_bytes(32)
      }
    end

    it 'returns the proof hash' do
      store.save_proof(wtxid: wtxid, proof: proof_data)
      result = store.find_proof(wtxid: wtxid)

      expect(result[:height]).to eq(800_000)
      expect(result[:block_index]).to eq(42)
      expect(result[:wtxid]).to eq(wtxid)
    end

    it 'returns nil when not found' do
      expect(store.find_proof(wtxid: SecureRandom.random_bytes(32))).to be_nil
    end
  end

  describe '#proof_exists?' do
    let(:wtxid) { SecureRandom.random_bytes(32) }
    let(:proof_data) do
      {
        height: 800_000,
        block_index: 42,
        merkle_path: SecureRandom.random_bytes(64),
        raw_tx: SecureRandom.random_bytes(100),
        block_hash: SecureRandom.random_bytes(32),
        merkle_root: SecureRandom.random_bytes(32)
      }
    end

    it 'returns true when proof exists' do
      store.save_proof(wtxid: wtxid, proof: proof_data)
      expect(store.proof_exists?(wtxid: wtxid)).to be true
    end

    it 'returns false when no proof' do
      expect(store.proof_exists?(wtxid: SecureRandom.random_bytes(32))).to be false
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
      source_action = BSV::Wallet::Store::Models::Action.create(description: 'test action',
                                                                broadcast_intent: 'none',
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
      # spendable.action_id is FK'd to promotions(action_id) (#307) — the
      # internal-path promotions row must precede the spendable row.
      BSV::Wallet::Store::Models::Promotion.create(action_id: source_action.id, intent: 'none', authorising_status: nil)
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
      source_action = BSV::Wallet::Store::Models::Action.create(description: 'test action', broadcast_intent: 'none')
      output = BSV::Wallet::Store::Models::Output.create(
        action_id: source_action.id, satoshis: 500, vout: 0,
        locking_script: SecureRandom.random_bytes(25),
        output_type: 'root'
      )
      # spendable.action_id is FK'd to promotions(action_id) (#307).
      BSV::Wallet::Store::Models::Promotion.create(action_id: source_action.id, intent: 'none', authorising_status: nil)
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
        BSV::Wallet::Store::Models::Action.create(description: 'test action',
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
      lock_action = BSV::Wallet::Store::Models::Action.create(description: 'test action', nlocktime: 0)
      BSV::Wallet::Store::Models::Input.create(action_id: lock_action.id, output_id: output.id, vin: 0)

      candidates = store.find_spendable(satoshis: 9999, basket: 'default')
      expect(candidates.map { |c| c[:id] }).not_to include(output.id)
    end
  end

  # --- Block Headers ---

  describe '#record_block_header' do
    it 'inserts a new block from hex strings' do
      merkle_root_hex = 'aa' * 32
      block_hash_hex = 'bb' * 32

      store.record_block_header(height: 100, merkle_root: merkle_root_hex, block_hash: block_hash_hex)

      block = BSV::Wallet::Store::Models::Block.first(height: 100)
      expect(block).not_to be_nil
      expect(block.merkle_root).to eq([merkle_root_hex].pack('H*'))
      expect(block.block_hash).to eq([block_hash_hex].pack('H*'))
    end

    it 'inserts a new block from binary values' do
      merkle_root_bin = SecureRandom.random_bytes(32)
      block_hash_bin = SecureRandom.random_bytes(32)

      store.record_block_header(height: 200, merkle_root: merkle_root_bin, block_hash: block_hash_bin)

      block = BSV::Wallet::Store::Models::Block.first(height: 200)
      expect(block.merkle_root).to eq(merkle_root_bin)
      expect(block.block_hash).to eq(block_hash_bin)
    end

    it 'upserts when height already exists' do
      original_root = SecureRandom.random_bytes(32)
      updated_root = SecureRandom.random_bytes(32)

      store.record_block_header(height: 300, merkle_root: original_root)
      store.record_block_header(height: 300, merkle_root: updated_root)

      block = BSV::Wallet::Store::Models::Block.first(height: 300)
      expect(block.merkle_root).to eq(updated_root)
    end

    it 'handles nil block_hash' do
      store.record_block_header(height: 400, merkle_root: SecureRandom.random_bytes(32))

      block = BSV::Wallet::Store::Models::Block.first(height: 400)
      expect(block.block_hash).to be_nil
    end
  end

  describe '#find_block' do
    it 'returns block data for a known height' do
      merkle_root = SecureRandom.random_bytes(32)
      block_hash = SecureRandom.random_bytes(32)
      store.record_block_header(height: 500, merkle_root: merkle_root, block_hash: block_hash)

      result = store.find_block(height: 500)

      expect(result).to eq({ height: 500, merkle_root: merkle_root, block_hash: block_hash })
    end

    it 'returns nil for unknown height' do
      expect(store.find_block(height: 999_999)).to be_nil
    end
  end

  describe '#max_block_height' do
    it 'returns nil when no blocks stored' do
      expect(store.max_block_height).to be_nil
    end

    it 'returns the highest stored height' do
      store.record_block_header(height: 10, merkle_root: SecureRandom.random_bytes(32))
      store.record_block_header(height: 50, merkle_root: SecureRandom.random_bytes(32))
      store.record_block_header(height: 30, merkle_root: SecureRandom.random_bytes(32))

      expect(store.max_block_height).to eq(50)
    end
  end

  # --- Broadcasts ---

  describe '#record_broadcast_result' do
    let(:action) do
      BSV::Wallet::Store::Models::Action.create(
        description: 'test action', nlocktime: 0,
        wtxid: SecureRandom.random_bytes(32),
        raw_tx: SecureRandom.random_bytes(100)
      )
    end

    it 'updates an existing broadcast record' do
      BSV::Wallet::Store::Models::Broadcast.create(action_id: action.id, intent: 'delayed', broadcast_at: Time.now - 60)

      result = store.record_broadcast_result(
        action_id: action.id, tx_status: 'MINED',
        block_hash: SecureRandom.random_bytes(32),
        block_height: 800_000
      )

      expect(result[:tx_status]).to eq('MINED')
      expect(result[:block_height]).to eq(800_000)
      expect(result[:block_hash]).not_to be_nil
      expect(result[:block_hash].encoding).to eq(Encoding::BINARY)
    end

    it 'decodes hex block_hash and merkle_path to binary' do
      BSV::Wallet::Store::Models::Broadcast.create(action_id: action.id, intent: 'delayed', broadcast_at: Time.now - 60)
      block_hash_hex = 'aa' * 32
      merkle_path_hex = 'bb' * 64

      result = store.record_broadcast_result(
        action_id: action.id, tx_status: 'MINED',
        block_hash: block_hash_hex, merkle_path: merkle_path_hex
      )

      expect(result[:block_hash]).to eq([block_hash_hex].pack('H*'))
      expect(result[:merkle_path]).to eq([merkle_path_hex].pack('H*'))
    end

    it 'returns provider in the result hash (NULL by default)' do
      BSV::Wallet::Store::Models::Broadcast.create(action_id: action.id, intent: 'delayed', broadcast_at: Time.now - 60)

      result = store.record_broadcast_result(action_id: action.id, tx_status: 'SEEN_ON_NETWORK')

      expect(result).to have_key(:provider)
      expect(result[:provider]).to be_nil
    end

    # Under the post-T2/T3 invariant, the broadcasts row is created atomically
    # with sign_action and broadcast_at is stamped pre-POST by
    # mark_broadcast_attempted. record_broadcast_result is only ever called
    # after that, with the ARC response in hand. A missing row indicates a
    # broken caller -- raise loudly rather than silently stubbing one in.
    it 'raises when no broadcasts row exists for the action' do
      expect do
        store.record_broadcast_result(action_id: action.id, tx_status: 'SEEN_ON_NETWORK')
      end.to raise_error(RuntimeError, /no broadcasts row/)
    end

    # The pre-POST stamp set by mark_broadcast_attempted is canonical;
    # record_broadcast_result must never touch broadcast_at, even on the
    # first response or on subsequent updates.
    it 'does not modify broadcast_at on first call' do
      original = Time.now - 120
      BSV::Wallet::Store::Models::Broadcast.create(action_id: action.id, intent: 'delayed', broadcast_at: original)

      store.record_broadcast_result(action_id: action.id, tx_status: 'SEEN_ON_NETWORK')

      broadcast = BSV::Wallet::Store::Models::Broadcast.first(action_id: action.id)
      expect(broadcast.broadcast_at.to_i).to eq(original.to_i)
    end

    it 'does not modify broadcast_at on subsequent calls (no double-stamping)' do
      original = Time.now - 120
      BSV::Wallet::Store::Models::Broadcast.create(action_id: action.id, intent: 'delayed', broadcast_at: original)

      store.record_broadcast_result(action_id: action.id, tx_status: 'SEEN_ON_NETWORK')
      store.record_broadcast_result(action_id: action.id, tx_status: 'MINED')

      broadcast = BSV::Wallet::Store::Models::Broadcast.first(action_id: action.id)
      expect(broadcast.broadcast_at.to_i).to eq(original.to_i)
    end

    # The resolution loop polls every ~30s and records a result on each pass.
    # Promotion now fires on every non-rejected status (#240), so the same
    # action is promoted repeatedly as the tx walks QUEUED -> RECEIVED ->
    # SEEN_ON_NETWORK -> MINED. That repeated promotion must be idempotent:
    # exactly one spendable row, the output promoted once, no errors. This
    # property is load-bearing now that promotion isn't gated on a single
    # ACCEPTED transition.
    it 'promotes the output exactly once across repeated non-rejected status updates' do
      BSV::Wallet::Store::Models::Broadcast.create(action_id: action.id, intent: 'delayed', broadcast_at: Time.now - 60)
      output = BSV::Wallet::Store::Models::Output.create(
        action_id: action.id, satoshis: 500, vout: 0,
        locking_script: SecureRandom.random_bytes(25),
        derivation_prefix: SecureRandom.uuid, derivation_suffix: '1',
        sender_identity_key: 'self'
      )

      %w[QUEUED RECEIVED ANNOUNCED_TO_NETWORK SEEN_ON_NETWORK MINED].each do |status|
        store.record_broadcast_result(action_id: action.id, tx_status: status)
      end

      # Exactly one promotions row (idempotent across the status walk; the
      # ON UPDATE CASCADE keeps authorising_status synced to the latest
      # tx_status) and exactly one spendable row.
      expect(BSV::Wallet::Store::Models::Promotion.where(action_id: action.id).count).to eq(1)
      expect(output.reload.spendable?).to be(true)
      expect(BSV::Wallet::Store::Models::Spendable.where(output_id: output.id).count).to eq(1)
    end
  end

  describe '#broadcast_status' do
    let(:action) do
      BSV::Wallet::Store::Models::Action.create(
        description: 'test action', nlocktime: 0,
        wtxid: SecureRandom.random_bytes(32),
        raw_tx: SecureRandom.random_bytes(100)
      )
    end

    it 'returns broadcast status for an action' do
      BSV::Wallet::Store::Models::Broadcast.create(action_id: action.id, intent: 'delayed')
      store.record_broadcast_result(action_id: action.id, tx_status: 'SEEN_ON_NETWORK')

      result = store.broadcast_status(action_id: action.id)
      expect(result[:tx_status]).to eq('SEEN_ON_NETWORK')
    end

    it 'returns nil when no broadcast exists' do
      expect(store.broadcast_status(action_id: action.id)).to be_nil
    end
  end

  describe '#pending_resolutions' do
    let(:action) do
      BSV::Wallet::Store::Models::Action.create(
        description: 'test action', nlocktime: 0,
        wtxid: SecureRandom.random_bytes(32),
        raw_tx: SecureRandom.random_bytes(100)
      )
    end

    it 'returns attempted, non-terminal broadcasts' do
      BSV::Wallet::Store::Models::Broadcast.create(
        action_id: action.id, intent: 'delayed',
        broadcast_at: Time.now - 60
      )

      results = store.pending_resolutions(limit: 10)
      expect(results.size).to eq(1)
      expect(results.first[:action_id]).to eq(action.id)
    end

    it 'includes recently-attempted rows (no staleness predicate)' do
      BSV::Wallet::Store::Models::Broadcast.create(
        action_id: action.id, intent: 'delayed',
        broadcast_at: Time.now
      )

      results = store.pending_resolutions(limit: 10)
      expect(results.size).to eq(1)
      expect(results.first[:action_id]).to eq(action.id)
    end

    it 'includes crash-recovery rows (broadcast_at set, tx_status NULL)' do
      BSV::Wallet::Store::Models::Broadcast.create(
        action_id: action.id, intent: 'delayed',
        broadcast_at: Time.now - 60,
        tx_status: nil
      )

      results = store.pending_resolutions(limit: 10)
      expect(results.size).to eq(1)
      expect(results.first[:action_id]).to eq(action.id)
    end

    it 'excludes broadcasts with terminal status' do
      BSV::Wallet::Store::Models::Broadcast.create(
        action_id: action.id, intent: 'delayed',
        broadcast_at: Time.now - 60,
        tx_status: 'MINED'
      )

      results = store.pending_resolutions(limit: 10)
      expect(results).to be_empty
    end

    # MINED_IN_STALE_BLOCK is intentionally transient -- the tx is on a fork
    # but valid; the poll loop must continue checking until it lands on the
    # main chain (see docs/wallet-events.md and HLR #182).
    it 'includes MINED_IN_STALE_BLOCK rows (transient, not terminal)' do
      BSV::Wallet::Store::Models::Broadcast.create(
        action_id: action.id, intent: 'delayed',
        broadcast_at: Time.now - 60,
        tx_status: 'MINED_IN_STALE_BLOCK'
      )

      results = store.pending_resolutions(limit: 10)
      expect(results.size).to eq(1)
      expect(results.first[:action_id]).to eq(action.id)
    end

    it 'excludes queued rows (broadcast_at IS NULL)' do
      BSV::Wallet::Store::Models::Broadcast.create(action_id: action.id, intent: 'delayed')

      results = store.pending_resolutions(limit: 10)
      expect(results).to be_empty
    end

    it 'returns empty array when none pending' do
      expect(store.pending_resolutions).to eq([])
    end
  end

  describe '#pending_submissions' do
    let(:action) do
      BSV::Wallet::Store::Models::Action.create(
        description: 'test action', nlocktime: 0,
        wtxid: SecureRandom.random_bytes(32),
        raw_tx: SecureRandom.random_bytes(100)
      )
    end

    it 'returns broadcasts queued for an initial submission (broadcast_at IS NULL)' do
      BSV::Wallet::Store::Models::Broadcast.create(action_id: action.id, intent: 'delayed')

      results = store.pending_submissions(limit: 10)
      expect(results.size).to eq(1)
      expect(results.first[:action_id]).to eq(action.id)
      expect(results.first[:broadcast_at]).to be_nil
    end

    it 'excludes broadcasts that have already been attempted' do
      BSV::Wallet::Store::Models::Broadcast.create(
        action_id: action.id, intent: 'delayed',
        broadcast_at: Time.now
      )

      expect(store.pending_submissions(limit: 10)).to be_empty
    end

    it 'excludes attempted rows regardless of tx_status' do
      BSV::Wallet::Store::Models::Broadcast.create(
        action_id: action.id, intent: 'delayed',
        broadcast_at: Time.now - 60,
        tx_status: 'SEEN_ON_NETWORK'
      )

      expect(store.pending_submissions(limit: 10)).to be_empty
    end

    it 'respects the limit' do
      3.times do |i|
        a = BSV::Wallet::Store::Models::Action.create(
          description: "test action #{i}", nlocktime: 0,
          wtxid: SecureRandom.random_bytes(32),
          raw_tx: SecureRandom.random_bytes(100)
        )
        BSV::Wallet::Store::Models::Broadcast.create(action_id: a.id, intent: 'delayed')
      end

      expect(store.pending_submissions(limit: 2).size).to eq(2)
    end

    it 'returns empty array when none queued' do
      expect(store.pending_submissions).to eq([])
    end
  end

  describe '#mark_broadcast_attempted' do
    let(:action) do
      BSV::Wallet::Store::Models::Action.create(
        description: 'test action', nlocktime: 0,
        wtxid: SecureRandom.random_bytes(32),
        raw_tx: SecureRandom.random_bytes(100)
      )
    end

    it 'stamps broadcast_at on a queued row' do
      BSV::Wallet::Store::Models::Broadcast.create(action_id: action.id, intent: 'delayed')
      before = Time.now

      store.mark_broadcast_attempted(action_id: action.id)

      broadcast = BSV::Wallet::Store::Models::Broadcast.first(action_id: action.id)
      expect(broadcast.broadcast_at).not_to be_nil
      expect(broadcast.broadcast_at).to be >= before
    end

    it 'is idempotent — does not overwrite an existing broadcast_at' do
      original = Time.now - 60
      BSV::Wallet::Store::Models::Broadcast.create(action_id: action.id, intent: 'delayed', broadcast_at: original)

      store.mark_broadcast_attempted(action_id: action.id)

      broadcast = BSV::Wallet::Store::Models::Broadcast.first(action_id: action.id)
      expect(broadcast.broadcast_at.to_i).to eq(original.to_i)
    end

    it 'does not leave tx_status set (crash-recovery signal)' do
      BSV::Wallet::Store::Models::Broadcast.create(action_id: action.id, intent: 'delayed')

      store.mark_broadcast_attempted(action_id: action.id)

      broadcast = BSV::Wallet::Store::Models::Broadcast.first(action_id: action.id)
      expect(broadcast.tx_status).to be_nil
    end

    it 'removes the row from pending_submissions results' do
      BSV::Wallet::Store::Models::Broadcast.create(action_id: action.id, intent: 'delayed')
      expect(store.pending_submissions.map { |b| b[:action_id] }).to include(action.id)

      store.mark_broadcast_attempted(action_id: action.id)

      expect(store.pending_submissions.map { |b| b[:action_id] }).not_to include(action.id)
    end

    it 'raises when no broadcasts row exists for the action (invariant violation)' do
      # Action exists but no broadcasts row -- e.g., action created with
      # broadcast_intent: 'none'. Stamping in this state would silently no-op
      # and leave the action untracked by either discovery loop.
      expect do
        store.mark_broadcast_attempted(action_id: action.id)
      end.to raise_error(RuntimeError, /no broadcasts row/)
    end
  end

  describe '#clear_broadcast_attempted' do
    let(:action) do
      BSV::Wallet::Store::Models::Action.create(
        description: 'test action', nlocktime: 0,
        wtxid: SecureRandom.random_bytes(32),
        raw_tx: SecureRandom.random_bytes(100)
      )
    end

    it 'reverts broadcast_at to NULL on an in-flight row (tx_status NULL)' do
      stamped = Time.now - 30
      BSV::Wallet::Store::Models::Broadcast.create(
        action_id: action.id, intent: 'delayed', broadcast_at: stamped
      )

      store.clear_broadcast_attempted(action_id: action.id)

      broadcast = BSV::Wallet::Store::Models::Broadcast.first(action_id: action.id)
      expect(broadcast.broadcast_at).to be_nil
    end

    it 'returns the row to pending_submissions' do
      BSV::Wallet::Store::Models::Broadcast.create(
        action_id: action.id, intent: 'delayed', broadcast_at: Time.now - 30
      )
      expect(store.pending_submissions.map { |b| b[:action_id] }).not_to include(action.id)

      store.clear_broadcast_attempted(action_id: action.id)

      expect(store.pending_submissions.map { |b| b[:action_id] }).to include(action.id)
    end

    it 'guards against the concurrent-SSE race: no-op when tx_status has progressed' do
      # The listener applied SEEN concurrent with our 503 path -- the row
      # has moved on. The clear must not roll state back.
      stamped = Time.now - 30
      BSV::Wallet::Store::Models::Broadcast.create(
        action_id: action.id, intent: 'delayed',
        broadcast_at: stamped, tx_status: 'SEEN_ON_NETWORK'
      )

      store.clear_broadcast_attempted(action_id: action.id)

      broadcast = BSV::Wallet::Store::Models::Broadcast.first(action_id: action.id)
      expect(broadcast.broadcast_at).not_to be_nil
      expect(broadcast.tx_status).to eq('SEEN_ON_NETWORK')
    end

    it 'is a no-op on an already-cleared row (idempotent)' do
      BSV::Wallet::Store::Models::Broadcast.create(action_id: action.id, intent: 'delayed')

      expect { store.clear_broadcast_attempted(action_id: action.id) }.not_to raise_error

      broadcast = BSV::Wallet::Store::Models::Broadcast.first(action_id: action.id)
      expect(broadcast.broadcast_at).to be_nil
    end

    it 'is a no-op when no broadcasts row exists for the action' do
      # Mirrors the lenient shape of pending_submissions / poll discovery:
      # missing row is not an invariant violation here (caller's 503 path
      # may be re-running a clear from a partial earlier attempt).
      expect { store.clear_broadcast_attempted(action_id: action.id) }.not_to raise_error
    end

    # Listener-wins interleaving: the SSE listener applies SEEN via
    # record_broadcast_result, THEN the 503 path runs clear. Deterministic
    # ordering -- transactions are sequential, but the test exercises the
    # same row-state outcome that a real race would produce when the
    # listener commits first. End-state: SEEN intact, broadcast_at stays
    # stamped (row sits in the resolution set, not back in the queued set).
    it 'listener-wins interleaving: record_broadcast_result then clear leaves SEEN intact' do
      stamped = Time.now - 30
      BSV::Wallet::Store::Models::Broadcast.create(
        action_id: action.id, intent: 'delayed', broadcast_at: stamped
      )

      # Step 1 -- listener delivers SEEN. This is what
      # Store::EventApplicator#apply would do off an SSE frame.
      store.record_broadcast_result(
        action_id: action.id, tx_status: 'SEEN_ON_NETWORK',
        arc_status: 200, block_hash: nil, block_height: nil,
        merkle_path: nil, extra_info: nil, competing_txs: nil
      )

      # Step 2 -- 503 path runs clear. Must be a no-op under the
      # tx_status: nil guard.
      store.clear_broadcast_attempted(action_id: action.id)

      broadcast = BSV::Wallet::Store::Models::Broadcast.first(action_id: action.id)
      expect(broadcast.tx_status).to eq('SEEN_ON_NETWORK')
      expect(broadcast.broadcast_at).not_to be_nil
    end

    # Clear-wins interleaving: the 503 path runs clear, THEN the listener
    # applies SEEN. The row returns to the queued set briefly, then the
    # listener's record_broadcast_result records SEEN on top of a
    # cleared-row -- the SEEN status is the ground truth and dominates.
    # This is a permitted no-loss outcome: the row ends up in the same
    # eventual state (SEEN tx_status), only the broadcast_at timing
    # differs from the listener-wins case.
    it 'clear-wins interleaving: clear then record_broadcast_result still records SEEN' do
      stamped = Time.now - 30
      BSV::Wallet::Store::Models::Broadcast.create(
        action_id: action.id, intent: 'delayed', broadcast_at: stamped
      )

      store.clear_broadcast_attempted(action_id: action.id)
      store.record_broadcast_result(
        action_id: action.id, tx_status: 'SEEN_ON_NETWORK',
        arc_status: 200, block_hash: nil, block_height: nil,
        merkle_path: nil, extra_info: nil, competing_txs: nil
      )

      broadcast = BSV::Wallet::Store::Models::Broadcast.first(action_id: action.id)
      expect(broadcast.tx_status).to eq('SEEN_ON_NETWORK')
    end
  end

  # --- Pending Proofs ---

  describe '#pending_proofs' do
    def create_signed_action(broadcast_intent: 'delayed', tx_proof_id: nil)
      action = BSV::Wallet::Store::Models::Action.create(
        description: 'test action', nlocktime: 0,
        broadcast_intent: broadcast_intent,
        wtxid: SecureRandom.random_bytes(32),
        raw_tx: SecureRandom.random_bytes(100)
      )
      action.update(tx_proof_id: tx_proof_id) if tx_proof_id
      action
    end

    it 'returns actions that need proofs' do
      action = create_signed_action
      results = store.pending_proofs
      expect(results.size).to eq(1)
      expect(results.first[:id]).to eq(action.id)
      expect(results.first[:wtxid]).to eq(action.wtxid)
    end

    it 'excludes actions with tx_proof_id set' do
      action = create_signed_action
      proof_id = store.save_proof(wtxid: action.wtxid, proof: {
                                    height: 800_000, block_index: 1,
                                    merkle_path: SecureRandom.random_bytes(64),
                                    raw_tx: action.raw_tx,
                                    merkle_root: SecureRandom.random_bytes(32)
                                  })
      store.link_proof(action_id: action.id, tx_proof_id: proof_id)
      expect(store.pending_proofs).to be_empty
    end

    it 'excludes actions with broadcast none' do
      create_signed_action(broadcast_intent: 'none')
      expect(store.pending_proofs).to be_empty
    end

    it 'excludes unsigned actions (no wtxid)' do
      BSV::Wallet::Store::Models::Action.create(
        description: 'unsigned', nlocktime: 0, broadcast_intent: 'delayed'
      )
      expect(store.pending_proofs).to be_empty
    end

    it 'respects the limit parameter' do
      3.times { create_signed_action }
      results = store.pending_proofs(limit: 2)
      expect(results.size).to eq(2)
    end

    it 'returns empty array when nothing pending' do
      expect(store.pending_proofs).to eq([])
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
      result = store.create_action(action: { description: 'nosend', nlocktime: 0, broadcast_intent: :none })
      store.sign_action(action_id: result[:id], wtxid: SecureRandom.random_bytes(32),
                        raw_tx: SecureRandom.random_bytes(100))
      BSV::Wallet::Store::Models::Action.where(id: result[:id]).update(created_at: Time.now - 600)

      store.reap_stale_actions(threshold: 300)
      expect(BSV::Wallet::Store::Models::Action[result[:id]]).not_to be_nil
    end

    it 'does not reap a promoted send action' do
      # A send action (intent != 'none') that has been broadcast-accepted and
      # so carries a promotions row. The reaper protects promoted actions; only
      # unpromoted, stale, broadcast-intent send actions are eligible.
      result = store.create_action(action: { description: 'promoted', broadcast_intent: :delayed, nlocktime: 0 })
      store.sign_action(
        action_id: result[:id], wtxid: SecureRandom.random_bytes(32),
        raw_tx: SecureRandom.random_bytes(100),
        outputs: [
          { satoshis: 500, vout: 0, locking_script: SecureRandom.random_bytes(25),
            derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
        ]
      )
      store.record_broadcast_result(action_id: result[:id], tx_status: 'QUEUED')
      expect(BSV::Wallet::Store::Models::Promotion.where(action_id: result[:id]).any?).to be(true)
      BSV::Wallet::Store::Models::Action.where(id: result[:id]).update(created_at: Time.now - 600)

      store.reap_stale_actions(threshold: 300)
      expect(BSV::Wallet::Store::Models::Action[result[:id]]).not_to be_nil
    end
  end
end
