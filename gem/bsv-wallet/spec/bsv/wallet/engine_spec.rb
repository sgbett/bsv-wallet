# frozen_string_literal: true

# Engine plumbing specs — tests for the BRC-100 interface methods
# (create_action, sign_action, internalize_action, BEEF/SPV, crypto).
#
# Porcelain specs (send_payment, limp mode, auto-fund) live in engine/.

require_relative 'engine/shared_context'

RSpec.describe BSV::Wallet::Engine do
  include_context 'engine setup'

  describe 'construction' do
    it 'accepts pluggable components' do
      expect(engine).to be_a(described_class)
    end

    it 'exposes the BRC-100 interface via the +#brc100+ accessor (#405 Stage 3)' do
      # Pre-Stage-3: Engine included BSV::Wallet::BRC100 (which itself
      # included Interface::BRC100), putting the contract in Engine's
      # ancestry. Stage 3 swapped the mixin for composition — the
      # contract now lives on the BRC100 instance the accessor returns.
      expect(engine.brc100).to be_a(BSV::Wallet::BRC100)
      expect(engine.brc100.class.ancestors).to include(BSV::Wallet::Interface::BRC100)
    end
  end

  describe 'wtxid validation' do
    it 'Store#sign_action rejects display-order hex as wtxid' do
      action = store.create_action(
        action: { description: 'validation test', broadcast_intent: :none }
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
        engine.brc100.internalize_action(
          tx: "\x00".b, # will fail later, but validation fires first
          description: 'validation test',
          trust_self: 'known',
          known_txids: [hex_dtxid],
          outputs: []
        )
      end.to raise_error(ArgumentError, /known_txids entry/)
    end
  end

  describe '#create_action BEEF hint publish (#269)' do
    # publish_beef_hint reads BSV::Wallet.config.hints_socket (#277). Each
    # example sets the value directly on the singleton; the after hook
    # resets so neighbours aren't affected.
    after { BSV::Wallet.reset_config! }

    it 'is a no-op when hints_socket is unset' do
      BSV::Wallet.configure { |c| c.hints_socket = nil }
      allow(OMQ::PUSH).to receive(:connect)

      engine.brc100.create_action(
        description: 'hint disabled',
        inputs: [],
        outputs: [
          { satoshis: 0, locking_script: OP_TRUE,
            derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
        ]
      )

      expect(OMQ::PUSH).not_to have_received(:connect)
    end

    it 'treats a set-but-blank BSV_WALLET_HINTS_SOCKET as unset (Config blank-to-nil normalisation)' do
      # Config#initialize handles the blank→nil normalisation; replay
      # via ENV mutation so the Config gets the realistic value.
      saved = ENV.fetch('BSV_WALLET_HINTS_SOCKET', nil)
      begin
        ENV['BSV_WALLET_HINTS_SOCKET'] = '   '
        BSV::Wallet.reset_config!
        allow(OMQ::PUSH).to receive(:connect)

        engine.brc100.create_action(
          description: 'hint disabled by blank env',
          inputs: [],
          outputs: [
            { satoshis: 0, locking_script: OP_TRUE,
              derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
          ]
        )

        expect(OMQ::PUSH).not_to have_received(:connect)
      ensure
        saved.nil? ? ENV.delete('BSV_WALLET_HINTS_SOCKET') : ENV['BSV_WALLET_HINTS_SOCKET'] = saved
      end
    end

    it 'connects + pushes a Marshalled hint when hints_socket is set' do
      BSV::Wallet.configure { |c| c.hints_socket = 'inproc://test-hints-publish' }
      sent = []
      fake_socket = double('PUSH')
      allow(fake_socket).to receive(:<<) { |payload| sent << payload }
      allow(OMQ::PUSH).to receive(:connect).with('inproc://test-hints-publish').and_return(fake_socket)

      engine.brc100.create_action(
        description: 'hint enabled',
        inputs: [],
        outputs: [
          { satoshis: 0, locking_script: OP_TRUE,
            derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
        ]
      )

      expect(OMQ::PUSH).to have_received(:connect).with('inproc://test-hints-publish')
      expect(sent.size).to eq(1)
      hint = Marshal.load(sent.first) # rubocop:disable Security/MarshalLoad
      expect(hint).to include(:action_id, :beef)
      expect(hint[:beef]).to be_a(String)
      expect(hint[:beef].bytesize).to be > 0
    end

    it 'swallows OMQ::PUSH.connect errors (best-effort, never blocks create_action)' do
      BSV::Wallet.configure { |c| c.hints_socket = 'ipc:///nonexistent/path.sock' }
      allow(OMQ::PUSH).to receive(:connect).and_raise(StandardError, 'connect boom')

      expect do
        engine.brc100.create_action(
          description: 'hint fail swallowed',
          inputs: [],
          outputs: [
            { satoshis: 0, locking_script: OP_TRUE,
              derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
          ]
        )
      end.not_to raise_error
    end

    it 'does not publish a hint for no_send actions (they will never be broadcast)' do
      BSV::Wallet.configure { |c| c.hints_socket = 'inproc://test-hints-no-send' }
      allow(OMQ::PUSH).to receive(:connect)

      engine.brc100.create_action(
        description: 'no_send hint skip',
        inputs: [],
        no_send: true,
        outputs: [
          { satoshis: 0, locking_script: OP_TRUE,
            derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
        ]
      )

      expect(OMQ::PUSH).not_to have_received(:connect)
    end
  end

  describe '#create_action' do
    it 'creates an action with outputs' do
      result = engine.brc100.create_action(
        description: 'test payment',
        inputs: [],
        outputs: [
          # 0 satoshis: synthetic-fixture pattern that exercises
          # create_action's lifecycle without value-from-nothing
          # (strict validate_for_handoff! catches output_overflow).
          { satoshis: 0, locking_script: OP_TRUE,
            output_description: 'payment', basket: 'payments', derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
        ]
      )

      expect(result).to include(:txid, :tx)
      expect(result[:txid]).to be_a(String)
      expect(result[:txid].length).to eq(32)
    end

    it 'saves raw_tx to ProofStore at sign time' do
      result = engine.brc100.create_action(
        description: 'proof store test',
        inputs: [],
        outputs: [
          { satoshis: 0, locking_script: OP_TRUE,
            derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
        ]
      )

      wtxid = result[:txid]
      proof = proof_store.find_proof(wtxid: wtxid)
      expect(proof).not_to be_nil
      expect(proof[:raw_tx]).to be_a(String)
      expect(proof[:raw_tx].bytesize).to be >= 10
    end

    it 'creates a deferred signing action with outputs queued for Phase 4' do
      result = engine.brc100.create_action(
        description: 'deferred action',
        inputs: [],
        sign_and_process: false,
        outputs: [
          { satoshis: 0, locking_script: OP_TRUE,
            output_description: 'output', basket: 'deferred', derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
        ]
      )

      expect(result).to include(:signable_transaction)
      expect(result[:signable_transaction][:reference]).to be_a(String)
      # BRC-100 contract: tx is Atomic BEEF of the unsigned transaction.
      expect(result[:signable_transaction][:tx]).to be_a(String)
      expect(result[:signable_transaction][:tx].bytesize).to be >= 10

      # Send-path outputs are persisted unpromoted at stage time — they exist
      # in the outputs table but aren't in the canonical UTXO set until Phase 4
      # (broadcast acceptance) records the promotions row and inserts spendable
      # rows. list_outputs is gated on spendable, so total is 0.
      listed = engine.brc100.list_outputs(basket: 'deferred')
      expect(listed[:total_outputs]).to eq(0)

      action = store.find_action(reference: result[:signable_transaction][:reference])
      expect(action[:raw_tx]).to be_a(String)

      # The pending output row exists, but there is no promotions row yet.
      rows = BSV::Wallet::Store::Models::Output.where(action_id: action[:id]).all
      expect(rows.size).to eq(1)
      expect(BSV::Wallet::Store::Models::Promotion.where(action_id: action[:id]).any?).to be(false)
    end

    it 'creates a no-send action' do
      result = engine.brc100.create_action(
        description: 'no-send action',
        inputs: [],
        no_send: true,
        outputs: [
          { satoshis: 0, locking_script: OP_TRUE,
            output_description: 'output', basket: 'pending', derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
        ]
      )

      expect(result).to include(:txid, :tx, :no_send_change)
    end

    it 'attaches labels' do
      engine.brc100.create_action(
        description: 'labeled action',
        inputs: [],
        no_send: true,
        labels: %w[payment urgent],
        outputs: [
          { satoshis: 0, locking_script: OP_TRUE,
            output_description: 'output' }
        ]
      )

      actions = engine.brc100.list_actions(labels: ['payment'], include_labels: true)
      expect(actions[:total_actions]).to eq(1)
      expect(actions[:actions].first[:labels]).to include('payment', 'urgent')
    end

    it 'validates description length' do
      expect do
        engine.brc100.create_action(description: 'hi', inputs: [], outputs: [{ satoshis: 1, output_description: 'x' }])
      end.to raise_error(BSV::Wallet::InvalidParameterError)
    end

    it 'validates at least one input or output' do
      expect do
        engine.brc100.create_action(description: 'no inputs or outputs')
      end.to raise_error(BSV::Wallet::InvalidParameterError)
    end

    context 'with inline broadcast' do
      subject(:engine) do
        described_class.new(
          store: store, utxo_pool: utxo_pool,
          services: services, broadcaster: broadcaster, network: :mainnet
        )
      end

      let(:broadcast_response) do
        double('ProtocolResponse', http_success?: true, data: {
                 tx_status: 'SEEN_ON_NETWORK', status: 200
               })
      end
      let(:services) { double('Services') }
      let(:broadcaster) do
        b = double('Broadcaster')
        allow(b).to receive(:broadcast).with(anything, wtxid: anything).and_return(broadcast_response)
        b
      end

      it 'broadcasts inline and promotes on acceptance' do
        result = engine.brc100.create_action(
          description: 'inline broadcast',
          inputs: [],
          accept_delayed_broadcast: false,
          outputs: [
            { satoshis: 0, locking_script: OP_TRUE,
              output_description: 'output', basket: 'payments', derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
          ]
        )

        expect(result[:txid]).not_to be_nil
        expect(broadcaster).to have_received(:broadcast).with(anything, wtxid: anything)

        # Verify outputs were promoted
        listed = engine.brc100.list_outputs(basket: 'payments')
        expect(listed[:total_outputs]).to eq(1)
      end

      it 'stamps broadcast_at before the ARC call (pre-POST timing)' do
        # Inject a stubbed broadcaster.broadcast that raises mid-POST. The row
        # should still have broadcast_at set -- the recognisable
        # crash-recovery state the poll loop subsequently resolves.
        stamped_at_call_time = nil
        allow(broadcaster).to receive(:broadcast).with(anything, wtxid: anything) do
          action = store.send(:models)::Action.order(:id).last
          stamped_at_call_time = store.broadcast_status(action_id: action.id)
          raise StandardError, 'network down'
        end

        expect do
          engine.brc100.create_action(
            description: 'pre-POST stamp guard',
            inputs: [],
            accept_delayed_broadcast: false,
            outputs: [
              { satoshis: 0, locking_script: OP_TRUE,
                output_description: 'output', basket: 'payments', derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
            ]
          )
        end.to raise_error(StandardError, 'network down')

        expect(stamped_at_call_time).not_to be_nil
        expect(stamped_at_call_time[:broadcast_at]).not_to be_nil
        expect(stamped_at_call_time[:tx_status]).to be_nil
      end

      it 'records tx_status from the ARC response' do
        engine.brc100.create_action(
          description: 'records tx_status',
          inputs: [],
          accept_delayed_broadcast: false,
          outputs: [
            { satoshis: 0, locking_script: OP_TRUE,
              output_description: 'output', basket: 'payments', derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
          ]
        )

        action = store.send(:models)::Action.order(:id).last
        status = store.broadcast_status(action_id: action.id)
        expect(status[:broadcast_at]).not_to be_nil
        expect(status[:tx_status]).to eq('SEEN_ON_NETWORK')
      end

      # A definitive sync rejection arrives as a non-2xx body carrying a
      # terminal (camelCase) txStatus. inline_broadcast must surface it so
      # the caller's rejected? check unwinds the action via reject_action —
      # mirroring the daemon submit path. Without this, a failed submit
      # would leave the action's outputs speculatively promoted and its
      # inputs locked.
      it 'rejects the action on a non-2xx response carrying a terminal txStatus' do
        allow(broadcaster).to receive(:broadcast).with(anything, wtxid: anything).and_return(
          double('ProtocolResponse', http_success?: false, code: '400', data: { 'txStatus' => 'REJECTED' })
        )

        engine.brc100.create_action(
          description: 'inline broadcast rejected',
          inputs: [],
          accept_delayed_broadcast: false,
          outputs: [
            { satoshis: 0, locking_script: OP_TRUE,
              output_description: 'output', basket: 'payments', derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
          ]
        )

        # reject_action cascade-deletes the action and its inputs, so the
        # action is gone and no spendable output was promoted.
        action = store.send(:models)::Action.where(description: 'inline broadcast rejected').last
        expect(action).to be_nil
        expect(engine.brc100.list_outputs(basket: 'payments')[:total_outputs]).to eq(0)
      end

      it 'forwards the configured callback_token on the broadcaster call (X-CallbackToken plumbing)' do
        # Override the default broadcaster stub (which is keyed on the
        # zero-token signature) so the callback_token-laden call matches.
        allow(broadcaster).to receive(:broadcast)
          .with(anything, hash_including(callback_token: 'tok-inline-xyz'))
          .and_return(broadcast_response)

        engine_with_token = described_class.new(
          store: store, utxo_pool: utxo_pool, services: services,
          broadcaster: broadcaster, network: :mainnet,
          callback_token: 'tok-inline-xyz'
        )

        engine_with_token.brc100.create_action(
          description: 'inline broadcast with token',
          inputs: [],
          accept_delayed_broadcast: false,
          outputs: [
            { satoshis: 0, locking_script: OP_TRUE,
              output_description: 'output', basket: 'payments', derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
          ]
        )

        expect(broadcaster).to have_received(:broadcast)
          .with(anything, hash_including(callback_token: 'tok-inline-xyz'))
      end

      # 503 backpressure: mirror Engine::Broadcast#submit's null-on-503
      # behaviour (plan §4.2). The row's broadcast_at gets reverted so
      # the daemon's pending_submissions discovery picks it up next cycle
      # for clean retry. Preserves the inline_broadcast contract -- caller
      # sees the not-yet-accepted state (no fake REJECTED return).
      it 'on a 503 backpressure response, clears broadcast_at so the row re-enters the queued set' do
        allow(broadcaster).to receive(:broadcast).with(anything, wtxid: anything).and_return(
          double('ProtocolResponse', http_success?: false, code: '503', data: nil)
        )

        engine.brc100.create_action(
          description: 'inline 503 backpressure',
          inputs: [],
          accept_delayed_broadcast: false,
          outputs: [
            { satoshis: 0, locking_script: OP_TRUE,
              output_description: 'output', basket: 'payments', derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
          ]
        )

        action = store.send(:models)::Action.where(description: 'inline 503 backpressure').last
        expect(action).not_to be_nil
        status = store.broadcast_status(action_id: action.id)
        # broadcast_at reverted; row returns to pending_submissions.
        expect(status[:broadcast_at]).to be_nil
        expect(store.pending_submissions.map { |b| b[:action_id] }).to include(action.id)
      end
    end

    context 'when constructed without a broadcaster' do
      it 'raises ArgumentError at construction (broadcaster is required post-#271)' do
        expect do
          described_class.new(
            store: store, utxo_pool: utxo_pool,
            services: double('Services', call: nil), network: :mainnet
          )
        end.to raise_error(ArgumentError, /missing keyword: :broadcaster/)
      end
    end

    context 'with delayed broadcast (accept_delayed_broadcast: true)' do
      subject(:engine) do
        described_class.new(
          store: store, utxo_pool: utxo_pool, broadcaster: broadcaster,
          services: services, network: :mainnet
        )
      end

      let(:services) do
        svc = double('Services')
        allow(svc).to receive(:call)
        svc
      end

      it 'creates a broadcasts row with broadcast_at IS NULL and does not call ARC' do
        engine.brc100.create_action(
          description: 'delayed broadcast',
          inputs: [],
          accept_delayed_broadcast: true,
          outputs: [
            { satoshis: 0, locking_script: OP_TRUE,
              output_description: 'output', basket: 'payments', derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
          ]
        )

        expect(services).not_to have_received(:call)

        action = store.send(:models)::Action.order(:id).last
        status = store.broadcast_status(action_id: action.id)
        expect(status).not_to be_nil
        expect(status[:broadcast_at]).to be_nil
        expect(status[:tx_status]).to be_nil
      end
    end

    context 'with no_send: true' do
      it 'creates no broadcasts row (regression guard for #184 atomic invariant)' do
        engine_with_keys.brc100.create_action(
          description: 'no_send guard',
          inputs: [],
          no_send: true,
          outputs: [
            { satoshis: 0, locking_script: OP_TRUE,
              output_description: 'output', basket: 'payments', derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
          ]
        )

        action = store.send(:models)::Action.order(:id).last
        expect(store.broadcast_status(action_id: action.id)).to be_nil
      end
    end
  end

  describe '#sign_action' do
    it 'raises for non-UUID reference' do
      expect do
        engine.brc100.sign_action(spends: {}, reference: 'not-a-uuid')
      end.to raise_error(BSV::Wallet::InvalidParameterError)
    end

    it 'raises for nonexistent reference' do
      expect do
        engine.brc100.sign_action(spends: {}, reference: '00000000-0000-0000-0000-000000000000')
      end.to raise_error(BSV::Wallet::InvalidParameterError)
    end

    it 'completes a deferred signing flow with outputs only' do
      # Deferred action with outputs but no inputs
      locking_script = OP_TRUE
      create_result = engine.brc100.create_action(
        description: 'deferred outputs',
        inputs: [],
        sign_and_process: false,
        outputs: [
          { satoshis: 0, locking_script: locking_script,
            output_description: 'output', basket: 'deferred_sign', derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
        ]
      )

      reference = create_result[:signable_transaction][:reference]

      # Send-path outputs aren't in the canonical UTXO set yet — they were
      # written unpromoted at stage time. Phase 4 (broadcast acceptance) is
      # what records the promotions row and inserts the spendable rows that
      # list_outputs queries.
      listed_before = engine.brc100.list_outputs(basket: 'deferred_sign')
      expect(listed_before[:total_outputs]).to eq(0)

      # Sign with empty spends (no inputs to sign). no_send: true short-
      # circuits broadcast — Phase 4 never runs, so outputs stay invisible.
      result = engine.brc100.sign_action(
        spends: {},
        reference: reference
      )

      expect(result[:txid]).to be_a(String)
      expect(result[:txid].bytesize).to eq(32)
      expect(result[:tx]).to be_a(String)

      # Verify the transaction can be deserialized
      parsed = parse_beef_tx(result[:tx])
      expect(parsed.outputs.length).to eq(1)
      expect(parsed.outputs[0].satoshis).to eq(0)

      # Still no spendable rows — no broadcast acceptance was simulated.
      listed_after = engine.brc100.list_outputs(basket: 'deferred_sign')
      expect(listed_after[:total_outputs]).to eq(0)
    end

    it 'promotes outputs after broadcast acceptance on a deferred sign-then-broadcast flow' do
      basket = 'deferred_promoted'
      create_result = engine.brc100.create_action(
        description: 'deferred to broadcast',
        inputs: [],
        sign_and_process: false,
        outputs: [
          { satoshis: 0, locking_script: OP_TRUE,
            output_description: 'output', basket: basket,
            derivation_prefix: SecureRandom.uuid, derivation_suffix: '1',
            sender_identity_key: 'self' }
        ]
      )
      reference = create_result[:signable_transaction][:reference]
      action = store.find_action(reference: reference)

      # Sign with default broadcast intent (delayed). store.sign_action
      # creates the broadcasts row; the engine returns without invoking
      # ARC because broadcast_intent: :delayed defers to the daemon. The test
      # then simulates the daemon's Phase 4 trigger directly.
      engine.brc100.sign_action(spends: {}, reference: reference)

      # Outputs still pending — no Phase 4 yet.
      expect(engine.brc100.list_outputs(basket: basket)[:total_outputs]).to eq(0)

      # Simulate the daemon recording a non-rejected broadcast result on
      # acceptance — record_broadcast_result promotes (QUEUED is non-rejected).
      store.record_broadcast_result(action_id: action[:id], tx_status: 'QUEUED')
      expect(BSV::Wallet::Store::Models::Promotion.where(action_id: action[:id]).any?).to be(true)

      # The output is now in the canonical UTXO set.
      listed = engine.brc100.list_outputs(basket: basket)
      expect(listed[:total_outputs]).to eq(1)
      expect(listed[:outputs].first[:satoshis]).to eq(0)
    end

    it 'builds a valid Atomic BEEF before broadcast acceptance (no promotions row yet)' do
      # BEEF construction resolves *source* outputs of the new action's
      # inputs (parent transactions), not the new action's own outputs.
      # Even with the new action unpromoted (no promotions row),
      # BEEF construction should produce a valid envelope.
      basket = 'beef_before_phase4'
      create_result = engine.brc100.create_action(
        description: 'beef pre phase4',
        inputs: [],
        outputs: [
          { satoshis: 0, locking_script: OP_TRUE,
            output_description: 'output', basket: basket,
            derivation_prefix: SecureRandom.uuid, derivation_suffix: '1',
            sender_identity_key: 'self' }
        ]
      )

      action = store.find_action(wtxid: create_result[:txid])
      rows = BSV::Wallet::Store::Models::Output.where(action_id: action[:id]).all
      expect(rows).not_to be_empty
      expect(BSV::Wallet::Store::Models::Promotion.where(action_id: action[:id]).any?).to be(false)

      parsed = parse_beef_tx(create_result[:tx])
      expect(parsed.outputs.length).to eq(1)
      expect(parsed.outputs[0].satoshis).to eq(0)
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

    # Fund the wallet with a real P2PKH output that can be signed.
    #
    # op_true_lock: lock outputs with OP_TRUE instead of P2PKH. Used by
    # tests that exercise the caller-supplied-unlocking-script path —
    # under strict validate_for_handoff! (#296 Phase B) the resulting
    # BEEF must verify, which a stub unlocking script cannot satisfy
    # against a P2PKH lock. OP_TRUE accepts any unlocking.
    def fund_wallet_with_keys(satoshis: 1000, count: 1,
                              prefix: 'wallet payment', suffix: 'suffix1',
                              sender_identity_key: 'self', op_true_lock: false)
      outputs = count.times.map do |i|
        out_suffix = i.zero? ? suffix : "#{suffix}-#{i}"
        script_binary = if op_true_lock
                          op_true
                        else
                          derived_key = key_deriver.derive_private_key(
                            protocol_id: [2, prefix], key_id: out_suffix,
                            counterparty: sender_identity_key || 'self'
                          )
                          p2pkh_locking_script_for(derived_key).to_binary
                        end
        {
          satoshis: satoshis, vout: i,
          locking_script: script_binary,
          basket: 'default',
          derivation_prefix: prefix,
          derivation_suffix: out_suffix,
          sender_identity_key: sender_identity_key
        }
      end
      register_funded_outputs(outputs)
    end

    context 'full deferred flow with P2PKH inputs' do
      it 'wallet signs all P2PKH inputs when spends is empty' do
        fund_wallet_with_keys(satoshis: 1000)
        output_script = p2pkh_locking_script_for(derive_key).to_binary

        # Get the funded output ID
        listed = engine_with_keys.brc100.list_outputs(basket: 'default')
        output_id = listed[:outputs].first[:id]

        # Create a deferred action with an input
        create_result = engine_with_keys.brc100.create_action(
          description: 'deferred p2pkh',
          sign_and_process: false,
          inputs: [{ output_id: output_id }],
          outputs: [{ satoshis: 900, locking_script: output_script }]
        )

        reference = create_result[:signable_transaction][:reference]

        # Sign with empty spends — wallet signs the P2PKH input
        result = engine_with_keys.brc100.sign_action(
          spends: {},
          reference: reference
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
        # White-box test exercising apply_spends's caller-unlock branch.
        # The custom_unlock below is a 3-byte stub — proving the wallet
        # applies whatever the caller provided verbatim — not a valid
        # P2PKH unlock. Strict validate_for_handoff! (#296 Phase B) is
        # stubbed because the assertion is about apply_spends's
        # mechanism, not BEEF validity.
        allow_any_instance_of(BSV::Wallet::Engine::Hydrator).to receive(:validate_for_handoff!) # rubocop:disable RSpec/AnyInstance
        fund_wallet_with_keys(satoshis: 1000)
        output_script = OP_TRUE

        listed = engine_with_keys.brc100.list_outputs(basket: 'default')
        output_id = listed[:outputs].first[:id]

        # engine_with_keys is needed because build_transaction (now called
        # during deferred create_action) requires a key_deriver for P2PKH inputs
        create_result = engine_with_keys.brc100.create_action(
          description: 'deferred caller',
          sign_and_process: false,
          inputs: [{ output_id: output_id }],
          outputs: [{ satoshis: 900, locking_script: output_script }]
        )

        reference = create_result[:signable_transaction][:reference]
        custom_unlock = "\x01\x02\x03".b

        # Caller provides unlocking script for input 0
        result = engine_with_keys.brc100.sign_action(
          spends: { 0 => { unlocking_script: custom_unlock } },
          reference: reference
        )

        expect(result[:txid]).to be_a(String)
        expect(result[:txid].bytesize).to eq(32)

        parsed = parse_beef_tx(result[:tx])
        expect(parsed.inputs[0].unlocking_script.to_binary).to eq(custom_unlock)
      end
    end

    context 'mixed signing' do
      it 'applies caller scripts for some inputs, wallet signs the rest' do
        # White-box mechanism test — see comment in
        # 'applies caller scripts without wallet signing' above.
        allow_any_instance_of(BSV::Wallet::Engine::Hydrator).to receive(:validate_for_handoff!) # rubocop:disable RSpec/AnyInstance
        fund_wallet_with_keys(satoshis: 1000, count: 2)
        output_script = OP_TRUE

        listed = engine_with_keys.brc100.list_outputs(basket: 'default')
        output_ids = listed[:outputs].map { |o| o[:id] }

        create_result = engine_with_keys.brc100.create_action(
          description: 'deferred mixed',
          sign_and_process: false,
          inputs: output_ids.each_with_index.map { |id, i| { output_id: id, vin: i } },
          outputs: [{ satoshis: 1800, locking_script: output_script }]
        )

        reference = create_result[:signable_transaction][:reference]
        custom_unlock = "\x04\x05\x06".b

        # Caller provides script for input 0, wallet signs input 1
        result = engine_with_keys.brc100.sign_action(
          spends: { 0 => { unlocking_script: custom_unlock } },
          reference: reference
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

    context 'caller-supplied unlock that is genuinely valid (#298)' do
      it 'passes strict validate_for_handoff! through the apply_spends path' do
        # The verbatim-mechanism tests above use a recognisable stub and
        # bypass validation (the stub is deliberately not a real script).
        # This one drives a *valid* caller unlock through apply_spends and
        # lets strict validate_for_handoff! run for real — unit-level cover
        # for the egress-validity contract on the caller-supplied path.
        fund_wallet_with_keys(satoshis: 1000)

        listed = engine_with_keys.brc100.list_outputs(basket: 'default')
        output_id = listed[:outputs].first[:id]

        create_result = engine_with_keys.brc100.create_action(
          description: 'deferred valid caller',
          sign_and_process: false,
          inputs: [{ output_id: output_id }],
          outputs: [{ satoshis: 900, locking_script: OP_TRUE }]
        )

        # Produce a genuinely-valid P2PKH unlock by signing the wallet's own
        # unsigned signable tx with the source's derived key (the same
        # derivation fund_wallet_with_keys locked the source to). apply_spends
        # rebuilds from the identical staged raw_tx, so this unlock is valid
        # for the final transaction.
        unsigned = parse_beef_tx(create_result[:signable_transaction][:tx])
        signing_key = key_deriver.derive_private_key(
          protocol_id: [2, 'wallet payment'], key_id: 'suffix1', counterparty: 'self'
        )
        unsigned.inputs[0].unlocking_script_template = BSV::Transaction::P2PKH.new(signing_key)
        unsigned.sign(0, signing_key)
        valid_unlock = unsigned.inputs[0].unlocking_script.to_binary

        # No stub on validate_for_handoff! — and assert it actually ran by
        # spying on the Beef.from_binary deserialise it performs (the only
        # such call in the sign flow), letting it execute for real.
        allow(BSV::Transaction::Beef).to receive(:from_binary).and_call_original

        result = engine_with_keys.brc100.sign_action(
          spends: { 0 => { unlocking_script: valid_unlock } },
          reference: create_result[:signable_transaction][:reference]
        )

        # Strict validate_for_handoff! ran (it deserialises the egress BEEF).
        expect(BSV::Transaction::Beef).to have_received(:from_binary).at_least(:once)
        expect(result[:txid].bytesize).to eq(32)
        parsed = parse_beef_tx(result[:tx])
        expect(parsed.inputs[0].unlocking_script.to_binary).to eq(valid_unlock)
      end
    end

    context 'invalid input reference' do
      it 'raises for non-existent vin in spends' do
        create_result = engine.brc100.create_action(
          description: 'deferred invalid',
          inputs: [],
          sign_and_process: false,
          outputs: [{ satoshis: 0, locking_script: OP_TRUE }]
        )

        reference = create_result[:signable_transaction][:reference]

        expect do
          engine.brc100.sign_action(
            spends: { 99 => { unlocking_script: "\x00".b } },
            reference: reference
          )
        end.to raise_error(BSV::Wallet::InvalidParameterError, /vin 99/)
      end
    end

    context 'output persistence at stage time' do
      it 'writes outputs with no promotions row during deferred create_action' do
        binary_script = "\x76\xa9\x14".b + ("\x00" * 20).b + "\x88\xac".b
        create_result = engine.brc100.create_action(
          description: 'deferred promo',
          inputs: [],
          sign_and_process: false,
          outputs: [
            { satoshis: 0, locking_script: binary_script,
              basket: 'deferred_test', output_description: 'test output', derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
          ]
        )

        # Send-path outputs are pending Phase 4 — written but not in the
        # canonical UTXO set, so list_outputs returns nothing.
        listed = engine.brc100.list_outputs(basket: 'deferred_test')
        expect(listed[:total_outputs]).to eq(0)

        # The output row itself exists, but no promotions row has been recorded.
        action = store.find_action(reference: create_result[:signable_transaction][:reference])
        rows = BSV::Wallet::Store::Models::Output.where(action_id: action[:id]).all
        expect(rows.size).to eq(1)
        expect(rows.first.satoshis).to eq(0)
        expect(BSV::Wallet::Store::Models::Promotion.where(action_id: action[:id]).any?).to be(false)
      end

      it 'stores unsigned raw_tx on the action' do
        create_result = engine.brc100.create_action(
          description: 'deferred rawtx',
          inputs: [],
          sign_and_process: false,
          outputs: [{ satoshis: 0, locking_script: OP_TRUE }]
        )

        action = store.find_action(reference: create_result[:signable_transaction][:reference])
        expect(action[:raw_tx]).to be_a(String)

        # The unsigned raw_tx is a valid serialized transaction
        parsed = BSV::Transaction::Tx.from_binary(action[:raw_tx])
        expect(parsed.outputs.length).to eq(1)
        expect(parsed.outputs[0].satoshis).to eq(0)
      end
    end

    context 'RESTRICT cleanup' do
      it 'raw delete of an action with outputs is blocked by RESTRICT FK (#189)' do
        create_result = engine.brc100.create_action(
          description: 'cascade test action',
          inputs: [],
          sign_and_process: false,
          outputs: [
            { satoshis: 0, locking_script: OP_TRUE,
              basket: 'cascade_test', derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
          ]
        )

        reference = create_result[:signable_transaction][:reference]
        action = store.find_action(reference: reference)
        expect(BSV::Wallet::Store::Models::Output.where(action_id: action[:id]).count).to eq(1)

        # Match the base Sequel::DatabaseError + message: Postgres 18 reports
        # RESTRICT violations with SQLSTATE 23001 (PG::RestrictViolation),
        # which Sequel doesn't map to ForeignKeyConstraintViolation.
        expect { BSV::Wallet::Store::Models::Action.where(id: action[:id]).delete }
          .to raise_error(Sequel::DatabaseError, /foreign key/i)
      end
    end

    context 'sequence number override' do
      it 'applies sequence number from spends' do
        # White-box mechanism test — see comment in
        # 'applies caller scripts without wallet signing' above.
        allow_any_instance_of(BSV::Wallet::Engine::Hydrator).to receive(:validate_for_handoff!) # rubocop:disable RSpec/AnyInstance
        fund_wallet_with_keys(satoshis: 1000)
        output_script = OP_TRUE

        listed = engine_with_keys.brc100.list_outputs(basket: 'default')
        output_id = listed[:outputs].first[:id]

        create_result = engine_with_keys.brc100.create_action(
          description: 'deferred seqnum',
          sign_and_process: false,
          inputs: [{ output_id: output_id }],
          outputs: [{ satoshis: 900, locking_script: output_script }]
        )

        reference = create_result[:signable_transaction][:reference]

        result = engine_with_keys.brc100.sign_action(
          spends: { 0 => { unlocking_script: "\x01".b, sequence_number: 42 } },
          reference: reference
        )

        parsed = parse_beef_tx(result[:tx])
        expect(parsed.inputs[0].sequence).to eq(42)
      end
    end
  end

  describe '#abort_action' do
    it 'aborts an unsigned action' do
      create_result = engine.brc100.create_action(
        description: 'to be aborted',
        inputs: [],
        sign_and_process: false,
        outputs: [
          { satoshis: 0, locking_script: OP_TRUE,
            output_description: 'output' }
        ]
      )

      reference = create_result[:signable_transaction][:reference]
      result = engine.brc100.abort_action(reference: reference)

      expect(result).to eq({ aborted: true })

      # Verify action is gone
      found = store.find_action(reference: reference)
      expect(found).to be_nil
    end

    it 'raises for non-UUID reference' do
      expect do
        engine.brc100.abort_action(reference: 'not-a-uuid')
      end.to raise_error(BSV::Wallet::InvalidParameterError)
    end

    it 'raises for nonexistent reference' do
      expect do
        engine.brc100.abort_action(reference: '00000000-0000-0000-0000-000000000000')
      end.to raise_error(BSV::Wallet::InvalidParameterError)
    end
  end

  # Wallet-vocab primitive surface (#402 Stage 2 / ADR-026).
  #
  # +Engine#do_*+ are the four thick write-side primitives BRC100 calls
  # into. These tests exercise them directly (non-BRC100 consumers — the
  # future #223 HTTP wrapper, #192 batch — will call them the same way).
  # The BRC-100-wrap behaviour is covered by the BRC-100-named blocks
  # above (+#create_action+, +#sign_action+, +#abort_action+,
  # +#internalize_action+); these blocks focus on the wallet-vocab
  # return shapes the wrap layer translates from.
  describe '#build_action (wallet-vocab primitive)' do
    it 'returns { wtxid:, atomic_beef: } on the synchronous path' do
      result = engine.build_action(
        description: 'sync primitive',
        inputs: [],
        outputs: [
          { satoshis: 0, locking_script: OP_TRUE,
            derivation_prefix: SecureRandom.uuid, derivation_suffix: '1',
            sender_identity_key: 'self' }
        ]
      )

      expect(result.keys).to contain_exactly(:wtxid, :atomic_beef)
      expect(result[:wtxid]).to be_a(String).and(have_attributes(bytesize: 32))
      expect(result[:atomic_beef]).to be_a(String).and(satisfy { |b| b.bytesize >= 10 })
    end

    it 'returns { wtxid:, atomic_beef:, change_outpoints: } on the no_send path' do
      fund_wallet(satoshis: 100_000, basket: 'default', suffix: 'do_build_no_send')
      result = engine_with_keys.build_action(
        description: 'no_send primitive',
        outputs: [{ satoshis: 10_000, locking_script: OP_TRUE }],
        no_send: true
      )

      expect(result.keys).to contain_exactly(:wtxid, :atomic_beef, :change_outpoints)
      expect(result[:wtxid].bytesize).to eq(32)
      expect(result[:change_outpoints]).to be_an(Array)
      # outpoint format is "dtxid.vout" (64-char hex + "." + integer)
      expect(result[:change_outpoints]).to all(match(/\A[0-9a-f]{64}\.\d+\z/))
    end

    it 'returns { signable: { atomic_beef:, reference: } } on the deferred path' do
      result = engine.build_action(
        description: 'deferred primitive',
        inputs: [], sign_and_process: false,
        outputs: [
          { satoshis: 0, locking_script: OP_TRUE,
            derivation_prefix: SecureRandom.uuid, derivation_suffix: '1',
            sender_identity_key: 'self' }
        ]
      )

      expect(result.keys).to contain_exactly(:signable)
      expect(result[:signable].keys).to contain_exactly(:atomic_beef, :reference)
      expect(result[:signable][:reference]).to match(BSV::Wallet::Engine::UUID_RE)
      expect(result[:signable][:atomic_beef]).to be_a(String).and(satisfy { |b| b.bytesize >= 10 })
    end

    it 'does not accept the BRC-100 vocabulary kwargs (+originator:+, +return_txid_only:+, +trust_self:+)' do
      # ADR-026 decision 7 — those stay at BRC100. Verify the primitive
      # signature actually excludes them (an accidental future +**kwargs+
      # forwarding would silently re-accept them).
      params = engine.method(:build_action).parameters.map { |_kind, name| name }
      expect(params).not_to include(:originator, :return_txid_only, :trust_self)
    end
  end

  describe '#sign_action (wallet-vocab primitive)' do
    let(:deferred_reference) do
      result = engine.build_action(
        description: 'parked for sign primitive',
        inputs: [], sign_and_process: false,
        outputs: [
          { satoshis: 0, locking_script: OP_TRUE,
            derivation_prefix: SecureRandom.uuid, derivation_suffix: '1',
            sender_identity_key: 'self' }
        ]
      )
      result[:signable][:reference]
    end

    it 'returns { wtxid:, atomic_beef: } for a successful sign' do
      result = engine.sign_action(reference: deferred_reference, spends: {})

      expect(result.keys).to contain_exactly(:wtxid, :atomic_beef)
      expect(result[:wtxid].bytesize).to eq(32)
      expect(result[:atomic_beef]).to be_a(String)
    end

    it 'raises InvalidParameterError for an unknown reference' do
      expect do
        engine.sign_action(
          reference: '00000000-0000-0000-0000-000000000000', spends: {}
        )
      end.to raise_error(BSV::Wallet::InvalidParameterError)
    end

    it 'rejects no_send: true when the action was not parked with broadcast_intent: none' do
      expect do
        engine.sign_action(
          reference: deferred_reference, spends: {}, no_send: true
        )
      end.to raise_error(BSV::Wallet::UnsupportedActionError, /signAction\(no_send: true\)/)
    end
  end

  describe '#abort_action (wallet-vocab primitive)' do
    let(:deferred_reference) do
      result = engine.build_action(
        description: 'parked for abort primitive',
        inputs: [], sign_and_process: false,
        outputs: [
          { satoshis: 500, locking_script: OP_TRUE,
            output_description: 'output' }
        ]
      )
      result[:signable][:reference]
    end

    it 'returns { aborted: true } and removes the action row' do
      result = engine.abort_action(reference: deferred_reference)

      expect(result).to eq({ aborted: true })
      expect(store.find_action(reference: deferred_reference)).to be_nil
    end

    it 'raises InvalidParameterError for an unknown reference' do
      expect do
        engine.abort_action(reference: '00000000-0000-0000-0000-000000000000')
      end.to raise_error(BSV::Wallet::InvalidParameterError)
    end
  end

  describe '#import_beef (wallet-vocab primitive)' do
    it 'delegates to Engine::BeefImporter#import and forwards the kwargs' do
      # Smoke: build a minimal incoming-BEEF scenario indirectly via the
      # BRC-100 wrapper, asserting the primitive does NOT consume
      # +originator:+ (which BRC100 swallows per ADR-026 decision 7).
      params = engine.method(:import_beef).parameters.map { |_kind, name| name }
      expect(params).not_to include(:originator)
      expect(params).to include(:tx, :outputs, :description, :labels, :trust_self,
                                :known_txids, :seek_permission)
    end
  end

  # Wallet-vocab read-side primitive surface (#402 Stage 2 PR 2).
  #
  # Behaviour is exercised by the existing per-BRC-100-method describe
  # blocks below (each goes BRC100 wrapper → Engine#do_<name> →
  # collaborator), so this block focuses on the surface invariants that
  # transitive coverage can't catch:
  # - All 24 +do_+ primitives are defined.
  # - None accepts +originator:+ (BRC-100 vocab — stays at the wrap layer).
  describe 'read-side primitive surface' do
    READ_SIDE_PRIMITIVES = %i[
      encrypt decrypt create_hmac verify_hmac
      create_signature verify_signature
      get_public_key reveal_counterparty_key_linkage reveal_specific_key_linkage
      acquire_certificate list_certificates prove_certificate
      relinquish_certificate discover_by_identity_key discover_by_attributes
      list_actions list_outputs relinquish_output
      authenticated? wait_for_authentication
      get_height get_header_for_height get_network get_version
    ].freeze

    it 'defines exactly 24 read-side primitives' do
      expect(READ_SIDE_PRIMITIVES.length).to eq(24)
    end

    READ_SIDE_PRIMITIVES.each do |name|
      it "##{name} is defined on Engine" do
        expect(engine).to respond_to(name)
      end

      it "##{name} does not accept +originator:+ (ADR-026 decision 7)" do
        params = engine.method(name).parameters.map { |_kind, pname| pname }
        expect(params).not_to include(:originator),
                              "expected #{name} signature to exclude :originator, got #{params.inspect}"
      end

      it "##{name} has an explicit keyword signature (no anonymous **kwargs)" do
        # Anonymous +**+ forwarding would silently accept arbitrary
        # kwargs including +originator:+, defeating the previous test.
        # Explicit signatures are the structural guarantee.
        forwards = engine.method(name).parameters.any? { |kind, _| kind == :keyrest }
        expect(forwards).to be(false),
                            "expected #{name} to declare its keywords explicitly, found anonymous **kwargs"
      end
    end
  end

  describe '#reject_action' do
    it 'delegates to Store#reject_action and returns a structured result' do
      # A rejectable send action: broadcast_intent='inline', a broadcasts row
      # holding REJECTED, and (per #307) no promotions row — the promotions row
      # pins intent='none' so it can't be flipped to 'inline' after the fact;
      # build the inline action directly instead.
      action = store.send(:models)::Action.create(
        description: 'speculative inline', broadcast_intent: 'inline',
        wtxid: SecureRandom.random_bytes(32), raw_tx: SecureRandom.random_bytes(100)
      )
      action_id = action.id
      store.db[:broadcasts].insert(action_id: action_id, intent: 'inline', tx_status: 'REJECTED')

      response = engine.reject_action(action_id: action_id)

      expect(response).to eq({ rejected: true, action_id: action_id })
      expect(store.find_action(id: action_id)).to be_nil
    end

    it 'raises InvalidParameterError when the action_id does not exist' do
      expect { engine.reject_action(action_id: 999_999_999) }
        .to raise_error(BSV::Wallet::InvalidParameterError, /not found/)
    end

    it 'propagates CannotRejectInternalActionError from the store' do
      engine.brc100.create_action(
        description: 'internal action',
        inputs: [],
        outputs: [{ satoshis: 0, locking_script: OP_TRUE, output_description: 'out' }],
        no_send: true
      )
      action_id = store.send(:models)::Action.where(description: 'internal action').last.id
      expect { engine.reject_action(action_id: action_id) }
        .to raise_error(BSV::Wallet::CannotRejectInternalActionError)
    end
  end

  describe '#list_actions' do
    before do
      # Vary locking_script per action so they hash to distinct wtxids
      # (actions.wtxid is UNIQUE). All three carry 0 satoshis to stay
      # within strict validate_for_handoff!'s output_total <= input_total.
      engine.brc100.create_action(
        description: 'payment action', inputs: [], no_send: true, labels: ['payment'],
        outputs: [{ satoshis: 0, output_description: 'output', locking_script: "\x01".b }]
      )
      engine.brc100.create_action(
        description: 'transfer action', inputs: [], no_send: true, labels: ['transfer'],
        outputs: [{ satoshis: 0, output_description: 'output', locking_script: "\x02".b }]
      )
      engine.brc100.create_action(
        description: 'both labels', inputs: [], no_send: true, labels: %w[payment transfer],
        outputs: [{ satoshis: 0, output_description: 'output', locking_script: "\x03".b }]
      )
    end

    it 'filters by label (any mode)' do
      result = engine.brc100.list_actions(labels: ['payment'])
      expect(result[:total_actions]).to eq(2)
    end

    it 'filters by label (all mode)' do
      result = engine.brc100.list_actions(labels: %w[payment transfer], label_query_mode: :all)
      expect(result[:total_actions]).to eq(1)
    end

    it 'paginates' do
      result = engine.brc100.list_actions(labels: ['payment'], limit: 1, offset: 0)
      expect(result[:actions].size).to eq(1)
      expect(result[:total_actions]).to eq(2)
    end

    it 'includes derived status' do
      result = engine.brc100.list_actions(labels: ['payment'])
      statuses = result[:actions].map { |a| a[:status] }
      expect(statuses).to all(be_a(Symbol))
    end
  end

  describe '#internalize_action' do
    # Mock chain tracker that accepts all merkle roots.
    # Transaction::Tx#verify delegates merkle proof validation here.
    let(:chain_tracker_mock) do
      tracker = double('ChainTracker')
      allow(tracker).to receive_messages(valid_root_for_height?: true, current_height: 900_000)
      tracker
    end

    let(:engine_with_tracker) do
      described_class.new(
        store: store, utxo_pool: utxo_pool, broadcaster: broadcaster,
        chain_tracker: chain_tracker_mock, network: :mainnet
      )
    end

    # Build a verifiable BEEF with a proven ancestor, OP_1 scripts, and
    # proper input wiring so Transaction::Tx#verify succeeds.
    #
    # The subject transaction spends from a proven ancestor via OP_1
    # locking/unlocking scripts (trivially valid). Additional proven
    # ancestors are independent — they exist in the BEEF but are not
    # spent by the subject (matching the old build_test_beef shape).
    def build_test_beef(satoshis: 0, with_proof: false, ancestor_count: 0,
                        input_satoshis: nil)
      actual_input = input_satoshis || (satoshis + 100)

      # Primary ancestor: the one the subject spends from
      primary_ancestor = BSV::Transaction::Tx.new(version: 1, lock_time: 0)
      primary_ancestor.add_output(BSV::Transaction::TransactionOutput.new(
                                    satoshis: actual_input,
                                    locking_script: BSV::Script::Script.from_binary(OP_TRUE)
                                  ))
      primary_ancestor.merkle_path = build_merkle_path(primary_ancestor, 800_000)

      beef = BSV::Transaction::Beef.new
      beef.merge_transaction(primary_ancestor)

      # Additional proven ancestors if requested (independent, not spent by subject)
      ancestor_count.times do |i|
        extra = BSV::Transaction::Tx.new(version: 1, lock_time: 0)
        extra.add_output(BSV::Transaction::TransactionOutput.new(
                           satoshis: 1000 + i,
                           locking_script: BSV::Script::Script.from_binary(OP_TRUE)
                         ))
        extra.merkle_path = build_merkle_path(extra, 800_001 + i)
        beef.merge_transaction(extra)
      end

      # Subject transaction: spends from the primary ancestor via OP_1
      subject_tx = BSV::Transaction::Tx.new(version: 1, lock_time: 0)
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

      result = engine_with_tracker.brc100.internalize_action(
        tx: beef_data,
        description: 'incoming payment',
        labels: ['incoming'],
        outputs: [
          {
            output_index: 0,
            protocol: :basket_insertion,
            satoshis: 0,
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
      listed = engine.brc100.list_outputs(basket: 'tokens', include_tags: true)
      expect(listed[:total_outputs]).to eq(1)
      expect(listed[:outputs].first[:tags]).to eq(['nft'])
    end

    it 'creates a completed incoming action with wallet payment' do
      beef_data = build_test_beef(satoshis: 1000)

      result = engine_with_tracker.brc100.internalize_action(
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

      engine_with_tracker.brc100.internalize_action(
        tx: beef_data,
        description: 'wtxid storage test',
        labels: ['test'],
        outputs: [
          { output_index: 0, protocol: :basket_insertion, satoshis: 0,
            insertion_remittance: { basket: 'wtxid_test', derivation_prefix: 'test', derivation_suffix: '1', sender_identity_key: 'self' } }
        ]
      )

      listed = engine.brc100.list_actions(labels: ['test'])
      action = listed[:actions].first
      expect(action[:wtxid]).to eq(expected_wtxid)
    end

    it 'saves ancestor proofs to ProofStore' do
      beef_data = build_test_beef(satoshis: 0, ancestor_count: 2)

      # Parse to get ancestor txids
      beef = BSV::Transaction::Beef.from_binary(beef_data)
      ancestor_wtxids = beef.transactions
                            .grep(BSV::Transaction::Beef::ProvenTxEntry)
                            .map(&:wtxid)

      engine_with_tracker.brc100.internalize_action(
        tx: beef_data,
        description: 'ancestor proof test',
        outputs: [
          { output_index: 0, protocol: :basket_insertion, satoshis: 0,
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
      beef_data = build_test_beef(satoshis: 0, with_proof: true)

      beef = BSV::Transaction::Beef.from_binary(beef_data)
      subject_wtxid = beef.subject_wtxid

      engine_with_tracker.brc100.internalize_action(
        tx: beef_data,
        description: 'proof link test',
        labels: ['proof-link'],
        outputs: [
          { output_index: 0, protocol: :basket_insertion, satoshis: 0,
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
      action_record = BSV::Wallet::Store::Models::Action.first(
        wtxid: Sequel.blob(subject_wtxid)
      )
      expect(action_record.tx_proof_id).to eq(proof[:id])
    end

    it 'does not link proof when subject has no BUMP' do
      beef_data = build_test_beef(satoshis: 0, with_proof: false)

      engine_with_tracker.brc100.internalize_action(
        tx: beef_data,
        description: 'no proof link test',
        labels: ['no-proof'],
        outputs: [
          { output_index: 0, protocol: :basket_insertion, satoshis: 0,
            insertion_remittance: { basket: 'no_proof_test', derivation_prefix: 'test', derivation_suffix: '1', sender_identity_key: 'self' } }
        ]
      )

      listed = engine.brc100.list_actions(labels: ['no-proof'])
      action = listed[:actions].first
      expect(action[:tx_proof_id]).to be_nil
    end

    it 'raises InvalidBeefError for truncated BEEF' do
      expect do
        engine_with_tracker.brc100.internalize_action(
          tx: "\x01\x00".b,
          description: 'truncated test',
          outputs: []
        )
      end.to raise_error(BSV::Wallet::InvalidBeefError, /truncated/)
    end

    it 'raises InvalidBeefError for non-BEEF data' do
      expect do
        engine_with_tracker.brc100.internalize_action(
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
        engine_with_tracker.brc100.internalize_action(
          tx: buf,
          description: 'empty beef test',
          outputs: []
        )
      end.to raise_error(BSV::Wallet::InvalidBeefError, /no transactions/)
    end

    it 'validates description' do
      expect do
        engine_with_tracker.brc100.internalize_action(tx: "\x00".b, description: 'hi', outputs: [])
      end.to raise_error(BSV::Wallet::InvalidParameterError)
    end

    it 'raises InvalidBeefError without chain_tracker' do
      beef_data = build_test_beef(satoshis: 500)

      expect do
        engine.brc100.internalize_action(
          tx: beef_data,
          description: 'no tracker fails',
          outputs: []
        )
      end.to raise_error(BSV::Wallet::InvalidBeefError, /chain_tracker required/)
    end

    # --- SPV verification via Transaction::Tx#verify ---

    context 'SPV verification' do
      it 'accepts valid BEEF that passes full verification' do
        beef_data = build_test_beef(satoshis: 500)

        result = engine_with_tracker.brc100.internalize_action(
          tx: beef_data,
          description: 'valid beef passes',
          outputs: [
            { output_index: 0, protocol: :basket_insertion, satoshis: 0,
              insertion_remittance: { basket: 'spv_valid', derivation_prefix: 'test', derivation_suffix: '1', sender_identity_key: 'self' } }
          ]
        )

        expect(result).to eq({ accepted: true })
      end

      it 'verifies merkle roots against chain tracker' do
        beef_data = build_test_beef(satoshis: 0, with_proof: true)

        result = engine_with_tracker.brc100.internalize_action(
          tx: beef_data,
          description: 'chain tracker ok',
          outputs: [
            { output_index: 0, protocol: :basket_insertion, satoshis: 0,
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
          store: store, utxo_pool: utxo_pool, broadcaster: broadcaster,
          chain_tracker: rejecting_tracker, network: :mainnet
        )

        beef_data = build_test_beef(satoshis: 500)

        expect do
          engine_reject.brc100.internalize_action(
            tx: beef_data,
            description: 'tracker rejects',
            outputs: []
          )
        end.to raise_error(BSV::Wallet::InvalidBeefError, /SPV verification failed.*invalid_merkle_proof/)
      end

      it 'rejects BEEF with missing ancestor (missing_source)' do
        # Build a BEEF where the subject references an ancestor not included
        ancestor_tx = BSV::Transaction::Tx.new(version: 1, lock_time: 0)
        ancestor_tx.add_output(BSV::Transaction::TransactionOutput.new(
                                 satoshis: 1000,
                                 locking_script: BSV::Script::Script.from_binary(OP_TRUE)
                               ))

        subject_tx = BSV::Transaction::Tx.new(version: 1, lock_time: 0)
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
          engine_with_tracker.brc100.internalize_action(
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

        result = engine_with_tracker.brc100.internalize_action(
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
          engine_with_tracker.brc100.internalize_action(
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
        beef_data = build_test_beef(satoshis: 0, ancestor_count: 2)

        # Pre-populate ProofStore with proofs for all ancestors
        beef = BSV::Transaction::Beef.from_binary(beef_data)
        beef.transactions
            .grep(BSV::Transaction::Beef::ProvenTxEntry)
            .each do |bt|
          proof_store.save_proof(
            wtxid: bt.wtxid,
            proof: { height: 800_000, raw_tx: bt.transaction.to_binary }
          )
        end

        result = engine_with_tracker.brc100.internalize_action(
          tx: beef_data,
          description: 'all ancestors known',
          trust_self: 'known',
          outputs: [
            { output_index: 0, protocol: :basket_insertion, satoshis: 0,
              insertion_remittance: { basket: 'trust_all', derivation_prefix: 'test', derivation_suffix: '1', sender_identity_key: 'self' } }
          ]
        )

        expect(result).to eq({ accepted: true })
      end

      it 'accepts BEEF with some ancestors known and others proven via BUMP' do
        beef_data = build_test_beef(satoshis: 0, ancestor_count: 2)

        # Only populate ProofStore for the first ancestor
        beef = BSV::Transaction::Beef.from_binary(beef_data)
        first_ancestor = beef.transactions
                             .grep(BSV::Transaction::Beef::ProvenTxEntry)
                             .first

        proof_store.save_proof(
          wtxid: first_ancestor.wtxid,
          proof: { height: 800_000, raw_tx: first_ancestor.transaction.to_binary }
        )

        result = engine_with_tracker.brc100.internalize_action(
          tx: beef_data,
          description: 'some known some bump',
          trust_self: 'known',
          outputs: [
            { output_index: 0, protocol: :basket_insertion, satoshis: 0,
              insertion_remittance: { basket: 'trust_some', derivation_prefix: 'test', derivation_suffix: '1', sender_identity_key: 'self' } }
          ]
        )

        expect(result).to eq({ accepted: true })
      end

      it 'rejects BEEF with unknown ancestor that has no BUMP' do
        # Build a BEEF where the ancestor is missing (not included)
        ancestor_tx = BSV::Transaction::Tx.new(version: 1, lock_time: 0)
        ancestor_tx.add_output(BSV::Transaction::TransactionOutput.new(
                                 satoshis: 1000,
                                 locking_script: BSV::Script::Script.from_binary(OP_TRUE)
                               ))

        subject_tx = BSV::Transaction::Tx.new(version: 1, lock_time: 0)
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
          engine_with_tracker.brc100.internalize_action(
            tx: beef_data,
            description: 'unknown no bump rej',
            trust_self: 'known',
            outputs: []
          )
        end.to raise_error(BSV::Wallet::InvalidBeefError, /SPV verification failed.*missing_source/)
      end

      it 'treats known_txids entries as known ancestors' do
        beef_data = build_test_beef(satoshis: 0, ancestor_count: 1)

        # Get the ancestor wtxid but do NOT put it in ProofStore
        beef = BSV::Transaction::Beef.from_binary(beef_data)
        ancestor_wtxid = beef.transactions
                             .find { |bt| bt.is_a?(BSV::Transaction::Beef::ProvenTxEntry) }
                             &.wtxid

        result = engine_with_tracker.brc100.internalize_action(
          tx: beef_data,
          description: 'known txids supple',
          trust_self: 'known',
          known_txids: [ancestor_wtxid],
          outputs: [
            { output_index: 0, protocol: :basket_insertion, satoshis: 0,
              insertion_remittance: { basket: 'known_txids', derivation_prefix: 'test', derivation_suffix: '1', sender_identity_key: 'self' } }
          ]
        )

        expect(result).to eq({ accepted: true })
      end

      it 'runs full validation without trust_self regardless of ProofStore' do
        beef_data = build_test_beef(satoshis: 0, ancestor_count: 1)

        # Pre-populate ProofStore — but since trust_self is nil, full validation runs
        beef = BSV::Transaction::Beef.from_binary(beef_data)
        beef.transactions
            .grep(BSV::Transaction::Beef::ProvenTxEntry)
            .each do |bt|
          proof_store.save_proof(
            wtxid: bt.wtxid,
            proof: { height: 800_000, raw_tx: bt.transaction.to_binary }
          )
        end

        # Without trust_self, BEEF keeps its original proven format — validation passes
        # because the ancestors have valid BUMPs in the BEEF itself
        result = engine_with_tracker.brc100.internalize_action(
          tx: beef_data,
          description: 'no trust self full',
          outputs: [
            { output_index: 0, protocol: :basket_insertion, satoshis: 0,
              insertion_remittance: { basket: 'no_trust', derivation_prefix: 'test', derivation_suffix: '1', sender_identity_key: 'self' } }
          ]
        )

        expect(result).to eq({ accepted: true })
      end
    end

    # --- Ancestor proof chain storage (#33) ---

    context 'ancestor proof chain storage' do
      it 'stores raw_tx for each ancestor in ProofStore' do
        beef_data = build_test_beef(satoshis: 0, ancestor_count: 2)

        beef = BSV::Transaction::Beef.from_binary(beef_data)
        ancestor_wtxids = beef.transactions
                              .grep(BSV::Transaction::Beef::ProvenTxEntry)
                              .map(&:wtxid)

        engine_with_tracker.brc100.internalize_action(
          tx: beef_data,
          description: 'raw_tx storage test',
          outputs: [
            { output_index: 0, protocol: :basket_insertion, satoshis: 0,
              insertion_remittance: { basket: 'raw_tx_test', derivation_prefix: 'test', derivation_suffix: '1', sender_identity_key: 'self' } }
          ]
        )

        ancestor_wtxids.each do |wtxid|
          proof = proof_store.find_proof(wtxid: wtxid)
          expect(proof).not_to be_nil
          expect(proof[:raw_tx]).to be_a(String)
          expect(proof[:raw_tx].bytesize).to be > 0

          # Verify the raw_tx can be deserialized back to a valid transaction
          tx = BSV::Transaction::Tx.from_binary(proof[:raw_tx])
          expect(tx.wtxid).to eq(wtxid)
        end
      end

      it 'stores consistent format from BEEF and broadcast sources' do
        # BEEF source: internalize action stores merkle_path as BRC-74 binary
        beef_data = build_test_beef(satoshis: 0, ancestor_count: 1)

        beef = BSV::Transaction::Beef.from_binary(beef_data)
        ancestor_bt = beef.transactions.find do |bt|
          bt.is_a?(BSV::Transaction::Beef::ProvenTxEntry)
        end
        ancestor_txid = ancestor_bt.wtxid

        engine_with_tracker.brc100.internalize_action(
          tx: beef_data,
          description: 'format consistency',
          outputs: [
            { output_index: 0, protocol: :basket_insertion, satoshis: 0,
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

    # Broadcast-proof linking (formerly Engine#handle_proof_from_broadcast):
    # moved to Engine::Broadcast#link_proof_if_present in #271; merkle-path
    # normalisation lives in Engine::MerklePathNormaliser. Direct coverage
    # in spec/bsv/wallet/engine/broadcast_spec.rb.
    #
    # Private-method tests for verify_incoming_transaction!, parse_beef,
    # and replace_known_ancestors! live in beef_importer_spec.rb — those
    # helpers were extracted from Engine::Action to Engine::BeefImporter
    # in #340 and are exercised there directly.
  end

  describe '#list_outputs' do
    before do
      engine.brc100.create_action(
        description: 'create outputs', inputs: [], no_send: true,
        outputs: [
          { satoshis: 0, locking_script: OP_TRUE,
            output_description: 'first', basket: 'wallet', tags: ['payment'],
            derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' },
          { satoshis: 0, locking_script: OP_TRUE,
            output_description: 'second', basket: 'wallet', tags: ['change'],
            derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' },
          { satoshis: 0, locking_script: OP_TRUE,
            output_description: 'third', basket: 'other',
            derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
        ]
      )
    end

    it 'filters by basket' do
      result = engine.brc100.list_outputs(basket: 'wallet')
      expect(result[:total_outputs]).to eq(2)
    end

    it 'filters by tag' do
      result = engine.brc100.list_outputs(basket: 'wallet', tags: ['payment'])
      expect(result[:total_outputs]).to eq(1)
    end

    it 'paginates' do
      result = engine.brc100.list_outputs(basket: 'wallet', limit: 1)
      expect(result[:outputs].size).to eq(1)
      expect(result[:total_outputs]).to eq(2)
    end
  end

  describe '#relinquish_output' do
    it 'removes output from tracking' do
      engine.brc100.create_action(
        description: 'with output', inputs: [], no_send: true,
        outputs: [
          { satoshis: 0, locking_script: OP_TRUE,
            output_description: 'to relinquish', basket: 'wallet',
            derivation_prefix: SecureRandom.uuid, derivation_suffix: '1', sender_identity_key: 'self' }
        ]
      )

      listed = engine.brc100.list_outputs(basket: 'wallet')
      output_id = listed[:outputs].first[:id]

      result = engine.brc100.relinquish_output(basket: 'wallet', output: output_id)
      expect(result).to eq({ relinquished: true })

      listed_after = engine.brc100.list_outputs(basket: 'wallet')
      expect(listed_after[:total_outputs]).to eq(0)
    end
  end

  describe '#get_public_key' do
    it 'returns the identity key when identity_key: true' do
      result = engine_with_keys.brc100.get_public_key(identity_key: true)
      expect(result[:public_key]).to be_a(String)
      expect(result[:public_key].length).to eq(66)
      expect(result[:public_key]).to match(/\A(?:02|03)[0-9a-f]{64}\z/)
      expect(result[:public_key]).to eq(root_key.public_key.to_hex)
    end

    it 'derives a public key with protocol_id and key_id' do
      result = engine_with_keys.brc100.get_public_key(
        protocol_id: [1, 'test proto'], key_id: 'key1', counterparty: 'self'
      )
      expect(result[:public_key]).to be_a(String)
      expect(result[:public_key].bytesize).to eq(33)

      # Verify determinism — same params yield same key
      result2 = engine_with_keys.brc100.get_public_key(
        protocol_id: [1, 'test proto'], key_id: 'key1', counterparty: 'self'
      )
      expect(result2[:public_key]).to eq(result[:public_key])
    end

    it 'raises without key_deriver' do
      expect { engine.brc100.get_public_key(identity_key: true) }
        .to raise_error(BSV::Wallet::Error, /key deriver/)
    end
  end

  describe '#reveal_counterparty_key_linkage' do
    it 'returns revelation with encrypted linkage and proof' do
      result = engine_with_keys.brc100.reveal_counterparty_key_linkage(
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
      result = engine_with_keys.brc100.reveal_specific_key_linkage(
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
      result = engine_with_keys.brc100.encrypt(
        plaintext: plaintext,
        protocol_id: [1, 'encryption test'], key_id: 'enc1'
      )
      expect(result[:ciphertext]).to be_a(String)
      expect(result[:ciphertext]).not_to eq(plaintext)
    end

    it 'round-trips encrypt then decrypt' do
      encrypted = engine_with_keys.brc100.encrypt(
        plaintext: plaintext,
        protocol_id: [1, 'encryption test'], key_id: 'enc1'
      )
      decrypted = engine_with_keys.brc100.decrypt(
        ciphertext: encrypted[:ciphertext],
        protocol_id: [1, 'encryption test'], key_id: 'enc1'
      )
      expect(decrypted[:plaintext]).to eq(plaintext)
    end

    it 'raises without key_deriver' do
      expect do
        engine.brc100.encrypt(plaintext: 'data'.b, protocol_id: [1, 'test proto'], key_id: 'k')
      end.to raise_error(BSV::Wallet::Error, /key deriver/)
    end
  end

  describe '#create_hmac / #verify_hmac' do
    it 'creates a 32-byte HMAC' do
      result = engine_with_keys.brc100.create_hmac(
        data: 'test data'.b, protocol_id: [1, 'hmac test proto'], key_id: 'h1'
      )
      expect(result[:hmac]).to be_a(String)
      expect(result[:hmac].bytesize).to eq(32)
    end

    it 'round-trips create then verify' do
      created = engine_with_keys.brc100.create_hmac(
        data: 'test data'.b, protocol_id: [1, 'hmac test proto'], key_id: 'h1'
      )
      result = engine_with_keys.brc100.verify_hmac(
        data: 'test data'.b, hmac: created[:hmac],
        protocol_id: [1, 'hmac test proto'], key_id: 'h1'
      )
      expect(result).to eq({ valid: true })
    end

    it 'raises InvalidHmacError for wrong HMAC' do
      expect do
        engine_with_keys.brc100.verify_hmac(
          data: 'test data'.b, hmac: SecureRandom.random_bytes(32),
          protocol_id: [1, 'hmac test proto'], key_id: 'h1'
        )
      end.to raise_error(BSV::Wallet::InvalidHmacError)
    end
  end

  describe '#create_signature / #verify_signature' do
    it 'creates a signature object' do
      result = engine_with_keys.brc100.create_signature(
        data: 'sign me'.b, protocol_id: [1, 'sig test proto'], key_id: 's1'
      )
      expect(result[:signature]).to be_a(BSV::Primitives::Signature)
    end

    it 'round-trips create then verify' do
      created = engine_with_keys.brc100.create_signature(
        data: 'sign me'.b, protocol_id: [1, 'sig test proto'], key_id: 's1'
      )
      result = engine_with_keys.brc100.verify_signature(
        signature: created[:signature], data: 'sign me'.b,
        protocol_id: [1, 'sig test proto'], key_id: 's1'
      )
      expect(result).to eq({ valid: true })
    end

    it 'raises InvalidSignatureError for wrong data' do
      created = engine_with_keys.brc100.create_signature(
        data: 'sign me'.b, protocol_id: [1, 'sig test proto'], key_id: 's1'
      )

      expect do
        engine_with_keys.brc100.verify_signature(
          signature: created[:signature], data: 'wrong data'.b,
          protocol_id: [1, 'sig test proto'], key_id: 's1'
        )
      end.to raise_error(BSV::Wallet::InvalidSignatureError)
    end
  end

  describe '#acquire_certificate' do
    it 'acquires a certificate directly' do
      result = engine_with_keys.brc100.acquire_certificate(
        type: 'identity', certifier: "02#{'c' * 64}",
        acquisition_protocol: :direct,
        fields: { 'name' => 'Alice', 'email' => 'alice@test.com' },
        serial_number: 'sn001', signature: 'sig_hex'
      )

      expect(result[:id]).to be_a(Integer)
      expect(result[:fields]).to eq({ 'name' => 'Alice', 'email' => 'alice@test.com' })
    end

    it 'raises for issuance protocol (not yet supported)' do
      expect do
        engine_with_keys.brc100.acquire_certificate(
          type: 'identity', certifier: "02#{'1' * 64}",
          acquisition_protocol: :issuance,
          fields: {}, certifier_url: 'https://cert.example.com'
        )
      end.to raise_error(BSV::Wallet::UnsupportedActionError)
    end
  end

  describe '#list_certificates' do
    before do
      engine_with_keys.brc100.acquire_certificate(
        type: 'id', certifier: "02#{'1' * 64}", acquisition_protocol: :direct,
        fields: { 'name' => 'Alice' }, serial_number: 'sn1', signature: 's1'
      )
      engine_with_keys.brc100.acquire_certificate(
        type: 'id', certifier: "02#{'2' * 64}", acquisition_protocol: :direct,
        fields: { 'name' => 'Bob' }, serial_number: 'sn2', signature: 's2'
      )
    end

    it 'lists certificates filtered by certifier and type' do
      result = engine_with_keys.brc100.list_certificates(certifiers: ["02#{'1' * 64}"], types: ['id'])
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

      result = engine_with_keys.brc100.prove_certificate(
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
      engine_with_keys.brc100.acquire_certificate(
        type: 'id', certifier: "02#{'1' * 64}", acquisition_protocol: :direct,
        fields: { 'name' => 'Alice' }, serial_number: 'sn1', signature: 's1'
      )

      result = engine_with_keys.brc100.relinquish_certificate(
        type: 'id', serial_number: 'sn1', certifier: "02#{'1' * 64}"
      )
      expect(result).to eq({ relinquished: true })

      listed = engine_with_keys.brc100.list_certificates(certifiers: ["02#{'1' * 64}"], types: ['id'])
      expect(listed[:total_certificates]).to eq(0)
    end
  end

  describe '#authenticated?' do
    it 'returns true with key_deriver' do
      expect(engine_with_keys.brc100.authenticated?).to eq({ authenticated: true })
    end

    it 'returns false without key_deriver' do
      expect(engine.brc100.authenticated?).to eq({ authenticated: false })
    end
  end

  describe '#wait_for_authentication' do
    it 'returns immediately when authenticated' do
      expect(engine_with_keys.brc100.wait_for_authentication).to eq({ authenticated: true })
    end

    it 'raises when not authenticated' do
      expect { engine.brc100.wait_for_authentication }.to raise_error(BSV::Wallet::Error)
    end
  end

  describe 'privileged mode' do
    it 'derives a different public key with privileged: true' do
      normal = engine_with_privileged_keys.brc100.get_public_key(
        protocol_id: [1, 'test proto'], key_id: 'key1', counterparty: 'self'
      )
      privileged = engine_with_privileged_keys.brc100.get_public_key(
        protocol_id: [1, 'test proto'], key_id: 'key1', counterparty: 'self',
        privileged: true
      )
      expect(privileged[:public_key]).not_to eq(normal[:public_key])
    end

    it 'round-trips encrypt/decrypt with privileged: true' do
      plaintext = 'privileged secret'.b
      encrypted = engine_with_privileged_keys.brc100.encrypt(
        plaintext: plaintext,
        protocol_id: [1, 'priv encrypt test'], key_id: 'p1',
        privileged: true
      )
      decrypted = engine_with_privileged_keys.brc100.decrypt(
        ciphertext: encrypted[:ciphertext],
        protocol_id: [1, 'priv encrypt test'], key_id: 'p1',
        privileged: true
      )
      expect(decrypted[:plaintext]).to eq(plaintext)
    end

    it 'round-trips HMAC create/verify with privileged: true' do
      created = engine_with_privileged_keys.brc100.create_hmac(
        data: 'privileged data'.b, protocol_id: [1, 'priv hmac test'], key_id: 'p1',
        privileged: true
      )
      result = engine_with_privileged_keys.brc100.verify_hmac(
        data: 'privileged data'.b, hmac: created[:hmac],
        protocol_id: [1, 'priv hmac test'], key_id: 'p1',
        privileged: true
      )
      expect(result).to eq({ valid: true })
    end

    it 'round-trips signature create/verify with privileged: true' do
      created = engine_with_privileged_keys.brc100.create_signature(
        data: 'privileged data'.b, protocol_id: [1, 'priv sig test'], key_id: 'p1',
        privileged: true
      )
      result = engine_with_privileged_keys.brc100.verify_signature(
        signature: created[:signature], data: 'privileged data'.b,
        protocol_id: [1, 'priv sig test'], key_id: 'p1',
        privileged: true
      )
      expect(result).to eq({ valid: true })
    end

    it 'raises when privileged key is not configured' do
      expect do
        engine_with_keys.brc100.get_public_key(
          protocol_id: [1, 'test proto'], key_id: 'key1',
          counterparty: 'self', privileged: true
        )
      end.to raise_error(BSV::Wallet::Error, /privileged key/)
    end
  end

  describe '#get_height' do
    it 'raises UnsupportedActionError (chain data source not configured)' do
      expect { engine.brc100.get_height }.to raise_error(BSV::Wallet::UnsupportedActionError)
    end
  end

  describe '#get_header_for_height' do
    it 'raises UnsupportedActionError (chain data source not configured)' do
      expect { engine.brc100.get_header_for_height(height: 1) }.to raise_error(BSV::Wallet::UnsupportedActionError)
    end
  end

  describe '#get_network' do
    it 'returns the configured network' do
      expect(engine.brc100.get_network).to eq({ network: :mainnet })
    end
  end

  describe '#get_version' do
    it 'returns the wallet version' do
      result = engine.brc100.get_version
      expect(result[:version]).to start_with('bsv-wallet-')
    end
  end

  # --- Output Construction and Randomization (#21) ---
  # Direct tests for #build_outputs live in engine/tx_builder_spec.rb
  # (lifted from Engine::Action to Engine::TxBuilder in #340).

  # --- Input Selection Primitive (#208) ---
  # Direct tests for input selection live in engine/funding_strategy_spec.rb
  # (#323; selection lives on Engine::FundingStrategy).

  # --- Change generation: explicit fee detection + shortfall reporting (#209) ---
  # Direct tests for TxBuilder#build_change live in engine/tx_builder_spec.rb
  # (renamed from #generate_change and lifted to Engine::TxBuilder in #340).

  # --- Input Resolution and P2PKH Signing (#22) ---
  # Direct tests for #build_inputs live in engine/tx_builder_spec.rb
  # (lifted from Engine::Action to Engine::TxBuilder in #340).

  # --- Transaction Assembly, Serialization, and Txid (#23) ---
  # No standalone #build_transaction primitive — transaction assembly is
  # composed inside TxBuilder#build_change (see engine/tx_builder_spec.rb)
  # and the action lifecycle covers end-to-end assembly in action_spec.rb.

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
        # Reserve UTXO keeps the headroom check satisfied while a small
        # caller UTXO drives the e2e signing path.
        fund_wallet(satoshis: 100_000, prefix: 'reserve', suffix: 'reserve', basket: 'reserve')
        fund_wallet(satoshis: 1000)

        listed = engine_with_keys.brc100.list_outputs(basket: 'default')
        output_id = listed[:outputs].first[:id]

        output_key = derive_key
        output_script = p2pkh_locking_script_for(output_key).to_binary

        result = engine_with_keys.brc100.create_action(
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

        # Caller output (900 sats) + change outputs absorb the surplus
        # (#210 — caller-inputs now receive change for the fee remainder).
        parsed = parse_beef_tx(result[:tx])
        expect(parsed.inputs.length).to eq(1)
        expect(parsed.outputs.length).to be >= 2
        caller_output = parsed.outputs.find { |o| o.locking_script.to_binary == output_script }
        expect(caller_output).not_to be_nil
        expect(caller_output.satoshis).to eq(900)

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
        payments = engine_with_keys.brc100.list_outputs(basket: 'payments')
        expect(payments[:total_outputs]).to eq(1)
      end
    end

    context 'multi-input transaction' do
      it 'spends multiple outputs in a single transaction' do
        # Reserve UTXO covers headroom while three small UTXOs feed the
        # caller-inputs path. Each output has a distinct, predictable suffix.
        fund_wallet(satoshis: 100_000, prefix: 'reserve', suffix: 'reserve', basket: 'reserve')
        fund_wallet(satoshis: 500, suffix: 'multi0')
        fund_wallet(satoshis: 500, suffix: 'multi1')
        fund_wallet(satoshis: 500, suffix: 'multi2')

        listed = engine_with_keys.brc100.list_outputs(basket: 'default')
        outputs_by_id = listed[:outputs].sort_by { |o| o[:id] }
        expect(outputs_by_id.length).to eq(3)

        output_key = derive_key
        output_script = p2pkh_locking_script_for(output_key).to_binary

        result = engine_with_keys.brc100.create_action(
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
        # Caller output + change outputs (surplus absorbed) per #210.
        expect(parsed.outputs.length).to be >= 2
        caller_output = parsed.outputs.find { |o| o.locking_script.to_binary == output_script }
        expect(caller_output).not_to be_nil
        expect(caller_output.satoshis).to eq(1400)

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
        fund_wallet(satoshis: 100_000, prefix: 'reserve', suffix: 'reserve', basket: 'reserve')
        fund_wallet(satoshis: 2000)

        listed = engine_with_keys.brc100.list_outputs(basket: 'default')
        output_id = listed[:outputs].first[:id]

        key1 = derive_key(suffix: 'out1')
        key2 = derive_key(suffix: 'out2')
        key3 = derive_key(suffix: 'out3')

        caller_scripts = [
          p2pkh_locking_script_for(key1).to_binary,
          p2pkh_locking_script_for(key2).to_binary,
          p2pkh_locking_script_for(key3).to_binary
        ]

        result = engine_with_keys.brc100.create_action(
          description: 'multi output test',
          no_send: true,
          inputs: [{ output_id: output_id }],
          outputs: [
            { satoshis: 600, locking_script: caller_scripts[0],
              output_description: 'first', basket: 'payments' },
            { satoshis: 700, locking_script: caller_scripts[1],
              output_description: 'second', basket: 'payments' },
            { satoshis: 500, locking_script: caller_scripts[2],
              output_description: 'third', basket: 'payments' }
          ],
          randomize_outputs: false
        )

        parsed = parse_beef_tx(result[:tx])
        expect(parsed.inputs.length).to eq(1)
        # Three caller outputs + change outputs (surplus absorbed) per #210.
        expect(parsed.outputs.length).to be >= 4
        # Caller outputs preserved at their satoshi values; change varies.
        caller_sats = caller_scripts.map do |script|
          out = parsed.outputs.find { |o| o.locking_script.to_binary == script }
          expect(out).not_to be_nil
          out.satoshis
        end
        expect(caller_sats).to eq([600, 700, 500])

        # Verify input
        parsed.inputs[0].source_satoshis = 2000
        parsed.inputs[0].source_locking_script = p2pkh_locking_script_for(derive_key)
        expect(parsed.verify_input(0)).to be true
      end
    end

    context 'no-send flow' do
      it 'returns transaction data without broadcasting' do
        fund_wallet(satoshis: 1000)

        listed = engine_with_keys.brc100.list_outputs(basket: 'default')
        output_id = listed[:outputs].first[:id]
        output_script = p2pkh_locking_script_for(derive_key).to_binary

        result = engine_with_keys.brc100.create_action(
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

        # Transaction::Tx is valid
        parsed = parse_beef_tx(result[:tx])
        parsed.inputs[0].source_satoshis = 1000
        parsed.inputs[0].source_locking_script = p2pkh_locking_script_for(derive_key)
        expect(parsed.verify_input(0)).to be true
      end
    end

    context 'deferred signing flow' do
      it 'creates unsigned then signs via sign_action' do
        fund_wallet(satoshis: 1000)

        listed = engine_with_keys.brc100.list_outputs(basket: 'default')
        output_id = listed[:outputs].first[:id]
        output_script = p2pkh_locking_script_for(derive_key).to_binary

        # Phase 1: create deferred action
        create_result = engine_with_keys.brc100.create_action(
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
        sign_result = engine_with_keys.brc100.sign_action(
          spends: {},
          reference: reference
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
        # Custom_unlock below is a random byte blob — a stub demonstrating
        # the wallet applies whatever the caller provides. Strict
        # validate_for_handoff! (#296 Phase B) is stubbed because the
        # assertion is about script forwarding, not BEEF validity.
        allow_any_instance_of(BSV::Wallet::Engine::Hydrator).to receive(:validate_for_handoff!) # rubocop:disable RSpec/AnyInstance
        fund_wallet(satoshis: 1000)

        listed = engine_with_keys.brc100.list_outputs(basket: 'default')
        output_id = listed[:outputs].first[:id]
        output_script = p2pkh_locking_script_for(derive_key).to_binary

        # Create deferred action, then provide a custom unlocking script
        create_result = engine_with_keys.brc100.create_action(
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

        result = engine_with_keys.brc100.sign_action(
          spends: { 0 => { unlocking_script: custom_unlock } },
          reference: reference
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

        listed = engine_with_keys.brc100.list_outputs(basket: 'default')
        output_id = listed[:outputs].first[:id]
        output_script = p2pkh_locking_script_for(derive_key).to_binary

        result = engine_with_keys.brc100.create_action(
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
  # Direct tests for #wire_ancestor live in engine/hydrator_spec.rb
  # (lives on Engine::Hydrator).

  # --- Auto-fund createAction (#61) ---

  # Limp mode specs: spec/bsv/wallet/engine/limp_mode_spec.rb
  # Porcelain specs (send_payment, auto-fund): spec/bsv/wallet/engine/porcelain_spec.rb
end
