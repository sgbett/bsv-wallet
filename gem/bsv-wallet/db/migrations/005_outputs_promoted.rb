# frozen_string_literal: true

# Add promoted flag to outputs — distinguishes the send-path lifecycle
# (outputs persisted at sign time but not in the canonical UTXO set
# until broadcast acceptance) from the internal-path lifecycle
# (synchronous Phase 4, promoted at create_action time).
#
# Single-shot false → true transition at Phase 4. Structurally analogous
# to actions.tx_proof_id NULL → set on proof arrival.
#
# Default true: backfills existing rows under the prior semantics where
# every output reaching the table was implicitly promoted.

Sequel.migration do
  change do
    add_column :outputs, :promoted, :boolean, null: false, default: true
  end
end
