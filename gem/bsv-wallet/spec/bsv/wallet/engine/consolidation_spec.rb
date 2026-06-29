# frozen_string_literal: true

# Unit specs for Engine#consolidate_step and Engine#sweep — the no_send
# consolidation primitives that #130 wires into a dry-run + #126 wires
# into the on-chain sweep-back.

require_relative 'shared_context'

RSpec.describe BSV::Wallet::Engine do # rubocop:disable RSpec/SpecFilePathFormat
  include_context 'engine setup'

  # Porcelain-style specs manage their own funding — skip the reserve UTXO.
  metadata[:skip_reserve] = true

  # Populate the wallet with +count+ spendable outputs of +satoshis+ each.
  # Each output goes to a fresh BRC-42-derived self-address so the engine
  # can sign them when consolidation / sweep needs to.
  def fund_with_outputs(satoshis:, count:, prefix: 'funded')
    derived_key = key_deriver.derive_private_key(
      protocol_id: [2, prefix], key_id: '1', counterparty: 'self'
    )
    pubkey_hash = BSV::Primitives::Digest.hash160(derived_key.public_key.compressed)
    script = BSV::Script::Script.p2pkh_lock(pubkey_hash)

    # Vary satoshi values per index so +smallest+ and +largest+ pick
    # distinct rows (otherwise ordering ties are undefined).
    outputs = count.times.map do |i|
      {
        satoshis: satoshis + i, vout: i,
        locking_script: script.to_binary,
        basket: nil,
        # HLR #467: every output spec states intent explicitly. Test
        # fixtures here build BRC-42 self-derived outputs — wallet-owned,
        # so always +'spendable'+.
        spendable_intent: 'spendable',
        derivation_prefix: prefix,
        derivation_suffix: '1',
        sender_identity_key: 'self'
      }
    end
    register_funded_outputs(outputs)
  end

  describe '#consolidate_step' do
    context 'with a healthy spendable set' do
      before { fund_with_outputs(satoshis: 5_000, count: 25) }

      it 'consumes 20 smallest + 1 largest inputs and emits one self-payment' do
        # HLR #467 / ADR-026 / ADR-027: +consolidate_step+ is wallet-vocab
        # porcelain — calls +#build_action+ directly, returns wallet vocab
        # (+:wtxid+ / +:atomic_beef+).
        result = engine_with_keys.consolidate_step(target_inputs: 20)
        expect(result).not_to be_nil
        expect(result[:wtxid]).to be_a(String)

        action = store.find_action(wtxid: result[:wtxid])
        input_rows = BSV::Wallet::Store::Models::Input.where(action_id: action[:id]).all
        expect(input_rows.length).to eq(21)

        # One own-change output (BRC-42 self-derived) — internalized via no_send.
        change_rows = BSV::Wallet::Store::Models::Output.where(action_id: action[:id]).all
        expect(change_rows.length).to eq(1)
        expect(change_rows.first.derivation_prefix).not_to be_nil
      end
    end

    context 'when the pool is below the target' do
      before { fund_with_outputs(satoshis: 5_000, count: 5) }

      it 'returns nil (signals loop termination)' do
        expect(engine_with_keys.consolidate_step(target_inputs: 20)).to be_nil
      end
    end

    context 'without a key_deriver' do
      it 'raises (BRC-42 derivation requires the wallet to be authenticated)' do
        expect { engine.consolidate_step(target_inputs: 20) }
          .to raise_error(BSV::Wallet::Error, /key deriver/)
      end
    end
  end

  describe '#sweep' do
    let(:recipient) { BSV::Primitives::PrivateKey.generate.public_key.to_hex }

    context 'with spendable outputs' do
      before { fund_with_outputs(satoshis: 10_000, count: 4) }

      it 'consumes every spendable output and emits one recipient output' do
        # HLR #467 / ADR-026 / ADR-027: +sweep+ is wallet-vocab porcelain —
        # calls +#build_action+ directly, returns wallet vocab (+:wtxid+ /
        # +:atomic_beef+).
        result = engine_with_keys.sweep(recipient: recipient)
        expect(result).not_to be_nil
        expect(result[:wtxid]).to be_a(String)

        action = store.find_action(wtxid: result[:wtxid])
        input_rows = BSV::Wallet::Store::Models::Input.where(action_id: action[:id]).all
        expect(input_rows.length).to eq(4)

        output_rows = BSV::Wallet::Store::Models::Output.where(action_id: action[:id]).all
        # Funding loop derives a change key; with our exact-fee estimate the
        # change output is dust-dropped, leaving only the recipient output.
        # If fee estimate was slightly high, a tiny change row may survive.
        expect(output_rows.length).to be_between(1, 2)
        # The recipient output is the largest of the caller+change set.
        biggest = output_rows.max_by(&:satoshis)
        expect(biggest.satoshis).to be > (40_000 - 200) # 4 × 10k inputs - fee
      end
    end

    context 'when the wallet has no spendable outputs' do
      it 'returns nil' do
        expect(engine_with_keys.sweep(recipient: recipient)).to be_nil
      end
    end

    context 'without a key_deriver' do
      it 'raises' do
        expect { engine.sweep(recipient: recipient) }
          .to raise_error(BSV::Wallet::Error, /key deriver/)
      end
    end
  end

  # Orchestration over consolidate_step + sweep. Both collaborators are
  # exercised on-chain (no_send: false) here, so we stub them and assert the
  # wiring rather than re-broadcasting in a unit spec.
  describe '#sweep_to_root' do
    it 'loops consolidate_step until nil, then sweeps to the root P2PKH' do
      # HLR #467 / ADR-026: +consolidate_step+ and +sweep+ return wallet
      # vocab (+:wtxid+ / +:atomic_beef+) — calls through +#build_action+
      # directly. The mock shapes track the real return.
      allow(engine_with_keys).to receive(:consolidate_step).and_return({ wtxid: 'a' }, { wtxid: 'b' }, nil)
      allow(engine_with_keys).to receive(:sweep).and_return({ wtxid: 'z' })

      result = engine_with_keys.sweep_to_root

      expect(engine_with_keys).to have_received(:consolidate_step)
        .with(target_inputs: 20, no_send: false, accept_delayed_broadcast: false).exactly(3).times
      expect(engine_with_keys).to have_received(:sweep)
        .with(recipient: key_deriver.identity_key, no_send: false, accept_delayed_broadcast: false)
      expect(result).to eq(consolidation_steps: 2, sweep: { wtxid: 'z' })
    end

    it 'defaults the recipient to the wallet identity key' do
      allow(engine_with_keys).to receive_messages(consolidate_step: nil, sweep: { wtxid: 'z' })

      engine_with_keys.sweep_to_root

      expect(engine_with_keys).to have_received(:sweep)
        .with(hash_including(recipient: key_deriver.identity_key))
    end

    it 'honors an explicit recipient override' do
      override = BSV::Primitives::PrivateKey.generate.public_key.to_hex
      allow(engine_with_keys).to receive_messages(consolidate_step: nil, sweep: { wtxid: 'z' })

      engine_with_keys.sweep_to_root(recipient: override)

      expect(engine_with_keys).to have_received(:sweep)
        .with(hash_including(recipient: override))
    end

    it 'forwards a custom target_inputs to consolidate_step' do
      allow(engine_with_keys).to receive_messages(consolidate_step: nil, sweep: nil)

      engine_with_keys.sweep_to_root(target_inputs: 50)

      expect(engine_with_keys).to have_received(:consolidate_step)
        .with(hash_including(target_inputs: 50))
    end

    context 'without a key_deriver' do
      it 'raises' do
        expect { engine.sweep_to_root }
          .to raise_error(BSV::Wallet::Error, /key deriver/)
      end
    end
  end
end
