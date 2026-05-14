# frozen_string_literal: true

# WBIKD specs — generate_receive_address, list_receive_addresses, and the slot mechanism.

require_relative 'shared_context'

RSpec.describe BSV::Wallet::Engine, if: POSTGRES_AVAILABLE do # rubocop:disable RSpec/SpecFilePathFormat
  include_context 'engine setup'

  describe '#list_receive_addresses' do
    it 'returns empty array when no addresses have been generated' do
      result = engine_with_keys.list_receive_addresses

      expect(result).to eq([])
    end

    it 'returns one entry after one generate_receive_address call' do
      generated = engine_with_keys.generate_receive_address
      listed = engine_with_keys.list_receive_addresses

      expect(listed.length).to eq(1)
      expect(listed.first[:address]).to eq(generated[:address])
    end

    it 'returns multiple entries after multiple generate_receive_address calls' do
      first = engine_with_keys.generate_receive_address
      second = engine_with_keys.generate_receive_address
      listed = engine_with_keys.list_receive_addresses

      expect(listed.length).to eq(2)
      addresses = listed.map { |e| e[:address] }
      expect(addresses).to contain_exactly(first[:address], second[:address])
    end

    it 'includes all expected fields in each entry' do
      engine_with_keys.generate_receive_address
      entry = engine_with_keys.list_receive_addresses.first

      expect(entry).to have_key(:address)
      expect(entry).to have_key(:derivation_prefix)
      expect(entry).to have_key(:derivation_suffix)
      expect(entry).to have_key(:action_reference)
      expect(entry).to have_key(:created_at)
      expect(entry[:address]).to start_with('1')
      expect(entry[:derivation_prefix]).to match(BSV::Wallet::Engine::UUID_RE)
    end

    it 'excludes aborted actions' do
      engine_with_keys.generate_receive_address
      listed_before = engine_with_keys.list_receive_addresses
      expect(listed_before.length).to eq(1)

      # Abort the locking action — the address should disappear
      engine_with_keys.abort_action(reference: listed_before.first[:action_reference])
      listed_after = engine_with_keys.list_receive_addresses

      expect(listed_after).to eq([])
    end

    it 'raises without key_deriver' do
      expect do
        engine.list_receive_addresses
      end.to raise_error(BSV::Wallet::Error, /key deriver/)
    end
  end

  describe '#generate_receive_address' do
    it 'returns an address string and derivation params' do
      result = engine_with_keys.generate_receive_address

      expect(result[:address]).to be_a(String)
      expect(result[:address]).to start_with('1')
      expect(result[:derivation_prefix]).to match(BSV::Wallet::Engine::UUID_RE)
      expect(result[:derivation_suffix]).to match(/\A\d+\z/)
    end

    it 'creates a slot in basket p wbikd when none exists' do
      engine_with_keys.generate_receive_address

      # The slot was created — but it's now locked (consumed as input),
      # so query_outputs won't find it. Verify via the wbikd label.
      actions = engine_with_keys.list_actions(labels: ['wbikd'])
      expect(actions[:total_actions]).to eq(1)
    end

    it 'reuses an existing unlocked slot from basket p wbikd' do
      # Pre-fund a slot directly
      prefix = SecureRandom.uuid
      suffix = '1'
      derived_pub = key_deriver.derive_public_key(
        protocol_id: [2, prefix], key_id: suffix, counterparty: 'self'
      )
      script = BSV::Script::Script.p2pkh_lock(
        BSV::Primitives::Digest.hash160(derived_pub)
      ).to_binary

      source_action = store.create_action(
        action: { description: 'slot source action', broadcast: :none, outgoing: false }
      )
      store.sign_action(action_id: source_action[:id], wtxid: SecureRandom.random_bytes(32), raw_tx: dummy_raw_tx)
      store.promote_action(
        action_id: source_action[:id],
        outputs: [{
          satoshis: 500, vout: 0, locking_script: script,
          basket: 'p wbikd',
          derivation_prefix: prefix, derivation_suffix: suffix,
          sender_identity_key: key_deriver.identity_key
        }]
      )

      # Should use the pre-funded slot, not create a new one via create_action
      result = engine_with_keys.generate_receive_address
      expect(result[:address]).to be_a(String)
      expect(result[:address]).to start_with('1')
    end

    it 'creates separate addresses for consecutive calls' do
      first = engine_with_keys.generate_receive_address
      second = engine_with_keys.generate_receive_address

      expect(first[:address]).not_to eq(second[:address])
      expect(first[:derivation_prefix]).not_to eq(second[:derivation_prefix])
    end

    it 'produces a deterministic address from the same derivation params' do
      result = engine_with_keys.generate_receive_address

      # Re-derive the address from the returned params
      derived_pub = key_deriver.derive_public_key(
        protocol_id: [2, result[:derivation_prefix]],
        key_id: result[:derivation_suffix],
        counterparty: 'self'
      )
      re_derived_address = BSV::Primitives::PublicKey.from_bytes(derived_pub)
                                                     .address(network: :mainnet)

      expect(re_derived_address).to eq(result[:address])
    end

    it 'raises without key_deriver' do
      expect do
        engine.generate_receive_address
      end.to raise_error(BSV::Wallet::Error, /key deriver/)
    end

    it 'attaches the wbikd label to the locking action' do
      engine_with_keys.generate_receive_address

      actions = engine_with_keys.list_actions(labels: ['wbikd'], include_labels: true)
      expect(actions[:total_actions]).to eq(1)
      expect(actions[:actions].first[:labels]).to include('wbikd')
    end

    it 'creates a locking action with nosend status' do
      engine_with_keys.generate_receive_address

      actions = engine_with_keys.list_actions(labels: ['wbikd'])
      locking_action = actions[:actions].first
      expect(locking_action[:status]).to eq(:nosend)
    end
  end
end
