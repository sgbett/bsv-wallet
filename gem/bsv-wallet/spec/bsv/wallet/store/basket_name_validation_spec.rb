# frozen_string_literal: true

require_relative 'shared_context'
require 'bsv/wallet/engine'
require 'bsv/wallet/brc100'

# Schema-level CHECK constraints on +baskets.name+ from the baskets block
# in +db/migrations/001_create_schema.rb+, enforcing the invalid-data
# rules from BRC-100 §"Rules for Basket Names" at the database floor.
#
# Design split, framed as "invalid data → DB CHECK; caller-facing
# policy → conformance layer only":
#   * INVALID-DATA rules — length, charset, double-space, trailing
#     +' basket'+, exact +'default'+, leading/trailing whitespace —
#     enforced at BOTH the conformance layer (+BSV::Wallet::BRC100+)
#     AND the DB CHECK. These names should never reach storage from any
#     path; the schema is the floor.
#   * RESERVATION rules — +admin+ and +p + prefixes — enforced at the
#     conformance layer ONLY. These ARE valid data the wallet itself
#     stores (+'p wbikd'+ for the WBIKD draft today, +'admin *'+ for
#     ADR-029 DBAP tomorrow), written via the Engine→Store direct path.
#     The DB intentionally accepts them so the wallet's own internals
#     can boot.
#
# Matrix-aware: every shape rule is exercised under BOTH Postgres and
# SQLite (per feedback_postgres_is_primary).
#
# Behavioural assertions only — no schema-text comparisons
# (per project_sqlite_schema_under_enforces).

RSpec.describe 'baskets.name BRC-100 CHECK constraints (#428)', :store do
  # Each shape rule is exercised by inserting directly via +db[:baskets].insert+
  # and asserting +Sequel::CheckConstraintViolation+. The error message
  # surfaces the constraint name on Postgres; SQLite's adapter only
  # reports the generic CHECK failure, so the name-in-message assertion
  # is Postgres-gated below.
  describe 'shape-rule rejects' do
    {
      name_length: { input: 'four', description: 'shorter than 5 characters' },
      name_length_max: { input: 'x' * 301, description: 'longer than 300 characters', constraint: :name_length },
      name_charset: { input: 'has-hyphen', description: 'non-allowed ASCII character (hyphen)' },
      name_charset_caps: { input: 'HasCaps', description: 'uppercase letters', constraint: :name_charset },
      name_charset_utf8: { input: 'café au lait', description: 'non-ASCII UTF-8 (byte-aware)', constraint: :name_charset },
      name_no_double_sp: { input: 'two  spaces', description: 'two consecutive spaces' },
      name_not_basket: { input: 'token basket', description: "trailing ' basket' suffix" },
      name_not_default: { input: 'default', description: "the literal 'default' (invalid data)" },
      name_no_leading_space: { input: ' wallet', description: 'leading space (invalid data)' },
      name_no_trailing_space: { input: 'wallet ', description: 'trailing space (invalid data)' }
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

  # Documents the conformance-vs-floor boundary: reservation rules
  # (+admin+ and +p +) trip the BRC-100 wrapper but NOT the DB.
  # +'p wbikd'+ is the concrete proof — the WBIKD draft uses it as the
  # wallet's live address-slot basket, written via Engine→Store direct
  # (see +Engine#find_or_create_wbikd_slot+). If the DB enforced the
  # +p +-prefix rule the wallet's own internals would not boot.
  # +'default'+ is NOT in this set — it's invalid data per the new
  # framing and is now schema-rejected; see "shape-rule rejects" above.
  describe 'reservation rules — conformance-only, DB accepts' do
    let(:brc100) { BSV::Wallet::BRC100.new(Object.new) }

    it "rejects 'p wbikd' at the BRC-100 conformance layer" do
      expect { brc100.send(:validate_basket_name!, 'p wbikd') }
        .to raise_error(BSV::Wallet::InvalidParameterError, /reserved/)
    end

    it "accepts 'p wbikd' written direct via Store (Engine→Store path)" do
      # Bypass the conformance layer entirely — invoke the Store primitive
      # the Engine uses, with the WBIKD slot's actual basket name. The
      # DB must NOT block this; if it did, +find_or_create_wbikd_slot+
      # would fail at first use.
      expect do
        db.transaction(savepoint: true) do
          store.find_or_create_basket(name: 'p wbikd')
        end
      end.not_to raise_error
    end

    it "accepts 'admin foo' written direct via the baskets table" do
      # +admin *+ is reserved at the boundary for future ADR-029 DBAP
      # baskets; the DB accepts it so wallet-internal writes can land.
      expect do
        db.transaction(savepoint: true) do
          db[:baskets].insert(name: 'admin foo')
        end
      end.not_to raise_error
    end
  end
end
