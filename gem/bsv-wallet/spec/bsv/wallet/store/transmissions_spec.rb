# frozen_string_literal: true

require_relative 'shared_context'

# Store-level specs for the Transmission domain's persistence (#385 Task 1).
# Methods live on +BSV::Wallet::Store+; this file proves the schema +
# behavioural contracts the Engine layer will sit on top of (#387 onward).
#
# Postgres-primary; the SQLite augmentation run proves the same behaviour
# at the level the SQLite backend supports (no regex CHECK; the augmented
# length + 02/03-prefix CHECK still rejects the malformed cases).
RSpec.describe BSV::Wallet::Store, :store do
  include_context 'store setup'

  let(:counterparty) { valid_identity_key }
  let(:other_party)  { "03#{SecureRandom.hex(32)}" }
  let(:wtxid_a) { SecureRandom.random_bytes(32) }
  let(:wtxid_b) { SecureRandom.random_bytes(32) }
  let(:wtxid_c) { SecureRandom.random_bytes(32) }

  def make_action(intent: 'delayed')
    BSV::Wallet::Store::Models::Action.create(
      description: 'transmission spec action', broadcast_intent: intent
    ).id
  end

  describe '#record_transmission' do
    it 'creates a row at grain (action, counterparty) and returns its id' do
      action_id = make_action
      id = store.record_transmission(action_id: action_id, counterparty: counterparty)

      expect(id).to be_a(Integer)
      row = BSV::Wallet::Store::Models::Transmission[id]
      expect(row.action_id).to eq(action_id)
      expect(row.counterparty).to eq(counterparty)
      expect(row.acked_at).to be_nil
    end

    it 'is idempotent per (action, peer): upserts in place, refreshes updated_at' do
      action_id = make_action
      first = store.record_transmission(action_id: action_id, counterparty: counterparty)
      first_row = BSV::Wallet::Store::Models::Transmission[first]
      original_updated = first_row.updated_at

      sleep 0.01 # ensure clock advances enough to observe the refresh
      second = store.record_transmission(action_id: action_id, counterparty: counterparty)

      expect(second).to eq(first)
      expect(
        BSV::Wallet::Store::Models::Transmission.where(action_id: action_id, counterparty: counterparty).count
      ).to eq(1)
      expect(first_row.reload.updated_at).to be > original_updated
    end

    it 'does NOT populate transmission_txids — that is reserved for ack time (HLR #385 two-phase)' do
      action_id = make_action
      id = store.record_transmission(action_id: action_id, counterparty: counterparty)

      expect(BSV::Wallet::Store::Models::TransmissionTxid.where(transmission_id: id).count).to eq(0)
      expect(store.transmission_known_wtxids(counterparty: counterparty)).to eq([])
    end

    it 'enforces grain uniqueness at the schema level' do
      action_id = make_action
      BSV::Wallet::Store::Models::Transmission.create(action_id: action_id, counterparty: counterparty)

      expect do
        BSV::Wallet::Store::Models::Transmission.create(action_id: action_id, counterparty: counterparty)
      end.to raise_error(Sequel::UniqueConstraintViolation)
    end

    # PG-only: concurrent threads need a committed parent row to FK against,
    # so this test runs against a side-channel DB connection (the :store
    # around-hook wraps each example in a rollback transaction visible only
    # to its own connection). On SQLite the same race is invisible because
    # writes serialise on the single file lock. The schema invariant —
    # UNIQUE (action_id, counterparty) — is identical on both; this proves
    # the upsert path eliminates the check-then-insert race on Postgres.
    it 'survives concurrent transmits at the same (action, peer) grain', :postgres do
      # Use a side Sequel pool so the test can write outside the spec's
      # +around(:store)+ transaction wrapper (rolled-back state on STORE_DB
      # is invisible to concurrent connections). Drive the inserts via raw
      # dataset access — NOT via +side_store.record_transmission+ — to
      # avoid +Store#bind_models!+, which globally rebinds every Sequel
      # model class's dataset to whichever connection the calling Store
      # wraps. Calling it here would point every model in the suite at
      # +side_db+ and, after the +ensure+ disconnect, leave subsequent
      # specs blocked on a dead pool. The property under test is the
      # PG-level UNIQUE serialisation of +INSERT … ON CONFLICT+, not the
      # specific code path through the Store wrapper.
      side_db = Sequel.connect(STORE_DB.opts[:uri] || STORE_DB.opts[:url])

      action_id = side_db[:actions].insert(
        description: 'concurrent transmit test',
        reference: SecureRandom.uuid,
        broadcast_intent: 'delayed'
      )

      barrier = Queue.new
      errors  = []
      ids     = []
      mutex   = Mutex.new
      now     = Time.now

      threads = Array.new(2) do
        Thread.new do
          barrier.pop
          rows = side_db[:transmissions]
                 .insert_conflict(
                   target: %i[action_id counterparty],
                   update: { updated_at: Sequel[:excluded][:updated_at] }
                 )
                 .returning(:id)
                 .insert(action_id: action_id, counterparty: counterparty,
                         created_at: now, updated_at: now)
          mutex.synchronize { ids << rows.first[:id] }
        rescue StandardError => e
          mutex.synchronize { errors << e }
        end
      end
      2.times { barrier << :go }
      threads.each(&:join)

      expect(errors).to be_empty
      expect(ids.uniq.size).to eq(1) # both threads converge on the same upserted row
      expect(
        side_db[:transmissions].where(action_id: action_id, counterparty: counterparty).count
      ).to eq(1)
    ensure
      if side_db
        if defined?(action_id) && action_id
          side_db[:transmissions].where(action_id: action_id).delete
          side_db[:actions].where(id: action_id).delete
        end
        side_db.disconnect
      end
    end
  end

  describe '#transmission_known_wtxids' do
    it 'unions wtxids across all transmissions to the counterparty, deduplicated' do
      a1 = make_action
      a2 = make_action
      store.mark_transmission_acked(
        action_id: store_transmit(a1, counterparty),
        counterparty: counterparty, wtxids: [wtxid_a, wtxid_b]
      )
      store.mark_transmission_acked(
        action_id: store_transmit(a2, counterparty),
        counterparty: counterparty, wtxids: [wtxid_b, wtxid_c]
      )

      expect(store.transmission_known_wtxids(counterparty: counterparty)).to contain_exactly(wtxid_a, wtxid_b, wtxid_c)
    end

    it 'is scoped per counterparty — does not leak another peer\'s set' do
      a1 = make_action
      a2 = make_action
      store.mark_transmission_acked(
        action_id: store_transmit(a1, counterparty),
        counterparty: counterparty, wtxids: [wtxid_a]
      )
      store.mark_transmission_acked(
        action_id: store_transmit(a2, other_party),
        counterparty: other_party, wtxids: [wtxid_b]
      )

      expect(store.transmission_known_wtxids(counterparty: counterparty)).to contain_exactly(wtxid_a)
      expect(store.transmission_known_wtxids(counterparty: other_party)).to contain_exactly(wtxid_b)
    end

    it 'returns [] for an unknown counterparty' do
      expect(store.transmission_known_wtxids(counterparty: other_party)).to eq([])
    end
  end

  describe '#mark_transmission_acked' do
    it 'sets acked_at and writes the known-set txids atomically' do
      action_id = make_action
      store.record_transmission(action_id: action_id, counterparty: counterparty)
      expect(BSV::Wallet::Store::Models::Transmission.first(action_id: action_id, counterparty: counterparty).acked_at).to be_nil

      at = Time.now
      returned = store.mark_transmission_acked(
        action_id: action_id, counterparty: counterparty,
        wtxids: [wtxid_a, wtxid_b], acked_at: at
      )

      row = BSV::Wallet::Store::Models::Transmission.first(action_id: action_id, counterparty: counterparty)
      expect(returned).to eq(row.id)
      expect(row.acked_at).to be_within(1).of(at)
      expect(store.transmission_known_wtxids(counterparty: counterparty)).to contain_exactly(wtxid_a, wtxid_b)
    end

    it 'is idempotent on re-ack: adds only new wtxids, no UNIQUE violation' do
      action_id = make_action
      store.record_transmission(action_id: action_id, counterparty: counterparty)
      store.mark_transmission_acked(
        action_id: action_id, counterparty: counterparty, wtxids: [wtxid_a, wtxid_b]
      )

      expect do
        store.mark_transmission_acked(
          action_id: action_id, counterparty: counterparty, wtxids: [wtxid_b, wtxid_c]
        )
      end.not_to raise_error

      expect(store.transmission_known_wtxids(counterparty: counterparty)).to contain_exactly(wtxid_a, wtxid_b, wtxid_c)
    end

    it 'accepts an empty wtxids array (no-op on the child table, still updates acked_at)' do
      action_id = make_action
      store.record_transmission(action_id: action_id, counterparty: counterparty)
      id = store.mark_transmission_acked(action_id: action_id, counterparty: counterparty, wtxids: [])

      expect(id).to be_a(Integer)
      row = BSV::Wallet::Store::Models::Transmission[id]
      expect(row.acked_at).not_to be_nil
      expect(BSV::Wallet::Store::Models::TransmissionTxid.where(transmission_id: id).count).to eq(0)
    end

    it 'returns nil when no transmission row matches' do
      expect(
        store.mark_transmission_acked(action_id: make_action, counterparty: counterparty, wtxids: [wtxid_a])
      ).to be_nil
    end

    it 'tolerates frozen-string wtxids' do
      action_id = make_action
      store.record_transmission(action_id: action_id, counterparty: counterparty)
      frozen = wtxid_a.dup.freeze

      expect do
        store.mark_transmission_acked(action_id: action_id, counterparty: counterparty, wtxids: [frozen])
      end.not_to raise_error
      expect(store.transmission_known_wtxids(counterparty: counterparty)).to contain_exactly(frozen)
    end
  end

  describe 'derived delivery status (principle of state)' do
    it 'has no status column — delivery is derived from acked_at presence' do
      cols = db.schema(:transmissions).map(&:first)
      expect(cols).not_to include(:status)
      expect(cols).to include(:acked_at)
    end

    it 'reserves the ack_signature column for the Phase 2 signed-ACK protocol (nullable bytea)' do
      schema = db.schema(:transmissions).to_h
      column = schema[:ack_signature]
      expect(column).not_to be_nil
      expect(column[:allow_null]).to be(true)
    end
  end

  describe 'shape CHECKs', :postgres do
    it 'rejects a counterparty whose length is not 66' do
      action_id = make_action
      expect do
        db.transaction(savepoint: true) do
          db[:transmissions].insert(action_id: action_id, counterparty: '02deadbeef')
        end
      end.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects an uncompressed-pubkey 04… prefix' do
      action_id = make_action
      bad = "04#{SecureRandom.hex(32)}"
      expect do
        db.transaction(savepoint: true) do
          db[:transmissions].insert(action_id: action_id, counterparty: bad)
        end
      end.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects non-hex characters in the body' do
      action_id = make_action
      bad = "02#{'z' * 64}"
      expect do
        db.transaction(savepoint: true) do
          db[:transmissions].insert(action_id: action_id, counterparty: bad)
        end
      end.to raise_error(Sequel::CheckConstraintViolation)
    end

    it 'rejects a transmission_txids.wtxid that is not 32 bytes' do
      action_id = make_action
      transmission_id = store.record_transmission(action_id: action_id, counterparty: counterparty)
      expect do
        db.transaction(savepoint: true) do
          db[:transmission_txids].insert(
            transmission_id: transmission_id,
            wtxid: Sequel.blob(SecureRandom.random_bytes(31))
          )
        end
      end.to raise_error(Sequel::CheckConstraintViolation)
    end
  end

  describe 'action_id CASCADE (reaper-cleanup parity)' do
    it 'cascades from action → transmissions → transmission_txids in one delete' do
      action_id = make_action
      transmission_id = store.record_transmission(action_id: action_id, counterparty: counterparty)
      store.mark_transmission_acked(
        action_id: action_id, counterparty: counterparty, wtxids: [wtxid_a, wtxid_b]
      )

      expect(BSV::Wallet::Store::Models::Transmission.where(action_id: action_id).count).to eq(1)
      expect(BSV::Wallet::Store::Models::TransmissionTxid.where(transmission_id: transmission_id).count).to eq(2)

      BSV::Wallet::Store::Models::Action.where(id: action_id).delete

      expect(BSV::Wallet::Store::Models::Transmission.where(action_id: action_id).count).to eq(0)
      expect(BSV::Wallet::Store::Models::TransmissionTxid.where(transmission_id: transmission_id).count).to eq(0)
    end

    it 'cascades from transmissions → transmission_txids when a transmission is deleted directly' do
      action_id = make_action
      transmission_id = store.record_transmission(action_id: action_id, counterparty: counterparty)
      store.mark_transmission_acked(
        action_id: action_id, counterparty: counterparty, wtxids: [wtxid_a]
      )

      BSV::Wallet::Store::Models::Transmission.where(id: transmission_id).delete

      expect(BSV::Wallet::Store::Models::TransmissionTxid.where(transmission_id: transmission_id).count).to eq(0)
    end
  end

  # Convenience helper: spec methods reading like "transmit then ack" want
  # the action_id back, not the transmission_id, so the call shape matches
  # what the Engine layer will do in #387.
  def store_transmit(action_id, peer)
    store.record_transmission(action_id: action_id, counterparty: peer)
    action_id
  end
end
