# frozen_string_literal: true

# Make outputs truly immutable by upgrading the outputs.action_id FK from
# ON DELETE SET NULL to ON DELETE RESTRICT and enforcing NOT NULL.
#
# Migration 002 relaxed this FK to SET NULL when the deferred-sign path
# promoted outputs at sign time -- aborting such an action then needed
# to sever the FK to delete the row. Under #194 the send path no longer
# promotes outputs at sign time (promoted: false until broadcast accept),
# and Store#fail_broadcast_action explicitly deletes promoted: false output
# rows before the action. No reachable code path mutates outputs.action_id.
#
# Pre-flight removes any legacy orphaned rows (action_id IS NULL) created
# under the prior SET NULL semantics. Orphaned outputs are by definition
# unreachable -- no FK chain leads back to a wallet operation -- so the
# delete is safe.

Sequel.migration do
  up do
    postgres = database_type == :postgres

    orphan_count = from(:outputs).where(action_id: nil).count
    if orphan_count.positive?
      BSV.logger&.warn { "[migration 006] deleting #{orphan_count} orphan output row(s) with action_id IS NULL" }
      # Output dependents (output_baskets, output_details, output_tags,
      # spendable) reference outputs.id but were never re-pointed when the
      # SET NULL semantics severed outputs.action_id, so legacy orphans may
      # still carry tags / details / baskets / spendable rows that block
      # the FK-RESTRICT delete below. Clear those first so the migration
      # can run on wallets that previously held tagged orphan outputs.
      orphan_ids = from(:outputs).where(action_id: nil).select(:id)
      from(:inputs).where(output_id: orphan_ids).delete
      from(:output_tags).where(output_id: orphan_ids).delete
      from(:output_baskets).where(output_id: orphan_ids).delete
      from(:output_details).where(output_id: orphan_ids).delete
      from(:spendable).where(output_id: orphan_ids).delete
      from(:outputs).where(action_id: nil).delete
    end

    if postgres
      run <<~SQL
        ALTER TABLE outputs
          DROP CONSTRAINT IF EXISTS outputs_action_id_fkey,
          ALTER COLUMN action_id SET NOT NULL,
          ADD CONSTRAINT outputs_action_id_fkey
            FOREIGN KEY (action_id) REFERENCES actions (id) ON DELETE RESTRICT
      SQL
    else
      alter_table(:outputs) do
        set_column_not_null :action_id
        drop_foreign_key [:action_id]
        add_foreign_key [:action_id], :actions, on_delete: :restrict
      end
    end
  end

  down do
    postgres = database_type == :postgres

    if postgres
      run <<~SQL
        ALTER TABLE outputs
          DROP CONSTRAINT IF EXISTS outputs_action_id_fkey,
          ALTER COLUMN action_id DROP NOT NULL,
          ADD CONSTRAINT outputs_action_id_fkey
            FOREIGN KEY (action_id) REFERENCES actions (id) ON DELETE SET NULL
      SQL
    else
      alter_table(:outputs) do
        set_column_allow_null :action_id
        drop_foreign_key [:action_id]
        add_foreign_key [:action_id], :actions, on_delete: :set_null
      end
    end
  end
end
