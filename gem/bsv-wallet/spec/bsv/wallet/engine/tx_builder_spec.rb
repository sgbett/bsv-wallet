# frozen_string_literal: true

require 'bsv-wallet'
require 'securerandom'

# Isolation specs for Engine::TxBuilder (#336 / #338).
#
# These specs run with NO store at all — TxBuilder is store-free by
# contract, so the suite proves it by construction (and the
# `store-free` example below grep-checks the source for the same).
RSpec.describe BSV::Wallet::Engine::TxBuilder do
  let(:root_key) { BSV::Primitives::PrivateKey.generate }
  let(:key_deriver) { BSV::Wallet::KeyDeriver.new(private_key: root_key) }
  let(:fee_model) { BSV::Transaction::FeeModels::SatoshisPerKilobyte.new(value: 100) }
  let(:builder) { described_class.new(key_deriver: key_deriver, fee_model: fee_model) }
  # OP_TRUE locking script — useful for outputs (where we don't care
  # about signing) and as a non-P2PKH input for custom-spend specs.
  let(:op_true) { "\x51".b }

  # BRC-29 derivation helper. Mirrors the shared_context helper used by
  # engine specs; lives here because tx_builder_spec runs without the
  # engine setup context. #478's atomic flip changes only this body.
  def derive_brc29_private_key(prefix:, suffix:, counterparty:)
    key_deriver.derive_private_key(
      protocol_id: [2, prefix], key_id: suffix, counterparty: counterparty
    )
  end

  # Build a resolved input hash backed by an actual P2PKH output the
  # key_deriver can sign. The derivation_prefix / suffix combine with
  # the root key to derive the private key whose public key hash matches
  # the locking script — TxBuilder rederives the same key at signing
  # time.
  def resolved_p2pkh_input(vin:, satoshis: 5_000, derivation_prefix: 'wallet payment',
                           derivation_suffix: nil, sender_identity_key: 'self')
    derivation_suffix ||= "s-#{SecureRandom.hex(4)}"
    derived = if derivation_prefix.nil?
                key_deriver.root_private_key
              else
                derive_brc29_private_key(
                  prefix: derivation_prefix, suffix: derivation_suffix,
                  counterparty: sender_identity_key
                )
              end
    pubkey_hash = BSV::Primitives::Digest.hash160(derived.public_key.compressed)
    locking_script = BSV::Script::Script.p2pkh_lock(pubkey_hash).to_binary
    {
      vin: vin,
      sequence: nil,
      source_wtxid: SecureRandom.random_bytes(32),
      source_vout: 0,
      source_satoshis: satoshis,
      source_locking_script: locking_script,
      derivation_prefix: derivation_prefix,
      derivation_suffix: derivation_suffix,
      sender_identity_key: sender_identity_key
    }
  end

  describe '#build (no-change)' do
    it 'assembles and signs a P2PKH-funded outgoing transaction' do
      resolved = [resolved_p2pkh_input(vin: 0, satoshis: 5_000)]

      result = builder.build(
        resolved_inputs: resolved,
        caller_outputs: [{ satoshis: 4_000, locking_script: op_true }],
        caller_inputs: nil,
        lock_time: 0, version: 1, randomize: false, sign: true
      )

      expect(result).to include(:wtxid, :raw_tx, :vout_mapping, :tx)
      expect(result[:wtxid]).to be_a(String).and(have_attributes(bytesize: 32))
      expect(result[:tx]).to be_a(BSV::Transaction::Tx)
      # Round-trip the raw_tx — proves it deserialises cleanly.
      decoded = BSV::Transaction::Tx.from_binary(result[:raw_tx])
      expect(decoded.inputs.length).to eq(1)
      expect(decoded.outputs.length).to eq(1)
      # Signed: the unlocking script actually satisfies the source P2PKH.
      # verify_input evaluates sig+pubkey against the attached source data,
      # so it catches InputSource-wiring or key-derivation regressions that
      # a mere "non-empty script" check would miss — TxBuilder is now the
      # signing boundary. result[:tx] carries source_satoshis /
      # source_locking_script wired by build_inputs, so no re-attach needed.
      expect(result[:tx].verify_input(0)).to be true
    end

    it 'yields a deserialisable unsigned tx when sign: false' do
      resolved = [resolved_p2pkh_input(vin: 0, satoshis: 5_000)]

      result = builder.build(
        resolved_inputs: resolved,
        caller_outputs: [{ satoshis: 4_000, locking_script: op_true }],
        caller_inputs: nil,
        lock_time: 0, version: 1, randomize: false, sign: false
      )

      decoded = BSV::Transaction::Tx.from_binary(result[:raw_tx])
      expect(decoded.inputs.length).to eq(1)
      # Unsigned: unlocking script is empty.
      unlocking = result[:tx].inputs[0].unlocking_script
      expect(unlocking.nil? || unlocking.to_binary.empty?).to be(true)
    end

    it 'returns [[],{}] shape for empty inputs (OP_RETURN-only path)' do
      result = builder.build(
        resolved_inputs: [],
        caller_outputs: [{ satoshis: 0, locking_script: "\x6a".b }],
        caller_inputs: nil,
        lock_time: 0, version: 1, randomize: false, sign: true
      )
      expect(result[:tx].inputs).to be_empty
      expect(result[:tx].outputs.length).to eq(1)
    end

    it 'honours a caller-supplied custom unlocking script (no signing key derived)' do
      # OP_TRUE source: no P2PKH, so the wallet cannot sign without a
      # caller-supplied unlocking_script.
      resolved = {
        vin: 0, sequence: nil,
        source_wtxid: SecureRandom.random_bytes(32), source_vout: 0,
        source_satoshis: 5_000, source_locking_script: op_true,
        derivation_prefix: nil, derivation_suffix: nil, sender_identity_key: nil
      }

      result = builder.build(
        resolved_inputs: [resolved],
        caller_outputs: [{ satoshis: 4_000, locking_script: op_true }],
        caller_inputs: [{ vin: 0, unlocking_script: '' }],
        lock_time: 0, version: 1, randomize: false, sign: true
      )

      expect(result[:tx].inputs[0].unlocking_script).to be_a(BSV::Script::Script)
    end

    it 'maps each original output index to its final vout position when randomize is true' do
      resolved = [resolved_p2pkh_input(vin: 0, satoshis: 50_000)]

      # Distinct satoshi values tag each output so we can assert the mapping
      # tracks content to its final position. Order-agnostic: shuffle! may
      # legitimately return the identity permutation (~1/120 for five
      # outputs), so we assert correspondence, never that reordering happened.
      outputs = 5.times.map { |i| { satoshis: 1_000 + i, locking_script: op_true } }
      result = builder.build(
        resolved_inputs: resolved, caller_outputs: outputs, caller_inputs: nil,
        lock_time: 0, version: 1, randomize: true, sign: true
      )

      expect(result[:vout_mapping].keys.sort).to eq([0, 1, 2, 3, 4])
      expect(result[:vout_mapping].values.sort).to eq([0, 1, 2, 3, 4])
      # The output at each mapped position carries original output i's content.
      outputs.each_with_index do |orig, i|
        expect(result[:tx].outputs[result[:vout_mapping][i]].satoshis).to eq(orig[:satoshis])
      end
    end
  end

  describe '#build_change' do
    it 'returns the converged build with change_outputs on success' do
      resolved = [resolved_p2pkh_input(vin: 0, satoshis: 100_000)]

      result = builder.build_change(
        resolved_inputs: resolved,
        caller_outputs: [{ satoshis: 10_000, locking_script: op_true }],
        caller_inputs: nil,
        lock_time: 0, version: 1, randomize: false, change_count: 1
      )

      expect(result).to include(:wtxid, :raw_tx, :tx, :vout_mapping, :change_outputs)
      expect(result[:change_outputs]).not_to be_empty
      change = result[:change_outputs].first
      expect(change).to include(:satoshis, :vout, :locking_script,
                                :derivation_prefix, :derivation_suffix,
                                :sender_identity_key)
      expect(change[:satoshis]).to be > 0
      expect(change[:sender_identity_key]).to eq(key_deriver.identity_key)
      expect(change[:derivation_prefix]).to be_a(String)
      expect(change[:derivation_suffix]).to be_a(String)
    end

    it 'returns {shortfall: N} when surplus does not cover the required fee' do
      # 100 sats input, 100 sats output → surplus 0, fee positive → shortfall.
      resolved = [resolved_p2pkh_input(vin: 0, satoshis: 100)]

      result = builder.build_change(
        resolved_inputs: resolved,
        caller_outputs: [{ satoshis: 100, locking_script: op_true }],
        caller_inputs: nil,
        lock_time: 0, version: 1, randomize: false, change_count: 1
      )

      expect(result).to have_key(:shortfall)
      expect(result[:shortfall]).to be > 0
      expect(result).not_to have_key(:wtxid)
    end

    it 'raises ArgumentError when change_count < 1' do
      expect do
        builder.build_change(
          resolved_inputs: [resolved_p2pkh_input(vin: 0, satoshis: 100_000)],
          caller_outputs: [{ satoshis: 10_000, locking_script: op_true }],
          caller_inputs: nil,
          lock_time: 0, version: 1, randomize: false, change_count: 0
        )
      end.to raise_error(ArgumentError, /change_count must be >= 1/)
    end

    it 'raises when no key deriver is configured (change derivation needs one)' do
      deriverless = described_class.new(key_deriver: nil, fee_model: fee_model)
      # Empty input set so build_inputs does not guard first — proves the
      # build_change guard itself fires before any change derivation.
      expect do
        deriverless.build_change(
          resolved_inputs: [], caller_outputs: [{ satoshis: 1_000, locking_script: op_true }],
          caller_inputs: nil, lock_time: 0, version: 1, randomize: false, change_count: 1
        )
      end.to raise_error(BSV::Wallet::Error, /no key deriver configured/)
    end

    it 'exposes the live Transaction::Tx so FundingStrategy can read total_input_satoshis' do
      resolved = [resolved_p2pkh_input(vin: 0, satoshis: 100_000)]
      result = builder.build_change(
        resolved_inputs: resolved,
        caller_outputs: [{ satoshis: 10_000, locking_script: op_true }],
        caller_inputs: nil,
        lock_time: 0, version: 1, randomize: false, change_count: 1
      )
      expect(result[:tx]).to be_a(BSV::Transaction::Tx)
      expect(result[:tx].total_input_satoshis).to eq(100_000)
    end

    context 'change_basket: (HLR #436)' do
      let(:resolved) { [resolved_p2pkh_input(vin: 0, satoshis: 100_000)] }
      let(:caller_outputs) { [{ satoshis: 10_000, locking_script: op_true }] }

      it 'stamps :basket on change_output_specs when change_basket is supplied' do
        result = builder.build_change(
          resolved_inputs: resolved, caller_outputs: caller_outputs,
          caller_inputs: nil, lock_time: 0, version: 1, randomize: false,
          change_count: 1, change_basket: 'importedfunds'
        )
        expect(result[:change_outputs]).not_to be_empty
        result[:change_outputs].each do |chg|
          expect(chg[:basket]).to eq('importedfunds')
        end
      end

      it 'omits :basket from change_output_specs when change_basket is nil (default)' do
        result = builder.build_change(
          resolved_inputs: resolved, caller_outputs: caller_outputs,
          caller_inputs: nil, lock_time: 0, version: 1, randomize: false,
          change_count: 1
        )
        expect(result[:change_outputs]).not_to be_empty
        result[:change_outputs].each do |chg|
          expect(chg).not_to have_key(:basket)
        end
      end
    end
  end

  describe '#apply_spends' do
    it 'signs wallet-owned P2PKH inputs when no spend is provided' do
      resolved = [resolved_p2pkh_input(vin: 0, satoshis: 5_000)]

      # Unsigned tx with one input matching the resolved row.
      unsigned = builder.build(
        resolved_inputs: resolved,
        caller_outputs: [{ satoshis: 4_000, locking_script: op_true }],
        caller_inputs: nil,
        lock_time: 0, version: 1, randomize: false, sign: false
      )[:raw_tx]
      tx = BSV::Transaction::Tx.from_binary(unsigned)

      wtxid, raw_tx, signed_tx = builder.apply_spends(tx: tx, resolved_inputs: resolved, spends: {})

      expect(wtxid).to be_a(String).and(have_attributes(bytesize: 32))
      expect(raw_tx).to be_a(String)
      expect(signed_tx.inputs[0].unlocking_script).not_to be_nil
      expect(signed_tx.inputs[0].unlocking_script.to_binary).not_to be_empty
    end

    it 'applies a caller-provided unlocking script over a non-P2PKH input' do
      resolved = [{
        vin: 0, sequence: nil,
        source_wtxid: SecureRandom.random_bytes(32), source_vout: 0,
        source_satoshis: 5_000, source_locking_script: op_true,
        derivation_prefix: nil, derivation_suffix: nil, sender_identity_key: nil
      }]

      tx = BSV::Transaction::Tx.new(version: 1, lock_time: 0)
      tx.add_input(BSV::Transaction::TransactionInput.new(
                     prev_wtxid: resolved.first[:source_wtxid],
                     prev_tx_out_index: 0, sequence: 0xFFFFFFFF
                   ))
      tx.add_output(BSV::Transaction::TransactionOutput.new(
                      satoshis: 4_000, locking_script: BSV::Script::Script.from_binary(op_true)
                    ))

      _wtxid, _raw_tx, signed_tx = builder.apply_spends(
        tx: tx, resolved_inputs: resolved,
        spends: { 0 => { unlocking_script: '00' } }
      )

      expect(signed_tx.inputs[0].unlocking_script).to be_a(BSV::Script::Script)
    end

    it 'raises when a non-P2PKH input has no caller spend' do
      resolved = [{
        vin: 0, sequence: nil,
        source_wtxid: SecureRandom.random_bytes(32), source_vout: 0,
        source_satoshis: 5_000, source_locking_script: op_true,
        derivation_prefix: nil, derivation_suffix: nil, sender_identity_key: nil
      }]

      tx = BSV::Transaction::Tx.new(version: 1, lock_time: 0)
      tx.add_input(BSV::Transaction::TransactionInput.new(
                     prev_wtxid: resolved.first[:source_wtxid],
                     prev_tx_out_index: 0, sequence: 0xFFFFFFFF
                   ))

      expect do
        builder.apply_spends(tx: tx, resolved_inputs: resolved, spends: {})
      end.to raise_error(BSV::Wallet::Error, /no unlocking script/)
    end
  end

  describe 'store-free invariants' do
    it 'has no store dependency and no engine reach-through (source-level)' do
      source = File.read(
        File.expand_path('../../../../lib/bsv/wallet/engine/tx_builder.rb', __dir__)
      )
      # Filter out comment lines — the documentation references
      # +Store#resolve_inputs_for_signing+ as the shape of the resolved
      # row data, which is fine.
      code = source.lines.reject { |l| l.strip.start_with?('#') }.join

      expect(code).not_to include('@store')
      expect(code).not_to include('resolve_inputs_for_signing')
      expect(code).not_to include('engine.send(')
      expect(code).not_to include('.send(:')
      expect(code).not_to include('@engine')
    end

    it 'runs a full build with no store argument (constructor only takes key_deriver + fee_model)' do
      # Reconstruct to prove the public surface really is store-free.
      isolated = described_class.new(key_deriver: key_deriver, fee_model: fee_model)
      resolved = [resolved_p2pkh_input(vin: 0, satoshis: 100_000)]

      result = isolated.build_change(
        resolved_inputs: resolved,
        caller_outputs: [{ satoshis: 10_000, locking_script: op_true }],
        caller_inputs: nil,
        lock_time: 0, version: 1, randomize: false, change_count: 1
      )

      expect(result).to include(:wtxid, :raw_tx, :tx, :vout_mapping, :change_outputs)
    end
  end
end
