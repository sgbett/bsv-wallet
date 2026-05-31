# frozen_string_literal: true

# Database-level guard mirroring Store#reject_action's internal-action
# refusal (CannotRejectInternalActionError). Actions with
# broadcast_intent = 'none' (internalize_action, import_utxo, wbikd) are
# canonical UTXO history received via channels other than broadcast —
# nothing should ever delete them. The application layer already refuses
# (do_reject raises before any DELETE; reap_stale_actions excludes 'none';
# abort_action refuses via the promoted-output guard), so this BEFORE
# DELETE trigger is defense-in-depth: it forbids the delete by ANY path.
#
# A CHECK constraint cannot express this — CHECKs fire on INSERT/UPDATE,
# never DELETE. A BEFORE DELETE trigger is the only DB mechanism that
# constrains row removal, the same pattern as prevent_outbound_spendable
# (003). check_violation ERRCODE → Sequel::CheckConstraintViolation.

Sequel.migration do
  up do
    if database_type == :postgres
      run <<~SQL
        CREATE FUNCTION prevent_internal_action_delete() RETURNS trigger AS $$
        BEGIN
          IF OLD.broadcast_intent = 'none' THEN
            RAISE EXCEPTION 'cannot delete internal action % (broadcast_intent=none)', OLD.id
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
      run <<~SQL
        CREATE TRIGGER check_internal_action_delete
          BEFORE DELETE ON actions
          FOR EACH ROW
          WHEN OLD.broadcast_intent = 'none'
        BEGIN
          SELECT RAISE(ABORT, 'cannot delete internal action (broadcast_intent=none)');
        END;
      SQL
    end
  end

  down do
    if database_type == :postgres
      run 'DROP TRIGGER IF EXISTS check_internal_action_delete ON actions'
      run 'DROP FUNCTION IF EXISTS prevent_internal_action_delete()'
    else
      run 'DROP TRIGGER IF EXISTS check_internal_action_delete'
    end
  end
end
