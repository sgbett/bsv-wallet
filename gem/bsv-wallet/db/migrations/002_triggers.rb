# frozen_string_literal: true

# Behavioural guards that can't sit inside CREATE TABLE — BEFORE-row triggers
# referencing other tables, plus the PG functions they execute.
#
# Why a separate file: CHECK constraints can only reference columns on the
# same row. Cross-table invariants (this row's existence is illegal given
# *that* table's state) need triggers. Triggers also need functions defined
# beforehand on Postgres, and the function/trigger pair is its own object —
# co-locating with CREATE TABLE would clutter every table's block with
# trigger plumbing for the few that need it.
#
# Trigger inventory (each pair: function + trigger):
#
#   1. prevent_outbound_spendable / check_outbound_spendable
#      Invariant: an output with output_type='outbound' must never have a
#      spendable row. Outbound outputs aren't ours.
#      Trigger type: BEFORE INSERT on spendable.
#
#   2. prevent_internal_action_delete / check_internal_action_delete
#      Invariant: an internal-path action (broadcast_intent='none') with a
#      promotions row owns canonical received UTXO history; cannot be deleted.
#      Trigger type: BEFORE DELETE on actions. A CHECK can't express delete-
#      side invariants (CHECKs fire on INSERT/UPDATE, never DELETE).
#
# Both triggers raise with the check_violation ERRCODE on Postgres so
# Sequel maps them to Sequel::CheckConstraintViolation — the same exception
# class CHECK constraints produce, keeping the error-handling surface uniform.

Sequel.migration do
  up do
    postgres = database_type == :postgres

    # --- 1. outbound-spendable guard ---
    if postgres
      run <<~SQL
        CREATE FUNCTION prevent_outbound_spendable() RETURNS trigger AS $$
        BEGIN
          IF EXISTS (SELECT 1 FROM outputs WHERE id = NEW.output_id AND output_type = 'outbound') THEN
            RAISE EXCEPTION 'spendable row forbidden for outbound output %', NEW.output_id
              USING ERRCODE = 'check_violation';
          END IF;
          RETURN NEW;
        END;
        $$ LANGUAGE plpgsql;
      SQL
      run <<~SQL
        CREATE TRIGGER check_outbound_spendable
          BEFORE INSERT ON spendable
          FOR EACH ROW
          EXECUTE FUNCTION prevent_outbound_spendable();
      SQL
    else
      run <<~SQL
        CREATE TRIGGER check_outbound_spendable
          BEFORE INSERT ON spendable
          FOR EACH ROW
          WHEN (SELECT output_type FROM outputs WHERE id = NEW.output_id) = 'outbound'
        BEGIN
          SELECT RAISE(ABORT, 'spendable row forbidden for outbound output');
        END;
      SQL
    end

    # --- 2. internal-action-delete guard ---
    if postgres
      run <<~SQL
        CREATE FUNCTION prevent_internal_action_delete() RETURNS trigger AS $$
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
      run 'DROP FUNCTION IF EXISTS prevent_internal_action_delete()'
      run 'DROP TRIGGER IF EXISTS check_outbound_spendable ON spendable'
      run 'DROP FUNCTION IF EXISTS prevent_outbound_spendable()'
    else
      run 'DROP TRIGGER IF EXISTS check_internal_action_delete'
      run 'DROP TRIGGER IF EXISTS check_outbound_spendable'
    end
  end
end
