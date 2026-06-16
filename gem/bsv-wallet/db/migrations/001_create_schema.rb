# frozen_string_literal: true

# Final schema structure: every table in its end-state shape, including the two
# tables added post-001 (sse_cursors #249, promotions #307 / ADR-022 / ADR-023)
# and the SEEN_MULTIPLE_NODES tx_status value (#011 folded inline).
#
# Pre-release "amend in place" policy (#353): migrations express the canonical
# structure rather than its change history. CHECKs, NOT NULLs, and triggers
# remain in 003; the denormalised action_id cascade FKs remain in 002.
#
# Guard convention:
#   postgres = database_type == :postgres
#   c[:type]  — column type map (Postgres-native, SQLite equivalent)
#   Two-line PK: Postgres BIGINT IDENTITY, SQLite autoincrement

Sequel.migration do
  up do
    postgres = database_type == :postgres

    c = {}
    c[:bytea] = postgres ? :bytea : :blob
    c[:timestamptz] = postgres ? :timestamptz : :datetime
    c[:broadcast_intent] = postgres ? :broadcast_intent : :text
    c[:tx_status] = postgres ? :tx_status : :text
    c[:output_type] = postgres ? :output_type : :text
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
      create_enum(:output_type, %w[root outbound])
    end

    # 1. blocks — known block headers (chain tracker's local view)
    create_table(:blocks) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      column :height, :integer, null: false, unique: true
      column :merkle_root, c[:bytea], null: false
      column :block_hash, c[:bytea]
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]
    end

    # 2. tx_proofs — merkle inclusion proofs (settlement evidence)
    create_table(:tx_proofs) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      column :wtxid, c[:bytea], null: false, unique: true
      foreign_key :block_id, :blocks, type: :bigint
      column :block_index, :integer
      column :merkle_path, c[:bytea]
      column :raw_tx, c[:bytea]
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]
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
        column :reference, :uuid, unique: true, default: Sequel.function(:uuidv7)
      else
        column :reference, :text, unique: true
      end
      column :description, :text
      column :broadcast_intent, c[:broadcast_intent], null: false, default: 'delayed'
      column :raw_tx, c[:bytea]
      column :input_beef, c[:bytea]
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]

      index :wtxid, unique: true, where: Sequel.lit('wtxid IS NOT NULL')
      index :broadcast_intent

      # Composite FK target: broadcasts(action_id, intent) → actions(id, broadcast_intent)
      # makes broadcasts.intent track actions.broadcast_intent atomically (#221).
      unique %i[id broadcast_intent]
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
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]
      column :retry_count, :integer, null: false, default: 0
      column :provider, :text

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
    end

    # 5. baskets — output grouping with replenishment policy
    create_table(:baskets) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      column :name, :text, null: false
      column :target_count, :integer
      column :target_value, :integer
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]

      unique :name, name: :baskets_name_unique
    end

    # 6. outputs — immutable append-only log
    create_table(:outputs) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      foreign_key :action_id, :actions, type: :bigint, null: false, on_delete: :restrict
      column :satoshis, :bigint, null: false
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :locking_script, c[:bytea]
      column :vout, :integer, null: false
      column :sender_identity_key, :text
      column :derivation_prefix, :text
      column :derivation_suffix, :text
      column :output_type, c[:output_type]

      unique %i[action_id vout]
    end

    # 7. spendable — the UTXO set
    create_table(:spendable) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      foreign_key :output_id, :outputs, type: :bigint, null: false, unique: true
    end

    # 8. output_details — display and application metadata
    create_table(:output_details) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      foreign_key :output_id, :outputs, type: :bigint, null: false, unique: true
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
    end

    # 11. labels — label definitions
    create_table(:labels) do
      column :id, :bigint, primary_key: true, identity: :always if postgres
      primary_key :id if !postgres
      column :label, :text, null: false
      column :created_at, c[:timestamptz], null: false, default: c[:now]
      column :updated_at, c[:timestamptz], null: false, default: c[:now]

      unique :label, name: :labels_label_unique
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
    # via +BSV::Wallet::CallbackToken#derive+) that the wallet supplies to
    # Arcade for callback scoping, not a row in any other wallet table.
    # last_event_id is the SSE id field, a nanosecond timestamp emitted by
    # Arcade (PR #50): bigint accommodates the full 19-digit value.
    create_table(:sse_cursors) do
      String :token, primary_key: true
      Bignum :last_event_id, null: false
      column :updated_at, c[:timestamptz], null: false, default: c[:now]
    end

    # 19. promotions — promote-authorisation as a FK row (#307 / ADR-022 / ADR-023)
    #
    # A promotions row means "this action's outputs are canonical". It is gated:
    #   - intent tracks the parent action (composite FK to actions(id, broadcast_intent)),
    #     exactly as broadcasts.intent does (ADR-019).
    #   - authorising_status names the broadcast tx_status that authorised a
    #     send-path promotion; NULL on the internal path.
    #   - promo_path CHECK (003): internal => no status; send => a status.
    #   - auth_not_rejected CHECK (003): a present status is in the optimistic set
    #     (anything except REJECTED / DOUBLE_SPEND_ATTEMPTED).
    #   - composite FK (action_id, authorising_status) → broadcasts(action_id, tx_status)
    #     ON UPDATE CASCADE: a send promotion can exist only while its broadcast is
    #     in a non-rejected status (NULL skips the FK; MATCH SIMPLE — internal path
    #     needs no broadcast). The cascade keeps authorising_status synced as
    #     tx_status advances; a flip to REJECTED requires deleting the promotions
    #     row first, else the cascade would hit auth_not_rejected.
    #
    # Created after actions and broadcasts so the composite FK targets exist.
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
  end

  down do
    postgres = database_type == :postgres

    drop_table :promotions, :sse_cursors, :settings, :certificate_fields, :certificates,
               :output_tags, :tags, :action_labels, :labels, :inputs,
               :output_baskets, :output_details, :spendable, :outputs,
               :baskets, :broadcasts, :actions, :tx_proofs, :blocks

    if postgres
      extension :pg_enum
      drop_enum(:output_type)
      drop_enum(:tx_status)
      drop_enum(:broadcast_intent)
    end
  end
end
