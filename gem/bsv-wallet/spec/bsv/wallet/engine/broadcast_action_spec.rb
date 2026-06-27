# frozen_string_literal: true

require_relative 'shared_context'

RSpec.describe BSV::Wallet::Engine, '#broadcast_action' do
  include_context 'engine setup'

  # Override the shared context's keyless +engine+ — +build_action+
  # / +fund_wallet+ both require a +KeyDeriver+. +let+ wins over the
  # shared context's +subject+.
  let(:engine) do
    described_class.new(
      store: store, utxo_pool: utxo_pool, broadcaster: broadcaster,
      key_deriver: key_deriver, network: :mainnet
    )
  end

  # A signed, parked action. +no_send: true+ goes through the
  # internal-completion path: the action's +raw_tx+ + +wtxid+ are
  # populated, broadcast_intent is +:none+, no broadcasts row exists,
  # outputs are promoted to spendable. This is the canonical
  # "ready to broadcast on demand" state.
  let(:signed_reference) do
    fund_wallet(satoshis: 100_000)
    result = engine.build_action(
      description: 'signed for broadcast',
      outputs: [
        { satoshis: 500, locking_script: OP_TRUE, output_description: 'output' }
      ],
      no_send: true
    )
    store.find_action(wtxid: result[:wtxid])[:reference]
  end

  describe 'happy path — :delayed' do
    it 'returns { wtxid:, atomic_beef: } matching the source action' do
      reference = signed_reference
      action_row = store.find_action(reference: reference)

      result = engine.broadcast_action(reference: reference, intent: :delayed)

      expect(result).to include(:wtxid, :atomic_beef)
      expect(result[:wtxid]).to eq(action_row[:wtxid])
      expect(result[:atomic_beef]).to be_a(String)
      expect(result[:atomic_beef].bytesize).to be > 0
    end

    it 'does not invoke the broadcast worker' do
      # +:delayed+ relies on the daemon picking up via OMQ hint;
      # the inline +@broadcast_worker.process+ path must NOT fire.
      # Spying through the engine's own +@broadcast_worker+ ivar
      # gives us a checkable target without +any_instance_of+.
      worker = engine.instance_variable_get(:@broadcast_worker)
      allow(worker).to receive(:process)
      engine.broadcast_action(reference: signed_reference, intent: :delayed)
      expect(worker).not_to have_received(:process)
    end
  end

  describe 'validation' do
    it 'raises InvalidParameterError when reference is unknown' do
      expect do
        engine.broadcast_action(
          reference: '00000000-0000-0000-0000-000000000000',
          intent: :inline
        )
      end.to raise_error(BSV::Wallet::InvalidParameterError, /reference \(not found\)/)
    end

    it 'raises UnsupportedActionError when raw_tx is absent (action never built)' do
      # Direct store manipulation: bare action row with raw_tx +
      # wtxid both NULL. The schema's +wtxid_raw_tx_parity+ constraint
      # forces them to move together, so this state is "row exists,
      # tx never built". The build_action / sign_action paths
      # always populate raw_tx, so this case is only reachable via
      # direct store row creation — but the validation is a structural
      # invariant the broadcaster relies on.
      bare = store.create_action(
        action: { description: 'bare row, no tx body', broadcast_intent: :none }
      )
      reference = store.find_action(id: bare[:id])[:reference]

      expect do
        engine.broadcast_action(reference: reference, intent: :inline)
      end.to raise_error(BSV::Wallet::UnsupportedActionError, /not in a broadcastable state/)
    end

    it 'raises InvalidParameterError for an unknown intent' do
      expect do
        engine.broadcast_action(reference: signed_reference, intent: :async)
      end.to raise_error(BSV::Wallet::InvalidParameterError, /intent: must be :inline or :delayed/)
    end

    it 'rejects intent: :none (use abort_action instead)' do
      expect do
        engine.broadcast_action(reference: signed_reference, intent: :none)
      end.to raise_error(BSV::Wallet::InvalidParameterError, /intent: must be :inline or :delayed/)
    end
  end

  describe 'API surface invariants' do
    let(:method) { engine.method(:broadcast_action) }
    let(:params) { method.parameters }

    it 'is public on Engine' do
      expect(described_class.public_method_defined?(:broadcast_action)).to be(true)
    end

    it 'takes reference: + intent: (with intent defaulting to :inline)' do
      kwargs = params.map { |kind, name| [kind, name] }
      expect(kwargs).to include(%i[keyreq reference])
      expect(kwargs).to include(%i[key intent])
    end

    it 'does not accept conformance vocabulary (originator:, seek_permission:)' do
      # Mirror of the read-side primitive invariant — the wallet-vocab
      # action surface keeps BRC-100 conformance fields out of the
      # engine layer (ADR-026 decision 7).
      names = params.map { |_, name| name }
      expect(names).not_to include(:originator, :seek_permission)

      forwards = params.any? { |kind, _| kind == :keyrest }
      expect(forwards).to be(false)
    end
  end
end
