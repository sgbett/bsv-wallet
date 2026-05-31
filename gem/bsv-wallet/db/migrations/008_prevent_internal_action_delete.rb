# frozen_string_literal: true

# Database-level guard protecting canonical received UTXO history from
# deletion — defense-in-depth mirroring Store#abort_action's promoted-
# output refusal (CannotAbortPromotedActionError) and reject_action's
# internal-action refusal (CannotRejectInternalActionError).
#
# The history we protect is embodied by an action's PROMOTED outputs:
# internalize_action and import_utxo write their outputs promoted: true at
# create time, so a broadcast_intent = 'none' action that owns a promoted
# output is received UTXO history and must never be deleted.
#
# The criterion is "promoted output", not "broadcast_intent = none" alone:
# a WBIKD address-lock is also broadcast_intent = 'none' but is a zero-
# output speculative slot lock — abort_action and slot recycling delete it
# legitimately, and it carries no UTXO history. Keying on promoted outputs
# (the same criterion abort_action enforces) protects the history while
# leaving these ephemeral locks deletable.
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

  down do
    if database_type == :postgres
      run 'DROP TRIGGER IF EXISTS check_internal_action_delete ON actions'
      run 'DROP FUNCTION IF EXISTS prevent_internal_action_delete()'
    else
      run 'DROP TRIGGER IF EXISTS check_internal_action_delete'
    end
  end
end
