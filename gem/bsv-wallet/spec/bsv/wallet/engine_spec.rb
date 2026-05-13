# frozen_string_literal: true

# Engine plumbing specs — tests for the BRC-100 interface methods
# (create_action, sign_action, internalize_action, BEEF/SPV, crypto).
#
# Porcelain specs (send_payment, limp mode, auto-fund) live in engine/.

require_relative 'engine/shared_context'

RSpec.describe BSV::Wallet::Engine, if: POSTGRES_AVAILABLE do
  include_context 'engine setup'

  describe 'construction' do
    it 'accepts pluggable components' do
      expect(engine).to be_a(described_class)
    end

    it 'includes BRC100 interface' do
      expect(described_class.ancestors).to include(BSV::Wallet::Interface::BRC100)
    end
  end

  describe 'wtxid validation' do
    it 'Store#sign_action rejects display-order hex as wtxid' do
      action = store.create_action(
        action: { description: 'validation test', broadcast: :none, outgoing: false }
      )
      hex_dtxid = 'a' * 64 # 64-char hex string, not 32-byte binary
      expect do
        store.sign_action(action_id: action[:id], wtxid: hex_dtxid, raw_tx: DUMMY_RAW_TX)
      end.to raise_error(ArgumentError, /sign_action wtxid/)
    end

    it 'ProofStore#save_proof rejects display-order hex as wtxid' do
      hex_dtxid = 'b' * 64
      expect do
        proof_store.save_proof(wtxid: hex_dtxid, proof: { raw_tx: DUMMY_RAW_TX })
      end.to raise_error(ArgumentError, /save_proof wtxid/)
    end

    it 'internalize_action rejects hex entries in known_txids' do
      hex_dtxid = 'c' * 64
      expect do
        engine.internalize_action(
          tx: "\x00".b, # will fail later, but validation fires first
          description: 'validation test',
          trust_self: 'known',
          known_txids: [hex_dtxid],
          outputs: []
        )
      end.to raise_error(ArgumentError, /known_txids entry/)
    end
  end

  describe '#create_action' do
    it 'creates an action with outputs' do
      result = engine.create_action(
        description: 'test payment',
        inputs: [],
        outputs: [
          { satoshis: 500, locking_script: OP_TRUE,
            output_description: 'payment', basket: 'payments', derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
        ]
      )

      expect(result).to include(:txid, :tx)
      expect(result[:txid]).to be_a(String)
      expect(result[:txid].length).to eq(32)
    end

    it 'saves raw_tx to ProofStore at sign time' do
      result = engine.create_action(
        description: 'proof store test',
        inputs: [],
        outputs: [
          { satoshis: 500, locking_script: OP_TRUE,
            derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
        ]
      )

      wtxid = result[:txid]
      proof = proof_store.find_proof(wtxid: wtxid)
      expect(proof).not_to be_nil
      expect(proof[:raw_tx]).to be_a(String)
      expect(proof[:raw_tx].bytesize).to be >= 10
    end

    it 'creates a deferred signing action with outputs promoted immediately' do
      result = engine.create_action(
        description: 'deferred action',
        inputs: [],
        sign_and_process: false,
        outputs: [
          { satoshis: 500, locking_script: OP_TRUE,
            output_description: 'output', basket: 'deferred', derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
        ]
      )

      expect(result).to include(:signable_transaction)
      expect(result[:signable_transaction][:reference]).to be_a(String)

      # Outputs are promoted during create_action, not deferred to sign_action
      listed = engine.list_outputs(basket: 'deferred')
      expect(listed[:total_outputs]).to eq(1)

      # Unsigned raw_tx is stored on the action
      action = store.find_action(reference: result[:signable_transaction][:reference])
      expect(action[:raw_tx]).to be_a(String)
    end

    it 'creates a no-send action' do
      result = engine.create_action(
        description: 'no-send action',
        inputs: [],
        no_send: true,
        outputs: [
          { satoshis: 500, locking_script: OP_TRUE,
            output_description: 'output', basket: 'pending', derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
        ]
      )

      expect(result).to include(:txid, :tx, :no_send_change)
    end

    it 'attaches labels' do
      engine.create_action(
        description: 'labeled action',
        inputs: [],
        no_send: true,
        labels: %w[payment urgent],
        outputs: [
          { satoshis: 500, locking_script: OP_TRUE,
            output_description: 'output' }
        ]
      )

      actions = engine.list_actions(labels: ['payment'], include_labels: true)
      expect(actions[:total_actions]).to eq(1)
      expect(actions[:actions].first[:labels]).to include('payment', 'urgent')
    end

    it 'validates description length' do
      expect do
        engine.create_action(description: 'hi', inputs: [], outputs: [{ satoshis: 1, output_description: 'x' }])
      end.to raise_error(BSV::Wallet::InvalidParameterError)
    end

    it 'validates at least one input or output' do
      expect do
        engine.create_action(description: 'no inputs or outputs')
      end.to raise_error(BSV::Wallet::InvalidParameterError)
    end

    context 'with inline broadcast' do
      let(:push_response) do
        double('ProtocolResponse', http_success?: true, data: {
                 tx_status: 'SEEN_ON_NETWORK', status: 200
               })
      end
      let(:services) do
        svc = double('Services')
        allow(svc).to receive(:push!) do |broadcast|
          broadcast.write!(push_response)
          push_response
        end
        svc
      end
      let(:broadcast_queue) { BSV::Wallet::Postgres::BroadcastQueue.new(services: services) }

      it 'broadcasts inline and promotes on acceptance' do
        result = engine.create_action(
          description: 'inline broadcast',
          inputs: [],
          accept_delayed_broadcast: false,
          outputs: [
            { satoshis: 500, locking_script: OP_TRUE,
              output_description: 'output', basket: 'payments', derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
          ]
        )

        expect(result[:txid]).not_to be_nil
        expect(services).to have_received(:push!)

        # Verify outputs were promoted
        listed = engine.list_outputs(basket: 'payments')
        expect(listed[:total_outputs]).to eq(1)
      end
    end
  end

  describe '#sign_action' do
    it 'raises for non-UUID reference' do
      expect do
        engine.sign_action(spends: {}, reference: 'not-a-uuid')
      end.to raise_error(BSV::Wallet::InvalidParameterError)
    end

    it 'raises for nonexistent reference' do
      expect do
        engine.sign_action(spends: {}, reference: '00000000-0000-0000-0000-000000000000')
      end.to raise_error(BSV::Wallet::InvalidParameterError)
    end

    it 'completes a deferred signing flow with outputs only' do
      # Deferred action with outputs but no inputs
      locking_script = OP_TRUE
      create_result = engine.create_action(
        description: 'deferred outputs',
        inputs: [],
        sign_and_process: false,
        outputs: [
          { satoshis: 500, locking_script: locking_script,
            output_description: 'output', basket: 'deferred_sign', derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
        ]
      )

      reference = create_result[:signable_transaction][:reference]

      # Outputs are already in the database from create_action
      listed_before = engine.list_outputs(basket: 'deferred_sign')
      expect(listed_before[:total_outputs]).to eq(1)

      # Sign with empty spends (no inputs to sign)
      result = engine.sign_action(
        spends: {},
        reference: reference,
        no_send: true
      )

      expect(result[:txid]).to be_a(String)
      expect(result[:txid].bytesize).to eq(32)
      expect(result[:tx]).to be_a(String)

      # Verify the transaction can be deserialized
      parsed = parse_beef_tx(result[:tx])
      expect(parsed.outputs.length).to eq(1)
      expect(parsed.outputs[0].satoshis).to eq(500)

      # Outputs remain after sign_action (not duplicated)
      listed_after = engine.list_outputs(basket: 'deferred_sign')
      expect(listed_after[:total_outputs]).to eq(1)
    end
  end

  # --- apply_spends (deferred signing) (#24) ---

  describe '#apply_spends (private)' do
    # Helpers for building realistic test data
    def p2pkh_locking_script_for(private_key)
      pubkey_hash = BSV::Primitives::Digest.hash160(private_key.public_key.compressed)
      BSV::Script::Script.p2pkh_lock(pubkey_hash)
    end

    def derive_key(prefix: 'wallet payment', suffix: 'suffix1', counterparty: 'self')
      key_deriver.derive_private_key(
        protocol_id: [2, prefix], key_id: suffix, counterparty: counterparty
      )
    end

    # Fund the wallet with a real P2PKH output that can be signed
    def fund_wallet_with_keys(satoshis: 1000, count: 1,
                              prefix: 'wallet payment', suffix: 'suffix1',
                              sender_identity_key: 'self')
      derived_key = key_deriver.derive_private_key(
        protocol_id: [2, prefix], key_id: suffix,
        counterparty: sender_identity_key || 'self'
      )
      script = p2pkh_locking_script_for(derived_key)

      # Create a source action with a wtxid (needed for input resolution)
      source_action = store.create_action(
        action: { description: 'funding source', broadcast: :none, outgoing: false }
      )
      # Set a real wtxid on the source action
      source_wtxid = SecureRandom.random_bytes(32)
      store.sign_action(action_id: source_action[:id], wtxid: source_wtxid, raw_tx: DUMMY_RAW_TX)

      outputs = count.times.map do |i|
        {
          satoshis: satoshis, vout: i,
          locking_script: script.to_binary,
          basket: 'default',
          derivation_prefix: prefix,
          derivation_suffix: i.zero? ? suffix : "#{suffix}-#{i}",
          sender_identity_key: sender_identity_key
        }
      end
      store.promote_action(action_id: source_action[:id], outputs: outputs)
    end

    context 'full deferred flow with P2PKH inputs' do
      it 'wallet signs all P2PKH inputs when spends is empty' do
        fund_wallet_with_keys(satoshis: 1000)
        output_script = p2pkh_locking_script_for(derive_key).to_binary

        # Get the funded output ID
        listed = engine_with_keys.list_outputs(basket: 'default')
        output_id = listed[:outputs].first[:id]

        # Create a deferred action with an input
        create_result = engine_with_keys.create_action(
          description: 'deferred p2pkh',
          sign_and_process: false,
          inputs: [{ output_id: output_id }],
          outputs: [{ satoshis: 900, locking_script: output_script }]
        )

        reference = create_result[:signable_transaction][:reference]

        # Sign with empty spends — wallet signs the P2PKH input
        result = engine_with_keys.sign_action(
          spends: {},
          reference: reference,
          no_send: true
        )

        expect(result[:txid]).to be_a(String)
        expect(result[:txid].bytesize).to eq(32)

        # Verify the transaction is valid
        parsed = parse_beef_tx(result[:tx])
        expect(parsed.inputs.length).to eq(1)
        expect(parsed.outputs.length).to eq(1)
        expect(parsed.outputs[0].satoshis).to eq(900)

        # Verify result[:txid] contains the wire-order wtxid
        expected_wtxid = parse_beef_tx(result[:tx]).wtxid
        expect(result[:txid]).to eq(expected_wtxid)
      end
    end

    context 'caller provides unlocking scripts for all inputs' do
      it 'applies caller scripts without wallet signing' do
        fund_wallet_with_keys(satoshis: 1000)
        output_script = OP_TRUE

        listed = engine_with_keys.list_outputs(basket: 'default')
        output_id = listed[:outputs].first[:id]

        # engine_with_keys is needed because build_transaction (now called
        # during deferred create_action) requires a key_deriver for P2PKH inputs
        create_result = engine_with_keys.create_action(
          description: 'deferred caller',
          sign_and_process: false,
          inputs: [{ output_id: output_id }],
          outputs: [{ satoshis: 900, locking_script: output_script }]
        )

        reference = create_result[:signable_transaction][:reference]
        custom_unlock = "\x01\x02\x03".b

        # Caller provides unlocking script for input 0
        result = engine_with_keys.sign_action(
          spends: { 0 => { unlocking_script: custom_unlock } },
          reference: reference,
          no_send: true
        )

        expect(result[:txid]).to be_a(String)
        expect(result[:txid].bytesize).to eq(32)

        parsed = parse_beef_tx(result[:tx])
        expect(parsed.inputs[0].unlocking_script.to_binary).to eq(custom_unlock)
      end
    end

    context 'mixed signing' do
      it 'applies caller scripts for some inputs, wallet signs the rest' do
        # Fund with two outputs
        fund_wallet_with_keys(satoshis: 1000, count: 2)
        output_script = OP_TRUE

        listed = engine_with_keys.list_outputs(basket: 'default')
        output_ids = listed[:outputs].map { |o| o[:id] }

        create_result = engine_with_keys.create_action(
          description: 'deferred mixed',
          sign_and_process: false,
          inputs: output_ids.each_with_index.map { |id, i| { output_id: id, vin: i } },
          outputs: [{ satoshis: 1800, locking_script: output_script }]
        )

        reference = create_result[:signable_transaction][:reference]
        custom_unlock = "\x04\x05\x06".b

        # Caller provides script for input 0, wallet signs input 1
        result = engine_with_keys.sign_action(
          spends: { 0 => { unlocking_script: custom_unlock } },
          reference: reference,
          no_send: true
        )

        expect(result[:txid]).to be_a(String)
        expect(result[:txid].bytesize).to eq(32)

        parsed = parse_beef_tx(result[:tx])
        expect(parsed.inputs.length).to eq(2)
        # Input 0: caller-provided
        expect(parsed.inputs[0].unlocking_script.to_binary).to eq(custom_unlock)
        # Input 1: wallet-signed (has an unlocking script)
        expect(parsed.inputs[1].unlocking_script).not_to be_nil
      end
    end

    context 'invalid input reference' do
      it 'raises for non-existent vin in spends' do
        create_result = engine.create_action(
          description: 'deferred invalid',
          inputs: [],
          sign_and_process: false,
          outputs: [{ satoshis: 500, locking_script: OP_TRUE }]
        )

        reference = create_result[:signable_transaction][:reference]

        expect do
          engine.sign_action(
            spends: { 99 => { unlocking_script: "\x00".b } },
            reference: reference,
            no_send: true
          )
        end.to raise_error(BSV::Wallet::InvalidParameterError, /vin 99/)
      end
    end

    context 'output promotion at create time' do
      it 'writes outputs to the database during deferred create_action' do
        binary_script = "\x76\xa9\x14".b + ("\x00" * 20).b + "\x88\xac".b
        engine.create_action(
          description: 'deferred promo',
          inputs: [],
          sign_and_process: false,
          outputs: [
            { satoshis: 500, locking_script: binary_script,
              basket: 'deferred_test', output_description: 'test output', derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
          ]
        )

        # Outputs are in the database immediately after create_action
        listed = engine.list_outputs(basket: 'deferred_test')
        expect(listed[:total_outputs]).to eq(1)
        expect(listed[:outputs].first[:satoshis]).to eq(500)
      end

      it 'stores unsigned raw_tx on the action' do
        create_result = engine.create_action(
          description: 'deferred rawtx',
          inputs: [],
          sign_and_process: false,
          outputs: [{ satoshis: 500, locking_script: OP_TRUE }]
        )

        action = store.find_action(reference: create_result[:signable_transaction][:reference])
        expect(action[:raw_tx]).to be_a(String)

        # The unsigned raw_tx is a valid serialized transaction
        parsed = BSV::Transaction::Transaction.from_binary(action[:raw_tx])
        expect(parsed.outputs.length).to eq(1)
        expect(parsed.outputs[0].satoshis).to eq(500)
      end
    end

    context 'cascade cleanup' do
      it 'deleting an action cascades to spendable entries' do
        create_result = engine.create_action(
          description: 'cascade test action',
          inputs: [],
          sign_and_process: false,
          outputs: [
            { satoshis: 500, locking_script: OP_TRUE,
              basket: 'cascade_test', derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
          ]
        )

        # Outputs and spendable entries exist
        listed = engine.list_outputs(basket: 'cascade_test')
        expect(listed[:total_outputs]).to eq(1)

        # Abort (delete) the action
        reference = create_result[:signable_transaction][:reference]
        action = store.find_action(reference: reference)

        # Delete the action directly (simulating reaper)
        BSV::Wallet::Postgres::Action.where(id: action[:id]).delete

        # Spendable entries are gone (cascade)
        listed_after = engine.list_outputs(basket: 'cascade_test')
        expect(listed_after[:total_outputs]).to eq(0)
      end
    end

    context 'sequence number override' do
      it 'applies sequence number from spends' do
        fund_wallet_with_keys(satoshis: 1000)
        output_script = OP_TRUE

        listed = engine_with_keys.list_outputs(basket: 'default')
        output_id = listed[:outputs].first[:id]

        create_result = engine_with_keys.create_action(
          description: 'deferred seqnum',
          sign_and_process: false,
          inputs: [{ output_id: output_id }],
          outputs: [{ satoshis: 900, locking_script: output_script }]
        )

        reference = create_result[:signable_transaction][:reference]

        result = engine_with_keys.sign_action(
          spends: { 0 => { unlocking_script: "\x01".b, sequence_number: 42 } },
          reference: reference,
          no_send: true
        )

        parsed = parse_beef_tx(result[:tx])
        expect(parsed.inputs[0].sequence).to eq(42)
      end
    end
  end

  describe '#abort_action' do
    it 'aborts an unsigned action' do
      create_result = engine.create_action(
        description: 'to be aborted',
        inputs: [],
        sign_and_process: false,
        outputs: [
          { satoshis: 500, locking_script: OP_TRUE,
            output_description: 'output' }
        ]
      )

      reference = create_result[:signable_transaction][:reference]
      result = engine.abort_action(reference: reference)

      expect(result).to eq({ aborted: true })

      # Verify action is gone
      found = store.find_action(reference: reference)
      expect(found).to be_nil
    end

    it 'raises for non-UUID reference' do
      expect do
        engine.abort_action(reference: 'not-a-uuid')
      end.to raise_error(BSV::Wallet::InvalidParameterError)
    end

    it 'raises for nonexistent reference' do
      expect do
        engine.abort_action(reference: '00000000-0000-0000-0000-000000000000')
      end.to raise_error(BSV::Wallet::InvalidParameterError)
    end
  end

  describe '#list_actions' do
    before do
      engine.create_action(
        description: 'payment action', inputs: [], no_send: true, labels: ['payment'],
        outputs: [{ satoshis: 100, output_description: 'output', locking_script: "\x01".b }]
      )
      engine.create_action(
        description: 'transfer action', inputs: [], no_send: true, labels: ['transfer'],
        outputs: [{ satoshis: 200, output_description: 'output', locking_script: "\x01".b }]
      )
      engine.create_action(
        description: 'both labels', inputs: [], no_send: true, labels: %w[payment transfer],
        outputs: [{ satoshis: 300, output_description: 'output', locking_script: "\x01".b }]
      )
    end

    it 'filters by label (any mode)' do
      result = engine.list_actions(labels: ['payment'])
      expect(result[:total_actions]).to eq(2)
    end

    it 'filters by label (all mode)' do
      result = engine.list_actions(labels: %w[payment transfer], label_query_mode: :all)
      expect(result[:total_actions]).to eq(1)
    end

    it 'paginates' do
      result = engine.list_actions(labels: ['payment'], limit: 1, offset: 0)
      expect(result[:actions].size).to eq(1)
      expect(result[:total_actions]).to eq(2)
    end

    it 'includes derived status' do
      result = engine.list_actions(labels: ['payment'])
      statuses = result[:actions].map { |a| a[:status] }
      expect(statuses).to all(be_a(Symbol))
    end
  end

  describe '#internalize_action' do
    # Mock chain tracker that accepts all merkle roots.
    # Transaction#verify delegates merkle proof validation here.
    let(:chain_tracker_mock) do
      tracker = double('ChainTracker')
      allow(tracker).to receive_messages(valid_root_for_height?: true, current_height: 900_000)
      tracker
    end

    let(:engine_with_tracker) do
      described_class.new(
        store: store, utxo_pool: utxo_pool,
        broadcast_queue: broadcast_queue, proof_store: proof_store,
        chain_tracker: chain_tracker_mock, network: :mainnet
      )
    end

    # Build a verifiable BEEF with a proven ancestor, OP_1 scripts, and
    # proper input wiring so Transaction#verify succeeds.
    #
    # The subject transaction spends from a proven ancestor via OP_1
    # locking/unlocking scripts (trivially valid). Additional proven
    # ancestors are independent — they exist in the BEEF but are not
    # spent by the subject (matching the old build_test_beef shape).
    def build_test_beef(satoshis: 500, with_proof: false, ancestor_count: 0,
                        input_satoshis: nil)
      actual_input = input_satoshis || (satoshis + 100)

      # Primary ancestor: the one the subject spends from
      primary_ancestor = BSV::Transaction::Transaction.new(version: 1, lock_time: 0)
      primary_ancestor.add_output(BSV::Transaction::TransactionOutput.new(
                                    satoshis: actual_input,
                                    locking_script: BSV::Script::Script.from_binary(OP_TRUE)
                                  ))
      primary_ancestor.merkle_path = build_merkle_path(primary_ancestor, 800_000)

      beef = BSV::Transaction::Beef.new
      beef.merge_transaction(primary_ancestor)

      # Additional proven ancestors if requested (independent, not spent by subject)
      ancestor_count.times do |i|
        extra = BSV::Transaction::Transaction.new(version: 1, lock_time: 0)
        extra.add_output(BSV::Transaction::TransactionOutput.new(
                           satoshis: 1000 + i,
                           locking_script: BSV::Script::Script.from_binary(OP_TRUE)
                         ))
        extra.merkle_path = build_merkle_path(extra, 800_001 + i)
        beef.merge_transaction(extra)
      end

      # Subject transaction: spends from the primary ancestor via OP_1
      subject_tx = BSV::Transaction::Transaction.new(version: 1, lock_time: 0)
      subject_tx.add_input(BSV::Transaction::TransactionInput.new(
                             prev_wtxid: primary_ancestor.wtxid,
                             prev_tx_out_index: 0,
                             sequence: 0xFFFFFFFF,
                             unlocking_script: BSV::Script::Script.from_binary(OP_TRUE)
                           ))
      subject_tx.inputs[0].source_transaction = primary_ancestor
      subject_tx.add_output(BSV::Transaction::TransactionOutput.new(
                              satoshis: satoshis,
                              locking_script: BSV::Script::Script.from_binary(OP_TRUE)
                            ))

      subject_tx.merkle_path = build_merkle_path(subject_tx, 900_000) if with_proof

      beef.merge_transaction(subject_tx)
      beef.to_atomic_binary(subject_tx.wtxid)
    end

    def build_merkle_path(tx, block_height)
      sibling_hash = SecureRandom.random_bytes(32)
      # Offset 2 (not 0) to avoid the coinbase maturity check —
      # offset 0 is the coinbase position and requires 100-block depth.
      BSV::Transaction::MerklePath.new(
        block_height: block_height,
        path: [[
          BSV::Transaction::MerklePath::PathElement.new(offset: 2, hash: tx.wtxid, txid: true),
          BSV::Transaction::MerklePath::PathElement.new(offset: 3, hash: sibling_hash)
        ]]
      )
    end

    it 'creates a completed incoming action with basket insertion' do
      beef_data = build_test_beef(satoshis: 500)

      result = engine_with_tracker.internalize_action(
        tx: beef_data,
        description: 'incoming payment',
        labels: ['incoming'],
        outputs: [
          {
            output_index: 0,
            protocol: :basket_insertion,
            satoshis: 500,
            insertion_remittance: {
              basket: 'tokens',
              tags: ['nft'],
              custom_instructions: 'token-id-123',
              derivation_prefix: 'test', derivation_suffix: '1', sender_identity_key: 'self'
            }
          }
        ]
      )

      expect(result).to eq({ accepted: true })

      # Verify outputs are in the basket (list_outputs shares the same store)
      listed = engine.list_outputs(basket: 'tokens', include_tags: true)
      expect(listed[:total_outputs]).to eq(1)
      expect(listed[:outputs].first[:tags]).to eq(['nft'])
    end

    it 'creates a completed incoming action with wallet payment' do
      beef_data = build_test_beef(satoshis: 1000)

      result = engine_with_tracker.internalize_action(
        tx: beef_data,
        description: 'incoming payment',
        outputs: [
          {
            output_index: 0,
            protocol: :wallet_payment,
            satoshis: 1000,
            payment_remittance: {
              derivation_prefix: 'prefix123',
              derivation_suffix: 'suffix456',
              sender_identity_key: 'sender_pubkey_hex'
            }
          }
        ]
      )

      expect(result).to eq({ accepted: true })
    end

    it 'stores wtxid and raw_tx on the action' do
      beef_data = build_test_beef(satoshis: 500)

      # Parse the BEEF to get expected wtxid
      beef = BSV::Transaction::Beef.from_binary(beef_data)
      expected_wtxid = beef.subject_wtxid

      engine_with_tracker.internalize_action(
        tx: beef_data,
        description: 'wtxid storage test',
        labels: ['test'],
        outputs: [
          { output_index: 0, protocol: :basket_insertion, satoshis: 500,
            insertion_remittance: { basket: 'wtxid_test', derivation_prefix: 'test', derivation_suffix: '1', sender_identity_key: 'self' } }
        ]
      )

      listed = engine.list_actions(labels: ['test'])
      action = listed[:actions].first
      expect(action[:wtxid]).to eq(expected_wtxid)
    end

    it 'saves ancestor proofs to ProofStore' do
      beef_data = build_test_beef(satoshis: 500, ancestor_count: 2)

      # Parse to get ancestor txids
      beef = BSV::Transaction::Beef.from_binary(beef_data)
      ancestor_wtxids = beef.transactions
                            .grep(BSV::Transaction::Beef::ProvenTxEntry)
                            .map(&:wtxid)

      engine_with_tracker.internalize_action(
        tx: beef_data,
        description: 'ancestor proof test',
        outputs: [
          { output_index: 0, protocol: :basket_insertion, satoshis: 500,
            insertion_remittance: { basket: 'ancestor_test', derivation_prefix: 'test', derivation_suffix: '1', sender_identity_key: 'self' } }
        ]
      )

      ancestor_wtxids.each do |wtxid|
        proof = proof_store.find_proof(wtxid: wtxid)
        expect(proof).not_to be_nil
        expect(proof[:height]).to be_a(Integer)
        expect(proof[:merkle_path]).to be_a(String)
      end
    end

    it 'links the subject proof to the action when subject is mined' do
      beef_data = build_test_beef(satoshis: 500, with_proof: true)

      beef = BSV::Transaction::Beef.from_binary(beef_data)
      subject_wtxid = beef.subject_wtxid

      engine_with_tracker.internalize_action(
        tx: beef_data,
        description: 'proof link test',
        labels: ['proof-link'],
        outputs: [
          { output_index: 0, protocol: :basket_insertion, satoshis: 500,
            insertion_remittance: { basket: 'proof_link_test', derivation_prefix: 'test', derivation_suffix: '1', sender_identity_key: 'self' } }
        ]
      )

      # Verify the proof exists
      proof = proof_store.find_proof(wtxid: subject_wtxid)
      expect(proof).not_to be_nil

      # Verify the action has the proof linked via the txid
      action = store.find_action(wtxid: subject_wtxid)
      expect(action).not_to be_nil

      # Query the underlying record to check tx_proof_id
      action_record = BSV::Wallet::Postgres::Action.first(
        wtxid: Sequel.blob(subject_wtxid)
      )
      expect(action_record.tx_proof_id).to eq(proof[:id])
    end

    it 'does not link proof when subject has no BUMP' do
      beef_data = build_test_beef(satoshis: 500, with_proof: false)

      engine_with_tracker.internalize_action(
        tx: beef_data,
        description: 'no proof link test',
        labels: ['no-proof'],
        outputs: [
          { output_index: 0, protocol: :basket_insertion, satoshis: 500,
            insertion_remittance: { basket: 'no_proof_test', derivation_prefix: 'test', derivation_suffix: '1', sender_identity_key: 'self' } }
        ]
      )

      listed = engine.list_actions(labels: ['no-proof'])
      action = listed[:actions].first
      expect(action[:tx_proof_id]).to be_nil
    end

    it 'raises InvalidBeefError for truncated BEEF' do
      expect do
        engine_with_tracker.internalize_action(
          tx: "\x01\x00".b,
          description: 'truncated test',
          outputs: []
        )
      end.to raise_error(BSV::Wallet::InvalidBeefError, /truncated/)
    end

    it 'raises InvalidBeefError for non-BEEF data' do
      expect do
        engine_with_tracker.internalize_action(
          tx: SecureRandom.random_bytes(200),
          description: 'random data test',
          outputs: []
        )
      end.to raise_error(BSV::Wallet::InvalidBeefError)
    end

    it 'raises InvalidBeefError for BEEF with no transactions' do
      # Construct a BEEF with zero transactions
      BSV::Transaction::Beef.new
      # Manually build atomic BEEF with no transactions
      buf = [BSV::Transaction::Beef::ATOMIC_BEEF].pack('V')
      buf << ("\x00" * 32) # subject txid
      buf << [BSV::Transaction::Beef::BEEF_V1].pack('V')
      buf << "\x00" # 0 bumps
      buf << "\x00" # 0 transactions

      expect do
        engine_with_tracker.internalize_action(
          tx: buf,
          description: 'empty beef test',
          outputs: []
        )
      end.to raise_error(BSV::Wallet::InvalidBeefError, /no transactions/)
    end

    it 'validates description' do
      expect do
        engine_with_tracker.internalize_action(tx: "\x00".b, description: 'hi', outputs: [])
      end.to raise_error(BSV::Wallet::InvalidParameterError)
    end

    it 'raises InvalidBeefError without chain_tracker' do
      beef_data = build_test_beef(satoshis: 500)

      expect do
        engine.internalize_action(
          tx: beef_data,
          description: 'no tracker fails',
          outputs: []
        )
      end.to raise_error(BSV::Wallet::InvalidBeefError, /chain_tracker required/)
    end

    # --- SPV verification via Transaction#verify ---

    context 'SPV verification' do
      it 'accepts valid BEEF that passes full verification' do
        beef_data = build_test_beef(satoshis: 500)

        result = engine_with_tracker.internalize_action(
          tx: beef_data,
          description: 'valid beef passes',
          outputs: [
            { output_index: 0, protocol: :basket_insertion, satoshis: 500,
              insertion_remittance: { basket: 'spv_valid', derivation_prefix: 'test', derivation_suffix: '1', sender_identity_key: 'self' } }
          ]
        )

        expect(result).to eq({ accepted: true })
      end

      it 'verifies merkle roots against chain tracker' do
        beef_data = build_test_beef(satoshis: 500, with_proof: true)

        result = engine_with_tracker.internalize_action(
          tx: beef_data,
          description: 'chain tracker ok',
          outputs: [
            { output_index: 0, protocol: :basket_insertion, satoshis: 500,
              insertion_remittance: { basket: 'tracker_ok', derivation_prefix: 'test', derivation_suffix: '1', sender_identity_key: 'self' } }
          ]
        )

        expect(result).to eq({ accepted: true })
        expect(chain_tracker_mock).to have_received(:valid_root_for_height?).at_least(:once)
      end

      it 'rejects BEEF when chain tracker rejects a merkle root' do
        rejecting_tracker = double('ChainTracker')
        allow(rejecting_tracker).to receive_messages(valid_root_for_height?: false, current_height: 900_000)

        engine_reject = described_class.new(
          store: store, utxo_pool: utxo_pool,
          broadcast_queue: broadcast_queue, proof_store: proof_store,
          chain_tracker: rejecting_tracker, network: :mainnet
        )

        beef_data = build_test_beef(satoshis: 500)

        expect do
          engine_reject.internalize_action(
            tx: beef_data,
            description: 'tracker rejects',
            outputs: []
          )
        end.to raise_error(BSV::Wallet::InvalidBeefError, /SPV verification failed.*invalid_merkle_proof/)
      end

      it 'rejects BEEF with missing ancestor (missing_source)' do
        # Build a BEEF where the subject references an ancestor not included
        ancestor_tx = BSV::Transaction::Transaction.new(version: 1, lock_time: 0)
        ancestor_tx.add_output(BSV::Transaction::TransactionOutput.new(
                                 satoshis: 1000,
                                 locking_script: BSV::Script::Script.from_binary(OP_TRUE)
                               ))

        subject_tx = BSV::Transaction::Transaction.new(version: 1, lock_time: 0)
        subject_tx.add_input(BSV::Transaction::TransactionInput.new(
                               prev_wtxid: ancestor_tx.wtxid,
                               prev_tx_out_index: 0,
                               sequence: 0xFFFFFFFF,
                               unlocking_script: BSV::Script::Script.from_binary(OP_TRUE)
                             ))
        subject_tx.add_output(BSV::Transaction::TransactionOutput.new(
                                satoshis: 900,
                                locking_script: BSV::Script::Script.from_binary(OP_TRUE)
                              ))

        # Only include subject, not ancestor — from_binary won't wire source_transaction
        beef = BSV::Transaction::Beef.new
        beef.merge_transaction(subject_tx)
        beef_data = beef.to_atomic_binary(subject_tx.wtxid)

        expect do
          engine_with_tracker.internalize_action(
            tx: beef_data,
            description: 'missing ancestor',
            outputs: []
          )
        end.to raise_error(BSV::Wallet::InvalidBeefError, /SPV verification failed.*missing_source/)
      end
    end

    context 'fee adequacy (output overflow)' do
      it 'accepts a transaction with adequate fee' do
        beef_data = build_test_beef(satoshis: 900, input_satoshis: 1000)

        result = engine_with_tracker.internalize_action(
          tx: beef_data,
          description: 'fee adequate test',
          outputs: [
            { output_index: 0, protocol: :basket_insertion, satoshis: 900,
              insertion_remittance: { basket: 'fee_ok', derivation_prefix: 'test', derivation_suffix: '1', sender_identity_key: 'self' } }
          ]
        )

        expect(result).to eq({ accepted: true })
      end

      it 'rejects a transaction where outputs exceed inputs' do
        beef_data = build_test_beef(satoshis: 600, input_satoshis: 500)

        expect do
          engine_with_tracker.internalize_action(
            tx: beef_data,
            description: 'negative fee test',
            outputs: []
          )
        end.to raise_error(BSV::Wallet::InvalidBeefError, /SPV verification failed.*output_overflow/)
      end
    end

    # --- trustSelf and known_txids (#31) ---

    context 'trustSelf and known_txids' do
      it 'accepts BEEF with all ancestors known in ProofStore' do
        beef_data = build_test_beef(satoshis: 500, ancestor_count: 2)

        # Pre-populate ProofStore with proofs for all ancestors
        beef = BSV::Transaction::Beef.from_binary(beef_data)
        beef.transactions
            .grep(BSV::Transaction::Beef::ProvenTxEntry)
            .each do |bt|
          proof_store.save_proof(
            wtxid: bt.wtxid,
            proof: { height: 800_000, merkle_path: "\x00".b, raw_tx: bt.transaction.to_binary }
          )
        end

        result = engine_with_tracker.internalize_action(
          tx: beef_data,
          description: 'all ancestors known',
          trust_self: 'known',
          outputs: [
            { output_index: 0, protocol: :basket_insertion, satoshis: 500,
              insertion_remittance: { basket: 'trust_all', derivation_prefix: 'test', derivation_suffix: '1', sender_identity_key: 'self' } }
          ]
        )

        expect(result).to eq({ accepted: true })
      end

      it 'accepts BEEF with some ancestors known and others proven via BUMP' do
        beef_data = build_test_beef(satoshis: 500, ancestor_count: 2)

        # Only populate ProofStore for the first ancestor
        beef = BSV::Transaction::Beef.from_binary(beef_data)
        first_ancestor = beef.transactions
                             .grep(BSV::Transaction::Beef::ProvenTxEntry)
                             .first

        proof_store.save_proof(
          wtxid: first_ancestor.wtxid,
          proof: { height: 800_000, merkle_path: "\x00".b, raw_tx: first_ancestor.transaction.to_binary }
        )

        result = engine_with_tracker.internalize_action(
          tx: beef_data,
          description: 'some known some bump',
          trust_self: 'known',
          outputs: [
            { output_index: 0, protocol: :basket_insertion, satoshis: 500,
              insertion_remittance: { basket: 'trust_some', derivation_prefix: 'test', derivation_suffix: '1', sender_identity_key: 'self' } }
          ]
        )

        expect(result).to eq({ accepted: true })
      end

      it 'rejects BEEF with unknown ancestor that has no BUMP' do
        # Build a BEEF where the ancestor is missing (not included)
        ancestor_tx = BSV::Transaction::Transaction.new(version: 1, lock_time: 0)
        ancestor_tx.add_output(BSV::Transaction::TransactionOutput.new(
                                 satoshis: 1000,
                                 locking_script: BSV::Script::Script.from_binary(OP_TRUE)
                               ))

        subject_tx = BSV::Transaction::Transaction.new(version: 1, lock_time: 0)
        subject_tx.add_input(BSV::Transaction::TransactionInput.new(
                               prev_wtxid: ancestor_tx.wtxid,
                               prev_tx_out_index: 0,
                               sequence: 0xFFFFFFFF,
                               unlocking_script: BSV::Script::Script.from_binary(OP_TRUE)
                             ))
        subject_tx.add_output(BSV::Transaction::TransactionOutput.new(
                                satoshis: 900,
                                locking_script: BSV::Script::Script.from_binary(OP_TRUE)
                              ))

        beef = BSV::Transaction::Beef.new
        beef.merge_transaction(subject_tx)
        beef_data = beef.to_atomic_binary(subject_tx.wtxid)

        expect do
          engine_with_tracker.internalize_action(
            tx: beef_data,
            description: 'unknown no bump rej',
            trust_self: 'known',
            outputs: []
          )
        end.to raise_error(BSV::Wallet::InvalidBeefError, /SPV verification failed.*missing_source/)
      end

      it 'treats known_txids entries as known ancestors' do
        beef_data = build_test_beef(satoshis: 500, ancestor_count: 1)

        # Get the ancestor wtxid but do NOT put it in ProofStore
        beef = BSV::Transaction::Beef.from_binary(beef_data)
        ancestor_wtxid = beef.transactions
                             .find { |bt| bt.is_a?(BSV::Transaction::Beef::ProvenTxEntry) }
                             &.wtxid

        result = engine_with_tracker.internalize_action(
          tx: beef_data,
          description: 'known txids supple',
          trust_self: 'known',
          known_txids: [ancestor_wtxid],
          outputs: [
            { output_index: 0, protocol: :basket_insertion, satoshis: 500,
              insertion_remittance: { basket: 'known_txids', derivation_prefix: 'test', derivation_suffix: '1', sender_identity_key: 'self' } }
          ]
        )

        expect(result).to eq({ accepted: true })
      end

      it 'runs full validation without trust_self regardless of ProofStore' do
        beef_data = build_test_beef(satoshis: 500, ancestor_count: 1)

        # Pre-populate ProofStore — but since trust_self is nil, full validation runs
        beef = BSV::Transaction::Beef.from_binary(beef_data)
        beef.transactions
            .grep(BSV::Transaction::Beef::ProvenTxEntry)
            .each do |bt|
          proof_store.save_proof(
            wtxid: bt.wtxid,
            proof: { height: 800_000, merkle_path: "\x00".b, raw_tx: bt.transaction.to_binary }
          )
        end

        # Without trust_self, BEEF keeps its original proven format — validation passes
        # because the ancestors have valid BUMPs in the BEEF itself
        result = engine_with_tracker.internalize_action(
          tx: beef_data,
          description: 'no trust self full',
          outputs: [
            { output_index: 0, protocol: :basket_insertion, satoshis: 500,
              insertion_remittance: { basket: 'no_trust', derivation_prefix: 'test', derivation_suffix: '1', sender_identity_key: 'self' } }
          ]
        )

        expect(result).to eq({ accepted: true })
      end
    end

    # --- Ancestor proof chain storage (#33) ---

    context 'ancestor proof chain storage' do
      it 'stores raw_tx for each ancestor in ProofStore' do
        beef_data = build_test_beef(satoshis: 500, ancestor_count: 2)

        beef = BSV::Transaction::Beef.from_binary(beef_data)
        ancestor_wtxids = beef.transactions
                              .grep(BSV::Transaction::Beef::ProvenTxEntry)
                              .map(&:wtxid)

        engine_with_tracker.internalize_action(
          tx: beef_data,
          description: 'raw_tx storage test',
          outputs: [
            { output_index: 0, protocol: :basket_insertion, satoshis: 500,
              insertion_remittance: { basket: 'raw_tx_test', derivation_prefix: 'test', derivation_suffix: '1', sender_identity_key: 'self' } }
          ]
        )

        ancestor_wtxids.each do |wtxid|
          proof = proof_store.find_proof(wtxid: wtxid)
          expect(proof).not_to be_nil
          expect(proof[:raw_tx]).to be_a(String)
          expect(proof[:raw_tx].bytesize).to be > 0

          # Verify the raw_tx can be deserialized back to a valid transaction
          tx = BSV::Transaction::Transaction.from_binary(proof[:raw_tx])
          expect(tx.wtxid).to eq(wtxid)
        end
      end

      it 'stores consistent format from BEEF and broadcast sources' do
        # BEEF source: internalize action stores merkle_path as BRC-74 binary
        beef_data = build_test_beef(satoshis: 500, ancestor_count: 1)

        beef = BSV::Transaction::Beef.from_binary(beef_data)
        ancestor_bt = beef.transactions.find do |bt|
          bt.is_a?(BSV::Transaction::Beef::ProvenTxEntry)
        end
        ancestor_txid = ancestor_bt.wtxid

        engine_with_tracker.internalize_action(
          tx: beef_data,
          description: 'format consistency',
          outputs: [
            { output_index: 0, protocol: :basket_insertion, satoshis: 500,
              insertion_remittance: { basket: 'fmt_test', derivation_prefix: 'test', derivation_suffix: '1', sender_identity_key: 'self' } }
          ]
        )

        proof = proof_store.find_proof(wtxid: ancestor_txid)
        expect(proof[:merkle_path].encoding).to eq(Encoding::ASCII_8BIT)

        # Verify it can be deserialized as BRC-74
        mp, = BSV::Transaction::MerklePath.from_binary(proof[:merkle_path])
        expect(mp).to be_a(BSV::Transaction::MerklePath)
        expect(mp.block_height).to be_a(Integer)
      end
    end

    context 'handle_proof_from_broadcast normalization' do
      it 'normalizes hex merkle_path to binary before storing' do
        # Create an action that will receive a broadcast proof
        beef_data = build_test_beef(satoshis: 500)
        beef = BSV::Transaction::Beef.from_binary(beef_data)
        subject_wtxid = beef.subject_wtxid

        engine_with_tracker.internalize_action(
          tx: beef_data,
          description: 'hex proof normal',
          outputs: [
            { output_index: 0, protocol: :basket_insertion, satoshis: 500,
              insertion_remittance: { basket: 'hex_test', derivation_prefix: 'test', derivation_suffix: '1', sender_identity_key: 'self' } }
          ]
        )

        # Build a valid merkle path and encode as hex
        # subject_wtxid from beef is wire order — use directly as merkle path hash
        sibling_hash = SecureRandom.random_bytes(32)
        mp = BSV::Transaction::MerklePath.new(
          block_height: 850_000,
          path: [[
            BSV::Transaction::MerklePath::PathElement.new(offset: 0, hash: subject_wtxid, txid: true),
            BSV::Transaction::MerklePath::PathElement.new(offset: 1, hash: sibling_hash)
          ]]
        )
        merkle_path_hex = mp.to_binary.unpack1('H*')

        # Find the action and simulate broadcast proof with hex merkle_path
        action = store.find_action(wtxid: subject_wtxid)
        engine.send(:handle_proof_from_broadcast, action[:id], {
                      wtxid: subject_wtxid,
                      block_height: 850_000,
                      merkle_path: merkle_path_hex
                    })

        proof = proof_store.find_proof(wtxid: subject_wtxid)
        expect(proof).not_to be_nil
        expect(proof[:merkle_path].encoding).to eq(Encoding::ASCII_8BIT)

        # Verify it can be deserialized
        stored_mp, = BSV::Transaction::MerklePath.from_binary(proof[:merkle_path])
        expect(stored_mp.block_height).to eq(850_000)
      end

      it 'passes through binary merkle_path unchanged' do
        beef_data = build_test_beef(satoshis: 500)
        beef = BSV::Transaction::Beef.from_binary(beef_data)
        subject_wtxid = beef.subject_wtxid

        engine_with_tracker.internalize_action(
          tx: beef_data,
          description: 'bin proof pass',
          outputs: [
            { output_index: 0, protocol: :basket_insertion, satoshis: 500,
              insertion_remittance: { basket: 'bin_test', derivation_prefix: 'test', derivation_suffix: '1', sender_identity_key: 'self' } }
          ]
        )

        # subject_wtxid from beef is wire order — use directly as merkle path hash
        sibling_hash = SecureRandom.random_bytes(32)
        mp = BSV::Transaction::MerklePath.new(
          block_height: 850_000,
          path: [[
            BSV::Transaction::MerklePath::PathElement.new(offset: 0, hash: subject_wtxid, txid: true),
            BSV::Transaction::MerklePath::PathElement.new(offset: 1, hash: sibling_hash)
          ]]
        )
        merkle_path_binary = mp.to_binary

        action = store.find_action(wtxid: subject_wtxid)
        engine.send(:handle_proof_from_broadcast, action[:id], {
                      wtxid: subject_wtxid,
                      block_height: 850_000,
                      merkle_path: merkle_path_binary
                    })

        proof = proof_store.find_proof(wtxid: subject_wtxid)
        expect(proof[:merkle_path]).to eq(merkle_path_binary)
      end

      it 'stores raw_tx from the action for BEEF construction' do
        # Create an outgoing action so it has raw_tx set
        locking_script = OP_TRUE
        result = engine.create_action(
          description: 'broadcast raw_tx',
          inputs: [],
          no_send: true,
          outputs: [{ satoshis: 500, locking_script: locking_script,
                      basket: 'proof_raw_tx' }]
        )

        wtxid = result[:txid]
        action = store.find_action(wtxid: wtxid)

        # Simulate ARC returning MINED with merkle_path
        # wtxid is wire order — use directly as merkle path hash
        sibling_hash = SecureRandom.random_bytes(32)
        mp = BSV::Transaction::MerklePath.new(
          block_height: 850_000,
          path: [[
            BSV::Transaction::MerklePath::PathElement.new(offset: 0, hash: wtxid, txid: true),
            BSV::Transaction::MerklePath::PathElement.new(offset: 1, hash: sibling_hash)
          ]]
        )

        engine.send(:handle_proof_from_broadcast, action[:id], {
                      wtxid: wtxid,
                      block_height: 850_000,
                      merkle_path: mp.to_binary
                    })

        proof = proof_store.find_proof(wtxid: wtxid)
        expect(proof).not_to be_nil
        expect(proof[:raw_tx]).not_to be_nil
        expect(proof[:raw_tx].bytesize).to be > 0
      end
    end

    # --- verify_incoming_transaction! unit tests ---

    context 'verify_incoming_transaction!' do
      it 'raises InvalidBeefError when chain_tracker is nil' do
        subject_tx = instance_double(BSV::Transaction::Transaction)
        expect do
          engine.send(:verify_incoming_transaction!, subject_tx)
        end.to raise_error(BSV::Wallet::InvalidBeefError, /chain_tracker required/)
      end

      it 'delegates to Transaction#verify on success' do
        subject_tx = instance_double(BSV::Transaction::Transaction)
        allow(subject_tx).to receive(:verify).with(chain_tracker: chain_tracker_mock).and_return(true)

        expect(engine_with_tracker.send(:verify_incoming_transaction!, subject_tx)).to be true
        expect(subject_tx).to have_received(:verify).with(chain_tracker: chain_tracker_mock)
      end

      it 'wraps VerificationError(:invalid_merkle_proof) into InvalidBeefError' do
        subject_tx = instance_double(BSV::Transaction::Transaction)
        allow(subject_tx).to receive(:verify).and_raise(
          BSV::Transaction::VerificationError.new(:invalid_merkle_proof, 'bad proof')
        )

        expect do
          engine_with_tracker.send(:verify_incoming_transaction!, subject_tx)
        end.to raise_error(BSV::Wallet::InvalidBeefError, /SPV verification failed.*bad proof.*invalid_merkle_proof/)
      end

      it 'wraps VerificationError(:script_failure) into InvalidBeefError' do
        subject_tx = instance_double(BSV::Transaction::Transaction)
        allow(subject_tx).to receive(:verify).and_raise(
          BSV::Transaction::VerificationError.new(:script_failure, 'script failed')
        )

        expect do
          engine_with_tracker.send(:verify_incoming_transaction!, subject_tx)
        end.to raise_error(BSV::Wallet::InvalidBeefError, /SPV verification failed.*script failed.*script_failure/)
      end

      it 'wraps VerificationError(:output_overflow) into InvalidBeefError' do
        subject_tx = instance_double(BSV::Transaction::Transaction)
        allow(subject_tx).to receive(:verify).and_raise(
          BSV::Transaction::VerificationError.new(:output_overflow, 'outputs exceed inputs')
        )

        expect do
          engine_with_tracker.send(:verify_incoming_transaction!, subject_tx)
        end.to raise_error(BSV::Wallet::InvalidBeefError, /SPV verification failed.*outputs exceed inputs.*output_overflow/)
      end

      it 'wraps VerificationError(:missing_source) into InvalidBeefError' do
        subject_tx = instance_double(BSV::Transaction::Transaction)
        allow(subject_tx).to receive(:verify).and_raise(
          BSV::Transaction::VerificationError.new(:missing_source, 'no source data')
        )

        expect do
          engine_with_tracker.send(:verify_incoming_transaction!, subject_tx)
        end.to raise_error(BSV::Wallet::InvalidBeefError, /SPV verification failed.*no source data.*missing_source/)
      end
    end

    # --- CRITICAL: TXID-only + verify integration test ---
    #
    # This validates the highest-risk assumption in the chain tracker pivot:
    # that make_txid_only (which mutates the BEEF's @transactions list)
    # does NOT invalidate in-memory source_transaction pointers wired by
    # Beef.from_binary. Transaction#verify walks via input.source_transaction,
    # not the BEEF list, so verification must succeed after TXID-only conversion.

    context 'TXID-only + verify integration' do
      it 'verify succeeds after replace_known_ancestors! converts ancestors to TXID-only' do
        # Build a BEEF with a proven ancestor that the subject spends
        ancestor = BSV::Transaction::Transaction.new(version: 1, lock_time: 0)
        ancestor.add_output(BSV::Transaction::TransactionOutput.new(
                              satoshis: 1000,
                              locking_script: BSV::Script::Script.from_binary(OP_TRUE)
                            ))
        ancestor.merkle_path = build_merkle_path(ancestor, 800_000)

        subject_tx = BSV::Transaction::Transaction.new(version: 1, lock_time: 0)
        subject_tx.add_input(BSV::Transaction::TransactionInput.new(
                               prev_wtxid: ancestor.wtxid,
                               prev_tx_out_index: 0,
                               sequence: 0xFFFFFFFF,
                               unlocking_script: BSV::Script::Script.from_binary(OP_TRUE)
                             ))
        subject_tx.inputs[0].source_transaction = ancestor
        subject_tx.add_output(BSV::Transaction::TransactionOutput.new(
                                satoshis: 900,
                                locking_script: BSV::Script::Script.from_binary(OP_TRUE)
                              ))

        beef = BSV::Transaction::Beef.new
        beef.merge_transaction(ancestor)
        beef.merge_transaction(subject_tx)
        beef_data = beef.to_atomic_binary(subject_tx.wtxid)

        # Step 1: Parse BEEF (wires source_transaction pointers)
        parsed_beef, parsed_subject = engine_with_tracker.send(:parse_beef, beef_data)

        # Verify the source_transaction pointer is wired
        expect(parsed_subject.inputs[0].source_transaction).not_to be_nil
        expect(parsed_subject.inputs[0].source_transaction.merkle_path).not_to be_nil

        # Step 2: Replace known ancestors with TXID-only
        # Pre-populate ProofStore so the ancestor is "known"
        proof_store.save_proof(
          wtxid: ancestor.wtxid,
          proof: { raw_tx: ancestor.to_binary, merkle_path: ancestor.merkle_path.to_binary, height: 800_000 }
        )
        engine_with_tracker.send(:replace_known_ancestors!, parsed_beef, parsed_subject.wtxid, nil)

        # Verify the BEEF entry was replaced with TXID-only
        replaced = parsed_beef.transactions.find { |bt| bt.wtxid == ancestor.wtxid }
        expect(replaced).to be_a(BSV::Transaction::Beef::TxidOnlyEntry)

        # Verify the in-memory source_transaction pointer SURVIVES the BEEF list mutation
        expect(parsed_subject.inputs[0].source_transaction).not_to be_nil
        expect(parsed_subject.inputs[0].source_transaction.merkle_path).not_to be_nil

        # Step 3: verify SUCCEEDS — the critical assertion
        expect(parsed_subject.verify(chain_tracker: chain_tracker_mock)).to be true
      end
    end
  end

  describe '#list_outputs' do
    before do
      engine.create_action(
        description: 'create outputs', inputs: [], no_send: true,
        outputs: [
          { satoshis: 500, locking_script: OP_TRUE,
            output_description: 'first', basket: 'wallet', tags: ['payment'],
            derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' },
          { satoshis: 300, locking_script: OP_TRUE,
            output_description: 'second', basket: 'wallet', tags: ['change'],
            derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' },
          { satoshis: 100, locking_script: OP_TRUE,
            output_description: 'third', basket: 'other',
            derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
        ]
      )
    end

    it 'filters by basket' do
      result = engine.list_outputs(basket: 'wallet')
      expect(result[:total_outputs]).to eq(2)
    end

    it 'filters by tag' do
      result = engine.list_outputs(basket: 'wallet', tags: ['payment'])
      expect(result[:total_outputs]).to eq(1)
    end

    it 'paginates' do
      result = engine.list_outputs(basket: 'wallet', limit: 1)
      expect(result[:outputs].size).to eq(1)
      expect(result[:total_outputs]).to eq(2)
    end
  end

  describe '#relinquish_output' do
    it 'removes output from tracking' do
      engine.create_action(
        description: 'with output', inputs: [], no_send: true,
        outputs: [
          { satoshis: 500, locking_script: OP_TRUE,
            output_description: 'to relinquish', basket: 'wallet',
            derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
        ]
      )

      listed = engine.list_outputs(basket: 'wallet')
      output_id = listed[:outputs].first[:id]

      result = engine.relinquish_output(basket: 'wallet', output: output_id)
      expect(result).to eq({ relinquished: true })

      listed_after = engine.list_outputs(basket: 'wallet')
      expect(listed_after[:total_outputs]).to eq(0)
    end
  end

  describe '#get_public_key' do
    it 'returns the identity key when identity_key: true' do
      result = engine_with_keys.get_public_key(identity_key: true)
      expect(result[:public_key]).to be_a(String)
      expect(result[:public_key].length).to eq(66)
      expect(result[:public_key]).to match(/\A(?:02|03)[0-9a-f]{64}\z/)
      expect(result[:public_key]).to eq(root_key.public_key.to_hex)
    end

    it 'derives a public key with protocol_id and key_id' do
      result = engine_with_keys.get_public_key(
        protocol_id: [1, 'test proto'], key_id: 'key1', counterparty: 'self'
      )
      expect(result[:public_key]).to be_a(String)
      expect(result[:public_key].bytesize).to eq(33)

      # Verify determinism — same params yield same key
      result2 = engine_with_keys.get_public_key(
        protocol_id: [1, 'test proto'], key_id: 'key1', counterparty: 'self'
      )
      expect(result2[:public_key]).to eq(result[:public_key])
    end

    it 'raises without key_deriver' do
      expect { engine.get_public_key(identity_key: true) }
        .to raise_error(BSV::Wallet::Error, /key deriver/)
    end
  end

  describe '#reveal_counterparty_key_linkage' do
    it 'returns revelation with encrypted linkage and proof' do
      result = engine_with_keys.reveal_counterparty_key_linkage(
        counterparty: counterparty_hex,
        verifier: verifier_hex
      )
      expect(result).to include(:prover, :verifier, :counterparty,
                                :revelation_time, :encrypted_linkage, :encrypted_linkage_proof)
      expect(result[:prover]).to eq(root_key.public_key.to_hex)
      expect(result[:verifier]).to eq(verifier_hex)
      expect(result[:counterparty]).to eq(counterparty_hex)
      expect(result[:encrypted_linkage]).to be_a(String)
      expect(result[:encrypted_linkage_proof]).to be_a(String)
    end
  end

  describe '#reveal_specific_key_linkage' do
    it 'returns revelation with encrypted linkage and proof_type' do
      result = engine_with_keys.reveal_specific_key_linkage(
        counterparty: counterparty_hex,
        verifier: verifier_hex,
        protocol_id: [1, 'test proto'], key_id: 'key1'
      )
      expect(result).to include(:prover, :encrypted_linkage, :encrypted_linkage_proof, :proof_type)
      expect(result[:prover]).to eq(root_key.public_key.to_hex)
      expect(result[:proof_type]).to eq(0)
    end
  end

  describe '#encrypt / #decrypt' do
    let(:plaintext) { 'hello world'.b }

    it 'encrypts data to ciphertext different from plaintext' do
      result = engine_with_keys.encrypt(
        plaintext: plaintext,
        protocol_id: [1, 'encryption test'], key_id: 'enc1'
      )
      expect(result[:ciphertext]).to be_a(String)
      expect(result[:ciphertext]).not_to eq(plaintext)
    end

    it 'round-trips encrypt then decrypt' do
      encrypted = engine_with_keys.encrypt(
        plaintext: plaintext,
        protocol_id: [1, 'encryption test'], key_id: 'enc1'
      )
      decrypted = engine_with_keys.decrypt(
        ciphertext: encrypted[:ciphertext],
        protocol_id: [1, 'encryption test'], key_id: 'enc1'
      )
      expect(decrypted[:plaintext]).to eq(plaintext)
    end

    it 'raises without key_deriver' do
      expect do
        engine.encrypt(plaintext: 'data'.b, protocol_id: [1, 'test proto'], key_id: 'k')
      end.to raise_error(BSV::Wallet::Error, /key deriver/)
    end
  end

  describe '#create_hmac / #verify_hmac' do
    it 'creates a 32-byte HMAC' do
      result = engine_with_keys.create_hmac(
        data: 'test data'.b, protocol_id: [1, 'hmac test proto'], key_id: 'h1'
      )
      expect(result[:hmac]).to be_a(String)
      expect(result[:hmac].bytesize).to eq(32)
    end

    it 'round-trips create then verify' do
      created = engine_with_keys.create_hmac(
        data: 'test data'.b, protocol_id: [1, 'hmac test proto'], key_id: 'h1'
      )
      result = engine_with_keys.verify_hmac(
        data: 'test data'.b, hmac: created[:hmac],
        protocol_id: [1, 'hmac test proto'], key_id: 'h1'
      )
      expect(result).to eq({ valid: true })
    end

    it 'raises InvalidHmacError for wrong HMAC' do
      expect do
        engine_with_keys.verify_hmac(
          data: 'test data'.b, hmac: SecureRandom.random_bytes(32),
          protocol_id: [1, 'hmac test proto'], key_id: 'h1'
        )
      end.to raise_error(BSV::Wallet::InvalidHmacError)
    end
  end

  describe '#create_signature / #verify_signature' do
    it 'creates a signature object' do
      result = engine_with_keys.create_signature(
        data: 'sign me'.b, protocol_id: [1, 'sig test proto'], key_id: 's1'
      )
      expect(result[:signature]).to be_a(BSV::Primitives::Signature)
    end

    it 'round-trips create then verify' do
      created = engine_with_keys.create_signature(
        data: 'sign me'.b, protocol_id: [1, 'sig test proto'], key_id: 's1'
      )
      result = engine_with_keys.verify_signature(
        signature: created[:signature], data: 'sign me'.b,
        protocol_id: [1, 'sig test proto'], key_id: 's1'
      )
      expect(result).to eq({ valid: true })
    end

    it 'raises InvalidSignatureError for wrong data' do
      created = engine_with_keys.create_signature(
        data: 'sign me'.b, protocol_id: [1, 'sig test proto'], key_id: 's1'
      )

      expect do
        engine_with_keys.verify_signature(
          signature: created[:signature], data: 'wrong data'.b,
          protocol_id: [1, 'sig test proto'], key_id: 's1'
        )
      end.to raise_error(BSV::Wallet::InvalidSignatureError)
    end
  end

  describe '#acquire_certificate' do
    it 'acquires a certificate directly' do
      result = engine_with_keys.acquire_certificate(
        type: 'identity', certifier: 'certifier_key',
        acquisition_protocol: :direct,
        fields: { 'name' => 'Alice', 'email' => 'alice@test.com' },
        serial_number: 'sn001', signature: 'sig_hex'
      )

      expect(result[:id]).to be_a(Integer)
      expect(result[:fields]).to eq({ 'name' => 'Alice', 'email' => 'alice@test.com' })
    end

    it 'raises for issuance protocol (not yet supported)' do
      expect do
        engine_with_keys.acquire_certificate(
          type: 'identity', certifier: 'c1',
          acquisition_protocol: :issuance,
          fields: {}, certifier_url: 'https://cert.example.com'
        )
      end.to raise_error(BSV::Wallet::UnsupportedActionError)
    end
  end

  describe '#list_certificates' do
    before do
      engine_with_keys.acquire_certificate(
        type: 'id', certifier: 'c1', acquisition_protocol: :direct,
        fields: { 'name' => 'Alice' }, serial_number: 'sn1', signature: 's1'
      )
      engine_with_keys.acquire_certificate(
        type: 'id', certifier: 'c2', acquisition_protocol: :direct,
        fields: { 'name' => 'Bob' }, serial_number: 'sn2', signature: 's2'
      )
    end

    it 'lists certificates filtered by certifier and type' do
      result = engine_with_keys.list_certificates(certifiers: ['c1'], types: ['id'])
      expect(result[:total_certificates]).to eq(1)
      expect(result[:certificates].first[:fields]['name']).to eq('Alice')
    end
  end

  describe '#prove_certificate' do
    it 'derives revelation keyring for the verifier' do
      certifier_deriver = BSV::Wallet::KeyDeriver.new(private_key: counterparty_key)
      cert_type = 'id'
      serial = 'sn1'

      # Certifier encrypts field keys for the subject (BRC-52)
      encrypt_protocol = [2, "authrite certificate field encryption #{cert_type}"]
      keyring = {
        'name' => certifier_deriver.encrypt(
          plaintext: SecureRandom.random_bytes(32),
          protocol_id: encrypt_protocol,
          key_id: "#{serial} name",
          counterparty: key_deriver.identity_key
        )
      }

      # Build certificate hash with keyring (prove_certificate operates on
      # the in-memory hash, not the DB record)
      cert = {
        type: cert_type,
        serial_number: serial,
        certifier: counterparty_hex,
        subject: key_deriver.identity_key,
        fields: { 'name' => 'Alice' },
        keyring: keyring
      }

      result = engine_with_keys.prove_certificate(
        certificate: cert, fields_to_reveal: ['name'],
        verifier: verifier_hex
      )

      expect(result[:keyring_for_verifier]).to be_a(Hash)
      expect(result[:keyring_for_verifier]).to have_key('name')
      expect(result[:keyring_for_verifier]['name']).to be_a(String)
    end
  end

  describe '#relinquish_certificate' do
    it 'soft-deletes a certificate' do
      engine_with_keys.acquire_certificate(
        type: 'id', certifier: 'c1', acquisition_protocol: :direct,
        fields: { 'name' => 'Alice' }, serial_number: 'sn1', signature: 's1'
      )

      result = engine_with_keys.relinquish_certificate(
        type: 'id', serial_number: 'sn1', certifier: 'c1'
      )
      expect(result).to eq({ relinquished: true })

      listed = engine_with_keys.list_certificates(certifiers: ['c1'], types: ['id'])
      expect(listed[:total_certificates]).to eq(0)
    end
  end

  describe '#authenticated?' do
    it 'returns true with key_deriver' do
      expect(engine_with_keys.authenticated?).to eq({ authenticated: true })
    end

    it 'returns false without key_deriver' do
      expect(engine.authenticated?).to eq({ authenticated: false })
    end
  end

  describe '#wait_for_authentication' do
    it 'returns immediately when authenticated' do
      expect(engine_with_keys.wait_for_authentication).to eq({ authenticated: true })
    end

    it 'raises when not authenticated' do
      expect { engine.wait_for_authentication }.to raise_error(BSV::Wallet::Error)
    end
  end

  describe 'privileged mode' do
    it 'derives a different public key with privileged: true' do
      normal = engine_with_privileged_keys.get_public_key(
        protocol_id: [1, 'test proto'], key_id: 'key1', counterparty: 'self'
      )
      privileged = engine_with_privileged_keys.get_public_key(
        protocol_id: [1, 'test proto'], key_id: 'key1', counterparty: 'self',
        privileged: true
      )
      expect(privileged[:public_key]).not_to eq(normal[:public_key])
    end

    it 'round-trips encrypt/decrypt with privileged: true' do
      plaintext = 'privileged secret'.b
      encrypted = engine_with_privileged_keys.encrypt(
        plaintext: plaintext,
        protocol_id: [1, 'priv encrypt test'], key_id: 'p1',
        privileged: true
      )
      decrypted = engine_with_privileged_keys.decrypt(
        ciphertext: encrypted[:ciphertext],
        protocol_id: [1, 'priv encrypt test'], key_id: 'p1',
        privileged: true
      )
      expect(decrypted[:plaintext]).to eq(plaintext)
    end

    it 'round-trips HMAC create/verify with privileged: true' do
      created = engine_with_privileged_keys.create_hmac(
        data: 'privileged data'.b, protocol_id: [1, 'priv hmac test'], key_id: 'p1',
        privileged: true
      )
      result = engine_with_privileged_keys.verify_hmac(
        data: 'privileged data'.b, hmac: created[:hmac],
        protocol_id: [1, 'priv hmac test'], key_id: 'p1',
        privileged: true
      )
      expect(result).to eq({ valid: true })
    end

    it 'round-trips signature create/verify with privileged: true' do
      created = engine_with_privileged_keys.create_signature(
        data: 'privileged data'.b, protocol_id: [1, 'priv sig test'], key_id: 'p1',
        privileged: true
      )
      result = engine_with_privileged_keys.verify_signature(
        signature: created[:signature], data: 'privileged data'.b,
        protocol_id: [1, 'priv sig test'], key_id: 'p1',
        privileged: true
      )
      expect(result).to eq({ valid: true })
    end

    it 'raises when privileged key is not configured' do
      expect do
        engine_with_keys.get_public_key(
          protocol_id: [1, 'test proto'], key_id: 'key1',
          counterparty: 'self', privileged: true
        )
      end.to raise_error(BSV::Wallet::Error, /privileged key/)
    end
  end

  describe '#get_height' do
    it 'raises UnsupportedActionError (chain data source not configured)' do
      expect { engine.get_height }.to raise_error(BSV::Wallet::UnsupportedActionError)
    end
  end

  describe '#get_header_for_height' do
    it 'raises UnsupportedActionError (chain data source not configured)' do
      expect { engine.get_header_for_height(height: 1) }.to raise_error(BSV::Wallet::UnsupportedActionError)
    end
  end

  describe '#get_network' do
    it 'returns the configured network' do
      expect(engine.get_network).to eq({ network: :mainnet })
    end
  end

  describe '#get_version' do
    it 'returns the wallet version' do
      result = engine.get_version
      expect(result[:version]).to start_with('bsv-wallet-')
    end
  end

  # --- Output Construction and Randomization (#21) ---

  describe '#build_outputs (private)' do
    # Access the private method for direct testing
    def build_outputs(outputs, randomize)
      engine.send(:build_outputs, outputs, randomize)
    end

    def resolve_locking_script(data)
      engine.send(:resolve_locking_script, data)
    end

    it 'returns empty array and empty mapping for nil outputs' do
      tx_outputs, vout_mapping = build_outputs(nil, false)
      expect(tx_outputs).to eq([])
      expect(vout_mapping).to eq({})
    end

    it 'returns empty array and empty mapping for empty outputs' do
      tx_outputs, vout_mapping = build_outputs([], false)
      expect(tx_outputs).to eq([])
      expect(vout_mapping).to eq({})
    end

    it 'builds TransactionOutput objects from binary locking scripts' do
      script_bytes = "\x76\xa9\x14".b + ("\x00" * 20).b + "\x88\xac".b # P2PKH pattern
      outputs = [
        { satoshis: 1000, locking_script: script_bytes },
        { satoshis: 2000, locking_script: "\x6a\x05hello".b } # OP_RETURN
      ]

      tx_outputs, vout_mapping = build_outputs(outputs, false)

      expect(tx_outputs.length).to eq(2)
      expect(tx_outputs[0]).to be_a(BSV::Transaction::TransactionOutput)
      expect(tx_outputs[0].satoshis).to eq(1000)
      expect(tx_outputs[0].locking_script.to_binary).to eq(script_bytes)
      expect(tx_outputs[1].satoshis).to eq(2000)
      expect(vout_mapping).to eq({ 0 => 0, 1 => 1 })
    end

    it 'builds TransactionOutput objects from hex locking scripts' do
      hex_script = "76a914#{'00' * 20}88ac"
      outputs = [{ satoshis: 500, locking_script: hex_script }]

      tx_outputs, _vout_mapping = build_outputs(outputs, false)

      expect(tx_outputs.length).to eq(1)
      expect(tx_outputs[0].locking_script.p2pkh?).to be true
    end

    it 'defaults satoshis to 0 when not specified' do
      outputs = [{ locking_script: "\x6a".b }]

      tx_outputs, _vout_mapping = build_outputs(outputs, false)

      expect(tx_outputs[0].satoshis).to eq(0)
    end

    it 'preserves OP_RETURN scripts without modification' do
      op_return_script = "\x00\x6a\x05hello".b # OP_FALSE OP_RETURN <data>
      outputs = [{ satoshis: 0, locking_script: op_return_script }]

      tx_outputs, _vout_mapping = build_outputs(outputs, false)

      expect(tx_outputs[0].locking_script.to_binary).to eq(op_return_script)
      expect(tx_outputs[0].locking_script.op_return?).to be true
    end

    context 'with randomization disabled' do
      it 'preserves original output order' do
        outputs = 5.times.map do |i|
          { satoshis: (i + 1) * 100, locking_script: "\x6a#{[i].pack('C')}".b }
        end

        tx_outputs, vout_mapping = build_outputs(outputs, false)

        expect(tx_outputs.map(&:satoshis)).to eq([100, 200, 300, 400, 500])
        expect(vout_mapping).to eq({ 0 => 0, 1 => 1, 2 => 2, 3 => 3, 4 => 4 })
      end
    end

    context 'with randomization enabled' do
      it 'shuffles output order (statistical)' do
        outputs = 10.times.map do |i|
          { satoshis: (i + 1) * 100, locking_script: OP_TRUE }
        end

        original_order = outputs.map { |o| o[:satoshis] }

        # Run multiple times — at least one should differ from original order
        shuffled = false
        20.times do
          tx_outputs, _vout_mapping = build_outputs(outputs, true)
          if tx_outputs.map(&:satoshis) != original_order
            shuffled = true
            break
          end
        end

        expect(shuffled).to be(true), 'Expected shuffle to change order at least once in 20 attempts'
      end

      it 'preserves all outputs (no data loss)' do
        outputs = 5.times.map do |i|
          { satoshis: (i + 1) * 100, locking_script: OP_TRUE }
        end

        tx_outputs, _vout_mapping = build_outputs(outputs, true)

        expect(tx_outputs.map(&:satoshis).sort).to eq([100, 200, 300, 400, 500])
      end

      it 'produces correct vout mapping' do
        outputs = 5.times.map do |i|
          { satoshis: (i + 1) * 100, locking_script: OP_TRUE }
        end

        tx_outputs, vout_mapping = build_outputs(outputs, true)

        # Every original index should map to exactly one new position
        expect(vout_mapping.keys.sort).to eq([0, 1, 2, 3, 4])
        expect(vout_mapping.values.sort).to eq([0, 1, 2, 3, 4])

        # Verify the mapping is consistent: the output at vout_mapping[i]
        # should have the satoshis of the original output at index i
        outputs.each_with_index do |out, orig_idx|
          new_vout = vout_mapping[orig_idx]
          expect(tx_outputs[new_vout].satoshis).to eq(out[:satoshis])
        end
      end

      it 'is a no-op for a single output' do
        outputs = [{ satoshis: 1000, locking_script: OP_TRUE }]

        tx_outputs, vout_mapping = build_outputs(outputs, true)

        expect(tx_outputs.length).to eq(1)
        expect(tx_outputs[0].satoshis).to eq(1000)
        expect(vout_mapping).to eq({ 0 => 0 })
      end
    end
  end

  # --- Input Resolution and P2PKH Signing (#22) ---

  describe '#build_inputs (private)' do
    # Use engine_with_keys for key derivation
    def build_inputs(resolved_inputs, caller_inputs)
      engine_with_keys.send(:build_inputs, resolved_inputs, caller_inputs)
    end

    # Helper: generate a P2PKH locking script for a derived key
    def p2pkh_locking_script_for(private_key)
      pubkey_hash = BSV::Primitives::Digest.hash160(private_key.public_key.compressed)
      BSV::Script::Script.p2pkh_lock(pubkey_hash)
    end

    # Helper: build a resolved input hash matching Store#resolve_inputs_for_signing output
    def make_resolved_input(vin:, private_key: nil, locking_script: nil,
                            satoshis: 1000, sender_identity_key: nil,
                            derivation_prefix: 'wallet payment',
                            derivation_suffix: 'suffix1')
      script = if locking_script
                 locking_script
               elsif private_key
                 p2pkh_locking_script_for(private_key).to_binary
               else
                 OP_TRUE
               end

      {
        vin: vin,
        sequence: 0xFFFFFFFF,
        source_wtxid: SecureRandom.random_bytes(32),
        source_vout: 0,
        source_satoshis: satoshis,
        source_locking_script: script,
        derivation_prefix: derivation_prefix,
        derivation_suffix: derivation_suffix,
        sender_identity_key: sender_identity_key
      }
    end

    it 'returns empty arrays for nil inputs' do
      tx_inputs, signing_keys = build_inputs(nil, nil)
      expect(tx_inputs).to eq([])
      expect(signing_keys).to eq({})
    end

    it 'returns empty arrays for empty inputs' do
      tx_inputs, signing_keys = build_inputs([], [])
      expect(tx_inputs).to eq([])
      expect(signing_keys).to eq({})
    end

    it 'builds TransactionInput with correct outpoint' do
      source_wtxid = SecureRandom.random_bytes(32)
      # Derive the key the same way the engine will
      derived_key = key_deriver.derive_private_key(
        protocol_id: [2, 'wallet payment'], key_id: 'suffix1', counterparty: 'self'
      )
      resolved = [make_resolved_input(vin: 0, private_key: derived_key).merge(source_wtxid: source_wtxid, source_vout: 2)]

      tx_inputs, _signing_keys = build_inputs(resolved, nil)

      expect(tx_inputs.length).to eq(1)
      expect(tx_inputs[0]).to be_a(BSV::Transaction::TransactionInput)
      expect(tx_inputs[0].prev_wtxid).to eq(source_wtxid)
      expect(tx_inputs[0].prev_tx_out_index).to eq(2)
      expect(tx_inputs[0].sequence).to eq(0xFFFFFFFF)
    end

    it 'sets source_satoshis and source_locking_script for sighash' do
      derived_key = key_deriver.derive_private_key(
        protocol_id: [2, 'wallet payment'], key_id: 'suffix1', counterparty: 'self'
      )
      p2pkh_locking_script_for(derived_key)
      resolved = [make_resolved_input(vin: 0, private_key: derived_key, satoshis: 5000)]

      tx_inputs, _signing_keys = build_inputs(resolved, nil)

      expect(tx_inputs[0].source_satoshis).to eq(5000)
      expect(tx_inputs[0].source_locking_script).to be_a(BSV::Script::Script)
      expect(tx_inputs[0].source_locking_script.p2pkh?).to be true
    end

    it 'derives signing key for P2PKH inputs' do
      derived_key = key_deriver.derive_private_key(
        protocol_id: [2, 'wallet payment'], key_id: 'suffix1', counterparty: 'self'
      )
      resolved = [make_resolved_input(vin: 0, private_key: derived_key)]

      _tx_inputs, signing_keys = build_inputs(resolved, nil)

      expect(signing_keys[0]).to be_a(BSV::Primitives::PrivateKey)
      # The derived key should produce the same public key
      expect(signing_keys[0].public_key.compressed).to eq(derived_key.public_key.compressed)
    end

    it 'signs a P2PKH input that verifies correctly' do
      derived_key = key_deriver.derive_private_key(
        protocol_id: [2, 'wallet payment'], key_id: 'suffix1', counterparty: 'self'
      )
      script = p2pkh_locking_script_for(derived_key)
      resolved = [make_resolved_input(vin: 0, private_key: derived_key, satoshis: 1000)]

      tx_inputs, signing_keys = build_inputs(resolved, nil)

      # Build a minimal transaction to verify signing works end-to-end
      tx = BSV::Transaction::Transaction.new
      tx.add_input(tx_inputs[0])
      tx.add_output(BSV::Transaction::TransactionOutput.new(satoshis: 900, locking_script: script))

      # Sign with the derived key
      tx.sign(0, signing_keys[0])

      expect(tx_inputs[0].unlocking_script).not_to be_nil
      expect(tx.verify_input(0)).to be true
    end

    it 'applies caller-provided unlocking script for custom inputs' do
      custom_unlock = "\x01\x02\x03".b
      custom_lock = "\x04\x05\x06".b # Non-P2PKH locking script
      resolved = [make_resolved_input(vin: 0, locking_script: custom_lock)]
      caller_inputs = [{ vin: 0, unlocking_script: custom_unlock }]

      tx_inputs, signing_keys = build_inputs(resolved, caller_inputs)

      expect(tx_inputs[0].unlocking_script).to be_a(BSV::Script::Script)
      expect(tx_inputs[0].unlocking_script.to_binary).to eq(custom_unlock)
      expect(signing_keys).to be_empty
    end

    it 'uses counterparty self for nil sender_identity_key' do
      # Derive a key as self-payment
      self_key = key_deriver.derive_private_key(
        protocol_id: [2, 'wallet payment'], key_id: 'self-suffix', counterparty: 'self'
      )
      resolved = [make_resolved_input(
        vin: 0, private_key: self_key,
        sender_identity_key: nil,
        derivation_suffix: 'self-suffix'
      )]

      _tx_inputs, signing_keys = build_inputs(resolved, nil)

      # The derived key should match the self-payment derivation
      expect(signing_keys[0].public_key.compressed).to eq(self_key.public_key.compressed)
    end

    it 'uses sender_identity_key as counterparty when present' do
      sender_key = BSV::Primitives::PrivateKey.generate
      sender_hex = sender_key.public_key.to_hex

      # Derive a key with the sender as counterparty
      derived_key = key_deriver.derive_private_key(
        protocol_id: [2, 'wallet payment'], key_id: 'from-sender',
        counterparty: sender_hex
      )
      resolved = [make_resolved_input(
        vin: 0, private_key: derived_key,
        sender_identity_key: sender_hex,
        derivation_suffix: 'from-sender'
      )]

      _tx_inputs, signing_keys = build_inputs(resolved, nil)

      expect(signing_keys[0].public_key.compressed).to eq(derived_key.public_key.compressed)
    end

    it 'raises for non-P2PKH input without unlocking_script' do
      custom_lock = "\x04\x05\x06".b # Non-P2PKH
      resolved = [make_resolved_input(vin: 0, locking_script: custom_lock)]

      expect do
        build_inputs(resolved, nil)
      end.to raise_error(BSV::Wallet::Error, /non-P2PKH.*no unlocking_script/)
    end

    it 'handles multiple inputs with mixed types' do
      # Input 0: P2PKH
      derived_key = key_deriver.derive_private_key(
        protocol_id: [2, 'wallet payment'], key_id: 'suffix1', counterparty: 'self'
      )
      # Input 1: custom script
      custom_lock = "\x04\x05\x06".b
      custom_unlock = "\x07\x08\x09".b

      resolved = [
        make_resolved_input(vin: 0, private_key: derived_key),
        make_resolved_input(vin: 1, locking_script: custom_lock)
      ]
      caller_inputs = [
        { vin: 0 },
        { vin: 1, unlocking_script: custom_unlock }
      ]

      tx_inputs, signing_keys = build_inputs(resolved, caller_inputs)

      expect(tx_inputs.length).to eq(2)
      expect(signing_keys).to have_key(0)
      expect(signing_keys).not_to have_key(1)
      expect(tx_inputs[1].unlocking_script.to_binary).to eq(custom_unlock)
    end

    it 'raises without key_deriver for P2PKH input' do
      derived_key = BSV::Primitives::PrivateKey.generate
      resolved = [make_resolved_input(vin: 0, private_key: derived_key)]

      expect do
        engine.send(:build_inputs, resolved, nil)
      end.to raise_error(BSV::Wallet::Error, /key deriver/)
    end
  end

  # --- Transaction Assembly, Serialization, and Txid (#23) ---

  describe '#build_transaction (private)' do
    # Helper: generate a P2PKH locking script for a derived key
    def p2pkh_locking_script_for(private_key)
      pubkey_hash = BSV::Primitives::Digest.hash160(private_key.public_key.compressed)
      BSV::Script::Script.p2pkh_lock(pubkey_hash)
    end

    # Helper: derive a key the same way the engine will
    def derive_key(prefix: 'wallet payment', suffix: 'suffix1', counterparty: 'self')
      key_deriver.derive_private_key(
        protocol_id: [2, prefix], key_id: suffix, counterparty: counterparty
      )
    end

    # Helper: build a resolved input hash
    def make_resolved_input(vin:, private_key:, satoshis: 1000, source_vout: 0)
      {
        vin: vin,
        sequence: 0xFFFFFFFF,
        source_wtxid: SecureRandom.random_bytes(32),
        source_vout: source_vout,
        source_satoshis: satoshis,
        source_locking_script: p2pkh_locking_script_for(private_key).to_binary,
        derivation_prefix: 'wallet payment',
        derivation_suffix: 'suffix1',
        sender_identity_key: nil
      }
    end

    let(:derived_key) { derive_key }
    let(:resolved_inputs) { [make_resolved_input(vin: 0, private_key: derived_key)] }
    let(:output_script) { p2pkh_locking_script_for(derived_key).to_binary }
    let(:caller_outputs) { [{ satoshis: 900, locking_script: output_script }] }

    before do
      allow(store).to receive(:resolve_inputs_for_signing).and_return(resolved_inputs)
    end

    def build_transaction(action_id, inputs, outputs, lock_time, version, randomize)
      engine_with_keys.send(:build_transaction, action_id, inputs, outputs, lock_time, version, randomize)
    end

    it 'assembles a transaction and returns wtxid, raw_tx, and vout_mapping' do
      wtxid, raw_tx, vout_mapping = build_transaction(1, nil, caller_outputs, nil, nil, false)

      expect(wtxid).to be_a(String)
      expect(wtxid.bytesize).to eq(32)
      expect(raw_tx).to be_a(String)
      expect(raw_tx.bytesize).to be > 10
      expect(vout_mapping).to eq({ 0 => 0 })
    end

    it 'produces a wtxid that is the double-SHA-256 of serialized tx (wire order)' do
      wtxid, raw_tx, _vout_mapping = build_transaction(1, nil, caller_outputs, nil, nil, false)

      expected_wtxid = BSV::Primitives::Digest.sha256d(raw_tx)
      expect(wtxid).to eq(expected_wtxid)
    end

    it 'produces a serialized tx that can be deserialized back' do
      _txid, raw_tx, _vout_mapping = build_transaction(1, nil, caller_outputs, nil, nil, false)

      parsed = BSV::Transaction::Transaction.from_binary(raw_tx)
      expect(parsed.inputs.length).to eq(1)
      expect(parsed.outputs.length).to eq(1)
      expect(parsed.outputs[0].satoshis).to eq(900)
    end

    it 'round-trips: serialize -> deserialize -> re-serialize produces identical bytes' do
      _txid, raw_tx, _vout_mapping = build_transaction(1, nil, caller_outputs, nil, nil, false)

      parsed = BSV::Transaction::Transaction.from_binary(raw_tx)
      expect(parsed.to_binary).to eq(raw_tx)
    end

    it 'sets version and lock_time correctly' do
      _txid, raw_tx, _vout_mapping = build_transaction(1, nil, caller_outputs, 500, 2, false)

      parsed = BSV::Transaction::Transaction.from_binary(raw_tx)
      expect(parsed.version).to eq(2)
      expect(parsed.lock_time).to eq(500)
    end

    it 'defaults version to 1 and lock_time to 0' do
      _txid, raw_tx, _vout_mapping = build_transaction(1, nil, caller_outputs, nil, nil, false)

      parsed = BSV::Transaction::Transaction.from_binary(raw_tx)
      expect(parsed.version).to eq(1)
      expect(parsed.lock_time).to eq(0)
    end

    it 'signs P2PKH inputs that pass verify_input' do
      _, raw_tx, _vout_mapping = build_transaction(1, nil, caller_outputs, nil, nil, false)

      # Reconstruct the transaction with source data for verification
      parsed = BSV::Transaction::Transaction.from_binary(raw_tx)
      parsed.inputs[0].source_satoshis = resolved_inputs[0][:source_satoshis]
      parsed.inputs[0].source_locking_script = BSV::Script::Script.from_binary(
        resolved_inputs[0][:source_locking_script]
      )

      expect(parsed.inputs[0].unlocking_script).not_to be_nil
      expect(parsed.verify_input(0)).to be true
    end

    it 'handles outputs-only transaction (no inputs)' do
      allow(store).to receive(:resolve_inputs_for_signing).and_return([])

      _, raw_tx, vout_mapping = build_transaction(1, nil, caller_outputs, nil, nil, false)

      parsed = BSV::Transaction::Transaction.from_binary(raw_tx)
      expect(parsed.inputs.length).to eq(0)
      expect(parsed.outputs.length).to eq(1)
      expect(vout_mapping).to eq({ 0 => 0 })
    end

    it 'handles multiple inputs and outputs' do
      derived_key2 = derive_key(suffix: 'suffix2')
      multi_resolved = [
        make_resolved_input(vin: 0, private_key: derived_key),
        make_resolved_input(vin: 1, private_key: derived_key2,
                            satoshis: 2000, source_vout: 1).merge(
                              derivation_suffix: 'suffix2'
                            )
      ]
      allow(store).to receive(:resolve_inputs_for_signing).and_return(multi_resolved)

      script2 = p2pkh_locking_script_for(derived_key2).to_binary
      multi_outputs = [
        { satoshis: 800, locking_script: output_script },
        { satoshis: 1500, locking_script: script2 }
      ]

      _, raw_tx, = build_transaction(1, nil, multi_outputs, nil, nil, false)

      parsed = BSV::Transaction::Transaction.from_binary(raw_tx)
      expect(parsed.inputs.length).to eq(2)
      expect(parsed.outputs.length).to eq(2)

      # Verify both inputs are signed
      multi_resolved.each_with_index do |resolved, idx|
        parsed.inputs[idx].source_satoshis = resolved[:source_satoshis]
        parsed.inputs[idx].source_locking_script = BSV::Script::Script.from_binary(
          resolved[:source_locking_script]
        )
      end
      expect(parsed.verify_input(0)).to be true
      expect(parsed.verify_input(1)).to be true
    end

    it 'resolves inputs from the store using the action_id' do
      build_transaction(42, nil, caller_outputs, nil, nil, false)

      expect(store).to have_received(:resolve_inputs_for_signing).with(action_id: 42)
    end

    it 'passes vout_mapping through from build_outputs' do
      multi_outputs = 3.times.map do |i|
        { satoshis: (i + 1) * 100, locking_script: output_script }
      end

      _txid, _raw_tx, vout_mapping = build_transaction(1, nil, multi_outputs, nil, nil, false)

      expect(vout_mapping.keys.sort).to eq([0, 1, 2])
      expect(vout_mapping.values.sort).to eq([0, 1, 2])
    end
  end

  # --- End-to-End Integration Tests (#25) ---

  describe 'end-to-end transaction construction' do
    # Helper: build a P2PKH locking script for a derived key
    def p2pkh_locking_script_for(private_key)
      pubkey_hash = BSV::Primitives::Digest.hash160(private_key.public_key.compressed)
      BSV::Script::Script.p2pkh_lock(pubkey_hash)
    end

    # Helper: derive a key matching the engine's derivation
    def derive_key(prefix: 'wallet payment', suffix: 'suffix', counterparty: 'self')
      key_deriver.derive_private_key(
        protocol_id: [2, prefix], key_id: suffix, counterparty: counterparty
      )
    end

    context 'single-input P2PKH' do
      it 'constructs a valid signed Bitcoin transaction end-to-end' do
        fund_wallet(satoshis: 1000)

        listed = engine_with_keys.list_outputs(basket: 'default')
        output_id = listed[:outputs].first[:id]

        output_key = derive_key
        output_script = p2pkh_locking_script_for(output_key).to_binary

        result = engine_with_keys.create_action(
          description: 'e2e payment test',
          no_send: true,
          inputs: [{ output_id: output_id }],
          outputs: [
            { satoshis: 900, locking_script: output_script,
              output_description: 'payment', basket: 'payments',
              derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
          ],
          randomize_outputs: false
        )

        expect(result[:txid]).to be_a(String)
        expect(result[:txid].bytesize).to eq(32)
        expect(result[:tx]).to be_a(String)

        # Deserialize and verify wire format
        parsed = parse_beef_tx(result[:tx])
        expect(parsed.inputs.length).to eq(1)
        expect(parsed.outputs.length).to eq(1)
        expect(parsed.outputs[0].satoshis).to eq(900)

        # Verify result[:txid] = wire-order wtxid (double-SHA-256 of serialized tx)
        expected_wtxid = parse_beef_tx(result[:tx]).wtxid
        expect(result[:txid]).to eq(expected_wtxid)

        # Set source data for script verification
        parsed.inputs[0].source_satoshis = 1000
        parsed.inputs[0].source_locking_script = p2pkh_locking_script_for(derive_key)

        # Verify the input signature
        expect(parsed.verify_input(0)).to be true

        # Verify BEEF round-trip: re-parsing yields the same raw tx
        reparsed = parse_beef_tx(result[:tx])
        expect(reparsed.to_binary).to eq(parsed.to_binary)

        # Verify outputs are promoted in the database
        payments = engine_with_keys.list_outputs(basket: 'payments')
        expect(payments[:total_outputs]).to eq(1)
      end
    end

    context 'multi-input transaction' do
      it 'spends multiple outputs in a single transaction' do
        # Fund with three separate calls so each output has a distinct, predictable suffix
        fund_wallet(satoshis: 500, suffix: 'multi0')
        fund_wallet(satoshis: 500, suffix: 'multi1')
        fund_wallet(satoshis: 500, suffix: 'multi2')

        listed = engine_with_keys.list_outputs(basket: 'default')
        outputs_by_id = listed[:outputs].sort_by { |o| o[:id] }
        expect(outputs_by_id.length).to eq(3)

        output_key = derive_key
        output_script = p2pkh_locking_script_for(output_key).to_binary

        result = engine_with_keys.create_action(
          description: 'multi input test',
          no_send: true,
          inputs: outputs_by_id.each_with_index.map { |o, i| { output_id: o[:id], vin: i } },
          outputs: [
            { satoshis: 1400, locking_script: output_script,
              output_description: 'combined', basket: 'payments' }
          ],
          randomize_outputs: false
        )

        parsed = parse_beef_tx(result[:tx])
        expect(parsed.inputs.length).to eq(3)
        expect(parsed.outputs.length).to eq(1)
        expect(parsed.outputs[0].satoshis).to eq(1400)

        # Verify each input signature using the matching derivation suffix
        %w[multi0 multi1 multi2].each_with_index do |suffix, i|
          derived = key_deriver.derive_private_key(
            protocol_id: [2, 'wallet payment'], key_id: suffix, counterparty: 'self'
          )
          parsed.inputs[i].source_satoshis = 500
          parsed.inputs[i].source_locking_script = p2pkh_locking_script_for(derived)
          expect(parsed.verify_input(i)).to be true
        end

        # Verify txid
        expected_wtxid = parse_beef_tx(result[:tx]).wtxid
        expect(result[:txid]).to eq(expected_wtxid)
      end
    end

    context 'multi-output transaction' do
      it 'creates multiple outputs from a single input' do
        fund_wallet(satoshis: 2000)

        listed = engine_with_keys.list_outputs(basket: 'default')
        output_id = listed[:outputs].first[:id]

        key1 = derive_key(suffix: 'out1')
        key2 = derive_key(suffix: 'out2')
        key3 = derive_key(suffix: 'out3')

        result = engine_with_keys.create_action(
          description: 'multi output test',
          no_send: true,
          inputs: [{ output_id: output_id }],
          outputs: [
            { satoshis: 600, locking_script: p2pkh_locking_script_for(key1).to_binary,
              output_description: 'first', basket: 'payments' },
            { satoshis: 700, locking_script: p2pkh_locking_script_for(key2).to_binary,
              output_description: 'second', basket: 'payments' },
            { satoshis: 500, locking_script: p2pkh_locking_script_for(key3).to_binary,
              output_description: 'third', basket: 'payments' }
          ],
          randomize_outputs: false
        )

        parsed = parse_beef_tx(result[:tx])
        expect(parsed.inputs.length).to eq(1)
        expect(parsed.outputs.length).to eq(3)
        expect(parsed.outputs.map(&:satoshis)).to eq([600, 700, 500])

        # Verify input
        parsed.inputs[0].source_satoshis = 2000
        parsed.inputs[0].source_locking_script = p2pkh_locking_script_for(derive_key)
        expect(parsed.verify_input(0)).to be true
      end
    end

    context 'no-send flow' do
      it 'returns transaction data without broadcasting' do
        fund_wallet(satoshis: 1000)

        listed = engine_with_keys.list_outputs(basket: 'default')
        output_id = listed[:outputs].first[:id]
        output_script = p2pkh_locking_script_for(derive_key).to_binary

        result = engine_with_keys.create_action(
          description: 'no send e2e test',
          no_send: true,
          inputs: [{ output_id: output_id }],
          outputs: [
            { satoshis: 900, locking_script: output_script,
              output_description: 'output', basket: 'wallet' }
          ],
          randomize_outputs: false
        )

        expect(result).to include(:txid, :tx, :no_send_change)
        expect(result[:txid].bytesize).to eq(32)

        # Transaction is valid
        parsed = parse_beef_tx(result[:tx])
        parsed.inputs[0].source_satoshis = 1000
        parsed.inputs[0].source_locking_script = p2pkh_locking_script_for(derive_key)
        expect(parsed.verify_input(0)).to be true
      end
    end

    context 'deferred signing flow' do
      it 'creates unsigned then signs via sign_action' do
        fund_wallet(satoshis: 1000)

        listed = engine_with_keys.list_outputs(basket: 'default')
        output_id = listed[:outputs].first[:id]
        output_script = p2pkh_locking_script_for(derive_key).to_binary

        # Phase 1: create deferred action
        create_result = engine_with_keys.create_action(
          description: 'deferred e2e test',
          sign_and_process: false,
          inputs: [{ output_id: output_id }],
          outputs: [
            { satoshis: 900, locking_script: output_script,
              output_description: 'output', basket: 'wallet' }
          ]
        )

        expect(create_result[:signable_transaction]).not_to be_nil
        reference = create_result[:signable_transaction][:reference]

        # Phase 2: sign with empty spends (wallet signs all P2PKH)
        sign_result = engine_with_keys.sign_action(
          spends: {},
          reference: reference,
          no_send: true
        )

        expect(sign_result[:txid]).to be_a(String)
        expect(sign_result[:txid].bytesize).to eq(32)

        # Verify the signed transaction
        parsed = parse_beef_tx(sign_result[:tx])
        expect(parsed.inputs.length).to eq(1)
        expect(parsed.outputs.length).to eq(1)
        expect(parsed.outputs[0].satoshis).to eq(900)

        # Verify input signature
        parsed.inputs[0].source_satoshis = 1000
        parsed.inputs[0].source_locking_script = p2pkh_locking_script_for(derive_key)
        expect(parsed.verify_input(0)).to be true

        # Verify wtxid
        expected_wtxid = parse_beef_tx(sign_result[:tx]).wtxid
        expect(sign_result[:txid]).to eq(expected_wtxid)
      end
    end

    context 'custom script input' do
      it 'applies a caller-provided unlocking script' do
        fund_wallet(satoshis: 1000)

        listed = engine_with_keys.list_outputs(basket: 'default')
        output_id = listed[:outputs].first[:id]
        output_script = p2pkh_locking_script_for(derive_key).to_binary

        # Create deferred action, then provide a custom unlocking script
        create_result = engine_with_keys.create_action(
          description: 'custom script test',
          sign_and_process: false,
          inputs: [{ output_id: output_id }],
          outputs: [
            { satoshis: 900, locking_script: output_script,
              output_description: 'output' }
          ]
        )

        reference = create_result[:signable_transaction][:reference]
        custom_unlock = "\x48".b + SecureRandom.random_bytes(71) + "\x21".b + SecureRandom.random_bytes(33)

        result = engine_with_keys.sign_action(
          spends: { 0 => { unlocking_script: custom_unlock } },
          reference: reference,
          no_send: true
        )

        parsed = parse_beef_tx(result[:tx])
        expect(parsed.inputs[0].unlocking_script.to_binary).to eq(custom_unlock)
        expect(parsed.outputs[0].satoshis).to eq(900)

        # Txid is still valid (even though the custom script won't verify against P2PKH)
        expected_wtxid = parse_beef_tx(result[:tx]).wtxid
        expect(result[:txid]).to eq(expected_wtxid)
      end
    end

    context 'database consistency' do
      it 'stores a wtxid that matches the actual transaction hash' do
        fund_wallet(satoshis: 1000)

        listed = engine_with_keys.list_outputs(basket: 'default')
        output_id = listed[:outputs].first[:id]
        output_script = p2pkh_locking_script_for(derive_key).to_binary

        result = engine_with_keys.create_action(
          description: 'db consistency test',
          no_send: true,
          labels: ['test-wtxid'],
          inputs: [{ output_id: output_id }],
          outputs: [
            { satoshis: 900, locking_script: output_script,
              output_description: 'output', basket: 'wallet' }
          ],
          randomize_outputs: false
        )

        # The wtxid from create_action should match the wire-order hash
        computed_wtxid = parse_beef_tx(result[:tx]).wtxid
        expect(result[:txid]).to eq(computed_wtxid)
      end
    end
  end

  # --- wire_ancestor / BEEF construction (#98) ---

  describe '#wire_ancestor (private)' do
    def make_fake_tx(satoshis:, inputs: [])
      tx = BSV::Transaction::Transaction.new(version: 1, lock_time: 0)
      inputs.each do |inp|
        tx.add_input(BSV::Transaction::TransactionInput.new(
                       prev_wtxid: inp[:prev_wtxid],
                       prev_tx_out_index: 0,
                       unlocking_script: BSV::Script::Script.from_binary(OP_TRUE)
                     ))
      end
      tx.add_output(BSV::Transaction::TransactionOutput.new(
                      satoshis: satoshis,
                      locking_script: BSV::Script::Script.from_binary(OP_TRUE)
                    ))
      tx
    end

    def make_merkle_path(wtxid:, height: 800_000)
      sibling_hash = SecureRandom.random_bytes(32)
      BSV::Transaction::MerklePath.new(
        block_height: height,
        path: [[
          BSV::Transaction::MerklePath::PathElement.new(offset: 0, hash: wtxid, txid: true),
          BSV::Transaction::MerklePath::PathElement.new(offset: 1, hash: sibling_hash)
        ]]
      )
    end

    it 'returns a proven ancestor with merkle_path set (no recursion)' do
      fake_tx = make_fake_tx(satoshis: 1000)
      raw_tx = fake_tx.to_binary
      wtxid = fake_tx.wtxid
      mp = make_merkle_path(wtxid: wtxid)

      proof_store.save_proof(
        wtxid: wtxid,
        proof: { height: 800_000, merkle_path: mp.to_binary, raw_tx: raw_tx }
      )

      result = engine_with_keys.send(:wire_ancestor, wtxid)
      expect(result).to be_a(BSV::Transaction::Transaction)
      expect(result.merkle_path).to be_a(BSV::Transaction::MerklePath)
      expect(result.merkle_path.block_height).to eq(800_000)
    end

    it 'recursively wires source_transactions for unconfirmed ancestors' do
      # Grandparent: proven (has merkle_path)
      grandparent_tx = make_fake_tx(satoshis: 2000)
      gp_raw = grandparent_tx.to_binary
      gp_wtxid = grandparent_tx.wtxid
      gp_mp = make_merkle_path(wtxid: gp_wtxid, height: 799_000)

      proof_store.save_proof(
        wtxid: gp_wtxid,
        proof: { height: 799_000, merkle_path: gp_mp.to_binary, raw_tx: gp_raw }
      )

      # Parent: unconfirmed (no merkle_path), spends grandparent
      parent_tx = make_fake_tx(satoshis: 1500, inputs: [{ prev_wtxid: gp_wtxid }])
      parent_raw = parent_tx.to_binary
      parent_wtxid = parent_tx.wtxid

      proof_store.save_proof(
        wtxid: parent_wtxid,
        proof: { raw_tx: parent_raw }
      )

      result = engine_with_keys.send(:wire_ancestor, parent_wtxid)
      expect(result).to be_a(BSV::Transaction::Transaction)
      expect(result.merkle_path).to be_nil

      # The input's source_transaction should be wired to the grandparent
      expect(result.inputs.first.source_transaction).to be_a(BSV::Transaction::Transaction)
      expect(result.inputs.first.source_transaction.merkle_path).to be_a(BSV::Transaction::MerklePath)
      expect(result.inputs.first.source_transaction.merkle_path.block_height).to eq(799_000)
    end

    it 'terminates on circular references via visited set' do
      # Two transactions referencing each other (pathological case)
      tx_a = make_fake_tx(satoshis: 500)
      tx_b = make_fake_tx(satoshis: 500, inputs: [{ prev_wtxid: tx_a.wtxid }])

      # Manually rebuild tx_a with an input pointing to tx_b
      tx_a_circular = make_fake_tx(satoshis: 500, inputs: [{ prev_wtxid: tx_b.wtxid }])

      proof_store.save_proof(wtxid: tx_a_circular.wtxid, proof: { raw_tx: tx_a_circular.to_binary })
      proof_store.save_proof(wtxid: tx_b.wtxid, proof: { raw_tx: tx_b.to_binary })

      # Should not raise or infinite loop
      result = engine_with_keys.send(:wire_ancestor, tx_a_circular.wtxid)
      expect(result).to be_a(BSV::Transaction::Transaction)
    end

    it 'returns nil for missing proofs' do
      missing_wtxid = SecureRandom.random_bytes(32)
      result = engine_with_keys.send(:wire_ancestor, missing_wtxid)
      expect(result).to be_nil
    end
  end

  # --- Auto-fund createAction (#61) ---

  # Limp mode specs: spec/bsv/wallet/engine/limp_mode_spec.rb
  # Porcelain specs (send_payment, auto-fund): spec/bsv/wallet/engine/porcelain_spec.rb
end
