# frozen_string_literal: true

# BRC-100 basket-name validation at the schema level (HLR #428).
#
# Replaces the +name_length+ (1..300) and +name_not_default+ CHECKs added in
# 003 with eight named, rule-aligned CHECKs that enforce every BRC-100
# §"Rules for Basket Names" rule. The application-layer validator at
# +BSV::Wallet::BRC100+ (sub-issue #440) runs first and emits clean BRC-100
# errors; this migration is the principle-of-state floor: even if the
# conformance layer is bypassed (Engine-direct, raw store calls), the DB
# rejects the write.
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
#
# ADR-029 / DBAP follow-up (not blocking):
#   The +name_not_admin+ rule reserves the +admin *+ namespace per BRC-100
#   §"Rules for Basket Names". When ADR-029's DBAP/DPACP/DCAP/DSAP
#   machinery lands, the wallet's own permission-token baskets
#   (+admin basket-access+, +admin protocol-permission+,
#   +admin certificate-access+, +admin spending-authorization+) will need
#   to be written and this CHECK blocks that. A follow-up migration
#   introduces a privileged-write path (or a separate storage shape) at
#   that point — out of scope here, DBAP is deferred at the HLR level.

Sequel.migration do
  up do
    postgres = database_type == :postgres

    # Idempotency probe: 004 has already applied iff +name_charset+ exists
    # on +baskets+. The other six names overlap with 003-era predicates,
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
      # the seven new CHECKs. Aborts the migration with a clear list of
      # offending IDs if any are found (same discipline as #380).
      offenders = from(:baskets).select(:id, :name).all.reject do |row|
        name = row[:name].to_s
        name.length.between?(5, 300) &&
          name.match?(/\A[a-z0-9 ]+\z/) &&
          !name.include?('  ') &&
          !name.end_with?(' basket') &&
          !name.start_with?('admin') &&
          name != 'default' &&
          !name.start_with?('p ')
      end

      unless offenders.empty?
        summary = offenders.map { |r| "id=#{r[:id]} name=#{r[:name].inspect}" }.join('; ')
        raise "004_basket_name_validation: aborting — #{offenders.size} existing baskets " \
              "would violate the new CHECK constraints: #{summary}. Resolve before re-running."
      end

      # Drop the 003-era CHECKs subsumed by the new ruleset. +name_length+
      # widens-to-narrows (1..300 → 5..300); +name_not_default+ is preserved
      # by name and re-added with the same predicate as part of the new set.
      alter_table(:baskets) do
        drop_constraint :name_length
        drop_constraint :name_not_default
      end

      if postgres
        run <<~SQL
          ALTER TABLE baskets
            ADD CONSTRAINT name_length        CHECK (length(name) BETWEEN 5 AND 300),
            ADD CONSTRAINT name_charset       CHECK (name ~ '^[a-z0-9 ]+$'),
            ADD CONSTRAINT name_no_double_sp  CHECK (name NOT LIKE '%  %'),
            ADD CONSTRAINT name_not_basket    CHECK (name NOT LIKE '% basket'),
            ADD CONSTRAINT name_not_admin     CHECK (name NOT LIKE 'admin%'),
            ADD CONSTRAINT name_not_default   CHECK (name <> 'default'),
            ADD CONSTRAINT name_not_p_prefix  CHECK (name NOT LIKE 'p %');
        SQL
      else
        # SQLite: +alter_table { add_constraint … }+ rebuilds the table.
        # Per project_sqlite_schema_under_enforces the rebuild can silently
        # drop indexes/triggers attached to the prior table; re-assert the
        # +baskets_name_unique+ index below as a guard. The byte-aware
        # +NOT GLOB '*[^a-z0-9 ]*'+ construction is load-bearing — see the
        # file header for the negation-glyph caveat.
        alter_table(:baskets) do
          add_constraint(:name_length,       'length(name) BETWEEN 5 AND 300')
          add_constraint(:name_charset,      "name NOT GLOB '*[^a-z0-9 ]*'")
          add_constraint(:name_no_double_sp, "name NOT LIKE '%  %'")
          add_constraint(:name_not_basket,   "name NOT LIKE '% basket'")
          add_constraint(:name_not_admin,    "name NOT LIKE 'admin%'")
          add_constraint(:name_not_default,  "name <> 'default'")
          add_constraint(:name_not_p_prefix, "name NOT LIKE 'p %'")
        end

        # Re-assert +baskets_name_unique+ if the rebuild dropped it. Sequel
        # generally preserves indexes through table-recreation, but the
        # exact behaviour is libsqlite-version dependent and a cheap probe
        # closes the gap.
        add_index :baskets, :name, unique: true, name: :baskets_name_unique unless indexes(:baskets).key?(:baskets_name_unique)
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
            DROP CONSTRAINT IF EXISTS name_not_basket,
            DROP CONSTRAINT IF EXISTS name_not_admin,
            DROP CONSTRAINT IF EXISTS name_not_default,
            DROP CONSTRAINT IF EXISTS name_not_p_prefix;
        SQL
      else
        alter_table(:baskets) do
          drop_constraint :name_length
          drop_constraint :name_charset
          drop_constraint :name_no_double_sp
          drop_constraint :name_not_basket
          drop_constraint :name_not_admin
          drop_constraint :name_not_default
          drop_constraint :name_not_p_prefix
        end
      end

      # Restore the 003-era predicates so the schema state after +down+
      # matches the pre-004 state exactly.
      alter_table(:baskets) do
        add_constraint(:name_length,      'length(name) BETWEEN 1 AND 300')
        add_constraint(:name_not_default, "name != 'default'")
      end

      add_index :baskets, :name, unique: true, name: :baskets_name_unique if !postgres && !indexes(:baskets).key?(:baskets_name_unique)
    end
  end
end
