# frozen_string_literal: true

# WBIKD specs — generate_receive_address, list_receive_addresses, and the slot mechanism.

require_relative 'shared_context'

RSpec.describe BSV::Wallet::Engine, if: POSTGRES_AVAILABLE do # rubocop:disable RSpec/SpecFilePathFormat
  include_context 'engine setup'

  # Pre-fund the wbikd basket so generate_receive_address finds a slot
  # without needing to broadcast a self-payment (which requires network
  # acceptance in the auto-fund path).
  def prefund_wbikd_slots(count: 3)
    count.times { |i| fund_wallet(satoshis: rand(100..1000), basket: 'p wbikd', suffix: "wbikd#{i}") }
  end

  before { prefund_wbikd_slots }

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
      # Derivation prefix is display-order txid (64-char hex)
      expect(entry[:derivation_prefix]).to match(/\A[0-9a-f]{64}\z/)
      # Derivation suffix is vout as decimal string
      expect(entry[:derivation_suffix]).to match(/\A\d+\z/)
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

  describe '#scan_receive_addresses' do
    it 'returns { scanned: 0, found: 0 } without key_deriver' do
      result = engine.scan_receive_addresses

      expect(result).to eq({ scanned: 0, found: 0 })
    end

    it 'returns { scanned: 0, found: 0 } without network_provider' do
      result = engine_with_keys.scan_receive_addresses

      expect(result).to eq({ scanned: 0, found: 0 })
    end

    it 'returns { scanned: 0, found: 0 } with no outstanding addresses' do
      network_provider = double(:network_provider)
      engine_net = described_class.new(
        store: store, utxo_pool: utxo_pool,
        broadcast_queue: broadcast_queue, proof_store: proof_store,
        key_deriver: key_deriver, network_provider: network_provider,
        network: :mainnet
      )

      result = engine_net.scan_receive_addresses

      expect(result).to eq({ scanned: 0, found: 0 })
    end

    context 'with a generated address and mock UTXO response' do
      let(:network_provider) { double(:network_provider) }
      let(:engine_net) do
        described_class.new(
          store: store, utxo_pool: utxo_pool,
          broadcast_queue: broadcast_queue, proof_store: proof_store,
          key_deriver: key_deriver, network_provider: network_provider,
          network: :mainnet
        )
      end

      it 'internalizes found UTXOs and returns correct counts' do
        # Generate a receive address
        addr_result = engine_net.generate_receive_address
        address = addr_result[:address]
        prefix = addr_result[:derivation_prefix]
        suffix = addr_result[:derivation_suffix]

        # Build a real transaction paying to this address
        derived_pub = key_deriver.derive_public_key(
          protocol_id: [2, prefix], key_id: suffix, counterparty: 'self'
        )
        locking_script = BSV::Script::Script.p2pkh_lock(
          BSV::Primitives::Digest.hash160(derived_pub)
        )

        funding_tx = BSV::Transaction::Transaction.new(version: 1, lock_time: 0)
        funding_tx.add_output(
          BSV::Transaction::TransactionOutput.new(satoshis: 10_000, locking_script: locking_script)
        )
        raw_tx_hex = funding_tx.to_binary.unpack1('H*')
        dtxid = funding_tx.wtxid.reverse.unpack1('H*')

        # Mock network responses
        utxo_response = double(:utxo_response,
                               http_success?: true,
                               data: [{ 'tx_hash' => dtxid, 'tx_pos' => 0 }])
        tx_response = double(:tx_response,
                             http_success?: true,
                             data: raw_tx_hex)
        details_response = double(:details_response,
                                  http_success?: false,
                                  data: {})

        allow(network_provider).to receive(:call).with(:get_utxos, address).and_return(utxo_response)
        allow(network_provider).to receive(:call).with(:get_tx, txid: dtxid).and_return(tx_response)
        allow(network_provider).to receive(:call).with(:get_tx_details, txid: dtxid).and_return(details_response)

        result = engine_net.scan_receive_addresses

        expect(result[:scanned]).to eq(1)
        expect(result[:found]).to eq(1)
      end

      it 'the internalized output is spendable in the default basket' do
        addr_result = engine_net.generate_receive_address
        prefix = addr_result[:derivation_prefix]
        suffix = addr_result[:derivation_suffix]
        address = addr_result[:address]

        # Build tx paying to the WBIKD address
        derived_pub = key_deriver.derive_public_key(
          protocol_id: [2, prefix], key_id: suffix, counterparty: 'self'
        )
        locking_script = BSV::Script::Script.p2pkh_lock(
          BSV::Primitives::Digest.hash160(derived_pub)
        )
        funding_tx = BSV::Transaction::Transaction.new(version: 1, lock_time: 0)
        funding_tx.add_output(
          BSV::Transaction::TransactionOutput.new(satoshis: 25_000, locking_script: locking_script)
        )
        raw_tx_hex = funding_tx.to_binary.unpack1('H*')
        dtxid = funding_tx.wtxid.reverse.unpack1('H*')

        utxo_response = double(:utxo_response,
                               http_success?: true,
                               data: [{ 'tx_hash' => dtxid, 'tx_pos' => 0 }])
        tx_response = double(:tx_response, http_success?: true, data: raw_tx_hex)
        details_response = double(:details_response, http_success?: false, data: {})

        allow(network_provider).to receive(:call).with(:get_utxos, address).and_return(utxo_response)
        allow(network_provider).to receive(:call).with(:get_tx, txid: dtxid).and_return(tx_response)
        allow(network_provider).to receive(:call).with(:get_tx_details, txid: dtxid).and_return(details_response)

        engine_net.scan_receive_addresses

        # The internalized output should be spendable in default basket
        outputs = engine_net.list_outputs(basket: 'default')
        internalized = outputs[:outputs].find { |o| o[:satoshis] == 25_000 }
        expect(internalized).not_to be_nil
      end

      it 'recycles the slot back to basket p wbikd after internalization' do
        addr_result = engine_net.generate_receive_address
        prefix = addr_result[:derivation_prefix]
        suffix = addr_result[:derivation_suffix]
        address = addr_result[:address]

        # Before scan: one slot locked, others still available
        slots_before = engine_net.list_outputs(basket: 'p wbikd')
        locked_count = slots_before[:total_outputs]

        # Build tx
        derived_pub = key_deriver.derive_public_key(
          protocol_id: [2, prefix], key_id: suffix, counterparty: 'self'
        )
        locking_script = BSV::Script::Script.p2pkh_lock(
          BSV::Primitives::Digest.hash160(derived_pub)
        )
        funding_tx = BSV::Transaction::Transaction.new(version: 1, lock_time: 0)
        funding_tx.add_output(
          BSV::Transaction::TransactionOutput.new(satoshis: 15_000, locking_script: locking_script)
        )
        raw_tx_hex = funding_tx.to_binary.unpack1('H*')
        dtxid = funding_tx.wtxid.reverse.unpack1('H*')

        utxo_response = double(:utxo_response,
                               http_success?: true,
                               data: [{ 'tx_hash' => dtxid, 'tx_pos' => 0 }])
        tx_response = double(:tx_response, http_success?: true, data: raw_tx_hex)
        details_response = double(:details_response, http_success?: false, data: {})

        allow(network_provider).to receive(:call).with(:get_utxos, address).and_return(utxo_response)
        allow(network_provider).to receive(:call).with(:get_tx, txid: dtxid).and_return(tx_response)
        allow(network_provider).to receive(:call).with(:get_tx_details, txid: dtxid).and_return(details_response)

        engine_net.scan_receive_addresses

        # After scan: locking action aborted, slot recycled — one more than before
        slots_after = engine_net.list_outputs(basket: 'p wbikd')
        expect(slots_after[:total_outputs]).to eq(locked_count + 1)
      end

      it 'the address disappears from list_receive_addresses after internalization' do
        addr_result = engine_net.generate_receive_address
        prefix = addr_result[:derivation_prefix]
        suffix = addr_result[:derivation_suffix]
        address = addr_result[:address]

        expect(engine_net.list_receive_addresses.length).to eq(1)

        derived_pub = key_deriver.derive_public_key(
          protocol_id: [2, prefix], key_id: suffix, counterparty: 'self'
        )
        locking_script = BSV::Script::Script.p2pkh_lock(
          BSV::Primitives::Digest.hash160(derived_pub)
        )
        funding_tx = BSV::Transaction::Transaction.new(version: 1, lock_time: 0)
        funding_tx.add_output(
          BSV::Transaction::TransactionOutput.new(satoshis: 10_000, locking_script: locking_script)
        )
        raw_tx_hex = funding_tx.to_binary.unpack1('H*')
        dtxid = funding_tx.wtxid.reverse.unpack1('H*')

        utxo_response = double(:utxo_response,
                               http_success?: true,
                               data: [{ 'tx_hash' => dtxid, 'tx_pos' => 0 }])
        tx_response = double(:tx_response, http_success?: true, data: raw_tx_hex)
        details_response = double(:details_response, http_success?: false, data: {})

        allow(network_provider).to receive(:call).with(:get_utxos, address).and_return(utxo_response)
        allow(network_provider).to receive(:call).with(:get_tx, txid: dtxid).and_return(tx_response)
        allow(network_provider).to receive(:call).with(:get_tx_details, txid: dtxid).and_return(details_response)

        engine_net.scan_receive_addresses

        expect(engine_net.list_receive_addresses).to eq([])
      end

      it 'skips addresses when network returns an error' do
        engine_net.generate_receive_address
        address = engine_net.list_receive_addresses.first[:address]

        error_response = double(:error_response, http_success?: false)
        allow(network_provider).to receive(:call).with(:get_utxos, address).and_return(error_response)

        result = engine_net.scan_receive_addresses

        expect(result[:scanned]).to eq(1)
        expect(result[:found]).to eq(0)
      end

      it 'skips addresses when no UTXOs are found' do
        engine_net.generate_receive_address
        address = engine_net.list_receive_addresses.first[:address]

        empty_response = double(:empty_response, http_success?: true, data: [])
        allow(network_provider).to receive(:call).with(:get_utxos, address).and_return(empty_response)

        result = engine_net.scan_receive_addresses

        expect(result[:scanned]).to eq(1)
        expect(result[:found]).to eq(0)
      end
    end
  end

  describe '#generate_receive_address' do
    it 'returns an address string and derivation params' do
      result = engine_with_keys.generate_receive_address

      expect(result[:address]).to be_a(String)
      expect(result[:address]).to start_with('1')
      # Derivation prefix is display-order txid (64-char hex)
      expect(result[:derivation_prefix]).to match(/\A[0-9a-f]{64}\z/)
      # Derivation suffix is vout as decimal string
      expect(result[:derivation_suffix]).to match(/\A\d+\z/)
    end

    it 'uses a pre-funded slot from basket p wbikd' do
      # prefund_wbikd_slots already created slots in before block
      engine_with_keys.generate_receive_address

      # Slot was consumed — locking action created with wbikd label
      actions = engine_with_keys.list_actions(labels: ['wbikd'])
      expect(actions[:total_actions]).to eq(1)
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
