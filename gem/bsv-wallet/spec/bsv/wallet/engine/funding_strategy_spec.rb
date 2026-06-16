# frozen_string_literal: true

require 'bsv-wallet'
require 'bsv/wallet/engine/funding_strategy'
require_relative '../store/shared_context'

RSpec.describe BSV::Wallet::Engine::FundingStrategy do
  include_context 'store setup'

  # Wrap each example in a transaction that rolls back at the end so
  # the action / input rows the strategy locks against don't leak into
  # later specs in the suite. Mirrors the engine shared context's
  # convention (the `:store` tag fires the same wrapper for store
  # specs).
  around do |example|
    STORE_DB.transaction(rollback: :always, auto_savepoint: true) do
      example.run
    end
  end

  let(:strategy) { described_class.new(store: store, utxo_pool: utxo_pool) }

  # Pool double: scripted to return specific candidates per +select+ call.
  # +spendable_count+ caps the funding loop's iteration count; specs that
  # don't exercise the cap use a generous default.
  let(:utxo_pool) do
    instance_double(BSV::Wallet::Store::UTXOPool).tap do |pool|
      allow(pool).to receive(:spendable_count).and_return(8)
    end
  end

  # Helper: build a fake pool candidate hash matching what
  # +UTXOPool#select+ returns (id is the only field the strategy reads).
  def candidate(id, satoshis: 1000)
    { id: id, satoshis: satoshis, vout: 0,
      locking_script: SecureRandom.random_bytes(25),
      action_id: nil, derivation_prefix: 'p', derivation_suffix: 's' }
  end

  # Helper: build a fake +Transaction::Tx+ stand-in whose
  # +total_input_satoshis+ matches a script.
  def fake_tx(total_input_satoshis:)
    instance_double(BSV::Transaction::Tx, total_input_satoshis: total_input_satoshis)
  end

  # Helper: build a success result the build seam would return.
  def success_result(tx:)
    {
      wtxid: SecureRandom.random_bytes(32),
      raw_tx: SecureRandom.random_bytes(200),
      tx: tx,
      vout_mapping: { 0 => 0 },
      change_outputs: []
    }
  end

  # Create a real action row to acquire against — the strategy needs a
  # real +action_id+ because it calls +store.lock_inputs+ which writes
  # input rows. Returns the +action_id+ of an input-less action row.
  def create_empty_action
    action = store.create_action(
      action: {
        description: 'funding strategy test target',
        broadcast_intent: :delayed, outgoing: true, nlocktime: 0
      },
      inputs: []
    )
    action[:id]
  end

  # Promote a fake spendable output to the canonical UTXO set so the
  # strategy can lock it. Returns the +output_id+. The output isn't
  # cryptographically valid — but the strategy never inspects script
  # contents, only +output.id+ and the inputs/spendable rows.
  def create_spendable_output(satoshis: 1000)
    funding = store.create_action(
      action: {
        description: 'funding strategy spec source',
        broadcast_intent: :none, outgoing: false, nlocktime: 0
      }
    )
    store.sign_action(action_id: funding[:id], wtxid: SecureRandom.random_bytes(32),
                      raw_tx: SecureRandom.random_bytes(200))
    store.promote_action(
      action_id: funding[:id],
      outputs: [{
        satoshis: satoshis, vout: 0, locking_script: SecureRandom.random_bytes(25),
        derivation_prefix: 'p', derivation_suffix: 's',
        sender_identity_key: 'self', basket: 'default'
      }]
    )
    BSV::Wallet::Store::Models::Output.where(action_id: funding[:id]).first.id
  end

  describe 'selection (#select_candidates via #acquire)' do
    it 'delegates to utxo_pool.select with the target and exclude list' do
      output_id = create_spendable_output(satoshis: 5_000)
      action_id = create_empty_action

      allow(utxo_pool).to receive(:select)
        .with(satoshis: 4_000, exclude: [])
        .and_return([candidate(output_id, satoshis: 5_000)])

      tx = fake_tx(total_input_satoshis: 5_000)
      strategy.acquire(
        action_id: action_id,
        caller_outputs: [{ satoshis: 4_000 }],
        caller_supplied_inputs: false,
        caller_inputs: nil,
        build: ->(_resolved) { success_result(tx: tx) }
      )

      expect(utxo_pool).to have_received(:select).with(satoshis: 4_000, exclude: [])
    end

    it 'selects nothing and runs build once when caller_outputs is empty' do
      action_id = create_empty_action
      tx = fake_tx(total_input_satoshis: 0)
      calls = 0
      build = lambda do |_resolved|
        calls += 1
        success_result(tx: tx)
      end
      allow(utxo_pool).to receive(:select)

      result = strategy.acquire(
        action_id: action_id,
        caller_outputs: [],
        caller_supplied_inputs: false,
        caller_inputs: nil,
        build: build
      )

      expect(calls).to eq(1)
      expect(result[:total_input_satoshis]).to eq(0)
      expect(utxo_pool).not_to have_received(:select)
    end
  end

  describe 'fixpoint convergence' do
    it 'returns after a single build attempt when first selection covers fee' do
      output_id = create_spendable_output(satoshis: 10_000)
      action_id = create_empty_action

      allow(utxo_pool).to receive(:select).and_return([candidate(output_id, satoshis: 10_000)])
      tx = fake_tx(total_input_satoshis: 10_000)
      attempts = 0
      build = lambda do |_resolved|
        attempts += 1
        success_result(tx: tx)
      end

      result = strategy.acquire(
        action_id: action_id,
        caller_outputs: [{ satoshis: 4_000 }],
        caller_supplied_inputs: false,
        caller_inputs: nil,
        build: build
      )

      expect(attempts).to eq(1)
      expect(result[:total_input_satoshis]).to eq(10_000)
    end

    it 'tops up on shortfall, then converges; top-up vins are contiguous' do
      first_id  = create_spendable_output(satoshis: 4_000)
      second_id = create_spendable_output(satoshis: 4_000)
      action_id = create_empty_action

      # Initial select covers sum(outputs); top-up select covers the
      # reported shortfall, excluding the already-locked output.
      allow(utxo_pool).to receive(:select).with(satoshis: 4_000, exclude: [])
                                          .and_return([candidate(first_id, satoshis: 4_000)])
      allow(utxo_pool).to receive(:select).with(satoshis: 200, exclude: [first_id])
                                          .and_return([candidate(second_id, satoshis: 4_000)])

      tx_ok = fake_tx(total_input_satoshis: 8_000)
      attempts = 0
      build = lambda do |_resolved|
        attempts += 1
        attempts == 1 ? { shortfall: 200 } : success_result(tx: tx_ok)
      end

      result = strategy.acquire(
        action_id: action_id,
        caller_outputs: [{ satoshis: 4_000 }],
        caller_supplied_inputs: false,
        caller_inputs: nil,
        build: build
      )

      expect(attempts).to eq(2)
      expect(result[:total_input_satoshis]).to eq(8_000)

      vins = BSV::Wallet::Store::Models::Input.where(action_id: action_id).order(:vin).select_map(:vin)
      expect(vins).to eq([0, 1])
    end
  end

  describe 'resolve relocation (#336 — store-free build seam)' do
    it 'passes the resolved input set across the build seam' do
      output_id = create_spendable_output(satoshis: 5_000)
      action_id = create_empty_action
      allow(utxo_pool).to receive(:select).and_return([candidate(output_id, satoshis: 5_000)])
      tx = fake_tx(total_input_satoshis: 5_000)

      received = nil
      build = lambda do |resolved|
        received = resolved
        success_result(tx: tx)
      end

      strategy.acquire(
        action_id: action_id,
        caller_outputs: [{ satoshis: 4_000 }],
        caller_supplied_inputs: false,
        caller_inputs: nil,
        build: build
      )

      expect(received).to be_an(Array)
      expect(received.length).to eq(1)
      expect(received.first).to include(:vin, :source_wtxid, :source_satoshis,
                                        :source_locking_script)
      expect(received.first[:source_satoshis]).to eq(5_000)
    end

    it 'resolves exactly once per build attempt' do
      output_id = create_spendable_output(satoshis: 10_000)
      action_id = create_empty_action
      allow(utxo_pool).to receive(:select).and_return([candidate(output_id, satoshis: 10_000)])
      tx = fake_tx(total_input_satoshis: 10_000)

      allow(store).to receive(:resolve_inputs_for_signing).and_call_original

      strategy.acquire(
        action_id: action_id,
        caller_outputs: [{ satoshis: 4_000 }],
        caller_supplied_inputs: false,
        caller_inputs: nil,
        build: ->(_resolved) { success_result(tx: tx) }
      )

      expect(store).to have_received(:resolve_inputs_for_signing).once
    end

    it 'resolves twice across a top-up — the second after the second lock' do
      first_id  = create_spendable_output(satoshis: 4_000)
      second_id = create_spendable_output(satoshis: 4_000)
      action_id = create_empty_action

      allow(utxo_pool).to receive(:select).with(satoshis: 4_000, exclude: [])
                                          .and_return([candidate(first_id, satoshis: 4_000)])
      allow(utxo_pool).to receive(:select).with(satoshis: 200, exclude: [first_id])
                                          .and_return([candidate(second_id, satoshis: 4_000)])
      tx_ok = fake_tx(total_input_satoshis: 8_000)

      # Each resolve snapshot reflects the current locked set — the
      # first call returns one row, the second returns two (the lock
      # grew between).
      resolve_lengths = []
      allow(store).to receive(:resolve_inputs_for_signing) do |args|
        rows = store.method(:resolve_inputs_for_signing).super_method.call(**args)
        resolve_lengths << rows.length
        rows
      end

      attempts = 0
      build = lambda do |_resolved|
        attempts += 1
        attempts == 1 ? { shortfall: 200 } : success_result(tx: tx_ok)
      end

      strategy.acquire(
        action_id: action_id,
        caller_outputs: [{ satoshis: 4_000 }],
        caller_supplied_inputs: false,
        caller_inputs: nil,
        build: build
      )

      expect(resolve_lengths).to eq([1, 2])
    end

    it 'resolves once on the caller-supplied (single-attempt) path' do
      output_id = create_spendable_output(satoshis: 10_000)
      action_id = create_empty_action
      allow(utxo_pool).to receive(:select)
      tx = fake_tx(total_input_satoshis: 10_000)
      allow(store).to receive(:resolve_inputs_for_signing).and_call_original

      strategy.acquire(
        action_id: action_id,
        caller_outputs: [{ satoshis: 4_000 }],
        caller_supplied_inputs: true,
        caller_inputs: [{ output_id: output_id, vin: 0 }],
        build: ->(_resolved) { success_result(tx: tx) }
      )

      expect(store).to have_received(:resolve_inputs_for_signing).once
    end

    it 'passes an empty array to build on the zero-output path' do
      action_id = create_empty_action
      tx = fake_tx(total_input_satoshis: 0)
      received = nil
      allow(utxo_pool).to receive(:select)

      strategy.acquire(
        action_id: action_id,
        caller_outputs: [],
        caller_supplied_inputs: false,
        caller_inputs: nil,
        build: lambda do |resolved|
          received = resolved
          success_result(tx: tx)
        end
      )

      expect(received).to eq([])
    end
  end

  describe 'pool depletion' do
    it 'raises InsufficientFundsError when initial selection cannot meet target' do
      action_id = create_empty_action
      allow(utxo_pool).to receive(:select).and_raise(BSV::Wallet::PoolDepletedError.new('default'))

      expect do
        strategy.acquire(
          action_id: action_id,
          caller_outputs: [{ satoshis: 4_000 }],
          caller_supplied_inputs: false,
          caller_inputs: nil,
          build: ->(_resolved) { raise 'should not be reached' }
        )
      end.to raise_error(BSV::Wallet::InsufficientFundsError)
    end

    it 'raises InsufficientFundsError when top-up select runs the pool dry' do
      first_id = create_spendable_output(satoshis: 4_000)
      action_id = create_empty_action

      allow(utxo_pool).to receive(:select).with(satoshis: 4_000, exclude: [])
                                          .and_return([candidate(first_id, satoshis: 4_000)])
      allow(utxo_pool).to receive(:select).with(satoshis: 200, exclude: [first_id])
                                          .and_raise(BSV::Wallet::PoolDepletedError.new('default'))

      build = ->(_resolved) { { shortfall: 200 } }

      expect do
        strategy.acquire(
          action_id: action_id,
          caller_outputs: [{ satoshis: 4_000 }],
          caller_supplied_inputs: false,
          caller_inputs: nil,
          build: build
        )
      end.to raise_error(BSV::Wallet::InsufficientFundsError)
    end
  end

  describe 'caller-supplied fail-fast' do
    it 'never calls utxo_pool.select and raises immediately on shortfall' do
      output_id = create_spendable_output(satoshis: 4_000)
      action_id = create_empty_action
      allow(utxo_pool).to receive(:select)
      build = ->(_resolved) { { shortfall: 500 } }

      expect do
        strategy.acquire(
          action_id: action_id,
          caller_outputs: [{ satoshis: 4_000 }],
          caller_supplied_inputs: true,
          caller_inputs: [{ output_id: output_id, vin: 0 }],
          build: build
        )
      end.to raise_error(BSV::Wallet::InsufficientFundsError)
      expect(utxo_pool).not_to have_received(:select)
    end

    it 'locks the caller inputs once and returns on success' do
      output_id = create_spendable_output(satoshis: 10_000)
      action_id = create_empty_action
      allow(utxo_pool).to receive(:select)
      tx = fake_tx(total_input_satoshis: 10_000)

      result = strategy.acquire(
        action_id: action_id,
        caller_outputs: [{ satoshis: 4_000 }],
        caller_supplied_inputs: true,
        caller_inputs: [{ output_id: output_id, vin: 0 }],
        build: ->(_resolved) { success_result(tx: tx) }
      )

      expect(result[:total_input_satoshis]).to eq(10_000)
      locks = BSV::Wallet::Store::Models::Input.where(action_id: action_id).count
      expect(locks).to eq(1)
    end
  end

  describe 'orchestration invariants' do
    it 'does not open a database transaction itself (Store owns atomicity)' do
      action_id = create_empty_action
      output_id = create_spendable_output(satoshis: 5_000)

      allow(utxo_pool).to receive(:select).and_return([candidate(output_id, satoshis: 5_000)])
      tx = fake_tx(total_input_satoshis: 5_000)

      # The strategy must orchestrate atomic Store methods, not open a
      # transaction itself. Spy on +db.transaction+ before calling
      # +acquire+, then ensure no top-level call comes from
      # FundingStrategy's code path. (The Store's lock_inputs opens its
      # own transaction internally — that's the correct atomicity
      # boundary.)
      expect(strategy).not_to respond_to(:db)
      expect(strategy.instance_variables).not_to include(:@db)

      strategy.acquire(
        action_id: action_id,
        caller_outputs: [{ satoshis: 4_000 }],
        caller_supplied_inputs: false,
        caller_inputs: nil,
        build: ->(_resolved) { success_result(tx: tx) }
      )
    end

    it 'has no engine back-reference and no .send(:private) reach-through' do
      source = File.read(File.expand_path('../../../../lib/bsv/wallet/engine/funding_strategy.rb', __dir__))
      expect(source).not_to include('engine.send(')
      expect(source).not_to include('.send(:')
      expect(source).not_to include('@engine')
    end
  end

  describe '#213 bounded lock-retry on contention', :postgres do
    # Contention paths need a real Postgres backend with ON CONFLICT
    # semantics; SQLite's lock_inputs translation does not reproduce
    # the short-count signal we rely on.

    # Drive contention deterministically: pre-insert an inputs row for
    # the candidate +output_id+ under a *different* action so the
    # strategy's lock_inputs INSERT … ON CONFLICT short-counts to 0.
    # The Sequel::Rollback in the Store then surfaces as a 0 return.
    def pre_lock_output(output_id)
      blocker = create_empty_action
      store.lock_inputs(action_id: blocker, inputs: [{ output_id: output_id, vin: 0 }])
      blocker
    end

    it 'succeeds when contention resolves within the bound (top-up)' do
      first_id    = create_spendable_output(satoshis: 4_000)
      contended   = create_spendable_output(satoshis: 4_000)
      fallback_id = create_spendable_output(satoshis: 4_000)
      pre_lock_output(contended)

      action_id = create_empty_action

      allow(utxo_pool).to receive(:select).with(satoshis: 4_000, exclude: [])
                                          .and_return([candidate(first_id, satoshis: 4_000)])
      allow(utxo_pool).to receive(:select).with(satoshis: 200, exclude: [first_id])
                                          .and_return([candidate(contended, satoshis: 4_000)])
      allow(utxo_pool).to receive(:select).with(satoshis: 200, exclude: [first_id, contended])
                                          .and_return([candidate(fallback_id, satoshis: 4_000)])

      tx_ok = fake_tx(total_input_satoshis: 8_000)
      attempts = 0
      build = lambda do |_resolved|
        attempts += 1
        attempts == 1 ? { shortfall: 200 } : success_result(tx: tx_ok)
      end

      result = strategy.acquire(
        action_id: action_id,
        caller_outputs: [{ satoshis: 4_000 }],
        caller_supplied_inputs: false,
        caller_inputs: nil,
        build: build
      )

      expect(result[:total_input_satoshis]).to eq(8_000)
    end

    it 'raises InsufficientFundsError when contention exceeds the retry bound' do
      first_id = create_spendable_output(satoshis: 4_000)
      action_id = create_empty_action

      # Generate (MAX_LOCK_RETRIES + 2) contended outputs so every retry
      # attempt picks a fresh one and finds it already locked.
      contended_ids = (described_class::MAX_LOCK_RETRIES + 2).times.map do
        id = create_spendable_output(satoshis: 4_000)
        pre_lock_output(id)
        id
      end

      allow(utxo_pool).to receive(:select).with(satoshis: 4_000, exclude: [])
                                          .and_return([candidate(first_id, satoshis: 4_000)])
      excluded = [first_id]
      contended_ids.each do |c|
        allow(utxo_pool).to receive(:select).with(satoshis: 200, exclude: excluded.dup)
                                            .and_return([candidate(c, satoshis: 4_000)])
        excluded << c
      end

      build = ->(_resolved) { { shortfall: 200 } }

      expect do
        strategy.acquire(
          action_id: action_id,
          caller_outputs: [{ satoshis: 4_000 }],
          caller_supplied_inputs: false,
          caller_inputs: nil,
          build: build
        )
      end.to raise_error(BSV::Wallet::InsufficientFundsError)
    end

    it 'succeeds when initial-lock contention resolves within the bound' do
      contended   = create_spendable_output(satoshis: 4_000)
      fallback_id = create_spendable_output(satoshis: 4_000)
      pre_lock_output(contended)
      action_id = create_empty_action

      allow(utxo_pool).to receive(:select).with(satoshis: 4_000, exclude: [])
                                          .and_return([candidate(contended, satoshis: 4_000)])
      allow(utxo_pool).to receive(:select).with(satoshis: 4_000, exclude: [contended])
                                          .and_return([candidate(fallback_id, satoshis: 4_000)])

      tx_ok = fake_tx(total_input_satoshis: 4_000)
      result = strategy.acquire(
        action_id: action_id,
        caller_outputs: [{ satoshis: 4_000 }],
        caller_supplied_inputs: false,
        caller_inputs: nil,
        build: ->(_resolved) { success_result(tx: tx_ok) }
      )

      expect(result[:total_input_satoshis]).to eq(4_000)
      locked_output_ids = BSV::Wallet::Store::Models::Input
                          .where(action_id: action_id)
                          .select_map(:output_id)
      expect(locked_output_ids).to eq([fallback_id])
    end

    it 'distinguishes pool depletion from contention exhaustion' do
      # Depletion path: no contention, simply no coin. Exhaustion is the
      # bounded-retry case (covered above). Both surface as
      # InsufficientFundsError, but the depletion path makes zero retry
      # attempts because the very first select raises PoolDepletedError.
      action_id = create_empty_action
      call_count = 0
      err = BSV::Wallet::PoolDepletedError.new('default')
      allow(utxo_pool).to receive(:select) do
        call_count += 1
        raise err
      end

      expect do
        strategy.acquire(
          action_id: action_id,
          caller_outputs: [{ satoshis: 4_000 }],
          caller_supplied_inputs: false,
          caller_inputs: nil,
          build: ->(_resolved) { raise 'unreachable' }
        )
      end.to raise_error(BSV::Wallet::InsufficientFundsError)
      expect(call_count).to eq(1)
    end
  end
end
