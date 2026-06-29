# frozen_string_literal: true

require_relative 'shared_context'

# Store#sweepable_state — the guard that answers "would dropping this DB
# destroy on-chain-anchored state?" Consulted by destructive operations
# (spec-setup recreation, future bsv-wallet destroy CLI, programmatic
# resets) before they proceed. HLR #448.
#
# clean? is true ⇔ zero spendable derived outputs whose action has been
# signed (actions.wtxid IS NOT NULL = signed AND broadcast happened).
# Root outputs and unsigned/aborted actions don't count — the former are
# recoverable from the identity key alone, the latter never reached chain.
#
# Matrix-aware: both Postgres and SQLite under the same store-shared
# context (per feedback_postgres_is_primary). Behavioural assertions on
# the returned SweepableState — no schema-text comparison.

RSpec.describe 'Store#sweepable_state (#448)', :store do
  # Sign an existing action with a random wtxid + valid raw_tx. Mirrors what
  # production sign_action does — the at-risk predicate fires only when
  # wtxid IS NOT NULL, so we need a real signing transition in fixture setup.
  def sign!(action_id)
    store.sign_action(
      action_id: action_id,
      wtxid: SecureRandom.random_bytes(32),
      raw_tx: SecureRandom.random_bytes(64)
    )
  end

  # Build a derived (BRC-42-shaped) output spec for promote_action. Derived
  # outputs carry the prefix/suffix/sender triple and a non-root locking
  # script with spendable_intent='spendable'.
  def derived_output(vout:, sats: 1000)
    { satoshis: sats, vout: vout,
      locking_script: SecureRandom.random_bytes(25),
      derivation_prefix: SecureRandom.uuid, derivation_suffix: vout.to_s,
      sender_identity_key: 'self',
      spendable_intent: 'spendable' }
  end

  # Root output — locking script matches the per-wallet root P2PKH literal,
  # no derivation fields. These are recoverable from the identity key alone
  # and the guard ignores them.
  def root_output(vout:, sats: 1000)
    { satoshis: sats, vout: vout,
      locking_script: TEST_ROOT_LOCKING_SCRIPT,
      spendable_intent: 'spendable' }
  end

  describe 'empty wallet' do
    it 'is clean — at_risk_outputs and at_risk_actions both zero' do
      state = store.sweepable_state

      expect(state.clean?).to be(true)
      expect(state.at_risk_outputs).to eq(0)
      expect(state.at_risk_actions).to eq(0)
    end

    it 'detail names zero counts and a nil guidance' do
      expect(store.sweepable_state.detail).to eq(
        at_risk_outputs: 0, at_risk_actions: 0, guidance: nil
      )
    end
  end

  describe 'at-risk: signed action with derived spendable outputs' do
    let(:action) do
      action = store.create_action(action: { description: 'at-risk one', broadcast_intent: :none })
      sign!(action[:id])
      store.promote_action(action_id: action[:id], outputs: [derived_output(vout: 0)])
      action
    end

    before { action }

    it 'is NOT clean' do
      expect(store.sweepable_state.clean?).to be(false)
    end

    it 'counts one at-risk output and one at-risk action' do
      state = store.sweepable_state

      expect(state.at_risk_outputs).to eq(1)
      expect(state.at_risk_actions).to eq(1)
    end

    it 'detail names the count and points the caller at sweep_to_root' do
      detail = store.sweepable_state.detail

      expect(detail[:at_risk_outputs]).to eq(1)
      expect(detail[:at_risk_actions]).to eq(1)
      expect(detail[:guidance]).to include('sweep_to_root')
    end
  end

  describe 'multiple at-risk outputs across distinct actions' do
    before do
      [0, 1].each do |i|
        action = store.create_action(action: { description: "act #{i}", broadcast_intent: :none })
        sign!(action[:id])
        store.promote_action(
          action_id: action[:id],
          outputs: [derived_output(vout: 0), derived_output(vout: 1)]
        )
      end
    end

    it 'counts 4 at-risk outputs across 2 at-risk actions (distinct count on actions)' do
      state = store.sweepable_state

      expect(state.at_risk_outputs).to eq(4)
      expect(state.at_risk_actions).to eq(2)
    end
  end

  describe 'NOT at-risk: signed action with only root outputs' do
    before do
      action = store.create_action(action: { description: 'root only', broadcast_intent: :none })
      sign!(action[:id])
      store.promote_action(action_id: action[:id], outputs: [root_output(vout: 0)])
    end

    it 'is clean — root outputs are recoverable from the identity key' do
      state = store.sweepable_state

      expect(state.clean?).to be(true)
      expect(state.at_risk_outputs).to eq(0)
    end
  end

  describe 'NOT at-risk: unsigned action with derived spendable outputs' do
    before do
      # promote_action requires a created action but does not require it to
      # be signed first — an internal-path action can be promoted at any
      # point. The unsigned action has no wtxid, so the guard ignores it.
      action = store.create_action(action: { description: 'unsigned promotion', broadcast_intent: :none })
      store.promote_action(action_id: action[:id], outputs: [derived_output(vout: 0)])
    end

    it 'is clean — no wtxid means no broadcast and nothing to orphan on chain' do
      expect(store.sweepable_state.clean?).to be(true)
    end
  end

  describe 'mixed wallet: one at-risk action plus one clean action plus root outputs' do
    before do
      a = store.create_action(action: { description: 'at-risk mix', broadcast_intent: :none })
      sign!(a[:id])
      store.promote_action(action_id: a[:id], outputs: [derived_output(vout: 0)])

      b = store.create_action(action: { description: 'unsigned mix', broadcast_intent: :none })
      store.promote_action(action_id: b[:id], outputs: [derived_output(vout: 0)])

      c = store.create_action(action: { description: 'root mix', broadcast_intent: :none })
      sign!(c[:id])
      store.promote_action(action_id: c[:id], outputs: [root_output(vout: 0)])
    end

    it 'counts only the signed-action derived outputs' do
      state = store.sweepable_state

      expect(state.at_risk_outputs).to eq(1)
      expect(state.at_risk_actions).to eq(1)
      expect(state.clean?).to be(false)
    end
  end
end
