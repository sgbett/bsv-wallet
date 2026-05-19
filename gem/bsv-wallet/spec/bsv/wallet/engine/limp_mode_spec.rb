# frozen_string_literal: true

require_relative 'shared_context'

RSpec.describe BSV::Wallet::Engine do # rubocop:disable RSpec/SpecFilePathFormat
  include_context 'engine setup'

  # All limp mode specs manage their own funding — skip the reserve.
  metadata[:skip_reserve] = true

  def fund_wallet_limp(satoshis:, count: 1)
    derived_key = key_deriver.derive_private_key(
      protocol_id: [2, 'limp test'], key_id: 'fund', counterparty: 'self'
    )
    script = BSV::Script::Script.p2pkh_lock(
      BSV::Primitives::Digest.hash160(derived_key.public_key.compressed)
    )
    source = store.create_action(action: { description: 'limp funding', broadcast: :none, outgoing: false })
    store.sign_action(action_id: source[:id], wtxid: SecureRandom.random_bytes(32), raw_tx: dummy_raw_tx)
    outputs = count.times.map do |i|
      { satoshis: satoshis, vout: i, locking_script: script.to_binary,
        basket: 'default', derivation_prefix: 'limp test',
        derivation_suffix: count > 1 ? "fund#{i}" : 'fund',
        sender_identity_key: 'self' }
    end
    store.promote_action(action_id: source[:id], outputs: outputs)
  end

  describe '#limp_mode?' do
    it 'returns true when balance is below threshold' do
      fund_wallet_limp(satoshis: 49_000)
      expect(engine_with_keys.limp_mode?).to be true
    end

    it 'returns false when balance is at threshold' do
      fund_wallet_limp(satoshis: 50_000)
      expect(engine_with_keys.limp_mode?).to be false
    end

    it 'returns false when balance is above threshold' do
      fund_wallet_limp(satoshis: 100_000)
      expect(engine_with_keys.limp_mode?).to be false
    end

    it 'returns true with no funding' do
      expect(engine_with_keys.limp_mode?).to be true
    end
  end

  describe '#headroom' do
    it 'returns available spend capacity' do
      fund_wallet_limp(satoshis: 200_000)
      expect(engine_with_keys.headroom).to eq(150_000)
    end

    it 'returns 0 when at threshold' do
      fund_wallet_limp(satoshis: 50_000)
      expect(engine_with_keys.headroom).to eq(0)
    end

    it 'returns 0 when below threshold' do
      fund_wallet_limp(satoshis: 10_000)
      expect(engine_with_keys.headroom).to eq(0)
    end
  end

  describe 'config' do
    it 'rejects limp_threshold below hard floor' do
      expect do
        described_class.new(
          store: store, utxo_pool: utxo_pool,
          broadcast_queue: broadcast_queue, proof_store: proof_store,
          limp_threshold: 5_000
        )
      end.to raise_error(ArgumentError, /limp_threshold/)
    end

    it 'accepts custom limp_threshold above hard floor' do
      custom = described_class.new(
        store: store, utxo_pool: utxo_pool,
        broadcast_queue: broadcast_queue, proof_store: proof_store,
        limp_threshold: 20_000
      )
      expect(custom.limp_threshold).to eq(20_000)
    end
  end

  describe 'entry guard' do
    it 'blocks auto-fund createAction when in limp mode' do
      fund_wallet_limp(satoshis: 30_000)

      expect do
        engine_with_keys.create_action(
          description: 'limp blocked',
          outputs: [{ satoshis: 1000, locking_script: SecureRandom.random_bytes(25) }],
          no_send: true
        )
      end.to raise_error(BSV::Wallet::LimpModeError)
    end

    it 'blocks caller-provided-inputs createAction when in limp mode' do
      fund_wallet_limp(satoshis: 30_000)
      listed = engine_with_keys.list_outputs(basket: 'default')
      output_id = listed[:outputs].first[:id]

      expect do
        engine_with_keys.create_action(
          description: 'limp manual',
          inputs: [{ output_id: output_id }],
          outputs: [{ satoshis: 1000, locking_script: SecureRandom.random_bytes(25),
                      derivation_prefix: SecureRandom.uuid, derivation_suffix: '1',
                      sender_identity_key: key_deriver.identity_key }],
          no_send: true
        )
      end.to raise_error(BSV::Wallet::LimpModeError)
    end

    it 'does not block internalize_action when in limp mode' do
      expect(engine_with_keys.limp_mode?).to be true

      expect do
        engine_with_keys.internalize_action(
          tx: 'invalid', description: 'limp receive',
          outputs: [{ vout: 0, basket: 'default' }]
        )
      end.to raise_error(BSV::Wallet::InvalidBeefError)
    end
  end

  describe 'headroom guard' do
    it 'blocks auto-fund that would enter limp mode' do
      fund_wallet_limp(satoshis: 100_000)
      expect(engine_with_keys.limp_mode?).to be false

      expect do
        engine_with_keys.create_action(
          description: 'limp headroom',
          outputs: [{ satoshis: 60_000, locking_script: SecureRandom.random_bytes(25) }],
          no_send: true
        )
      end.to raise_error(BSV::Wallet::LimpModeError)
    end

    it 'allows auto-fund within headroom' do
      fund_wallet_limp(satoshis: 200_000)
      expect(engine_with_keys.limp_mode?).to be false

      result = engine_with_keys.create_action(
        description: 'limp within headroom',
        outputs: [{ satoshis: 5_000, locking_script: SecureRandom.random_bytes(25) }],
        no_send: true
      )
      expect(result[:txid]).to be_a(String)
    end

    # No post-lock headroom guard for caller-provided inputs.
    # The caller explicitly chose which UTXOs to spend — the entry
    # guard (already in limp mode) is sufficient. The headroom guard
    # only applies to auto-fund where the engine selects UTXOs.
  end
end
