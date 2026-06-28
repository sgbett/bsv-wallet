# frozen_string_literal: true

module BSV
  module Wallet
    class Store
      # Snapshot of "would dropping this wallet's database destroy state that
      # the wallet has anchored on chain?" — answered structurally from
      # `spendable` × `outputs` × `actions` join.
      #
      # Returned by {Store#sweepable_state}. Consulted by destructive
      # operations (spec-setup DB recreation, a future `bsv-wallet destroy`
      # CLI, programmatic resets) before they proceed.
      #
      # `clean?` is true ⇔ zero spendable outputs at BRC-42 derived keys
      # whose action has been signed and broadcast. Under that condition
      # the wallet has no on-chain commitment a destroy would orphan:
      #
      # * Root outputs (no derivation triple — `derivation_prefix IS NULL`)
      #   don't count — root P2PKH funds are recoverable from the identity
      #   key alone.
      # * Unsigned / aborted actions don't count — no broadcast happened,
      #   so no on-chain anchor was created.
      #
      # The non-clean payload is a guided refusal: it names the count of
      # at-risk outputs and the actions they sit under, and points the
      # caller at +sweep_to_root+. The guard isn't a veto; it makes the
      # right next step obvious.
      SweepableState = Data.define(:at_risk_outputs, :at_risk_actions) do
        # @return [Boolean] true ⇔ no on-chain commitment a destroy would
        #   orphan; safe to drop the database.
        def clean?
          at_risk_outputs.zero?
        end

        # @return [Hash] structured breakdown for CLI / log reporting.
        #   Always includes :at_risk_outputs and :at_risk_actions; +guidance+
        #   is nil when clean and a suggested next step otherwise.
        def detail
          {
            at_risk_outputs: at_risk_outputs,
            at_risk_actions: at_risk_actions,
            guidance: clean? ? nil : guidance
          }
        end

        private

        # +signed actions+ rather than +broadcast actions+: an internal-path
        # action (+broadcast_intent = 'none'+) that has been signed and
        # internalised is also on chain, even though it didn't go through
        # the broadcast pipeline. The guard counts both; the wording matches.
        def guidance
          "#{at_risk_outputs} derived spendable outputs across " \
            "#{at_risk_actions} signed actions still anchored on chain — " \
            'run sweep_to_root then re-check before destroying'
        end
      end
    end
  end
end
