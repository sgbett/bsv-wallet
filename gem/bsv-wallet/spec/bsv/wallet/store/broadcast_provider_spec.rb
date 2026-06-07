# frozen_string_literal: true

require_relative 'shared_context'

RSpec.describe BSV::Wallet::Store, :store do
  describe '#record_broadcast_provider' do
    let(:wtxid) { SecureRandom.random_bytes(32) }
    let(:action) do
      BSV::Wallet::Store::Models::Action.create(
        outgoing: true, description: 'test action', nlocktime: 0,
        wtxid: Sequel.blob(wtxid),
        raw_tx: SecureRandom.random_bytes(100)
      )
    end

    it 'writes the provider name onto the broadcasts row matching the wtxid' do
      BSV::Wallet::Store::Models::Broadcast.create(action_id: action.id, intent: 'delayed')

      rows = store.record_broadcast_provider(wtxid: wtxid, provider: 'GorillaPool')

      expect(rows).to eq(1)
      expect(BSV::Wallet::Store::Models::Broadcast.first(action_id: action.id).provider).to eq('GorillaPool')
    end

    it 'overwrites an earlier provider value (last-broadcaster wins)' do
      BSV::Wallet::Store::Models::Broadcast.create(action_id: action.id, intent: 'delayed', provider: 'TAAL')

      store.record_broadcast_provider(wtxid: wtxid, provider: 'GorillaPool')

      expect(BSV::Wallet::Store::Models::Broadcast.first(action_id: action.id).provider).to eq('GorillaPool')
    end

    it 'is a no-op when no action matches the wtxid' do
      missing = SecureRandom.random_bytes(32)

      expect(store.record_broadcast_provider(wtxid: missing, provider: 'GorillaPool')).to eq(0)
    end

    it 'is a no-op when the matching action has no broadcasts row' do
      expect(store.record_broadcast_provider(wtxid: wtxid, provider: 'GorillaPool')).to eq(0)
    end

    it 'raises on an invalid wtxid' do
      expect { store.record_broadcast_provider(wtxid: 'not bytes', provider: 'X') }
        .to raise_error(ArgumentError, /wtxid/)
    end
  end

  describe '#broadcast_provider_for' do
    let(:wtxid) { SecureRandom.random_bytes(32) }
    let(:action) do
      BSV::Wallet::Store::Models::Action.create(
        outgoing: true, description: 'test action', nlocktime: 0,
        wtxid: Sequel.blob(wtxid),
        raw_tx: SecureRandom.random_bytes(100)
      )
    end

    it 'returns the persisted provider name' do
      BSV::Wallet::Store::Models::Broadcast.create(action_id: action.id, intent: 'delayed', provider: 'GorillaPool')

      expect(store.broadcast_provider_for(wtxid: wtxid)).to eq('GorillaPool')
    end

    it 'returns nil when no affinity recorded yet (NULL column)' do
      BSV::Wallet::Store::Models::Broadcast.create(action_id: action.id, intent: 'delayed')

      expect(store.broadcast_provider_for(wtxid: wtxid)).to be_nil
    end

    it 'returns nil when no action matches the wtxid' do
      missing = SecureRandom.random_bytes(32)

      expect(store.broadcast_provider_for(wtxid: missing)).to be_nil
    end

    it 'raises on an invalid wtxid' do
      expect { store.broadcast_provider_for(wtxid: 'not bytes') }
        .to raise_error(ArgumentError, /wtxid/)
    end
  end
end
