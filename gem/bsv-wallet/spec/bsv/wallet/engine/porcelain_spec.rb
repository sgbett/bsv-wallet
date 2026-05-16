# frozen_string_literal: true

# Porcelain engine specs — tests for the user-facing wallet methods:
# send_payment, import_utxo, and the auto-fund path that underlies them.

require_relative 'shared_context'

RSpec.describe BSV::Wallet::Engine, if: ENGINE_AVAILABLE do # rubocop:disable RSpec/SpecFilePathFormat
  include_context 'engine setup'

  # Porcelain specs manage their own funding — skip the reserve.
  metadata[:skip_reserve] = true

  def p2pkh_locking_script_for(private_key)
    pubkey_hash = BSV::Primitives::Digest.hash160(private_key.public_key.compressed)
    BSV::Script::Script.p2pkh_lock(pubkey_hash)
  end

  def fund_wallet_for_auto(satoshis: 1_000_000, count: 1,
                           prefix: 'wallet payment', suffix: 'autofund')
    derived_key = key_deriver.derive_private_key(
      protocol_id: [2, prefix], key_id: suffix, counterparty: 'self'
    )
    script = p2pkh_locking_script_for(derived_key)

    source_action = store.create_action(
      action: { description: 'funding source', broadcast: :none, outgoing: false }
    )
    source_wtxid = SecureRandom.random_bytes(32)
    store.sign_action(action_id: source_action[:id], wtxid: source_wtxid, raw_tx: dummy_raw_tx)

    outputs = count.times.map do |i|
      {
        satoshis: satoshis, vout: i,
        locking_script: script.to_binary,
        basket: 'default',
        derivation_prefix: prefix,
        derivation_suffix: count > 1 ? "#{suffix}#{i}" : suffix,
        sender_identity_key: 'self'
      }
    end
    store.promote_action(action_id: source_action[:id], outputs: outputs)
  end

  # --- send_payment ---

  describe '#send_payment' do
    it 'returns a BEEF envelope with derivation metadata' do
      fund_wallet_for_auto

      recipient_key = BSV::Primitives::PrivateKey.generate
      recipient_identity = recipient_key.public_key.to_hex

      result = engine_with_keys.send_payment(recipient: recipient_identity, satoshis: 5_000)

      expect(result[:beef]).to be_a(String)
      expect(result[:sender_identity_key]).to eq(key_deriver.identity_key)
      expect(result[:outputs]).to be_an(Array)
      expect(result[:outputs].length).to eq(1)

      out = result[:outputs].first
      expect(out[:satoshis]).to eq(5_000)
      expect(out[:vout]).to eq(0)
      expect(out[:derivation_prefix]).to be_a(String)
      expect(out[:derivation_suffix]).to eq('1')
    end

    it 'produces BEEF that can be parsed' do
      fund_wallet_for_auto

      recipient_key = BSV::Primitives::PrivateKey.generate
      result = engine_with_keys.send_payment(recipient: recipient_key.public_key.to_hex, satoshis: 5_000)

      parsed = parse_beef_tx(result[:beef])
      expect(parsed.inputs.length).to eq(1)
      expect(parsed.outputs.length).to be >= 2 # payment + change
    end
  end

  # --- auto-fund (underlying machinery for send_payment) ---

  describe 'auto-fund createAction' do
    context 'happy path' do
      it 'auto-selects UTXOs, computes fee, generates change, and signs' do
        fund_wallet_for_auto

        payment_script = SecureRandom.random_bytes(25)
        result = engine_with_keys.create_action(
          description: 'auto-fund test',
          outputs: [{ satoshis: 5_000, locking_script: payment_script }],
          no_send: true
        )

        expect(result[:txid]).to be_a(String)
        expect(result[:txid].bytesize).to eq(32)
        expect(result[:tx]).to be_a(String)

        parsed = parse_beef_tx(result[:tx])
        expect(parsed.inputs.length).to eq(1)
        expect(parsed.outputs.length).to be >= 2

        output_sats = parsed.outputs.map(&:satoshis).sort
        expect(output_sats).to include(5_000)

        total_output = parsed.outputs.sum(&:satoshis)
        fee = 1_000_000 - total_output
        expect(fee).to be > 0
        expect(fee).to be < 500
      end

      it 'creates multiple change outputs to grow the pool' do
        fund_wallet_for_auto

        result = engine_with_keys.create_action(
          description: 'auto-fund multi-change',
          outputs: [{ satoshis: 5_000, locking_script: SecureRandom.random_bytes(25) }],
          no_send: true
        )

        expect(result[:no_send_change].length).to eq(8)
        expect(result[:no_send_change]).to all(match(/\A[0-9a-f]{64}\.\d+\z/))
      end

      it 'returns change outpoints in no_send_change' do
        fund_wallet_for_auto

        result = engine_with_keys.create_action(
          description: 'auto-fund nosend',
          outputs: [{ satoshis: 5_000, locking_script: SecureRandom.random_bytes(25) }],
          no_send: true
        )

        expect(result[:no_send_change]).to be_an(Array)
        expect(result[:no_send_change].length).to be >= 1
        expect(result[:no_send_change]).to all(match(/\A[0-9a-f]{64}\.\d+\z/))
      end

      it 'change outputs are immediately spendable' do
        fund_wallet_for_auto

        engine_with_keys.create_action(
          description: 'auto-fund spend',
          outputs: [{ satoshis: 5_000, locking_script: SecureRandom.random_bytes(25) }],
          no_send: true
        )

        balance = utxo_pool.balance
        change_sats = 1_000_000 - 5_000
        expect(balance).to be > 0
        expect(balance).to be_within(500).of(change_sats)
        expect(utxo_pool.spendable_count).to be > 1
      end
    end

    context 'dust change removal' do
      it 'headroom guard prevents spending down to dust' do
        fund_wallet_for_auto

        expect do
          engine_with_keys.create_action(
            description: 'auto-fund dust',
            outputs: [{ satoshis: 960_000, locking_script: SecureRandom.random_bytes(25) }],
            no_send: true
          )
        end.to raise_error(BSV::Wallet::LimpModeError)
      end
    end

    context 'insufficient funds' do
      it 'raises LimpModeError when spend would exceed headroom' do
        fund_wallet_for_auto

        expect do
          engine_with_keys.create_action(
            description: 'auto-fund broke',
            outputs: [{ satoshis: 960_000, locking_script: SecureRandom.random_bytes(25) }],
            no_send: true
          )
        end.to raise_error(BSV::Wallet::LimpModeError)
      end
    end

    context 'deferred signing rejection' do
      it 'raises InvalidParameterError when sign_and_process is false' do
        expect do
          engine_with_keys.create_action(
            description: 'auto-fund defer',
            sign_and_process: false,
            outputs: [{ satoshis: 100, locking_script: SecureRandom.random_bytes(25) }]
          )
        end.to raise_error(BSV::Wallet::InvalidParameterError, /sign_and_process/)
      end
    end

    context 'without key_deriver' do
      it 'raises when wallet is not authenticated' do
        expect do
          engine.create_action(
            description: 'auto-fund nokey',
            outputs: [{ satoshis: 100, locking_script: SecureRandom.random_bytes(25) }]
          )
        end.to raise_error(BSV::Wallet::Error, /key deriver/)
      end
    end

    context 'backward compatibility' do
      it 'caller-provided inputs still work unchanged' do
        fund_wallet_for_auto(satoshis: 100_000, count: 2)

        listed = engine_with_keys.list_outputs(basket: 'default')
        output_id = listed[:outputs].first[:id]

        result = engine_with_keys.create_action(
          description: 'raw mode test',
          inputs: [{ output_id: output_id }],
          outputs: [{ satoshis: 4000, locking_script: SecureRandom.random_bytes(25),
                      derivation_prefix: SecureRandom.uuid, derivation_suffix: '1',
                      sender_identity_key: key_deriver.identity_key }],
          no_send: true
        )

        expect(result[:txid]).to be_a(String)
        expect(result[:txid].bytesize).to eq(32)

        parsed = parse_beef_tx(result[:tx])
        expect(parsed.inputs.length).to eq(1)
        expect(parsed.outputs.length).to eq(1)
        expect(parsed.outputs[0].satoshis).to eq(4000)
      end

      it 'explicit empty inputs (OP_RETURN) still work' do
        fund_wallet_for_auto

        result = engine_with_keys.create_action(
          description: 'opret test12345',
          inputs: [],
          outputs: [{ satoshis: 0, locking_script: "\x00\x6a\x04test".b }]
        )

        expect(result[:txid]).to be_a(String)
      end
    end
  end
end
