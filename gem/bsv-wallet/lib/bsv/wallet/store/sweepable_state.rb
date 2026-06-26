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
      # * Root outputs (output_type = 'root') don't count — root P2PKH
      #   funds are recoverable from the identity key alone.
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
        #   Always includes :at_risk_outputs and :at_risk_actions; when
        #   :guidance is present it carries the suggested next step.
        def detail
          return { at_risk_outputs: 0, at_risk_actions: 0, guidance: nil } if clean?

          {
            at_risk_outputs: at_risk_outputs,
            at_risk_actions: at_risk_actions,
            guidance: "#{at_risk_outputs} derived spendable outputs across " \
                      "#{at_risk_actions} broadcast actions still anchored on chain — " \
                      'run sweep_to_root then re-check before destroying'
          }
        end
      end
    end
  end
end
