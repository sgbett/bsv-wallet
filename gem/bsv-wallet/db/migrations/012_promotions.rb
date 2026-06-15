# frozen_string_literal: true

# Promotion as a row (#307). Replaces the mutable outputs.promoted flag with
# the *existence* of a per-action `promotions` row — restoring outputs to pure
# INSERT-only and giving promote-authorisation a declarative database backstop
# instead of a hot-path trigger. Realises ADR-022 (state as a FK row);
# supersedes ADR-011 (post-broadcast promotion).
#
# A promotions row means "this action's outputs are canonical". It is gated:
#   - intent tracks the parent action (composite FK to actions(id, broadcast_intent)),
#     exactly as broadcasts.intent does (ADR-019).
#   - authorising_status names the broadcast tx_status that authorised a
#     send-path promotion; NULL on the internal path.
#   - promo_path CHECK: internal => no status; send => a status.
#   - auth_not_rejected CHECK: a present status is in the optimistic set
#     (anything except REJECTED / DOUBLE_SPEND_ATTEMPTED).
#   - composite FK (action_id, authorising_status) -> broadcasts(action_id, tx_status)
#     ON UPDATE CASCADE: a send promotion can exist only while its broadcast is
#     in a non-rejected status (NULL status skips the FK, MATCH SIMPLE — the
#     internal path needs no broadcast). The cascade keeps authorising_status
#     synced as tx_status advances; a flip to REJECTED requires deleting the
#     promotions row first (reject_action does), else the cascade would hit
#     auth_not_rejected.
#
# spendable.action_id gains a second FK -> promotions(action_id) ON DELETE
# CASCADE: UTXO-set membership cannot exist without authorisation, and
# reject/reorg teardown is a single DELETE FROM promotions that cascades.

Sequel.migration do
  up do
    postgres = database_type == :postgres

    if postgres
      # The prevent_internal_action_delete trigger (008) reads outputs.promoted;
      # drop it before the column, recreate against promotions below.
      run 'DROP TRIGGER IF EXISTS check_internal_action_delete ON actions'

      run 'ALTER TABLE outputs DROP COLUMN promoted'

      # FK target for the status gate (action_id is already unique, so this is
      # trivially satisfiable, but the composite FK requires the index).
      run 'ALTER TABLE broadcasts ADD CONSTRAINT broadcasts_action_id_tx_status_key UNIQUE (action_id, tx_status)'

      run <<~SQL
        CREATE TABLE promotions (
          action_id          bigint PRIMARY KEY REFERENCES actions(id) ON DELETE CASCADE,
          intent             broadcast_intent NOT NULL,
          authorising_status tx_status,
          CONSTRAINT promo_path CHECK (
            (intent = 'none' AND authorising_status IS NULL)
            OR (intent <> 'none' AND authorising_status IS NOT NULL)
          ),
          CONSTRAINT auth_not_rejected CHECK (
            authorising_status IS NULL
            OR authorising_status NOT IN ('REJECTED', 'DOUBLE_SPEND_ATTEMPTED')
          ),
          CONSTRAINT promotions_action_intent_fkey
            FOREIGN KEY (action_id, intent) REFERENCES actions (id, broadcast_intent),
          CONSTRAINT promotions_broadcast_status_fkey
            FOREIGN KEY (action_id, authorising_status)
            REFERENCES broadcasts (action_id, tx_status) ON UPDATE CASCADE
        )
      SQL

      run <<~SQL
        ALTER TABLE spendable
          ADD CONSTRAINT spendable_promotion_fkey
          FOREIGN KEY (action_id) REFERENCES promotions (action_id) ON DELETE CASCADE
      SQL

      run <<~SQL
        CREATE OR REPLACE FUNCTION prevent_internal_action_delete() RETURNS trigger AS $$
        BEGIN
          IF OLD.broadcast_intent = 'none'
             AND EXISTS (SELECT 1 FROM promotions WHERE action_id = OLD.id) THEN
            RAISE EXCEPTION 'cannot delete internal action % (broadcast_intent=none with a promotions row)', OLD.id
              USING ERRCODE = 'check_violation';
          END IF;
          RETURN OLD;
        END;
        $$ LANGUAGE plpgsql;
      SQL
      run <<~SQL
        CREATE TRIGGER check_internal_action_delete
          BEFORE DELETE ON actions
          FOR EACH ROW
          EXECUTE FUNCTION prevent_internal_action_delete();
      SQL
    else
      # SQLite: enums are text; Sequel emulates ALTER via table recreation.
      run 'DROP TRIGGER IF EXISTS check_internal_action_delete'

      alter_table(:outputs) { drop_column :promoted }

      alter_table(:broadcasts) { add_unique_constraint %i[action_id tx_status] }

      create_table(:promotions) do
        column :action_id, :bigint, primary_key: true
        column :intent, :text, null: false
        column :authorising_status, :text
        foreign_key [:action_id], :actions, key: [:id], on_delete: :cascade
        foreign_key %i[action_id intent], :actions, key: %i[id broadcast_intent]
        foreign_key %i[action_id authorising_status], :broadcasts,
                    key: %i[action_id tx_status], on_update: :cascade
        constraint(:promo_path, Sequel.lit(
                                  "(intent = 'none' AND authorising_status IS NULL) " \
                                  "OR (intent <> 'none' AND authorising_status IS NOT NULL)"
                                ))
        constraint(:auth_not_rejected, Sequel.lit(
                                         'authorising_status IS NULL ' \
                                         "OR authorising_status NOT IN ('REJECTED', 'DOUBLE_SPEND_ATTEMPTED')"
                                       ))
      end

      alter_table(:spendable) do
        add_foreign_key [:action_id], :promotions, key: [:action_id], on_delete: :cascade
      end

      run <<~SQL
        CREATE TRIGGER check_internal_action_delete
          BEFORE DELETE ON actions
          FOR EACH ROW
          WHEN OLD.broadcast_intent = 'none'
        BEGIN
          SELECT RAISE(ABORT, 'cannot delete internal action (broadcast_intent=none with a promotions row)')
          WHERE EXISTS (SELECT 1 FROM promotions WHERE action_id = OLD.id);
        END;
      SQL
    end
  end

  down do
    postgres = database_type == :postgres

    if postgres
      run 'DROP TRIGGER IF EXISTS check_internal_action_delete ON actions'
      run 'ALTER TABLE spendable DROP CONSTRAINT IF EXISTS spendable_promotion_fkey'
      run 'DROP TABLE IF EXISTS promotions'
      run 'ALTER TABLE broadcasts DROP CONSTRAINT IF EXISTS broadcasts_action_id_tx_status_key'
      run 'ALTER TABLE outputs ADD COLUMN promoted boolean NOT NULL DEFAULT true'
      run <<~SQL
        CREATE OR REPLACE FUNCTION prevent_internal_action_delete() RETURNS trigger AS $$
        BEGIN
          IF OLD.broadcast_intent = 'none'
             AND EXISTS (SELECT 1 FROM outputs WHERE action_id = OLD.id AND promoted) THEN
            RAISE EXCEPTION 'cannot delete internal action % (broadcast_intent=none with promoted outputs)', OLD.id
              USING ERRCODE = 'check_violation';
          END IF;
          RETURN OLD;
        END;
        $$ LANGUAGE plpgsql;
      SQL
      run <<~SQL
        CREATE TRIGGER check_internal_action_delete
          BEFORE DELETE ON actions
          FOR EACH ROW
          EXECUTE FUNCTION prevent_internal_action_delete();
      SQL
    else
      run 'DROP TRIGGER IF EXISTS check_internal_action_delete'
      alter_table(:spendable) { drop_foreign_key [:action_id], name: :spendable_promotion_fkey }
      drop_table(:promotions)
      alter_table(:outputs) { add_column :promoted, :boolean, null: false, default: true }
      run <<~SQL
        CREATE TRIGGER check_internal_action_delete
          BEFORE DELETE ON actions
          FOR EACH ROW
          WHEN OLD.broadcast_intent = 'none'
        BEGIN
          SELECT RAISE(ABORT, 'cannot delete internal action (broadcast_intent=none with promoted outputs)')
          WHERE EXISTS (SELECT 1 FROM outputs WHERE action_id = OLD.id AND promoted);
        END;
      SQL
    end
  end
end
