# frozen_string_literal: true

# The wallet's schema. One file, every table in its end-state shape, with
# every structural constraint inline.
#
# Pre-release "amend in place" policy: this migration expresses the canonical
# structure rather than its change history. CHECK constraints, NOT NULL
# settings, single-column UNIQUE, composite UNIQUE, FK CASCADE behaviour
# and the inline integrity CHECKs all live with their CREATE TABLE.
#
# What is NOT here: BEFORE-row triggers and their PG functions live in
# 002_triggers.rb — they reference other tables and can't sit inside CREATE
# TABLE; they belong in a separate behavioural-guards file.
#
# Per-table column order convention:
#   1. id (two-line PK: Postgres BIGINT IDENTITY, SQLite autoincrement)
#   2. Foreign keys (belongs-to relationships)
#   3. Required content columns (null: false)
#   4. Optional content columns
#   5. created_at + updated_at
# After the create_table block:
#   6. Inline UNIQUEs (single-column and composite)
#   7. Indexes
#
# Documented deviations:
#   * outputs — column order is layout-optimised for Postgres tuple packing
#     (see the comment on the outputs block). Don't reorder without thinking.
#   * spendable / output_details / transmission_txids — no timestamps;
#     set-membership / 1:1 sidecar tables.
#   * promotions — raw SQL on Postgres for the gating CHECKs + composite FK
#     naming; SQLite uses the Sequel API path.
#   * broadcasts.action_id — declared as a raw column, not foreign_key,
#     because the composite FK (action_id, intent) → actions(id, broadcast_intent)
#     covers it; a single-column FK would duplicate.
#   * tx_proofs.wtxid — declared before block_id (the FK) because a proof is
#     identified by what it proves; chain placement is secondary.
#   * spendable's second FK to promotions(action_id) is added in an
#     alter_table at the bottom — promotions doesn't exist yet at
#     spendable creation time.
#
# Guard convention:
#   postgres = database_type == :postgres
#   c[:type]  — cross-backend column type map
#   c[:now]   — cross-backend default for timestamp columns

Sequel.migration do
  up do
    postgres = database_type == :postgres

    c = {}
    c[:bytea] = postgres ? :bytea : :blob
    c[:timestamptz] = postgres ? :timestamptz : :datetime
    c[:broadcast_intent] = postgres ? :broadcast_intent : :text
    c[:tx_status] = postgres ? :tx_status : :text
    c[:spendable_intent] = postgres ? :spendable_intent : :text
    c[:now] = postgres ? Sequel.function(:now) : Sequel::CURRENT_TIMESTAMP

    # ARC tx_status vocabulary, per
    # https://github.com/bitcoin-sv/arc internal/metamorph/metamorph_api/metamorph_api.proto.
    # SEEN_MULTIPLE_NODES appears between SEEN_ON_NETWORK and DOUBLE_SPEND_ATTEMPTED
    # (Arcade emits it, #011). IMMUTABLE appended for the wallet's TERMINAL_STATUSES
    # (anticipates an ARC addition; #198/#220 design intent).
    arc_tx_statuses = %w[
      UNKNOWN QUEUED RECEIVED STORED
      ANNOUNCED_TO_NETWORK REQUESTED_BY_NETWORK SENT_TO_NETWORK
      ACCEPTED_BY_NETWORK SEEN_IN_ORPHAN_MEMPOOL SEEN_ON_NETWORK
      SEEN_MULTIPLE_NODES
      DOUBLE_SPEND_ATTEMPTED REJECTED MINED_IN_STALE_BLOCK MINED IMMUTABLE
    ]

    if postgres
      extension :pg_enum
      create_enum(:broadcast_intent, %w[delayed inline none])
      create_enum(:tx_status, arc_tx_statuses)
      # spendable_intent: 'spendable' means the wallet asserts it can spend
      # this output (root P2PKH or BRC-42 derived); 'none' means it cannot
      # (BRC-29 outbound payment, base58 to counterparty). The intent is
      # stated explicitly, not inferred from outcomes (HLR #467 / ADR-031).
      create_enum(:spendable_intent, %w[spendable none])
    end

    # 1. blocks — known block headers (chain tracker's local view)
    create_table(:blocks) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      column :height, :integer, null: false, unique: true
      column :merkle_root, c[:bytea], null: false
      column :block_hash, c[:bytea]
      # The raw 80-byte block header, present iff this row was PoW-validated
      # locally (#335). Its presence is the structural "validated" signal —
      # there is no status column. Absent ⇒ a trusted-service row carrying
      # only the merkle_root fetched from a chain-query Service.
      column :header, c[:bytea]
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]

      constraint(:height_range, 'height >= 0')
      constraint(:merkle_root_length, 'length(merkle_root) = 32')
      constraint(:block_hash_length, 'block_hash IS NULL OR length(block_hash) = 32')
      # A header is exactly 80 bytes. Nullable: the trusted-service path
      # stores merkle_root alone.
      constraint(:header_length, 'header IS NULL OR length(header) = 80')
      # The merkle_root embedded in the header (bytes 36..67, 0-indexed) must
      # equal the indexed merkle_root column — the header is the source, the
      # column is the extracted answer, and they cannot disagree. The 1-indexed
      # SQL offset is 37, length 32. Postgres and SQLite spell substring
      # differently, so branch on the in-scope +postgres+ guard.
      embedded_root = postgres ? 'substring(header from 37 for 32)' : 'substr(header, 37, 32)'
      constraint(:header_root_match, "header IS NULL OR #{embedded_root} = merkle_root")
    end

    # 2. tx_proofs — merkle inclusion proofs (settlement evidence)
    create_table(:tx_proofs) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      # wtxid is the proof's natural identifier (the cryptographic content);
      # block_id is loose secondary association (where it sits in the chain).
      column :wtxid, c[:bytea], null: false, unique: true
      foreign_key :block_id, :blocks, type: :bigint
      column :block_index, :integer
      column :merkle_path, c[:bytea]
      column :raw_tx, c[:bytea], null: false
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]

      constraint(:wtxid_length, 'length(wtxid) = 32')
      # raw_tx must be at least 20 bytes: version + input_count + output_count
      # + amount + script_len + OP_1 + locktime (#380 gap 2).
      constraint(:raw_tx_min_length, 'length(raw_tx) >= 20')
      # A merkle_path without block context is unverifiable — no root to check
      # against. The reverse is fine (#198/#219): height-known + path-pending is
      # the "confirmed but unproven" intermediate state.
      constraint(:path_requires_block, 'merkle_path IS NULL OR block_id IS NOT NULL')
    end

    # 3. actions — transaction lifecycle
    create_table(:actions) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      foreign_key :tx_proof_id, :tx_proofs, type: :bigint
      column :wtxid, c[:bytea]
      if postgres
        # UUIDv7 is time-ordered (#198/#222) — sequential B-tree inserts on
        # the UNIQUE index, no page splits or fragmentation. Native to
        # Postgres 18. SQLite has no default — the Action model generates
        # via SecureRandom.uuid_v7 in before_create.
        column :reference, :uuid, null: false, unique: true, default: Sequel.function(:uuidv7)
      else
        column :reference, :text, null: false, unique: true
      end
      column :description, :text, null: false
      column :broadcast_intent, c[:broadcast_intent], null: false, default: 'delayed'
      column :raw_tx, c[:bytea]
      column :input_beef, c[:bytea]
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]

      # wtxid is unique when present; the partial unique index allows multiple
      # unsigned actions (wtxid NULL) to coexist.
      index :wtxid, unique: true, where: Sequel.lit('wtxid IS NOT NULL')
      index :broadcast_intent

      # Composite FK target: broadcasts(action_id, intent) → actions(id, broadcast_intent)
      # makes broadcasts.intent track actions.broadcast_intent atomically (#221).
      unique %i[id broadcast_intent]

      constraint(:wtxid_length, 'wtxid IS NULL OR length(wtxid) = 32')
      constraint(:description_length, 'length(description) BETWEEN 5 AND 50')
      constraint(:wtxid_raw_tx_parity, '(wtxid IS NULL) = (raw_tx IS NULL)')
      # Parallel to tx_proofs.raw_tx_min_length above (#380 gap 2).
      # NULL-permissive — the wtxid_raw_tx_parity rule allows both unset for
      # not-yet-signed actions.
      constraint(:raw_tx_min_length, 'raw_tx IS NULL OR length(raw_tx) >= 20')
      # SQLite gets a CHECK to mirror the Postgres broadcast_intent ENUM.
      constraint(:broadcast_intent_values, "broadcast_intent IN ('delayed', 'inline', 'none')") unless postgres
    end

    # 4. broadcasts — ARC lifecycle
    create_table(:broadcasts) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      column :action_id, :bigint, null: false
      column :broadcast_at, c[:timestamptz]
      column :callback_token, :text
      column :arc_status, :integer
      column :tx_status, c[:tx_status]
      # Composite FK to actions(id, broadcast_intent) + CHECK intent != 'none'
      # (#198/#221) keeps broadcasts.intent in sync with the parent action's
      # intent and forbids broadcast rows for internal-path actions.
      column :intent, c[:broadcast_intent], null: false
      column :block_hash, c[:bytea]
      column :block_height, :integer
      column :merkle_path, c[:bytea]
      column :extra_info, :text
      column :competing_txs, postgres ? 'text[]' : :text
      column :retry_count, :integer, null: false, default: 0
      column :provider, :text
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]

      unique :action_id
      # Composite FK target for promotions(action_id, authorising_status) → broadcasts.
      unique %i[action_id tx_status], name: :broadcasts_action_id_tx_status_key
      # ON UPDATE RESTRICT makes the immutability of actions.broadcast_intent
      # explicit at the schema level — any path that tries to mutate the
      # parent's intent while a broadcasts row exists is rejected, rather
      # than relying on application code to honour the invariant.
      foreign_key %i[action_id intent], :actions,
                  key: %i[id broadcast_intent], on_update: :restrict
      constraint(:intent_not_none, "intent != 'none'")
      constraint(:block_hash_length, 'block_hash IS NULL OR length(block_hash) = 32')
      constraint(:block_height_range, 'block_height IS NULL OR block_height >= 0')
      # Path-requires-block (#380 gap 1): a merkle_path is unverifiable without
      # block context, so if it's set the block fields must be too. The reverse
      # (block_hash/height set, merkle_path NULL) is the legitimate "confirmed
      # but unproven" intermediate state when ARC reports MINED with blockHeight
      # ahead of the path — see the parallel tx_proofs.path_requires_block
      # constraint and the discussion in docs/reference/schema.md.
      constraint(
        :path_requires_block,
        'merkle_path IS NULL OR (block_hash IS NOT NULL AND block_height IS NOT NULL)'
      )
      # SQLite gets a CHECK to mirror the Postgres tx_status ENUM. List mirrors
      # arc_tx_statuses above (ARC's metamorph Status enum plus IMMUTABLE,
      # #198/#220).
      unless postgres
        constraint(
          :tx_status_values,
          "tx_status IS NULL OR tx_status IN ('UNKNOWN', 'QUEUED', 'RECEIVED', 'STORED', " \
          "'ANNOUNCED_TO_NETWORK', 'REQUESTED_BY_NETWORK', 'SENT_TO_NETWORK', " \
          "'ACCEPTED_BY_NETWORK', 'SEEN_IN_ORPHAN_MEMPOOL', 'SEEN_ON_NETWORK', " \
          "'SEEN_MULTIPLE_NODES', 'DOUBLE_SPEND_ATTEMPTED', 'REJECTED', " \
          "'MINED_IN_STALE_BLOCK', 'MINED', 'IMMUTABLE')"
        )
      end
    end

    # 5. baskets — output grouping with replenishment policy
    #
    # Rule selection framing: invalid data → DB CHECK; caller-facing policy
    # → conformance layer only (BSV::Wallet::BRC100#validate_basket_name!).
    # See docs/reference/brc100-conformance.md for the full principle.
    #
    # AT THE DB FLOOR (rules below) — invalid data the wallet never
    # legitimately stores from any path:
    #   * Shape — wrong length, non-allowed charset, double-space,
    #     trailing ' basket'.
    #   * Exact 'default' — the wallet's effective default is unbasketed
    #     (no row), so a row literally named 'default' is a bug.
    #   * Leading/trailing whitespace — the application validator
    #     normalises it away on ingress via +strip+, but a non-BRC-100
    #     caller (Engine-direct, raw store, future #223 binding) bypasses
    #     the boundary and would otherwise land the malformed name.
    #
    # AT THE CONFORMANCE LAYER ONLY (NOT enforced here) — valid data the
    # wallet itself stores via the Engine→Store direct path:
    #   * 'admin' prefix — 'admin *' permission-token baskets for ADR-029
    #     DBAP/DPACP/DCAP/DSAP (forward-looking).
    #   * 'p ' prefix — 'p wbikd' is the WBIKD draft's live address-slot
    #     basket today.
    #
    # Constraint names mirror the validator's rule identifiers so a future
    # BRC-100 error-code mapper can translate Sequel::CheckConstraintViolation
    # → wire error code by constraint name alone.
    #
    # SQLite charset (DO NOT SIMPLIFY): `name NOT GLOB '*[^a-z0-9 ]*'` is
    # byte-aware — any byte outside the allowed set fails, including multi-byte
    # UTF-8 (e.g. 'café'). The negation glyph is `[^...]`, NOT `[!...]` —
    # SQLite treats `!` as a literal class member, causing silent-pass
    # behaviour; verified against SQLite 3.x. Equivalent enforcement to the
    # Postgres `~ '^[a-z0-9 ]+$'` regex; `COLLATE "C"` on Postgres forces
    # byte-level interpretation of the `[a-z]` range regardless of cluster
    # LC_CTYPE.
    create_table(:baskets) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      column :name, :text, null: false
      column :target_count, :integer
      column :target_value, :integer
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]

      unique :name, name: :baskets_name_unique

      constraint(:name_length,           'length(name) BETWEEN 5 AND 300')
      constraint(:name_charset,          postgres ? %(name COLLATE "C" ~ '^[a-z0-9 ]+$') : "name NOT GLOB '*[^a-z0-9 ]*'")
      constraint(:name_no_double_sp,     "name NOT LIKE '%  %'")
      constraint(:name_not_basket,       "name NOT LIKE '% basket'")
      constraint(:name_not_default,      "name <> 'default'")
      constraint(:name_no_leading_space, "name NOT LIKE ' %'")
      constraint(:name_no_trailing_space, "name NOT LIKE '% '")
      constraint(:target_count_range,    'target_count IS NULL OR target_count >= 0')
      constraint(:target_value_range,    'target_value IS NULL OR target_value >= 0')
    end

    # 6. outputs — immutable append-only log
    #
    # Column order is LAYOUT-OPTIMISED for Postgres tuple packing — DO NOT
    # REORDER without thinking through the alignment:
    #   * locking_script (bytea, ~18b) aligns to 24b, leaving 6b alignment
    #     padding.
    #   * vout (integer, 4b) slots into 4 of those 6 padding bytes with no
    #     padding of its own.
    #   * spendable_intent (enum/text, 2b) consumes the remaining 2b of
    #     locking_script's padding window, sitting next to vout for the
    #     semantic affinity ("intent for this output").
    #   * sender_identity_key, derivation_prefix, derivation_suffix (text,
    #     ~18b each) follow. End-of-tuple padding is MAXALIGN regardless.
    # No updated_at — outputs are immutable; rows never change after insert.
    # Outputs is the wallet's largest-cardinality table; a few bytes per
    # row compounds at scale.
    #
    # Two structural constraints together enforce the 8-permutation matrix
    # (root_pattern × controls_present × spendable_intent — see HLR #467 /
    # docs/reference/intent-and-outcomes.md):
    #
    #   * +controls_all_or_nothing+ — the BRC-42/BRC-29 derivation triple
    #     (+derivation_prefix+ / +derivation_suffix+ / +sender_identity_key+)
    #     is either complete or entirely absent. No partial state.
    #   * +spendable_recoverable+ — the row encodes a recoverable spending
    #     key, or honestly admits it cannot. The per-wallet literal is the
    #     +hash160(identity_pubkey)+ baked into the P2PKH script at
    #     migration time by +BSV::Wallet::Migration.expected_root_script+
    #     (single source of truth: +BSV::Script::Script.p2pkh_lock+).
    #
    # Per-wallet literal mechanism: the CHECK is wallet-specific by design —
    # cross-wallet schema dumps differ in the embedded hash. The hash is
    # public information (the wallet's root P2PKH address appears on chain),
    # so embedding it in the schema leaks nothing. WIF rotation is treated
    # as a new wallet — the CHECK is tied to the WIF for the wallet's
    # lifetime. See +docs/reference/intent-and-outcomes.md+.
    create_table(:outputs) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      foreign_key :action_id, :actions, type: :bigint, null: false, on_delete: :restrict
      column :satoshis, :bigint, null: false
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :locking_script, c[:bytea], null: false
      column :vout, :integer, null: false
      column :spendable_intent, c[:spendable_intent], null: false
      column :sender_identity_key, :text
      column :derivation_prefix, :text
      column :derivation_suffix, :text

      unique %i[action_id vout]
      # Composite-FK target: spendable(output_id, spendable_intent) →
      # outputs(id, spendable_intent). With a CHECK on +spendable+ requiring
      # +spendable_intent = 'spendable'+, an outbound output (intent='none')
      # cannot have a spendable row — declarative replacement for the
      # dropped +prevent_outbound_spendable+ trigger (no triggers on the
      # hot path; mirrors the +broadcasts(action_id, intent)+ pattern).
      unique %i[id spendable_intent]

      constraint(:satoshis_range,        'satoshis >= 0')
      constraint(:vout_range,            'vout >= 0')
      constraint(:locking_script_min,    'length(locking_script) >= 1')

      # SQLite gets a CHECK to mirror the Postgres spendable_intent ENUM.
      unless postgres
        constraint(:spendable_intent_values,
                   "spendable_intent IN ('spendable', 'none')")
      end

      # The BRC-42/BRC-29 derivation triple is set together or absent
      # together. Partial state would mean an output that claims to be
      # derived but cannot in fact be re-derived from chain artefacts.
      constraint(
        :controls_all_or_nothing,
        '(derivation_prefix IS NULL AND derivation_suffix IS NULL AND sender_identity_key IS NULL) ' \
        'OR (derivation_prefix IS NOT NULL AND derivation_suffix IS NOT NULL AND sender_identity_key IS NOT NULL)'
      )

      # Per-wallet structural recoverability CHECK with a binary literal —
      # the WIF-derived root P2PKH script bytes, populated at migration
      # time from +BSV::Wallet::Migration.expected_root_script+.
      #
      # Valid permutations (locking_script vs root, controls present,
      # spendable_intent):
      #   * root + no controls + 'spendable' — root P2PKH UTXO we own
      #   * non-root + no controls + 'none' — outbound base58 / OP_RETURN
      #   * non-root + controls + (either intent) — BRC-42 self-payment
      #     ('spendable') or BRC-29 outbound to counterparty ('none')
      #
      # Invalid (rejected):
      #   * root + controls (hash collision, ~2^-160 — treat as impossible)
      #   * root + no controls + 'none' (we own it; 'none' contradicts)
      #   * non-root + no controls + 'spendable' (no way to spend it)
      root_script_lit = Sequel.blob(BSV::Wallet::Migration.expected_root_script)
      constraint(
        :spendable_recoverable,
        Sequel.lit(
          '(locking_script = ? AND derivation_prefix IS NULL AND spendable_intent = ?) ' \
          'OR (locking_script <> ? AND derivation_prefix IS NULL AND spendable_intent = ?) ' \
          'OR (locking_script <> ? AND derivation_prefix IS NOT NULL)',
          root_script_lit, 'spendable',
          root_script_lit, 'none',
          root_script_lit
        )
      )
    end

    # 7. spendable — the UTXO set
    # action_id duplicates outputs.action_id but lifted here as a direct FK
    # so action deletion is a single statement: the action goes, every
    # spendable row dependent on it goes with it. Set once at row creation
    # and never mutated.
    # A second FK to promotions(action_id) is added at the bottom of this
    # migration — promotions doesn't exist yet at spendable creation time.
    #
    # spendable_intent denormalised here so the composite FK to
    # outputs(id, spendable_intent) + CHECK +spendable_intent = 'spendable'+
    # enforces "an outbound output cannot have a spendable row" purely
    # declaratively. Mirrors the +broadcasts(action_id, intent) →
    # actions(id, broadcast_intent)+ pattern. Replaced the trigger-based
    # +prevent_outbound_spendable+ guard (HLR #467 — no triggers on the
    # hot path).
    create_table(:spendable) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      foreign_key :output_id, :outputs, type: :bigint, null: false, unique: true
      foreign_key :action_id, :actions, type: :bigint, null: false, on_delete: :cascade
      column :spendable_intent, c[:spendable_intent], null: false, default: 'spendable'

      # Composite FK: spendable(output_id, spendable_intent) →
      # outputs(id, spendable_intent). The intent on a spendable row must
      # match the intent on its referenced outputs row — paired with the
      # CHECK below, this rejects spendable rows for 'none' outputs.
      foreign_key %i[output_id spendable_intent], :outputs,
                  key: %i[id spendable_intent]

      constraint(
        :spendable_intent_must_be_spendable,
        "spendable_intent = 'spendable'"
      )
      # SQLite ENUM-equivalent CHECK (mirrors outputs.spendable_intent_values).
      unless postgres
        constraint(:spendable_intent_values,
                   "spendable_intent IN ('spendable', 'none')")
      end
    end

    # 8. output_details — display and application metadata (1:1 sidecar)
    # No timestamps — the parent outputs row carries them.
    create_table(:output_details) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      foreign_key :output_id, :outputs, type: :bigint, null: false, unique: true
      foreign_key :action_id, :actions, type: :bigint, null: false, on_delete: :cascade
      column :change, :boolean, null: false, default: false
      column :type, :text
      column :purpose, :text
      column :provided_by, :text
      column :description, :text
      column :custom_instructions, :text
      column :script_length, :integer
      column :script_offset, :integer
    end

    # 9. output_baskets — basket membership
    create_table(:output_baskets) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      foreign_key :output_id, :outputs, type: :bigint, null: false, unique: true
      foreign_key :basket_id, :baskets, type: :bigint, null: false
      foreign_key :action_id, :actions, type: :bigint, null: false, on_delete: :cascade
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]

      index :basket_id
    end

    # 10. inputs — structural lock mechanism
    create_table(:inputs) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      foreign_key :action_id, :actions, type: :bigint, null: false, on_delete: :cascade
      foreign_key :output_id, :outputs, type: :bigint, null: false
      column :vin, :integer, null: false
      column :nsequence, :bigint, null: false, default: 4_294_967_295
      column :description, :text
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]

      unique :output_id
      unique %i[action_id vin]

      constraint(:vin_range, 'vin >= 0')
      constraint(:nsequence_range, 'nsequence BETWEEN 0 AND 4294967295')
    end

    # 11. labels — label definitions
    create_table(:labels) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      column :label, :text, null: false
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]

      unique :label, name: :labels_label_unique

      constraint(:label_length, 'length(label) BETWEEN 1 AND 300')
    end

    # 12. action_labels — join table
    create_table(:action_labels) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      foreign_key :action_id, :actions, type: :bigint, null: false, on_delete: :cascade
      foreign_key :label_id, :labels, type: :bigint, null: false
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]

      unique %i[action_id label_id]
      index :label_id
    end

    # 13. tags — tag definitions
    create_table(:tags) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      column :tag, :text, null: false
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]

      unique :tag, name: :tags_tag_unique

      constraint(:tag_length, 'length(tag) BETWEEN 1 AND 300')
    end

    # 14. output_tags — join table
    create_table(:output_tags) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      foreign_key :output_id, :outputs, type: :bigint, null: false
      foreign_key :tag_id, :tags, type: :bigint, null: false
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]

      unique %i[output_id tag_id]
      index :tag_id
    end

    # 15. certificates — identity certificates (BRC-52)
    # subject, certifier, verifier are BRC-52 identity pubkeys (compressed
    # hex, 66 chars). verifier is nullable for self-issued certificates.
    # SQLite under-enforces hex content (no portable regex in CHECKs) —
    # length + 02/03 prefix only, per project_sqlite_schema_under_enforces.
    create_table(:certificates) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      column :type, :text, null: false
      column :subject, :text
      column :serial_number, :text, null: false
      column :certifier, :text, null: false
      column :verifier, :text
      column :revocation_outpoint, :text
      column :signature, :text
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]

      unique %i[type serial_number certifier]
      index :certifier
      index :subject

      if postgres
        constraint(
          :subject_pubkey_shape,
          Sequel.lit("length(subject) = 66 AND subject ~ '^0[23][0-9a-f]{64}$'")
        )
        constraint(
          :certifier_pubkey_shape,
          Sequel.lit("length(certifier) = 66 AND certifier ~ '^0[23][0-9a-f]{64}$'")
        )
        constraint(
          :verifier_pubkey_shape,
          Sequel.lit("verifier IS NULL OR (length(verifier) = 66 AND verifier ~ '^0[23][0-9a-f]{64}$')")
        )
      else
        constraint(
          :subject_pubkey_shape,
          "length(subject) = 66 AND (substr(subject, 1, 2) = '02' OR substr(subject, 1, 2) = '03')"
        )
        constraint(
          :certifier_pubkey_shape,
          "length(certifier) = 66 AND (substr(certifier, 1, 2) = '02' OR substr(certifier, 1, 2) = '03')"
        )
        constraint(
          :verifier_pubkey_shape,
          'verifier IS NULL OR (length(verifier) = 66 AND ' \
          "(substr(verifier, 1, 2) = '02' OR substr(verifier, 1, 2) = '03'))"
        )
      end
    end

    # 16. certificate_fields — per-field encryption for selective revelation
    create_table(:certificate_fields) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      foreign_key :certificate_id, :certificates, type: :bigint, null: false, on_delete: :cascade
      column :name, :text, null: false
      column :value, :text
      column :master_key, :text
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]

      unique %i[certificate_id name]
    end

    # 17. settings — key-value wallet configuration
    create_table(:settings) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      column :key, :text, null: false, unique: true
      column :value, :text
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]
    end

    # 18. sse_cursors — Arcade SSE /events cursor persistence (#249)
    #
    # Token has no FK — it is a wallet-derived identifier (HMAC-from-WIF
    # via BSV::Wallet::CallbackToken#derive) that the wallet supplies to
    # Arcade for callback scoping, not a row in any other wallet table.
    # last_event_id is the SSE id field, a nanosecond timestamp emitted by
    # Arcade (PR #50): bigint accommodates the full 19-digit value.
    # No created_at — only the last-update time matters for cursor state.
    create_table(:sse_cursors) do
      column :token, :text, primary_key: true
      column :last_event_id, :bigint, null: false
      column :updated_at, c[:timestamptz], null: false, default: c[:now]
    end

    # 19. promotions — promote-authorisation as a FK row (#307 / ADR-022 / ADR-023)
    #
    # A promotions row means "this action's outputs are canonical". It is gated:
    #   - intent tracks the parent action (composite FK to actions(id, broadcast_intent)),
    #     exactly as broadcasts.intent does (ADR-019).
    #   - authorising_status names the broadcast tx_status that authorised a
    #     send-path promotion; NULL on the internal path.
    #   - promo_path CHECK (inline): internal => no status; send => a status.
    #   - auth_not_rejected CHECK (inline): a present status is in the optimistic set
    #     (anything except REJECTED / DOUBLE_SPEND_ATTEMPTED).
    #   - composite FK (action_id, authorising_status) → broadcasts(action_id, tx_status)
    #     ON UPDATE CASCADE: a send promotion can exist only while its broadcast is
    #     in a non-rejected status (NULL skips the FK; MATCH SIMPLE — internal path
    #     needs no broadcast). The cascade keeps authorising_status synced as
    #     tx_status advances; a flip to REJECTED requires deleting the promotions
    #     row first, else the cascade would hit auth_not_rejected.
    #
    # Created after actions and broadcasts so the composite FK targets exist.
    # Postgres uses raw SQL so the named CHECK and composite FK constraint
    # naming come out exactly as designed; SQLite uses the Sequel API path.
    if postgres
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
    else
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
    end

    # 20. transmissions — wallet→peer BEEF delivery, per (action × counterparty)
    #     (#385 / ADR-025). The wallet's first per-counterparty persistent state.
    #     Delivery status is DERIVED, not stored: a present acked_at means the
    #     peer acknowledged internalisation — no status column (principle of state).
    #
    #     The ack_signature column is reserved nullable from day 1: v1 ACK is a
    #     bare HTTP 200, so it stays NULL; the Phase 2 signed-ACK protocol writes
    #     into it without a schema migration.
    #
    #     counterparty is a BRC-43 identity pubkey (compressed hex, 66 chars).
    #     Identity-shaped pubkeys stay hex (the pubkey-hex carve-out in CLAUDE.md).
    create_table(:transmissions) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      foreign_key :action_id, :actions, type: :bigint, null: false, on_delete: :cascade
      column :counterparty, :text, null: false
      column :acked_at, c[:timestamptz]
      # Phase 2 slot: peer-signed ACK over the wtxid, recorded alongside acked_at
      # when the signed-ACK protocol lands. NULL means a v1 HTTP-200 ACK (or no
      # ACK yet); see HLR #385 phasing.
      column :ack_signature, c[:bytea]
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]

      # Grain: one row per (action, peer); re-transmit upserts in place.
      unique %i[action_id counterparty]
      # Composite index drives the known-set union query (filter on
      # counterparty, then JOIN transmission_txids by id) without a
      # sequential scan as the table grows.
      index %i[counterparty id]

      if postgres
        constraint(
          :counterparty_shape,
          Sequel.lit("length(counterparty) = 66 AND counterparty ~ '^0[23][0-9a-f]{64}$'")
        )
      else
        constraint(
          :counterparty_shape,
          "length(counterparty) = 66 AND (substr(counterparty, 1, 2) = '02' OR substr(counterparty, 1, 2) = '03')"
        )
      end
    end

    # 21. transmission_txids — pure membership: which wtxids each transmission's
    #     BEEF carried, so a later transmission to the same counterparty trims
    #     (BeefParty) to only what the peer lacks. The per-counterparty known
    #     set is the union of these rows across all of that peer's
    #     transmissions. wtxid stays binary (wire-order), per the
    #     wtxid/dtxid convention.
    #
    #     Two-phase write (HLR #385, Crypto + Security gate): rows are populated
    #     only in Store#mark_transmission_acked, never at record_transmission
    #     time — recording a wtxid the peer never received would over-trim a
    #     future BEEF into unverifiability.
    create_table(:transmission_txids) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      foreign_key :transmission_id, :transmissions, type: :bigint, null: false, on_delete: :cascade
      column :wtxid, c[:bytea], null: false

      unique %i[transmission_id wtxid]

      constraint(:wtxid_length, 'length(wtxid) = 32')
    end

    # spendable's second FK: action_id → promotions(action_id) ON DELETE CASCADE.
    # Lives here at the bottom because promotions doesn't exist at spendable
    # creation time. The double-FK on spendable.action_id means UTXO-set
    # membership cannot exist without authorisation, AND reject/reorg teardown
    # collapses to a single DELETE FROM promotions that cascades through.
    if postgres
      run <<~SQL
        ALTER TABLE spendable
          ADD CONSTRAINT spendable_promotion_fkey
          FOREIGN KEY (action_id) REFERENCES promotions (action_id) ON DELETE CASCADE
      SQL
    else
      alter_table(:spendable) do
        add_foreign_key [:action_id], :promotions, key: [:action_id], on_delete: :cascade
      end
    end
  end

  down do
    postgres = database_type == :postgres

    # Drop in dependency-respecting order — children before parents.
    # spendable carries spendable_promotion_fkey → promotions, so spendable
    # must go before promotions.
    drop_table :transmission_txids, :transmissions,
               :spendable, :promotions,
               :sse_cursors, :settings, :certificate_fields, :certificates,
               :output_tags, :tags, :action_labels, :labels, :inputs,
               :output_baskets, :output_details, :outputs,
               :baskets, :broadcasts, :actions, :tx_proofs, :blocks

    if postgres
      extension :pg_enum
      drop_enum(:spendable_intent)
      drop_enum(:tx_status)
      drop_enum(:broadcast_intent)
    end
  end
end
