# frozen_string_literal: true

require_relative 'shared_context'

# Schema-level CHECK constraints from migration 004
# (db/migrations/004_basket_name_validation.rb), enforcing BRC-100
# §"Rules for Basket Names" at the database floor.
#
# Matrix-aware: every rule is exercised under BOTH Postgres and SQLite
# (per feedback_postgres_is_primary). The conformance layer at
# +BSV::Wallet::BRC100+ (#440) translates these into BRC-100 errors;
# this spec gates the principle-of-state floor — even if the conformance
# layer is bypassed (Engine-direct, raw store calls), the DB rejects.
#
# Behavioural assertions only — no schema-text comparisons
# (per project_sqlite_schema_under_enforces).

RSpec.describe 'baskets.name BRC-100 CHECK constraints (#428)', :store do
  # Each rule is exercised by inserting directly via +db[:baskets].insert+
  # and asserting +Sequel::CheckConstraintViolation+. The error message
  # surfaces the constraint name on Postgres; SQLite's adapter only
  # reports the generic CHECK failure, so the name-in-message assertion
  # is Postgres-gated below.
  describe 'rule-by-rule rejects' do
    {
      name_length: { input: 'four', description: 'shorter than 5 characters' },
      name_length_max: { input: 'x' * 301, description: 'longer than 300 characters', constraint: :name_length },
      name_charset: { input: 'has-hyphen', description: 'non-allowed ASCII character (hyphen)' },
      name_charset_caps: { input: 'HasCaps', description: 'uppercase letters', constraint: :name_charset },
      name_charset_utf8: { input: 'café au lait', description: 'non-ASCII UTF-8 (byte-aware)', constraint: :name_charset },
      name_no_double_sp: { input: 'two  spaces', description: 'two consecutive spaces' },
      name_not_basket: { input: 'token basket', description: "trailing ' basket' suffix" },
      name_not_admin: { input: 'admin foo', description: "leading 'admin' (reserved for DBAP, ADR-029)" },
      name_not_default: { input: 'default', description: "exact literal 'default'" },
      name_not_p_prefix: { input: 'p foo', description: "leading 'p ' (BRC-99 reserved)" }
    }.each do |label, fixture|
      it "rejects #{fixture[:description]} (#{fixture[:constraint] || label})" do
        expect do
          db.transaction(savepoint: true) do
            db[:baskets].insert(name: fixture[:input])
          end
        end.to raise_error(Sequel::CheckConstraintViolation)
      end

      # Postgres surfaces the constraint name in the violation message —
      # use that to guard against rule drift (an insert tripping the wrong
      # CHECK). SQLite's adapter doesn't surface the constraint name, so
      # this assertion is Postgres-only.
      it "trips the #{fixture[:constraint] || label} constraint by name (Postgres-only)", :postgres do
        expected = fixture[:constraint] || label
        expect do
          db.transaction(savepoint: true) do
            db[:baskets].insert(name: fixture[:input])
          end
        end.to raise_error(Sequel::CheckConstraintViolation, /#{expected}/)
      end
    end
  end

  # Boundary cases — the rule edges that the application validator at #440
  # and the DB CHECK must agree on. Matrix-aware.
  describe 'rule boundaries' do
    it 'accepts a 5-character name (lower length boundary)' do
      expect { db[:baskets].insert(name: 'penta') }.not_to raise_error
    end

    it 'accepts a 300-character name (upper length boundary)' do
      expect { db[:baskets].insert(name: 'a' * 300) }.not_to raise_error
    end

    it 'accepts a name with single internal spaces' do
      expect { db[:baskets].insert(name: 'wallet payments') }.not_to raise_error
    end

    it "accepts a name that contains 'admin' but does not start with it" do
      # +name_not_admin+ is a prefix rule, not a substring rule —
      # 'my admin notes' is allowed.
      expect { db[:baskets].insert(name: 'my admin notes') }.not_to raise_error
    end

    it "accepts a name starting with 'p' but not 'p ' (no following space)" do
      # The +p +-prefix rule requires a literal space; 'pizza' is fine.
      expect { db[:baskets].insert(name: 'pizza') }.not_to raise_error
    end

    it "accepts a name ending in 'basket' without a leading space" do
      # The ' basket' suffix rule requires a leading space; 'tokenbasket'
      # is allowed.
      expect { db[:baskets].insert(name: 'tokenbasket') }.not_to raise_error
    end
  end

  # SQLite +alter_table { add_constraint … }+ rebuilds the baskets table.
  # Per project_sqlite_schema_under_enforces this rebuild can silently drop
  # the +baskets_name_unique+ index. Migration 004 re-asserts the index;
  # this spec guards the re-assertion. Matrix-aware (Postgres also has the
  # unique constraint by design).
  describe 'baskets_name_unique post-migration integrity' do
    it 'rejects a duplicate name with UniqueConstraintViolation' do
      db[:baskets].insert(name: 'unique check')
      expect do
        db.transaction(savepoint: true) do
          db[:baskets].insert(name: 'unique check')
        end
      end.to raise_error(Sequel::UniqueConstraintViolation)
    end
  end

  # Documents the principle-of-state floor: an Engine-level write
  # (Store#find_or_create_basket — exactly the path Engine uses to land
  # outputs in baskets) that bypasses the BRC-100 conformance layer at #440
  # is still rejected by the DB CHECK.
  describe 'Engine-direct bypass (principle-of-state floor)' do
    it "rejects 'admin foo' written via Store#find_or_create_basket" do
      # Bypass the conformance layer entirely — invoke the Store primitive
      # the Engine uses, with a reserved-name input the validator would
      # otherwise have caught upstream.
      expect do
        db.transaction(savepoint: true) do
          store.find_or_create_basket(name: 'admin foo')
        end
      end.to raise_error(Sequel::CheckConstraintViolation)
    end
  end

  # Migration lifecycle: idempotent +up+, +down+ that restores the 003-era
  # state, and the pre-flight audit that aborts +up+ if existing rows would
  # violate the new ruleset. These exercise the migration directly through
  # Sequel::Migrator on a scratch DB so the test database's existing
  # migrated state is left untouched.
  describe 'migration lifecycle' do
    let(:migrations_path) { File.expand_path('../../../../db/migrations', __dir__) }

    def scratch_db
      Sequel.sqlite.tap { |d| d.run('PRAGMA foreign_keys = ON') }
    end

    it 'is idempotent: re-running up on a migrated DB is a no-op' do
      d = scratch_db
      Sequel::Migrator.run(d, migrations_path)
      # Re-run — Sequel's version-tracking + the in-migration probe both
      # cooperate to make this a no-op.
      expect { Sequel::Migrator.run(d, migrations_path) }.not_to raise_error
      d.disconnect
    end

    it 'down restores the 003-era predicates (bad-name is accepted after rollback)' do
      d = scratch_db
      Sequel::Migrator.run(d, migrations_path)
      # Before rollback: 'bad-name' fails the new charset rule.
      expect { d[:baskets].insert(name: 'bad-name') }.to raise_error(Sequel::CheckConstraintViolation)
      # Rollback 004 only.
      Sequel::Migrator.run(d, migrations_path, target: 3)
      # After rollback: 003's name_length (1..300) is the only length CHECK;
      # 'bad-name' is accepted.
      expect { d[:baskets].insert(name: 'bad-name') }.not_to raise_error
      d.disconnect
    end

    it 'pre-flight audit aborts up when existing rows would violate the new ruleset' do
      d = scratch_db
      # Apply 001..003 only — the new CHECKs are NOT yet in force, so a
      # non-conformant name lands cleanly.
      Sequel::Migrator.run(d, migrations_path, target: 3)
      d[:baskets].insert(name: 'bad-name')
      # Now try to apply 004 — the pre-flight audit must list the offender
      # and abort.
      expect { Sequel::Migrator.run(d, migrations_path) }
        .to raise_error(StandardError, /aborting.*existing baskets/)
      d.disconnect
    end

    it 'baskets_name_unique survives the SQLite alter_table rebuild' do
      d = scratch_db
      Sequel::Migrator.run(d, migrations_path)
      # The index should still be present after 004's SQLite alter_table.
      expect(d.indexes(:baskets)).to have_key(:baskets_name_unique)
      d.disconnect
    end
  end
end
