# frozen_string_literal: true

# BRC-100 basket-name SHAPE validation at the schema level (HLR #428).
#
# Replaces the 003-era +name_length+ (1..300) and +name_not_default+ CHECKs
# with four named, rule-aligned CHECKs that enforce the structural rules
# from BRC-100 §"Rules for Basket Names":
#
#   * +name_length+        — length BETWEEN 5 AND 300
#   * +name_charset+       — only +[a-z0-9 ]+
#   * +name_no_double_sp+  — no two consecutive spaces
#   * +name_not_basket+    — no trailing +" basket"+ suffix
#
# Design split (resolved after the +'p wbikd'+ regression on the HLR #428
# branch): the DB enforces SHAPE rules only. The caller-facing
# RESERVATION rules (+admin+ / +default+ / +p +) live in the conformance
# layer (+BSV::Wallet::BRC100#validate_basket_name!+) and bind only callers
# crossing that boundary. Wallet-internal protocol-reserved baskets — most
# acutely +'p wbikd'+, the WBIKD address-slot basket BRC-99 reserves for
# specially-permissioned protocols — write via the Engine→Store direct
# path and must be free to land. Putting reservation rules in the DB
# would structurally block the wallet's own protocol-conformant usage.
#
# The application-layer validator at +BSV::Wallet::BRC100+ (sub-issue #440)
# still enforces ALL eight rules — four shape + three reservation +
# the "no trailing ` basket`" suffix — for callers crossing the BRC-100
# boundary. The schema's four shape CHECKs are the principle-of-state
# floor for those same shape rules: even if a non-BRC100 caller (raw
# store insert, future binding) bypasses the conformance layer, the DB
# rejects the malformed write.
#
# Single source of vocabulary: the constraint names here mirror the
# validator's rule identifiers so a future BRC-100 error-code mapper can
# translate +Sequel::CheckConstraintViolation+ → wire error code by
# constraint name alone.
#
# SQLite charset rationale (DO NOT SIMPLIFY):
#   The rule is "lowercase ASCII letters, digits, spaces only" — byte-aware,
#   no UTF-8. SQLite has no regex support without the optional ICU module,
#   so the construct is +name NOT GLOB '*[^a-z0-9 ]*'+: any byte outside
#   the allowed set anywhere in the string fails. A naive positive form
#   like +name GLOB '[a-z0-9 ]*'+ does NOT enforce charset — GLOB +*+
#   matches any character, so +'hello!'+ would pass. The negated form
#   is byte-aware and correctly rejects multi-byte UTF-8 (e.g. +'café'+,
#   +'аdmin foo'+ with Cyrillic 'а'). Equivalent enforcement to the
#   Postgres +~ '^[a-z0-9 ]+$'+ regex.
#
#   Negation glyph: SQLite GLOB uses +[^...]+ for the negated character
#   class, NOT the shell-style +[!...]+. With +[!...]+ SQLite treats +!+
#   as a literal class member, so the pattern always matches and the
#   constraint silently passes everything. Verified against SQLite 3.x
#   in PR #441; the same caveat is recorded in 003 against the certificates
#   pubkey-shape CHECK. The HLR comment-stream's literal SQL specified
#   +[!...]+ — corrected here at implementation time because the silent-pass
#   failure mode is a correctness-blocking deviation, not a style choice.

Sequel.migration do
  up do
    postgres = database_type == :postgres

    # Idempotency probe: 004 has already applied iff +name_charset+ exists
    # on +baskets+. The other three names overlap with 003-era predicates,
    # so they're not unique tells. Re-running +up+ on a migrated DB is a
    # no-op.
    already_migrated =
      if postgres
        from(:pg_constraint)
          .join(:pg_class, oid: :conrelid)
          .where(Sequel[:pg_class][:relname] => 'baskets',
                 Sequel[:pg_constraint][:conname] => 'name_charset')
          .any?
      else
        from(:sqlite_master).where(type: 'table', name: 'baskets').get(:sql).to_s.include?('name_charset')
      end
    next if already_migrated

    transaction do
      # Pre-flight audit — scan +baskets+ for rows that would fail any of
      # the four new shape CHECKs. Aborts the migration with a clear list
      # of offending IDs if any are found (same discipline as #380).
      # Reservation rules are NOT checked here — wallet-internal reserved
      # baskets (e.g. +'p wbikd'+) are legitimate writes under the new
      # design.
      offenders = from(:baskets).select(:id, :name).all.reject do |row|
        name = row[:name].to_s
        name.length.between?(5, 300) &&
          name.match?(/\A[a-z0-9 ]+\z/) &&
          !name.include?('  ') &&
          !name.end_with?(' basket')
      end

      unless offenders.empty?
        summary = offenders.map { |r| "id=#{r[:id]} name=#{r[:name].inspect}" }.join('; ')
        raise "004_basket_name_validation: aborting — #{offenders.size} existing baskets " \
              "would violate the new CHECK constraints: #{summary}. Resolve before re-running."
      end

      # Drop the 003-era CHECKs subsumed by the new ruleset. +name_length+
      # widens-to-narrows (1..300 → 5..300); +name_not_default+ is dropped
      # outright — reservation enforcement now lives at the conformance
      # layer only, so the schema must not block +'default'+ (or any other
      # reserved name) at the DB floor.
      if postgres
        alter_table(:baskets) do
          drop_constraint :name_length
          drop_constraint :name_not_default
        end

        run <<~SQL
          ALTER TABLE baskets
            ADD CONSTRAINT name_length        CHECK (length(name) BETWEEN 5 AND 300),
            ADD CONSTRAINT name_charset       CHECK (name ~ '^[a-z0-9 ]+$'),
            ADD CONSTRAINT name_no_double_sp  CHECK (name NOT LIKE '%  %'),
            ADD CONSTRAINT name_not_basket    CHECK (name NOT LIKE '% basket');
        SQL
      else
        # SQLite has no DROP CONSTRAINT — and Sequel's +alter_table+
        # emulation rebuilds the table without fixing up foreign keys in
        # OTHER tables that reference +baskets+. After the rebuild the
        # +output_baskets.basket_id+ FK still points at +baskets_backup0+,
        # which subsequent inserts trip over with
        # +SQLite3::SQLException: no such table: main.baskets_backup0+.
        #
        # We bypass +alter_table+ for SQLite and use the
        # SQLite-recommended table-rebuild idiom verbatim
        # (https://www.sqlite.org/lang_altertable.html §"making other
        # kinds of table schema changes"). The +RENAME+ in step 5
        # updates referencing FKs in OTHER tables in place precisely
        # because the rename happens within the recommended idiom. The
        # byte-aware +NOT GLOB '*[^a-z0-9 ]*'+ construction is
        # load-bearing — see the file header for the negation-glyph
        # caveat.
        run 'PRAGMA foreign_keys = OFF'
        run <<~SQL
          CREATE TABLE baskets_new (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE,
            target_count INTEGER,
            target_value INTEGER,
            created_at datetime DEFAULT (datetime(CURRENT_TIMESTAMP, 'localtime')) NOT NULL,
            updated_at datetime DEFAULT (datetime(CURRENT_TIMESTAMP, 'localtime')) NOT NULL,
            CONSTRAINT name_length        CHECK (length(name) BETWEEN 5 AND 300),
            CONSTRAINT name_charset       CHECK (name NOT GLOB '*[^a-z0-9 ]*'),
            CONSTRAINT name_no_double_sp  CHECK (name NOT LIKE '%  %'),
            CONSTRAINT name_not_basket    CHECK (name NOT LIKE '% basket'),
            CONSTRAINT target_count_range CHECK (target_count IS NULL OR target_count >= 0),
            CONSTRAINT target_value_range CHECK (target_value IS NULL OR target_value >= 0)
          )
        SQL
        run 'INSERT INTO baskets_new (id, name, target_count, target_value, created_at, updated_at) ' \
            'SELECT id, name, target_count, target_value, created_at, updated_at FROM baskets'
        run 'DROP TABLE baskets'
        run 'ALTER TABLE baskets_new RENAME TO baskets'
        add_index :baskets, :name, unique: true, name: :baskets_name_unique
        run 'PRAGMA foreign_keys = ON'
      end
    end
  end

  down do
    postgres = database_type == :postgres

    # Mirror the +up+ idempotency probe.
    already_migrated =
      if postgres
        from(:pg_constraint)
          .join(:pg_class, oid: :conrelid)
          .where(Sequel[:pg_class][:relname] => 'baskets',
                 Sequel[:pg_constraint][:conname] => 'name_charset')
          .any?
      else
        from(:sqlite_master).where(type: 'table', name: 'baskets').get(:sql).to_s.include?('name_charset')
      end
    next unless already_migrated

    transaction do
      if postgres
        run <<~SQL
          ALTER TABLE baskets
            DROP CONSTRAINT IF EXISTS name_length,
            DROP CONSTRAINT IF EXISTS name_charset,
            DROP CONSTRAINT IF EXISTS name_no_double_sp,
            DROP CONSTRAINT IF EXISTS name_not_basket;
        SQL

        # Restore the 003-era predicates so the schema state after +down+
        # matches the pre-004 state exactly. 003 assumed reservation
        # enforcement at the schema level too — restoring +name_not_default+
        # here keeps +down+ a faithful inverse of the pre-004 state, even
        # though the post-004 design has moved that rule to the conformance
        # layer.
        alter_table(:baskets) do
          add_constraint(:name_length,      'length(name) BETWEEN 1 AND 300')
          add_constraint(:name_not_default, "name != 'default'")
        end
      else
        # SQLite: same FK-update caveat as the +up+ direction —
        # +alter_table+ emulation leaves referencing FKs pointing at a
        # +baskets_backup0+ that no longer exists. Use the
        # SQLite-recommended table-rebuild idiom verbatim. The schema
        # restored here mirrors the 003-era state exactly: +name_length+
        # widens back to 1..300 and +name_not_default+ is re-introduced.
        run 'PRAGMA foreign_keys = OFF'
        run <<~SQL
          CREATE TABLE baskets_new (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            name TEXT NOT NULL UNIQUE,
            target_count INTEGER,
            target_value INTEGER,
            created_at datetime DEFAULT (datetime(CURRENT_TIMESTAMP, 'localtime')) NOT NULL,
            updated_at datetime DEFAULT (datetime(CURRENT_TIMESTAMP, 'localtime')) NOT NULL,
            CONSTRAINT name_length        CHECK (length(name) BETWEEN 1 AND 300),
            CONSTRAINT name_not_default   CHECK (name != 'default'),
            CONSTRAINT target_count_range CHECK (target_count IS NULL OR target_count >= 0),
            CONSTRAINT target_value_range CHECK (target_value IS NULL OR target_value >= 0)
          )
        SQL
        run 'INSERT INTO baskets_new (id, name, target_count, target_value, created_at, updated_at) ' \
            'SELECT id, name, target_count, target_value, created_at, updated_at FROM baskets'
        run 'DROP TABLE baskets'
        run 'ALTER TABLE baskets_new RENAME TO baskets'
        add_index :baskets, :name, unique: true, name: :baskets_name_unique
        run 'PRAGMA foreign_keys = ON'
      end
    end
  end
end
