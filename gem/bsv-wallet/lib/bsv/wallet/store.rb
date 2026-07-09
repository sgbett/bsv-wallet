# frozen_string_literal: true

require 'json'

# Store is currently used synchronously: callers (CLI tools, the Engine,
# and the daemon's worker fibers) issue a method call and wait for the
# result before continuing. Sequel's pool is keyed on whatever
# +Sequel.current+ returns -- Thread.current by default, Fiber.current
# when the +fiber_concurrency+ extension is enabled.
#
# Walletd (bin/walletd) enables +Sequel.extension :fiber_concurrency+
# because it runs many Async fibers on one reactor thread. CLI tools
# do not (one thread, one root fiber -- functionally identical, YAGNI).
#
# If a future change introduces fiber-based async access to Store
# (e.g. an OMQ-fronted PUSH/PULL queue for eventual-consistency writes,
# or any +task.async do+ that ends up calling Store methods), the
# calling process must enable +Sequel.extension :fiber_concurrency+
# *and* size the pool for the expected concurrent fiber count. See
# bin/walletd for the pattern and #268 for the bug that scoping
# prevents (concurrent fibers on a shared connection corrupt PG
# result state -- "undefined method 'nfields' for nil").

using BSV::Wallet::Txid

module BSV
  module Wallet
    # SQL-backed persistence for the wallet.
    #
    # Abstract base class. Concrete implementations (SQLite, Postgres)
    # provide database-specific configuration and input-locking semantics.
    #
    # Usage:
    #   store = BSV::Wallet::Store.connect('sqlite://wallet.db')
    #   store.migrate!
    #   store.create_action(action: { description: 'payment' })
    class Store
      include BSV::Wallet::Interface::Store

      attr_reader :db, :identity_pubkey_hash

      # Factory: return a SQLite or Postgres instance based on the URL.
      #
      # @param url [String] database URL (sqlite:// or postgres://)
      # @param identity_pubkey_hash [String, nil] 20-byte +hash160+ of the
      #   wallet's identity pubkey. Required to migrate (the per-wallet
      #   +outputs.spendable_recoverable+ CHECK embeds the WIF-derived
      #   root P2PKH script as a literal — HLR #467). Reading specs that
      #   never call +#migrate!+ may pass +nil+.
      # @param db_opts [Hash] extra options passed through to
      #   +Sequel.connect+. CLI tools omit this (Sequel default pool
      #   suffices for single-process, single-fiber use). The walletd
      #   daemon supplies +max_connections+ sized for its concurrent
      #   fiber inventory after enabling +Sequel.extension(:fiber_concurrency)+.
      #   See #268 + bin/walletd.
      # @return [BSV::Wallet::Store::SQLite, BSV::Wallet::Store::Postgres]
      def self.connect(url, identity_pubkey_hash: nil, **db_opts)
        klass = url.to_s.downcase.start_with?('postgres') ? Postgres : SQLite
        klass.new(url: url, identity_pubkey_hash: identity_pubkey_hash, db_opts: db_opts)
      end

      def initialize(url: nil, db: nil, identity_pubkey_hash: nil, db_opts: {})
        @db = db || Sequel.connect(url, **db_opts)
        @identity_pubkey_hash = identity_pubkey_hash
        # Set global so Sequel::Model(:table_name) calls in model class
        # bodies can resolve the database during autoload.
        Sequel::Model.db = @db
        configure_db
      end

      # Database-specific setup (PRAGMAs, extensions). Subclasses override.
      def configure_db
        raise NotImplementedError
      end

      # Run pending migrations against this wallet's database. Populates
      # +BSV::Wallet::Migration.identity_pubkey_hash+ (and the matching
      # +models::Output.expected_root_script+ class accessor) from
      # +@identity_pubkey_hash+ so the per-wallet
      # +outputs.spendable_recoverable+ CHECK literal can be built at
      # +CREATE TABLE+ time. Resets the global in +ensure+ — the migrator
      # is the only consumer of the global, and a leaked value across
      # wallets would silently mis-bake the next wallet's schema.
      def migrate!(target: nil)
        Sequel.extension :migration
        migrations_path = File.expand_path('../../../db/migrations', __dir__)
        # Capture so we can restore on failure — leaving a partially-migrated
        # wallet's hash in the class accessor would silently poison validators
        # for whatever wallet runs next in the same process.
        prior_expected_root_script = models::Output.expected_root_script
        if @identity_pubkey_hash
          BSV::Wallet::Migration.identity_pubkey_hash = @identity_pubkey_hash
          models::Output.expected_root_script = BSV::Wallet::Migration.expected_root_script
        end
        Sequel::Migrator.run(@db, migrations_path, target: target)
        bind_models!
      rescue StandardError
        models::Output.expected_root_script = prior_expected_root_script
        raise
      ensure
        BSV::Wallet::Migration.identity_pubkey_hash = nil
      end

      # Verify the per-wallet +outputs.spendable_recoverable+ CHECK literal
      # in the database matches the expected root P2PKH script for the WIF
      # currently driving this wallet (HLR #467). Catches schema drift,
      # restore-to-wrong-DB, and WIF rotation — any of which would let
      # the wallet sign spends against a CHECK that no longer mirrors
      # its identity.
      #
      # No-op on SQLite (pragma_check / sqlite_master parsing isn't
      # round-trip stable across versions; the SQLite path is for fast
      # logic-only specs that don't exercise the per-wallet CHECK).
      #
      # @raise [BSV::Wallet::SchemaIntegrityError] when the literal does
      #   not match +identity_pubkey_hash+ or cannot be located.
      def verify_schema!
        return unless @db.database_type == :postgres
        raise BSV::Wallet::SchemaIntegrityError, 'identity_pubkey_hash not set' unless @identity_pubkey_hash

        expected = BSV::Script::Script.p2pkh_lock(@identity_pubkey_hash).to_binary
        expected_hex = expected.unpack1('H*')

        # pg_get_constraintdef formats the literal as +'\\x76a914...88ac'::bytea+
        # inside the CHECK expression. Substring match avoids brittleness
        # around quoting variations across PG versions.
        defn = @db.fetch(
          'SELECT pg_get_constraintdef(oid) AS def FROM pg_constraint ' \
          "WHERE conname = 'spendable_recoverable' AND conrelid = 'outputs'::regclass"
        ).first
        raise BSV::Wallet::SchemaIntegrityError, 'spendable_recoverable CHECK not found' unless defn

        return if defn[:def].include?(expected_hex)

        raise BSV::Wallet::SchemaIntegrityError,
              'spendable_recoverable CHECK literal does not match wallet identity ' \
              "(expected hex=#{expected_hex})"
      end

      # Verify the running binary's +VERIFIER_VERSION+ is not older than the
      # highest version stamped into +tx_proofs+ (ADR-033 / HLR #516).
      # A downgraded binary that trusted higher-version rows would honour
      # entries produced under logic it can no longer reproduce.
      #
      # @raise [BSV::Wallet::SchemaIntegrityError] when the code's version
      #   is lower than +MAX(tx_proofs.verifier_version)+
      def verify_verifier_version!
        seen = max_verifier_version_seen
        return unless seen && seen > BSV::Wallet::VERIFIER_VERSION

        raise BSV::Wallet::SchemaIntegrityError,
              "wallet requires VERIFIER_VERSION >= #{seen}, " \
              "code is at #{BSV::Wallet::VERIFIER_VERSION} — downgrade refused"
      end

      def disconnect
        @db&.disconnect
        @db = nil
      end

      # --- Action Lifecycle ---

      def create_action(action:, inputs: [])
        @db.transaction do
          record = models::Action.create(
            description: action[:description],
            broadcast_intent: action[:broadcast_intent]&.to_s || 'delayed',
            input_beef: action[:input_beef]
          )

          raise Sequel::Rollback if inputs.any? && !lock_inputs_atomic?(action_id: record.id, inputs: inputs)

          action_to_hash(record)
        end
      end

      def lock_inputs(action_id:, inputs:)
        return 0 if inputs.empty?

        @db.transaction do
          raise Sequel::Rollback unless lock_inputs_atomic?(action_id: action_id, inputs: inputs)

          inputs.size
        end || 0
      end

      def sign_action(action_id:, wtxid:, raw_tx:, outputs: [], change_outputs: [])
        BSV::Primitives::Hex.validate_wtxid!(wtxid, name: 'sign_action wtxid')
        BSV.logger&.debug { "[Store] sign_action: action_id=#{action_id} dtxid=#{wtxid.to_dtxid}" }
        @db.transaction do
          write_signing_artifacts(action_id: action_id, wtxid: wtxid, raw_tx: raw_tx)

          intent = models::Action.where(id: action_id).get(:broadcast_intent)
          # broadcasts.(action_id, intent) → actions(id, broadcast_intent) composite FK +
          # CHECK intent != 'none' (#198/#221) — the intent column lets the FK tie
          # the broadcast row to its parent action's intent atomically.
          if intent && intent != 'none'
            models::Broadcast.dataset.insert_conflict(target: :action_id).insert(
              action_id: action_id, intent: intent
            )
          end

          # Send-path outputs are plain INSERTs (no promotions row yet).
          # spendable rows deferred until Phase 4 (broadcast acceptance). Internal-path
          # callers pass an empty outputs array and reach the canonical UTXO
          # set via promote_action; change_outputs follow the same lifecycle
          # as the action's broadcast intent.
          write_pending_outputs(action_id: action_id, outputs: outputs)
          write_change_outputs(action_id: action_id, change_outputs: change_outputs)
        end
      end

      # Atomically complete an internal (+no_send+) action in one transition:
      # sign, save its proof, promote its outputs, and make change spendable —
      # so a crash can never strand a signed-but-unpromoted internal action
      # (#327) or a promoted action with unspendable change (#328).
      #
      # Composes the existing per-step methods inside a single +db.transaction+;
      # their own +@db.transaction+ blocks flatten into this one (Sequel reuses
      # the open transaction), so it is all commit-or-rollback together. This is
      # the same proven pattern +Engine#import_utxo+ Phase 1 uses inline — lifted
      # into Store so atomicity lives here, not in the Engine.
      #
      # @param action_id [Integer]
      # @param wtxid [String] 32-byte wire-order wtxid
      # @param raw_tx [String] signed raw transaction binary
      # @param sign_outputs [Array<Hash>] outputs for +sign_action+ (empty on the
      #   internal path — real outputs are promoted, not staged)
      # @param change_outputs [Array<Hash>] change outputs for +sign_action+
      # @param promote_outputs [Array<Hash>] output specs to promote
      def complete_internal_action(action_id:, wtxid:, raw_tx:,
                                   sign_outputs:, change_outputs:, promote_outputs:)
        @db.transaction do
          sign_action(action_id: action_id, wtxid: wtxid, raw_tx: raw_tx,
                      outputs: sign_outputs, change_outputs: change_outputs)
          save_proof(wtxid: wtxid, proof: { raw_tx: raw_tx })
          promote_action(action_id: action_id, outputs: promote_outputs) if promote_outputs.any?
          promote_change_to_spendable(action_id: action_id) if change_outputs.any?
        end
      end

      def stage_action(action_id:, wtxid:, raw_tx:, outputs: [])
        BSV::Primitives::Hex.validate_wtxid!(wtxid, name: 'stage_action wtxid')
        BSV.logger&.debug { "[Store] stage_action: action_id=#{action_id} dtxid=#{wtxid.to_dtxid}" }
        @db.transaction do
          write_signing_artifacts(action_id: action_id, wtxid: wtxid, raw_tx: raw_tx)
          # Deferred-path outputs persisted as plain INSERTs (no promotions row). The BRC-100
          # signAction call later updates raw_tx + wtxid but doesn't reach
          # the outputs again; their metadata must live in the row from now on.
          write_pending_outputs(action_id: action_id, outputs: outputs)
        end
      end

      # Internal-path Phase 4: write outputs as already promoted, insert
      # spendable rows in the same transaction. Used by incoming actions
      # (internalize_action, import_utxo, wbikd) where broadcast_intent == 'none'
      # — outputs join the canonical UTXO set immediately.
      def promote_action(action_id:, outputs:)
        @db.transaction do
          # The promotions row (the canonical-state fact) must exist before any
          # spendable row — spendable.action_id is FK'd to promotions. Internal
          # path: intent='none', no authorising broadcast status.
          record_promotion(action_id: action_id, authorising_status: nil)

          outputs.map do |out|
            intent = out[:spendable_intent].to_s
            output = create_output_or_translate(
              action_id: action_id,
              satoshis: out[:satoshis],
              vout: out[:vout],
              locking_script: out[:locking_script],
              spendable_intent: intent,
              derivation_prefix: out[:derivation_prefix],
              derivation_suffix: out[:derivation_suffix],
              sender_identity_key: out[:sender_identity_key]
            )

            # INSERT … ON CONFLICT (output_id) DO NOTHING — idempotent / concurrency-safe.
            # 'spendable' intent → row joins the UTXO set; 'none' → outbound,
            # no spendable row (declarative composite-FK + CHECK on +spendable+
            # would reject one anyway — HLR #467).
            if intent == 'spendable'
              models::Spendable.dataset.insert_conflict(target: :output_id).insert(
                output_id: output.id, action_id: action_id, spendable_intent: 'spendable'
              )
            end

            write_output_associations(output: output, action_id: action_id, spec: out)

            output.id
          end
        end
      end

      # Send-path Phase 4: record the promotions row (the canonical-state fact)
      # and insert spendable rows for wallet-owned outputs. Called when the
      # broadcast is accepted (inline or via the daemon) with the authorising
      # tx_status. Idempotent — a second invocation finds the promotions row
      # present and is a no-op. The promotions row's composite FK to
      # broadcasts(action_id, tx_status) means it can only be created while the
      # broadcast holds that (non-rejected) status.
      def promote_action_outputs(action_id:, authorising_status:)
        @db.transaction do
          return [] if models::Promotion.where(action_id: action_id).any?

          record_promotion(action_id: action_id, authorising_status: authorising_status)

          promoted = []
          models::Output.where(action_id: action_id).all.each do |output|
            next unless output.spendable_intent.to_s == 'spendable'

            # INSERT … ON CONFLICT (output_id) DO NOTHING: concurrent Phase-4
            # promotion (duplicate ARC events / poll + SSE) is a no-op, not a
            # unique violation.
            models::Spendable.dataset.insert_conflict(target: :output_id).insert(
              output_id: output.id, action_id: action_id, spendable_intent: 'spendable'
            )
            promoted << output.id
          end
          promoted
        end
      end

      def link_proof(action_id:, tx_proof_id:)
        models::Action.where(id: action_id).update(tx_proof_id: tx_proof_id)
      end

      # --- Transmissions (wallet→peer BEEF delivery, #385 / ADR-025) ---

      # Record that +action_id+'s BEEF was (or is being) transmitted to
      # +counterparty+. Idempotent and concurrency-safe at grain (action,
      # peer) via +INSERT ... ON CONFLICT DO UPDATE RETURNING id+: a
      # re-transmit refreshes +updated_at+ and returns the same row.
      #
      # NOTE: this does NOT write +transmission_txids+ rows. The known-set
      # is written only on ack (+mark_transmission_acked+) — recording
      # wtxids the peer never received would over-trim a future BEEF into
      # unverifiability (HLR #385 two-phase gate).
      #
      # @param action_id [Integer]
      # @param counterparty [String] BRC-43 identity pubkey (66-char hex)
      # @return [Integer] transmission id
      def record_transmission(action_id:, counterparty:)
        now = Time.now
        rows = models::Transmission.dataset
                                   .insert_conflict(
                                     target: %i[action_id counterparty],
                                     update: { updated_at: Sequel[:excluded][:updated_at] }
                                   )
                                   .returning(:id)
                                   .insert(action_id: action_id, counterparty: counterparty,
                                           created_at: now, updated_at: now)
        rows.first[:id]
      end

      # The set of wtxids +counterparty+ has acknowledged across every
      # transmission to them — the BeefParty known set for trimming the
      # next BEEF. Wire-order binary wtxids; deduplicated across
      # transmissions.
      #
      # @param counterparty [String] BRC-43 identity pubkey (66-char hex)
      # @return [Array<String>] wire-order binary wtxids
      def transmission_known_wtxids(counterparty:)
        models::TransmissionTxid
          .join(:transmissions, id: :transmission_id)
          .where(Sequel[:transmissions][:counterparty] => counterparty)
          .distinct
          .select_map(Sequel[:transmission_txids][:wtxid])
      end

      # Mark a transmission acknowledged by the peer and record the
      # wtxids that the BEEF carried (the known-set, written here and
      # only here — two-phase, HLR #385). Idempotent: re-ack updates
      # +acked_at+ and adds only wtxids not already recorded.
      #
      # Returns the transmission id, or +nil+ when no matching row
      # exists for (action_id, counterparty).
      #
      # @param action_id [Integer]
      # @param counterparty [String] BRC-43 identity pubkey (66-char hex)
      # @param wtxids [Array<String>] wire-order binary wtxids carried by the BEEF
      # @param acked_at [Time] ack timestamp
      # @return [Integer, nil]
      def mark_transmission_acked(action_id:, counterparty:, wtxids: [], acked_at: Time.now)
        @db.transaction do
          row = models::Transmission.first(action_id: action_id, counterparty: counterparty)
          next nil unless row

          row.update(acked_at: acked_at)

          if wtxids.any?
            # Batch INSERT ... ON CONFLICT (transmission_id, wtxid) DO NOTHING
            # — one statement, dedup'd at the schema (no N+1). Frozen-string
            # safety: wrap each wtxid in a fresh Sequel.blob.
            rows = wtxids.map { |wtxid| { transmission_id: row.id, wtxid: Sequel.blob(wtxid) } }
            models::TransmissionTxid.dataset
                                    .insert_conflict(target: %i[transmission_id wtxid])
                                    .multi_insert(rows)
          end

          row.id
        end
      end

      def abort_action(action_id:)
        @db.transaction do
          broadcast_exists = models::Broadcast.where(action_id: action_id).any?
          return 0 if broadcast_exists

          # Refuse if the action is promoted (has a promotions row). Internal-
          # path actions (broadcast_intent = 'none') legitimately have no
          # broadcasts row but are promoted at create_action time and may be
          # spendable / spent — deleting them would destroy canonical UTXO
          # history. abortAction is meant for unfinished work, not for
          # rewinding already-committed actions.
          if models::Promotion.where(action_id: action_id).any?
            raise BSV::Wallet::CannotAbortPromotedActionError,
                  "action_id=#{action_id} is promoted; abort refused"
          end

          # outputs.action_id is RESTRICT (#189). The deferred-sign path
          # writes outputs as promoted: false at stage_action time; aborting
          # such an action must clear those rows first.
          output_ids = models::Output.where(action_id: action_id).select_map(:id)
          if output_ids.any?
            models::OutputBasket.where(action_id: action_id).delete
            models::OutputDetail.where(action_id: action_id).delete
            models::OutputTag.where(output_id: output_ids).delete
            models::Output.where(id: output_ids).delete
          end
          models::Action.where(id: action_id).delete
        end
      end

      # Unwind a broadcast action whose network outcome was terminal-
      # rejected. Speculatively-promoted outputs (the wallet's optimistic
      # bet on a non-rejected ARC response) get rolled back along with
      # every dependent — and cascades forward through any child action
      # that consumed this action's outputs, recursively.
      #
      # Single outer transaction. Children are torn down before the
      # parent so outputs.action_id RESTRICT doesn't block the parent's
      # output deletes (a child's input row references this action's
      # output; deleting the output requires the input gone first, which
      # happens when the child's action_id CASCADE-deletes its inputs).
      #
      # Raises CannotRejectInternalActionError if the target — or any
      # cascade descendant — has broadcast_intent='none'. Internal-path
      # actions produce canonical wallet state and are not the domain of
      # this method; encountering one mid-cascade means an invariant was
      # violated upstream. Rollback leaves the broadcasts row intact for
      # the resolution loop to discover next cycle.
      #
      # Idempotent: calling on an already-deleted action_id is a no-op.
      def reject_action(action_id:)
        @db.transaction do
          do_reject(action_id, visited: Set.new)
        end
      end

      # Return action_ids of every action whose inputs spend an output
      # of +action_id+. The forward-walk for reject_action's cascade.
      def child_actions_of(action_id:)
        output_ids = models::Output.where(action_id: action_id).select(:id)
        models::Input.where(output_id: output_ids).distinct.select_map(:action_id)
      end

      # --- Queries ---

      def find_output(id:)
        record = models::Output[id]
        return unless record

        {
          id: record.id, action_id: record.action_id,
          satoshis: record.satoshis, vout: record.vout,
          locking_script: record.locking_script,
          spendable_intent: record.spendable_intent,
          derivation_prefix: record.derivation_prefix,
          derivation_suffix: record.derivation_suffix,
          sender_identity_key: record.sender_identity_key
        }
      end

      def find_action(id: nil, wtxid: nil, reference: nil)
        BSV::Primitives::Hex.validate_wtxid!(wtxid, name: 'find_action wtxid') if wtxid
        record = if id then models::Action[id]
                 elsif wtxid then models::Action.first(wtxid: Sequel.blob(wtxid))
                 elsif reference then models::Action.first(reference: reference)
                 end
        return unless record

        action_to_hash(record)
      end

      def query_actions(labels:, label_query_mode: :any, limit: 10, offset: 0,
                        include_labels: false, include_inputs: false,
                        include_input_locking_scripts: false,
                        include_input_unlocking_scripts: false, # rubocop:disable Lint/UnusedMethodArgument
                        include_outputs: false, include_output_locking_scripts: false)
        label_ids = models::Label.where(label: labels).select_map(:id)
        return { total: 0, actions: [] } if label_ids.empty?

        base = models::Action
               .join(:action_labels, action_id: :id)
               .where(Sequel[:action_labels][:label_id] => label_ids)
               .select_all(:actions)

        base = if label_query_mode == :all
                 base
                   .group(Sequel[:actions][:id])
                   .having { count(Sequel.function(:distinct, Sequel[:action_labels][:label_id])) >= label_ids.size }
               else
                 base.distinct
               end

        total = base.count
        records = base
                  .order(Sequel.desc(Sequel[:actions][:created_at]))
                  .limit(limit).offset(offset).all

        actions = records.map do |row|
          a = row.is_a?(models::Action) ? row : models::Action[row[:id]]
          action_to_hash(a,
                         include_labels: include_labels,
                         include_inputs: include_inputs,
                         include_input_locking_scripts: include_input_locking_scripts,
                         include_outputs: include_outputs,
                         include_output_locking_scripts: include_output_locking_scripts)
        end

        { total: total, actions: actions }
      end

      # Sentinel for "basket filter not applied". Distinct from +nil+, which
      # means "outputs with no basket row" (the spec's unbasketed-outputs
      # semantics). Distinct from any String, which names a basket.
      BASKET_UNSPECIFIED = Object.new.freeze
      private_constant :BASKET_UNSPECIFIED

      # Query spendable outputs with optional filters and aggregation.
      #
      # @param basket [String, Array<String>, nil, omitted]
      #   - omitted (default) → no basket filter; all spendable outputs match.
      #   - +String+           → outputs in that named basket.
      #   - +Array<String>+    → outputs in any of the named baskets.
      #   - +nil+              → outputs with no +output_baskets+ row (unbasketed).
      # @param aggregate [:sum, :count, nil]
      #   - +nil+ (default) → returns +{ total:, outputs: }+ (paginated rows + match count).
      #   - +:sum+          → returns Integer (sum of +satoshis+ over matched outputs).
      #   - +:count+        → returns Integer (count of matched outputs).
      def query_outputs(basket: BASKET_UNSPECIFIED, tags: nil, tag_query_mode: :any,
                        aggregate: nil,
                        limit: 10, offset: 0,
                        include_locking_scripts: false,
                        include_custom_instructions: false,
                        include_tags: false, include_labels: false)
        base = models::Output.spendable
        base = base.in_basket(basket) unless basket.equal?(BASKET_UNSPECIFIED)

        if tags&.any?
          tag_ids = models::Tag.where(tag: tags).select_map(:id)
          unless tag_ids.empty?
            tag_ds = models::OutputTag.dataset
                                      .where(tag_id: tag_ids)
                                      .where(Sequel[:output_tags][:output_id] => Sequel[:outputs][:id])
                                      .select(1)

            base = if tag_query_mode == :all
                     base.where(
                       tag_ds
                         .group(Sequel[:output_tags][:output_id])
                         .having { count(Sequel.function(:distinct, Sequel[:output_tags][:tag_id])) >= tag_ids.size }
                         .exists
                     )
                   else
                     base.where(tag_ds.exists)
                   end
          end
        end

        case aggregate
        when :sum
          return (base.sum(:satoshis) || 0).to_i
        when :count
          return base.count
        when nil
          # fall through to the paginated rows-and-total return
        else
          raise ArgumentError, "unknown aggregate: #{aggregate.inspect} (expected :sum, :count, or nil)"
        end

        total = base.count
        records = base.order(Sequel.desc(:created_at)).limit(limit).offset(offset).all

        outputs = records.map do |o|
          output_to_hash(o,
                         include_locking_scripts: include_locking_scripts,
                         include_custom_instructions: include_custom_instructions,
                         include_tags: include_tags,
                         include_labels: include_labels)
        end

        { total: total, outputs: outputs }
      end

      def pending_proofs(limit: 100)
        # broadcast_intent != 'none' is the "outgoing/broadcastable" predicate
        # (every internal action is 'none'); the sibling reap query selects the
        # same set the same way. The dropped outgoing column added nothing here.
        models::Action
          .where(Sequel.~(wtxid: nil))
          .where(tx_proof_id: nil)
          .where(Sequel.~(broadcast_intent: 'none'))
          .limit(limit)
          .all
          .map { |a| action_to_hash(a) }
      end

      def relinquish_output(output_id:)
        @db.transaction do
          models::Spendable.where(output_id: output_id).delete
          models::OutputBasket.where(output_id: output_id).delete
        end
      end

      # Snapshot of "would dropping this DB destroy on-chain-anchored state?"
      #
      # Returns a {SweepableState} carrying +at_risk_outputs+ (count of
      # spendable derived outputs whose action has been signed and
      # broadcast) and +at_risk_actions+ (distinct actions owning them).
      # +clean?+ is true iff +at_risk_outputs+ is zero. Consult before
      # any destructive operation (DB drop, blank-slate reset, spec
      # setup recreation, future +bsv-wallet destroy+ CLI). HLR #448.
      #
      # The query intentionally excludes:
      #   * Root outputs (no derivation triple) — recoverable from the
      #     identity key alone, so destroying them costs only re-import.
      #   * Unsigned / aborted actions (+actions.wtxid IS NULL+) — no
      #     broadcast happened, so nothing on chain to orphan.
      #
      # @return [SweepableState]
      def sweepable_state
        # Derived outputs are the at-risk set — derivation_prefix IS NOT NULL
        # marks an output that requires the wallet's per-output controls to
        # respend (BRC-42 / BRC-29). Roots carry no derivation triple
        # (controls_all_or_nothing CHECK) and stay outside the at-risk count.
        row = @db[:spendable]
              .join(:outputs, id: Sequel[:spendable][:output_id])
              .join(:actions, id: Sequel[:outputs][:action_id])
              .exclude(Sequel[:outputs][:derivation_prefix] => nil)
              .exclude(Sequel[:actions][:wtxid] => nil)
              .select do
                [Sequel.function(:count, Sequel[:outputs][:id]).as(:at_risk_outputs),
                 Sequel.function(:count, Sequel[:actions][:id]).distinct.as(:at_risk_actions)]
              end
              .first

        SweepableState.new(
          at_risk_outputs: row[:at_risk_outputs].to_i,
          at_risk_actions: row[:at_risk_actions].to_i
        )
      end

      # --- Labels, Tags, Baskets ---

      def find_or_create_labels(names:)
        names.map do |name|
          label = models::Label.first(label: name)
          label ||= models::Label.create(label: name)
          label.id
        end
      end

      def find_or_create_tags(names:)
        names.map do |name|
          tag = models::Tag.first(tag: name)
          tag ||= models::Tag.create(tag: name)
          tag.id
        end
      end

      def find_or_create_basket(name:)
        basket = models::Basket.first(name: name)
        basket ||= models::Basket.create(name: name)
        basket.id
      end

      def label_action(action_id:, label_ids:)
        label_ids.each do |lid|
          existing = models::ActionLabel.first(action_id: action_id, label_id: lid)
          models::ActionLabel.create(action_id: action_id, label_id: lid) unless existing
        end
      end

      # --- Certificates ---

      def save_certificate(certificate)
        @db.transaction do
          cert = models::Certificate.create(
            type: certificate[:type],
            subject: certificate[:subject],
            serial_number: certificate[:serial_number],
            certifier: certificate[:certifier],
            verifier: certificate[:verifier],
            revocation_outpoint: certificate[:revocation_outpoint],
            signature: certificate[:signature]
          )

          certificate[:fields]&.each do |name, value|
            models::CertificateField.create(
              certificate_id: cert.id,
              name: name.to_s,
              value: value.to_s,
              master_key: certificate.dig(:keyring, name.to_s)
            )
          end

          certificate_to_hash(cert)
        end
      end

      def query_certificates(certifiers:, types:, limit: 10, offset: 0)
        base = models::Certificate.where(certifier: certifiers, type: types)
        total = base.count
        records = base.order(Sequel.desc(:created_at)).limit(limit).offset(offset).all
        { total: total, certificates: records.map { |c| certificate_to_hash(c) } }
      end

      def delete_certificate(type:, serial_number:, certifier:)
        models::Certificate.where(type: type, serial_number: serial_number, certifier: certifier).delete
      end

      # --- Proofs ---

      def save_proof(wtxid:, proof:)
        BSV::Primitives::Hex.validate_wtxid!(wtxid, name: 'save_proof wtxid')
        BSV.logger&.debug { "[Store] save_proof: dtxid=#{wtxid.to_dtxid} height=#{proof[:height]}" }

        @db.transaction do
          block_id = find_or_create_block(proof) if proof[:height]

          existing = models::TxProof.first(wtxid: Sequel.blob(wtxid))
          cols = proof_columns(proof).merge(block_id ? { block_id: block_id } : {})
          if existing
            existing.update(cols)
            existing.id
          else
            models::TxProof.create({ wtxid: wtxid }.merge(cols)).id
          end
        end
      end

      def find_proof(wtxid:)
        BSV::Primitives::Hex.validate_wtxid!(wtxid, name: 'find_proof wtxid')
        record = models::TxProof.first(wtxid: Sequel.blob(wtxid))
        return unless record

        proof_to_hash(record)
      end

      def proof_exists?(wtxid:)
        BSV::Primitives::Hex.validate_wtxid!(wtxid, name: 'proof_exists? wtxid')
        models::TxProof.where(wtxid: Sequel.blob(wtxid)).any?
      end

      # --- Verification cache (ADR-033 / HLR #516) ---

      # Chunk size for +wtxid IN (?...)+ queries. Postgres allows up to
      # 65_535 bind parameters per statement; 10k leaves headroom for
      # additional predicates and keeps a single chunk's plan small.
      VERIFY_BATCH_CHUNK = 10_000
      private_constant :VERIFY_BATCH_CHUNK

      def mark_verified(wtxid:, via:, at_time: nil)
        # Single form delegates to the batch — validation of both +wtxid+
        # and +via+ happens once, inside the batch method.
        mark_verified_batch(wtxids: [wtxid], via: via, at_time: at_time)
      end

      def mark_verified_batch(wtxids:, via:, at_time: nil)
        return 0 if wtxids.empty?

        validate_verified_via!(via)
        wtxids.each { |w| BSV::Primitives::Hex.validate_wtxid!(w, name: 'mark_verified_batch wtxid') }
        version = BSV::Wallet::VERIFIER_VERSION
        stamp = at_time || Time.now

        # Monotonic predicate. +existing <= new+ admits the three legal
        # transitions: NULL → any (first write), N-1 → N (version upgrade),
        # N → N (same-version metadata upgrade, e.g. +self_built+ →
        # +broadcast_ack+). Refuses N+1 → N — a downgraded binary cannot
        # clobber rows written under stricter logic.
        #
        # HLR #521 strength ratchet, *same-version only*: the version
        # clause alone leaves +verified_via+ downgrades legal at the same
        # version. Enforce the doc'd trust hierarchy (+self_built+ <
        # +broadcast_ack+ < +spv+ per +verification-cache.md+) by
        # refusing same-version writes whose new via is weaker than the
        # existing one. Cross-version writes (N-1 → N) bypass the
        # ratchet: the new verifier's classification is authoritative,
        # and Sub 5's read path already gates on +verifier_version >=
        # current+, so stale weaker marks fall out of the trust set
        # naturally.
        allowed_prior = allowed_prior_states_for(via)
        rows = 0
        wtxids.each_slice(VERIFY_BATCH_CHUNK) do |chunk|
          blobs = chunk.map { |w| Sequel.blob(w) }
          scope = models::TxProof.where(wtxid: blobs)
          scope = if allowed_prior
                    # Combined monotonic-version + same-version ratchet.
                    # Explicit +IS NULL OR IN (...)+ — +where(col: [nil,
                    # ...])+ emits +col IN (NULL, ...)+, and SQL's
                    # three-valued logic never matches +col = NULL+ that
                    # way (would filter fresh rows alongside ratcheted
                    # ones).
                    scope.where do
                      Sequel.expr(verifier_version: nil) |
                        (Sequel[:verifier_version] < version) |
                        (Sequel.expr(verifier_version: version) &
                         (Sequel.expr(verified_via: nil) |
                          Sequel.expr(verified_via: allowed_prior)))
                    end
                  else
                    scope.where { (verifier_version <= version) | Sequel.expr(verifier_version: nil) }
                  end
          rows += scope.update(verified_at: stamp, verified_via: via, verifier_version: version)
        end
        rows
      end

      def verification_state(wtxid:)
        BSV::Primitives::Hex.validate_wtxid!(wtxid, name: 'verification_state wtxid')
        record = models::TxProof
                 .where(wtxid: Sequel.blob(wtxid))
                 .exclude(verified_at: nil)
                 .first
        return unless record

        {
          verified_at: record.verified_at,
          verified_via: record.verified_via.to_s,
          verifier_version: record.verifier_version
        }
      end

      def verified_wtxids(wtxids:, version_at_least:, via_in:)
        return Set.new if wtxids.empty?

        wtxids.each { |w| BSV::Primitives::Hex.validate_wtxid!(w, name: 'verified_wtxids wtxid') }
        acc = Set.new
        wtxids.each_slice(VERIFY_BATCH_CHUNK) do |chunk|
          blobs = chunk.map { |w| Sequel.blob(w) }
          # +verified_at IS NOT NULL+ is redundant given the coherent-state
          # CHECK (verified_via IS NOT NULL ⟺ verified_at IS NOT NULL), but
          # Postgres's planner does not infer partial-index matches from
          # CHECK implications — the WHERE clause must literally name the
          # partial-index predicate for the covering index to be picked.
          hits = models::TxProof
                 .where(wtxid: blobs, verified_via: via_in)
                 .exclude(verified_at: nil)
                 .where { verifier_version >= version_at_least }
                 .select_map(:wtxid)
          acc.merge(hits.map(&:to_s))
        end
        acc
      end

      def max_verifier_version_seen
        # Filter on +verified_at+ (not +verifier_version+): the covering
        # index is partial on +verified_at IS NOT NULL+, so filtering by
        # that column lets the planner satisfy the MAX from the index at
        # boot time. Coherent CHECK makes the two filters semantically
        # equivalent.
        models::TxProof.exclude(verified_at: nil).max(:verifier_version)
      end

      # Anchor-liveness invalidation writer (HLR #516 Sub 6.1).
      #
      # Clears the three verification-cache columns
      # (+verified_at+, +verified_via+, +verifier_version+) on any
      # +tx_proofs+ row whose stored anchor disagrees with the tracker's
      # current view. The anchor key is +(block_height, computed_root)+
      # in wire-order 32-byte binary bytes — NOT hex, NOT BUMP-encoded
      # bytes. The persisted +merkle_path+ is folded through the SDK's
      # +MerklePath#compute_root+ so that BUMP-encoding variability
      # (offset-0 leaf duplicates, unbalanced padding, hash-side ordering)
      # closes at the canonical root before comparison — two BUMPs with
      # the same computed root produce identical invalidation decisions
      # regardless of their on-wire bytes.
      #
      # Coarse-clear rule: all three columns move together to satisfy the
      # +verification_state_coherent+ CHECK. Only rows already carrying a
      # trust mark (+verified_via IS NOT NULL+) are touched; unverified
      # rows are left alone (no work for the descendant walker to undo).
      #
      # +heights_to_roots+ semantics:
      # - present with a 32-byte value ⇒ compare, invalidate on mismatch.
      # - present with +nil+          ⇒ height is "unknown" to the tracker
      #   (transient outage, sync gap) — never invalidate. The trust set
      #   must not decay under a network blip.
      # - height absent from the Hash ⇒ untouched (caller did not ask).
      #
      # No chain_tracker dependency here — this method is a pure writer.
      # +Engine::AnchorLivenessCache+ resolves +heights_to_roots+ from
      # the tracker and hands it in.
      #
      # @param heights_to_roots [Hash{Integer => String, nil}] wire-order
      #   32-byte binary current roots keyed by block height
      # @return [Array<Integer>] +actions.id+ values whose proofs were
      #   invalidated (needed by Sub 6.2's descendant walk)
      def invalidate_stale_anchors!(heights_to_roots:)
        return [] if heights_to_roots.empty?

        invalidated_action_ids = []
        # Chunk by height to keep the per-statement predicate small on
        # wallets with tens of thousands of proofs per re-org'd block.
        # +VERIFY_BATCH_CHUNK+ (10k) is the row-level ceiling; batching
        # by height directly is coarser but simpler and matches the
        # write shape (one UPDATE per (height, root) pair).
        @db.transaction do
          heights_to_roots.each do |height, current_root_bytes|
            # +current_root_bytes+ may be +nil+ (tracker outage for this
            # height). We still walk the candidates so
            # structurally-unverifiable rows (missing / unparseable
            # +merkle_path+ with a trust mark) get fail-closed cleared
            # regardless of tracker reachability. The anchor-mismatch
            # comparison itself is what needs a live tracker; unverifiable
            # rows are unverifiable at any tracker state. Copilot round-6
            # on #533.
            invalidated_action_ids.concat(
              invalidate_anchors_at_height(height, current_root_bytes)
            )
          end
        end
        invalidated_action_ids.uniq
      end

      # Chunk size for the descent-invalidation UPDATE (HLR #516 Sub 6.2).
      # Half +VERIFY_BATCH_CHUNK+: the WHERE predicate is more complex
      # (large +action_id IN (...)+ set plus the +verified_via IS NOT
      # NULL+ gate) and this keeps a single chunk safely under
      # +SQLITE_MAX_VARIABLE_NUMBER = 32_766+ while leaving planner
      # headroom on Postgres.
      INVALIDATE_BATCH_CHUNK = 5_000
      private_constant :INVALIDATE_BATCH_CHUNK

      # Structural descent walk (HLR #516 Sub 6.2).
      #
      # Descent linkage (each hop from a parent action to its child):
      #
      #   outputs.action_id (parent) → outputs.id
      #                              → inputs.output_id
      #                              → inputs.action_id (child)
      #
      # Implemented as a recursive CTE via +Sequel::Dataset#with_recursive+.
      # The CTE is named +descent+ with columns +(action_id, depth)+.
      # The base case seeds +descent+ from +action_ids+ at depth 0. The
      # recursive step joins the last descent row through +outputs+ and
      # +inputs+ to produce the child action_ids at +depth + 1+, stopping
      # once the depth column hits +max_depth+.
      #
      # Three properties matter for correctness:
      #
      # - +union_all: false+ so the CTE emits UNION (dedup); a diamond
      #   ancestry where two paths from X reach Y still yields one Y row.
      # - The depth counter caps recursion at +max_depth+ (default 100 =
      #   coinbase-maturity ceiling) — a natural bound above which any
      #   descendant is beyond every re-org's reach.
      # - The depth cap is also the cycle guard. A contrived cyclic input
      #   graph (shouldn't exist in real tx graphs but the CHECKs don't
      #   forbid it) would re-visit rows through dedup; combined with the
      #   depth ceiling, the walk terminates in bounded time regardless.
      #
      # Returns the seed ids plus every descendant reachable within the
      # depth cap. The caller feeds this set to
      # +invalidate_verification+ for coarse row-clearing.
      #
      # @param action_ids [Array<Integer>, Set<Integer>] seed action_ids
      # @param max_depth [Integer] recursion ceiling (default 100)
      # @return [Set<Integer>] seed action_ids + all transitive descendants
      def descendant_action_ids_of(action_ids:, max_depth: 100)
        seeds = action_ids.to_a
        return Set.new if seeds.empty?

        # Base case — every seed enters +descent+ at depth 0. Casts on
        # both columns are load-bearing on Postgres: the recursive step
        # emits +inputs.action_id+ (bigint) and +depth + 1+ (integer),
        # so the seed columns must match those types or PG raises a
        # +DatatypeMismatch+ ("column N has type integer in non-
        # recursive term but type bigint overall"). +actions.id+ is
        # +bigserial+ (already bigint), so only +depth+ needs an
        # explicit cast; SQLite is duck-typed and honours either shape.
        #
        # Seed from a single +actions IN (…)+ query, not one +SELECT
        # literal+ per +action_id+ UNION'd together — for a re-org with
        # many invalidated anchors the multi-UNION SQL grows O(N) and
        # can hit statement-size limits. The IN-list still uses N bind
        # parameters, well under SQLite's 32_766 ceiling at every
        # realistic re-org size (per-height chunking upstream at
        # +VERIFY_BATCH_CHUNK = 10_000+ bounds this even further).
        # Copilot round-8 on #533.
        seed_ds = @db[:actions]
                  .where(id: seeds)
                  .select(
                    Sequel[:id].as(:action_id),
                    Sequel.cast(0, :integer).as(:depth)
                  )

        # Recursive step — for every row currently in +descent+ below the
        # depth cap, find the actions whose inputs consume outputs
        # produced by that action.
        recursive_ds = @db[:outputs]
                       .join(:descent, action_id: Sequel[:outputs][:action_id])
                       .join(:inputs, output_id: Sequel[:outputs][:id])
                       .where(Sequel[:descent][:depth] < max_depth)
                       .select(
                         Sequel[:inputs][:action_id].as(:action_id),
                         (Sequel[:descent][:depth] + 1).as(:depth)
                       )

        # +union_all: false+ ⇒ UNION (dedup at each step). Diamond
        # ancestry survives without duplicate visits; cyclic paths
        # produce redundant same-action_id-different-depth rows until
        # the depth cap halts recursion — bounded time, and Set.new
        # collapses to unique action_ids on return.
        cte = @db[:descent]
              .with_recursive(:descent, seed_ds, recursive_ds,
                              args: %i[action_id depth],
                              union_all: false)

        Set.new(cte.select_map(:action_id))
      end

      # Shared row-clearing primitive for verification-cache invalidation
      # (HLR #516 Sub 6.2). Called by the descent walk wired into
      # +Engine::AnchorLivenessCache+ after +invalidate_stale_anchors!+
      # returns invalidated anchor +action_ids+.
      #
      # Two gates on the UPDATE:
      #
      # - +action_id IN (chunk)+ — the coarse-cleared descent set
      # - +verified_via IS NOT NULL+ — the security-specialist DoS
      #   defence. The descent WALK is unbounded on the read side
      #   (structural descendants can be poisoned by an adversary
      #   grafting synthetic rows); the UPDATE is bounded to rows
      #   carrying a trust mark. Rows without +verified_via+ have no
      #   cache state to clear and would trip the coherent CHECK.
      #
      # All three verification columns move together in one UPDATE so
      # +verification_state_coherent+ is satisfied atomically.
      # +INVALIDATE_BATCH_CHUNK+ (5k rows/statement) keeps the per-chunk
      # bind-parameter count and planner cost bounded on both backends.
      #
      # @param action_ids [Array<Integer>, Set<Integer>]
      # @return [Integer] rows cleared
      def invalidate_verification(action_ids:)
        ids = action_ids.to_a
        return 0 if ids.empty?

        rows_cleared = 0
        ids.each_slice(INVALIDATE_BATCH_CHUNK) do |chunk|
          # Resolve the +tx_proofs.id+ set backing this chunk of actions.
          # Actions with no proof row (mid-lifecycle) are excluded here
          # — no verification state to clear.
          proof_ids = models::Action
                      .where(id: chunk)
                      .exclude(tx_proof_id: nil)
                      .select_map(:tx_proof_id)
          next if proof_ids.empty?

          # Debug-log the wtxid + root anchor context BEFORE the UPDATE
          # so a trace-path reader sees "cleared X because Y". Skipped
          # when the logger is nil (production hot path — no DB round-
          # trip cost).
          log_transitive_invalidation(proof_ids) if BSV.logger

          rows_cleared += clear_verification_columns_for_proofs(proof_ids)
        end
        rows_cleared
      end

      # Boot-time cache sanity sweep (HLR #516 Sub 6.3, failsafe-for-
      # failsafe). Samples a bounded number of +tx_proofs+ rows whose
      # verification is +'spv'+ and whose +merkle_path+ is populated,
      # then compares each row's computed root against the +chain_tracker+'s
      # current view at the same block height. On divergence: log via
      # +BSV.logger.warn+.
      #
      # This method does NOT invalidate rows — that job belongs to
      # +invalidate_stale_anchors!+ / +Engine::AnchorLivenessCache+ on
      # the per-verify-walk path. This is a divergence *detector*: it
      # surfaces silent drift (schema-level bug, tracker-write race,
      # migration corruption) that the per-walk path would eventually
      # catch on next reference but might not for cold rows.
      #
      # Env-gated by +BSV_WALLET_VERIFY_BOOT_SWEEP=1+. Unset → the whole
      # method is a no-op (CLI tools boot fast, the daemon opts in).
      # Non-fatal at every failure surface: DB errors, +chain_tracker+
      # outages, empty samples, and unparseable BUMPs all fall through
      # to a debug log and return.
      #
      # Not part of any per-walk hot path. Cost is a single indexed
      # SELECT bounded by +sample_size+ plus one batched
      # +known_roots_for_heights+ call — an order of magnitude below
      # the ongoing chain-tracker traffic even at daemon boot.
      #
      # @param chain_tracker [#known_roots_for_heights] anchor-liveness-
      #   capable chain tracker
      # @param sample_size [Integer] upper bound on rows to sample
      # @return [Integer] number of rows whose stored root diverged from
      #   the tracker's current view (0 when the sweep did nothing)
      def sanity_sweep_verified_anchors!(chain_tracker:, sample_size: 100)
        return 0 unless ENV['BSV_WALLET_VERIFY_BOOT_SWEEP'] == '1'
        return 0 if chain_tracker.nil?

        # Sample the freshest 'spv' rows with a merkle_path present.
        # Ordering by +verified_at DESC+ concentrates the sample on
        # the frontier — the rows most likely to be near an active
        # re-org tip.
        samples = sanity_sweep_sample(sample_size)
        return 0 if samples.empty?

        heights = samples.map { |row| row[:height] }.uniq
        current_roots = safe_known_roots_for(chain_tracker, heights)
        return 0 if current_roots.empty?

        divergences = 0
        samples.each do |row|
          current = current_roots[row[:height]]
          next if current.nil? # tracker "unknown" — not a divergence

          computed = computed_root_for_path(row[:merkle_path], row[:wtxid])
          next unless computed # unparseable BUMP — skip, not a divergence
          next if computed == current

          divergences += 1
          BSV.logger&.warn do
            "[Store#sanity_sweep_verified_anchors!] wtxid=#{row[:wtxid].to_dtxid} " \
              "cause=boot_sweep_divergence height=#{row[:height]} " \
              "computed_root=#{computed.to_dtxid} " \
              "current_root=#{current.to_dtxid}"
          end
        end
        divergences
      rescue Sequel::DatabaseError => e
        BSV.logger&.debug { "[Store#sanity_sweep_verified_anchors!] db error: #{e.message}" }
        0
      end

      # --- Block Headers ---

      # Persist a +blocks+ row, append-or-reject (#335).
      #
      # The +blocks+ table carries two row flavours distinguished by the
      # +header+ column. A *trusted-service* row (header NULL) records only
      # the +merkle_root+ a chain-query Service handed back. A *validated*
      # row (header present, the raw 80 bytes) is one whose PoW the wallet
      # checked locally — its presence is the structural "this height is
      # validated" signal (there is no status column). The
      # +header_root_match+ CHECK ties the indexed +merkle_root+ to the
      # bytes the header embeds, so the two can never disagree.
      #
      # Append-or-reject preserves the validated chain as evidence (and the
      # competing-header reorg trace, #245):
      #
      # - Passing +header:+ writes/upgrades a validated row. At an
      #   already-validated height carrying a *different* header, this
      #   raises {CompetingBlockHeaderError} rather than overwriting — a
      #   fork at an occupied height is reorg evidence to investigate, not
      #   an upsert to silently win. The same header re-presented is an
      #   idempotent no-op. A header-NULL row at that height is *upgraded*
      #   in place (trusted → validated).
      # - The trusted-service path (no +header:+) may still refresh
      #   +merkle_root+ / +block_hash+, but its update is scoped to
      #   header-NULL rows: it can never downgrade a header-bearing row to
      #   NULL, nor mutate the +merkle_root+ a validated header pins (which
      #   would trip +header_root_match+).
      #
      # @param height [Integer]
      # @param merkle_root [String] 32 wire bytes (or hex; coerced)
      # @param block_hash [String, nil] 32 wire bytes (or hex; coerced)
      # @param header [String, nil] raw 80-byte header — present ⇒ validated row
      # @raise [BSV::Wallet::CompetingBlockHeaderError] on a conflicting validated header
      def record_block_header(height:, merkle_root:, block_hash: nil, header: nil)
        root_bin = to_binary(merkle_root)
        hash_bin = block_hash ? to_binary(block_hash) : nil
        header_bin = header ? to_binary(header) : nil

        return record_validated_header(height, root_bin, hash_bin, header_bin) if header_bin

        # Trusted-service path: upsert merkle_root / block_hash, but never
        # touch +header+ and only update rows where +header+ is NULL — a
        # validated row stays untouched (no downgrade, no merkle_root drift
        # against its pinned header).
        update_fields = { merkle_root: Sequel.blob(root_bin) }
        update_fields[:block_hash] = Sequel.blob(hash_bin) if hash_bin

        insert_fields = { height: height, merkle_root: Sequel.blob(root_bin) }
        insert_fields[:block_hash] = Sequel.blob(hash_bin) if hash_bin

        models::Block.dataset
                     .insert_conflict(target: :height,
                                      update: update_fields,
                                      update_where: { Sequel[:blocks][:header] => nil })
                     .insert(insert_fields)
      end

      def find_block(height:)
        record = models::Block.first(height: height)
        return unless record

        { height: record.height, merkle_root: record.merkle_root, block_hash: record.block_hash }
      end

      # The raw 80-byte header at +height+, or +nil+ when the height holds
      # no row or only a trusted-service (header-NULL) row. The presence of
      # a non-nil return is the "this height is locally validated" signal.
      #
      # @param height [Integer]
      # @return [String, nil] the 80 raw wire bytes, or nil
      def header_at(height:)
        models::Block.where(height: height).get(:header)
      end

      def max_block_height
        models::Block.max(:height)
      end

      # Highest height of the contiguous run of *validated* (header-present)
      # rows that starts at +from_height+ (the checkpoint) — the validated
      # tip (#335).
      #
      # Structural and gap-stopping: a header-island sitting above a missing
      # height is NOT the validated tip. Walks the ascending set of
      # header-present heights at/above +from_height+ and returns the last
      # height before the first break in the +h, h+1, h+2, …+ sequence.
      # Returns +nil+ when +from_height+ itself is not validated (the chain
      # has not even been seeded).
      #
      # @param from_height [Integer] the checkpoint height (run anchor)
      # @return [Integer, nil] the validated tip, or +nil+ if unseeded
      def validated_tip(from_height:)
        # Iterate the ascending header-present heights and stop at the first
        # gap, rather than materialising the whole run into an array — the
        # contiguous chain can grow long on a wallet whose checkpoint has
        # drifted far below the tip.
        tip = nil
        models::Block
          .where(height: from_height..)
          .exclude(header: nil)
          .order(:height)
          .select(:height)
          .each do |row|
            h = row[:height]
            break if tip.nil? && h != from_height # from_height itself not validated → unseeded
            break if tip && h != tip + 1          # gap — the run ends at the previous height

            tip = h
          end
        tip
      end

      # --- Settings ---

      def get_setting(key:)
        models::Setting.get(key)
      end

      def set_setting(key:, value:)
        models::Setting.set(key, value)
      end

      # --- Input Resolution ---

      def resolve_inputs_for_signing(action_id:)
        rows = @db[:inputs]
               .join(:outputs, id: :output_id)
               .join(Sequel[:actions].as(:source_actions), id: Sequel[:outputs][:action_id])
               .where(Sequel[:inputs][:action_id] => action_id)
               .order(Sequel[:inputs][:vin])
               .select(
                 Sequel[:inputs][:vin],
                 Sequel[:inputs][:nsequence].as(:sequence),
                 Sequel[:source_actions][:wtxid].as(:source_wtxid),
                 Sequel[:outputs][:vout].as(:source_vout),
                 Sequel[:outputs][:satoshis].as(:source_satoshis),
                 Sequel[:outputs][:locking_script].as(:source_locking_script),
                 Sequel[:outputs][:derivation_prefix],
                 Sequel[:outputs][:derivation_suffix],
                 Sequel[:outputs][:sender_identity_key]
               )
               .all

        result = rows.map do |row|
          raise "Source action has nil wtxid for input vin #{row[:vin]} of action #{action_id}" if row[:source_wtxid].nil?

          BSV::Primitives::Hex.validate_wtxid!(row[:source_wtxid], name: "resolve_inputs source vin=#{row[:vin]}")

          {
            vin: row[:vin],
            sequence: row[:sequence],
            source_wtxid: row[:source_wtxid],
            source_vout: row[:source_vout],
            source_satoshis: row[:source_satoshis],
            source_locking_script: row[:source_locking_script],
            derivation_prefix: row[:derivation_prefix],
            derivation_suffix: row[:derivation_suffix],
            sender_identity_key: row[:sender_identity_key]
          }
        end

        BSV.logger&.debug do
          dtxids = result.first(5).map { |r| r[:source_wtxid].to_dtxid }
          suffix = result.size > 5 ? " (+#{result.size - 5} more)" : ''
          "[Store] resolve_inputs_for_signing: action_id=#{action_id} inputs=#{result.size} sources=#{dtxids.join(',')}#{suffix}"
        end

        result
      end

      def query_change_output_vouts(action_id:)
        models::Output.where(action_id: action_id)
                      .where(
                        models::OutputDetail.dataset
                          .where(Sequel[:output_details][:output_id] => Sequel[:outputs][:id])
                          .where(change: true)
                          .select(1)
                          .exists
                      )
                      .select_map(:vout)
      end

      def promote_change_to_spendable(action_id:)
        @db.transaction do
          # No-send / internal path (broadcast_intent='none'): the promotions
          # row authorises the change outputs to join the UTXO set with no
          # broadcast. Must precede the spendable rows (FK). Idempotent.
          record_promotion(action_id: action_id, authorising_status: nil)

          change_outputs = models::Output.where(action_id: action_id)
                                         .where(
                                           models::OutputDetail.dataset
                                             .where(Sequel[:output_details][:output_id] => Sequel[:outputs][:id])
                                             .where(change: true)
                                             .select(1)
                                             .exists
                                         )
                                         .exclude(
                                           models::Spendable.where(Sequel[:spendable][:output_id] => Sequel[:outputs][:id])
                                                            .select(1).exists
                                         )
                                         .all
          change_outputs.each do |output|
            # INSERT … ON CONFLICT (output_id) DO NOTHING — the exclude() above
            # is a fast path; this makes concurrent calls race-safe, not a
            # unique violation.
            models::Spendable.dataset.insert_conflict(target: :output_id).insert(
              output_id: output.id, action_id: action_id, spendable_intent: 'spendable'
            )
          end
        end
      end

      # +basket+ accepts the same vocabulary as +query_outputs+:
      #   - omitted (default) → all spendable outputs.
      #   - +nil+              → unbasketed outputs only (no +output_baskets+ row).
      #   - +String+           → outputs in that named basket.
      #   - +Array<String>+    → outputs in any listed basket.
      def find_spendable(satoshis:, basket: BASKET_UNSPECIFIED, exclude: [])
        ds = models::Output.spendable
        ds = ds.in_basket(basket) unless basket.equal?(BASKET_UNSPECIFIED)
        ds = ds.exclude(Sequel[:outputs][:id] => exclude) if exclude.any?
        ds = ds.order(Sequel.desc(:satoshis))

        candidates = []
        total = 0
        ds.each do |output|
          candidates << {
            id: output.id, satoshis: output.satoshis,
            vout: output.vout, action_id: output.action_id,
            locking_script: output.locking_script,
            derivation_prefix: output.derivation_prefix,
            derivation_suffix: output.derivation_suffix,
            sender_identity_key: output.sender_identity_key
          }
          total += output.satoshis
          break if total >= satoshis
        end
        candidates
      end

      # --- Broadcasts ---

      def record_broadcast_result(action_id:, tx_status:, arc_status: nil,
                                  block_hash: nil, block_height: nil,
                                  merkle_path: nil, extra_info: nil,
                                  competing_txs: nil)
        @db.transaction do
          broadcast = models::Broadcast.first(action_id: action_id)
          raise "no broadcasts row for action_id=#{action_id}" unless broadcast

          fields = { tx_status: tx_status }
          fields[:arc_status] = arc_status if arc_status
          fields[:block_hash] = decode_hex(block_hash) if block_hash
          fields[:block_height] = block_height if block_height
          fields[:merkle_path] = decode_hex(merkle_path) if merkle_path
          fields[:extra_info] = extra_info if extra_info
          fields[:competing_txs] = encode_competing_txs(competing_txs) if competing_txs

          broadcast.update(fields)

          # Phase 4 promotion happens inside this transaction when the
          # broadcast is *not* rejected — speculative-promote on the same
          # predicate the Engine inline path uses (#240). Both inline and
          # async loops opportunistically promote so callers and chained
          # spends unblock as soon as Arcade has the tx; the resolution
          # loop + Store#reject_action is the safety net when a previously
          # non-rejected status later flips to REJECTED.
          #
          # Atomicity here closes a crash-recovery gap: without it the
          # broadcasts row could carry a terminal status (so the
          # resolution loop won't rediscover it) while the promotions row was
          # never recorded. Single transaction = single recoverable state.
          status_upper = tx_status.to_s.upcase
          if !status_upper.empty? && !BSV::Wallet::ArcStatus::REJECTED.include?(status_upper)
            promote_action_outputs(action_id: action_id, authorising_status: tx_status)
          end

          broadcast_to_hash(broadcast)
        end
      end

      def broadcast_status(action_id:)
        broadcast = models::Broadcast.first(action_id: action_id)
        return unless broadcast

        broadcast_to_hash(broadcast)
      end

      def record_broadcast_provider(wtxid:, provider:)
        BSV::Primitives::Hex.validate_wtxid!(wtxid, name: 'record_broadcast_provider wtxid')
        action_id = models::Action.where(wtxid: Sequel.blob(wtxid)).get(:id)
        return 0 unless action_id

        # Last-broadcaster wins: re-broadcasting the same wtxid (e.g. retry
        # after a partial failure on a different provider) overwrites the
        # column so #provider_for reflects the most recent successful submit.
        models::Broadcast.where(action_id: action_id).update(provider: provider)
      end

      def broadcast_provider_for(wtxid:)
        BSV::Primitives::Hex.validate_wtxid!(wtxid, name: 'broadcast_provider_for wtxid')
        action_id = models::Action.where(wtxid: Sequel.blob(wtxid)).get(:id)
        return unless action_id

        models::Broadcast.where(action_id: action_id).get(:provider)
      end

      def pending_resolutions(limit: 100)
        models::Broadcast
          .exclude(broadcast_at: nil)
          .where(Sequel.|({ tx_status: nil }, Sequel.~(tx_status: BSV::Wallet::ArcStatus::TERMINAL)))
          .limit(limit)
          .all
          .map { |b| broadcast_to_hash(b) }
      end

      def pending_submissions(limit: 100)
        models::Broadcast
          .where(broadcast_at: nil)
          .limit(limit)
          .all
          .map { |b| broadcast_to_hash(b) }
      end

      def mark_broadcast_attempted(action_id:)
        @db.transaction do
          raise "no broadcasts row for action_id=#{action_id}" unless models::Broadcast.where(action_id: action_id).any?

          # State marker: stamp +broadcast_at+ as the row enters "submitted,
          # awaiting outcome". The +broadcast_at: nil+ predicate prevents
          # racing re-stamps within a single in-flight attempt; the
          # companion +clear_broadcast_attempted+ nulls the stamp on a 503
          # response so the row re-enters the queued state for clean retry.
          # After a 503 + retry, +broadcast_at+ reflects the retry timestamp
          # rather than the first attempt. See docs/reference/schema.md (Phase 3).
          models::Broadcast
            .where(action_id: action_id, broadcast_at: nil)
            .update(broadcast_at: Time.now)
        end
      end

      # Revert +broadcast_at+ to NULL on the 503 / backpressure path so the
      # row returns to the queued / push-discovery set for clean retry
      # next cycle. See #266 + plan §4.2.
      #
      # Guarded by +tx_status: nil+: if the SSE listener concurrently
      # delivered SEEN / REJECTED for the same wtxid (Arcade fanned out an
      # event before responding 503, or a previous attempt actually made it
      # through), the row has already transitioned and this clear becomes a
      # no-op. Without the guard, racing the listener could reset state
      # for an action that has moved on. Material edge case -- specced.
      #
      # @param action_id [Integer]
      # @return [Integer] number of rows updated (0 when guarded out, 1
      #   when the clear took effect)
      def clear_broadcast_attempted(action_id:)
        @db.transaction do
          models::Broadcast
            .where(action_id: action_id, tx_status: nil)
            .exclude(broadcast_at: nil)
            .update(broadcast_at: nil)
        end
      end

      # Bump the broadcasts.retry_count for an action whose reject_action
      # raised CannotRejectInternalActionError. Visibility into stuck rows
      # for dashboards; the row itself stays alive so the resolution loop
      # re-encounters it next cycle.
      def increment_broadcast_retry(action_id:)
        models::Broadcast
          .where(action_id: action_id)
          .update(retry_count: Sequel[:retry_count] + 1)
      end

      # --- SSE Cursors ---

      def load_sse_cursor(token:)
        models::SseCursor.where(token: token).get(:last_event_id)
      end

      def save_sse_cursor(token:, last_event_id:)
        # Upsert keyed on the token PK. Concurrent listeners booting for
        # the same token (defensive -- the daemon should run one) race
        # cleanly without PK violation. +update_where+ enforces strict
        # monotonicity: a stale write (reconnect race, dual listener
        # flushing residual events from before fail-over) that carries a
        # smaller +last_event_id+ becomes a no-op rather than rewinding
        # the cursor and re-delivering events the listener already
        # advanced past. See #262.
        models::SseCursor.dataset
                         .insert_conflict(target: :token,
                                          update: { last_event_id: last_event_id, updated_at: Time.now },
                                          update_where: (Sequel[:sse_cursors][:last_event_id] < last_event_id))
                         .insert(token: token, last_event_id: last_event_id, updated_at: Time.now)
      end

      # Discovery side of the reaper (#325). Returns up to +limit+ IDs of
      # orphaned actions ready to reclaim, for the Scheduler loop to push to
      # Engine::Reaper.
      #
      # The reaper reclaims *orphaned* actions — structurally valid states (the
      # schema forbids invalid ones) that hold locked inputs but have no
      # recovery owner and can no longer progress. An action is reapable when it
      # is past the staleness
      # threshold, has no promotions row (promoted is protected), has no
      # broadcasts row, and is either broadcastable (+broadcast_intent !=
      # 'none'+) or pre-sign (+wtxid IS NULL+).
      #
      # Two ownership boundaries:
      #
      # - **No broadcasts row** (PR #379): +sign_action+ creates the broadcasts
      #   row, so any signed broadcastable action is owned by the broadcast
      #   loops — success promotes it, terminal failure unwinds it via
      #   +reject_action+. Reaping one would release inputs of a tx that may
      #   already be on the network (a crash mid-submit leaves +broadcast_at+
      #   stamped but no status) — a double-spend.
      # - **Broadcastable OR pre-sign**: internal (+intent 'none'+) actions
      #   complete synchronously via +complete_internal_action+, which signs and
      #   promotes atomically — so a *signed* internal action is either promoted
      #   (excluded above) or a deliberately-parked/OP_RETURN completion (kept).
      #   Only a *pre-sign* internal action (+wtxid IS NULL+) is an orphaned
      #   mid-funding lock with no owner. Reaping those, but never a signed
      #   internal action, closes the internal pre-sign leak (#329) without
      #   touching completed internal state.
      #
      # @param threshold [Integer] age in seconds
      # @param limit [Integer] max IDs per discovery pass
      # @return [Array<Integer>] stale action IDs
      def stale_action_ids(threshold:, limit:)
        cutoff = Time.now - threshold
        promotion_exists = models::Promotion
                           .where(Sequel[:promotions][:action_id] => Sequel[:actions][:id])
                           .select(1)
        broadcast_exists = models::Broadcast
                           .where(Sequel[:broadcasts][:action_id] => Sequel[:actions][:id])
                           .select(1)

        models::Action
          .where { created_at < cutoff }
          .where(Sequel.|(Sequel.~(broadcast_intent: 'none'), Sequel.expr(wtxid: nil)))
          .exclude(promotion_exists.exists)
          .exclude(broadcast_exists.exists)
          .limit(limit)
          .select_map(:id)
      end

      # Reclaim a single orphaned action (#325). Tears the action down in one
      # transaction and deletes it, cascading its +inputs+ rows so the locked
      # UTXOs return to the spendable set.
      #
      # Re-validates inside the transaction: the action may have advanced past
      # reapability between discovery and here — promoted, or signed (which
      # creates a broadcasts row and hands it to the broadcast loops). A
      # +FOR UPDATE+ row lock closes the check-then-delete race: +sign_action+
      # updates the action row, so it serialises against this lock. Returns
      # +false+ (no delete) when the action is no longer reapable — the caller
      # emits +task.skipped+.
      #
      # @param action_id [Integer]
      # @return [Boolean] true if reclaimed, false if no longer reapable
      def reap_action(action_id:)
        promotion_exists = models::Promotion
                           .where(Sequel[:promotions][:action_id] => action_id)
                           .select(1)
        broadcast_exists = models::Broadcast
                           .where(action_id: action_id)
                           .select(1)

        @db.transaction do
          reapable = models::Action
                     .where(id: action_id)
                     .where(Sequel.|(Sequel.~(broadcast_intent: 'none'), Sequel.expr(wtxid: nil)))
                     .exclude(promotion_exists.exists)
                     .exclude(broadcast_exists.exists)
                     .for_update
                     .first
          next false unless reapable

          # outputs.action_id is RESTRICT (#189), so unpromoted output rows and
          # their dependents must be cleared before the action delete.
          output_ids = models::Output.where(action_id: action_id).select(:id)
          models::OutputBasket.where(action_id: action_id).delete
          models::OutputDetail.where(action_id: action_id).delete
          models::OutputTag.where(output_id: output_ids).delete
          models::Output.where(action_id: action_id).delete
          # broadcasts.action_id has no CASCADE FK today (tracked in #189),
          # so clear the broadcasts row before the action.
          models::Broadcast.where(action_id: action_id).delete
          models::Action.where(id: action_id).delete # cascades inputs, releasing locks
          true
        end
      end

      private

      def validate_verified_via!(via)
        return if models::TxProof::VERIFIED_VIA_VALUES.include?(via)

        raise ArgumentError,
              'mark_verified via must be one of ' \
              "#{models::TxProof::VERIFIED_VIA_VALUES.inspect}, got #{via.inspect}"
      end

      # HLR #521 strength ratchet: prior +verified_via+ values that a new
      # +via+ may overwrite when the existing row is at the SAME
      # +verifier_version+. Trust hierarchy per
      # +docs/reference/verification-cache.md+ is +self_built+ <
      # +broadcast_ack+ < +spv+; the ratchet lets trust only move
      # forward within a version. Cross-version writes are gated by the
      # version predicate at the call site, not by this table.
      #
      # +nil+ ⇒ no ratchet gate (the new +via+ is the strongest and
      # can overwrite anything, subject only to the version predicate).
      # The +NULL+ prior case is added at the query site, so callers
      # here only see the non-nil allowed-prior enum values.
      def allowed_prior_states_for(via)
        case via
        when models::TxProof::VERIFIED_VIA_SELF_BUILT
          [models::TxProof::VERIFIED_VIA_SELF_BUILT]
        when models::TxProof::VERIFIED_VIA_BROADCAST_ACK
          [models::TxProof::VERIFIED_VIA_SELF_BUILT, models::TxProof::VERIFIED_VIA_BROADCAST_ACK]
        end
        # VERIFIED_VIA_SPV: nil — the strongest; only the version
        # predicate gates it (an older-version binary still cannot
        # clobber a newer stamp).
      end

      # Recursive inner method for reject_action. Walks children first
      # (post-order tear-down) so outputs.action_id RESTRICT doesn't
      # block when this action's outputs are deleted -- the inputs that
      # referenced them are gone via each child's CASCADE on action_id.
      #
      # +visited+ is a Set of action_ids already entered; re-entering one
      # no-ops (see the diamond rationale in the body) rather than raising.
      def do_reject(action_id, visited:)
        # Idempotent re-entry guard. Action graphs are DAGs (an input can
        # only spend an already-existing output, so true cycles are
        # impossible), but legitimate diamonds occur: when one action D
        # spends outputs of two siblings B and C that share a parent A,
        # the forward walk reaches D once via each path. The second visit
        # must no-op, not raise -- raising would roll back the whole
        # cascade for a shape that arises naturally (e.g. a consolidation
        # combining two outputs of a common ancestor).
        return if visited.include?(action_id)

        visited.add(action_id)

        action = models::Action[action_id]
        return unless action # idempotent: nothing left to reject

        raise BSV::Wallet::CannotRejectInternalActionError, action_id if action.broadcast_intent == 'none'

        # Refuse if the network told us this tx is accepted. Deletion
        # would compound a wallet-vs-chain divergence — operator
        # investigation is the right response, not unwind.
        broadcast = models::Broadcast.first(action_id: action_id)
        if broadcast
          status = broadcast.tx_status.to_s.upcase
          raise BSV::Wallet::CannotRejectAcceptedActionError.new(action_id, status) if BSV::Wallet::ArcStatus::ACCEPTED.include?(status)
        end

        child_actions_of(action_id: action_id).each do |child_id|
          do_reject(child_id, visited: visited)
        end

        output_ids = models::Output.where(action_id: action_id).select_map(:id)
        if output_ids.any?
          # Drop dependents that reference outputs by output_id (RESTRICT
          # default on these FKs). action_id-denormalised tables
          # (spendable / output_baskets / output_details) cascade on the
          # action delete below — explicit deletes here are belt-and-
          # braces for code clarity and to guarantee zero leftover rows
          # in the same transaction.
          models::Spendable.where(output_id: output_ids).delete
          models::OutputTag.where(output_id: output_ids).delete
          models::OutputBasket.where(action_id: action_id).delete
          models::OutputDetail.where(action_id: action_id).delete
          models::Output.where(id: output_ids).delete
        end

        # Defensively clear tx_proof_id so the actions row delete isn't
        # blocked by any tx_proofs FK quirk; should be NULL on rejected
        # actions but a stale proof link from a prior optimistic-accept
        # race would otherwise leak through.
        models::Action.where(id: action_id).update(tx_proof_id: nil)
        models::ActionLabel.where(action_id: action_id).delete
        # Delete the promotions row before the broadcasts row: promotions has a
        # composite FK to broadcasts(action_id, tx_status), so the broadcasts
        # delete would be blocked otherwise. Removing it cascades any remaining
        # spendable rows (spendable.action_id -> promotions ON DELETE CASCADE).
        models::Promotion.where(action_id: action_id).delete
        models::Broadcast.where(action_id: action_id).delete
        models::Action.where(id: action_id).delete # cascades inputs
      end

      # Attempt to lock every input in +inputs+ against +action_id+.
      # Returns true iff all rows were inserted (i.e. no contention).
      # Caller is responsible for wrapping in a transaction and rolling
      # back when this returns false.
      def lock_inputs_atomic?(action_id:, inputs:)
        locked = 0
        inputs.each do |inp|
          locked += 1 if try_lock_input(record_id: action_id, inp: inp)
        end
        locked == inputs.size
      end

      # Base try_lock_input: performs the insert. Subclasses override to
      # add backend-specific result interpretation.
      def try_lock_input(record_id:, inp:)
        @db[:inputs].insert_conflict(target: :output_id).insert(
          action_id: record_id,
          output_id: inp[:output_id],
          vin: inp[:vin],
          nsequence: inp[:nsequence] || 4_294_967_295,
          description: inp[:description]
        )
      end

      def models
        BSV::Wallet::Store::Models
      end

      # Persist the signed artifacts (wtxid + raw_tx) on the action row and
      # upsert the matching TxProof entry. Caller is responsible for wrapping
      # in a transaction.
      def write_signing_artifacts(action_id:, wtxid:, raw_tx:)
        models::Action.where(id: action_id).update(
          wtxid: Sequel.blob(wtxid),
          raw_tx: Sequel.blob(raw_tx)
        )
        models::TxProof.dataset
                       .insert_conflict(target: :wtxid, update: { raw_tx: Sequel.blob(raw_tx) })
                       .insert(wtxid: Sequel.blob(wtxid), raw_tx: Sequel.blob(raw_tx))
      end

      # Record the per-action promotions row — the canonical-state fact that
      # replaces outputs.promoted (#307). intent tracks the action;
      # authorising_status is the broadcast tx_status that authorised a
      # send-path promotion, NULL on the internal path. Idempotent on the
      # action_id primary key.
      def record_promotion(action_id:, authorising_status:)
        intent = models::Action.where(id: action_id).get(:broadcast_intent)
        models::Promotion.dataset.insert_conflict(target: :action_id).insert(
          action_id: action_id, intent: intent, authorising_status: authorising_status
        )
      end

      # Write change output rows (and their detail rows) for an action.
      # Caller is responsible for wrapping in a transaction. Outputs are plain
      # INSERTs — promotion is the existence of a promotions row, recorded by
      # the promote_* paths, not a column here.
      def write_change_outputs(action_id:, change_outputs:)
        change_outputs.each do |chg|
          output = create_output_or_translate(
            action_id: action_id,
            satoshis: chg[:satoshis],
            vout: chg[:vout],
            locking_script: chg[:locking_script],
            spendable_intent: 'spendable',
            derivation_prefix: chg[:derivation_prefix],
            derivation_suffix: chg[:derivation_suffix],
            sender_identity_key: chg[:sender_identity_key]
          )
          models::OutputDetail.create(
            output_id: output.id,
            action_id: action_id,
            change: true
          )
          # Optional basket per HLR #436 — internal change-producing
          # operations (notably +Engine#import_utxo+) can route change
          # into a named basket so the caller has a stable handle on the
          # imported funds. Plain auto-fund change leaves +chg[:basket]+
          # unset; no +output_baskets+ row is written, keeping the
          # output in the wallet's unbasketed pool.
          next unless chg[:basket]

          basket_id = find_or_create_basket(name: chg[:basket])
          models::OutputBasket.create(
            output_id: output.id, basket_id: basket_id, action_id: action_id
          )
        end
      end

      # Write send-path output rows (plain INSERTs; no promotions row yet). Spendable rows are
      # deferred until Phase 4 (broadcast acceptance). Caller is responsible
      # for wrapping in a transaction.
      def write_pending_outputs(action_id:, outputs:)
        outputs.each do |out|
          output = create_output_or_translate(
            action_id: action_id,
            satoshis: out[:satoshis],
            vout: out[:vout],
            locking_script: out[:locking_script],
            spendable_intent: out[:spendable_intent].to_s,
            derivation_prefix: out[:derivation_prefix],
            derivation_suffix: out[:derivation_suffix],
            sender_identity_key: out[:sender_identity_key]
          )
          write_output_associations(output: output, action_id: action_id, spec: out)
        end
      end

      # Write basket / detail / tag rows for an output. Caller is responsible
      # for wrapping in a transaction. The spendable row is not handled here —
      # callers decide when an output joins the canonical UTXO set.
      def write_output_associations(output:, action_id:, spec:)
        if spec[:basket]
          basket_id = find_or_create_basket(name: spec[:basket])
          models::OutputBasket.create(output_id: output.id, basket_id: basket_id, action_id: action_id)
        end

        if spec[:description] || spec[:custom_instructions]
          models::OutputDetail.create(
            output_id: output.id,
            action_id: action_id,
            description: spec[:description],
            custom_instructions: spec[:custom_instructions]
          )
        end

        return unless spec[:tags]&.any?

        tag_ids = find_or_create_tags(names: spec[:tags])
        tag_ids.each { |tid| models::OutputTag.create(output_id: output.id, tag_id: tid) }
      end

      # Single boundary for +models::Output.create+: translates Sequel's
      # +ValidationFailed+ (raised when the +Output+ model's +#validate+
      # finds a structural mismatch — HLR #467 / +intent-and-outcomes.md+)
      # into +BSV::Wallet::InvalidParameterError+ so callers see a clean
      # app-level error rather than the raw Sequel exception. The DB CHECK
      # is the same logic, one step downstream — this rescue exists to
      # surface the failure earlier with a per-field message.
      def create_output_or_translate(**attrs)
        models::Output.create(attrs)
      rescue Sequel::ValidationFailed => e
        raise BSV::Wallet::InvalidParameterError.new('output', e.message)
      end

      # Convert a value to binary. If already binary-encoded, return as-is;
      # otherwise treat as hex string and pack.
      def to_binary(value)
        return value if value.encoding == Encoding::BINARY

        [value].pack('H*')
      end

      # Write (or upgrade to) a validated, header-bearing +blocks+ row.
      # Append-or-reject at an occupied height — see {#record_block_header}.
      #
      # A single +INSERT ... ON CONFLICT+ — atomic, so it avoids the
      # read-then-write race the previous +for_update+ check left open (two
      # writers both seeing no row and racing on +create+, one hitting a
      # unique violation that, in +:spv_headers+ mode, would fail a
      # verification closed):
      #   * no row            → INSERT the validated row.
      #   * row, header NULL  → UPGRADE in place (trusted → validated),
      #                         realigning merkle_root / block_hash so
      #                         +header_root_match+ holds (the +update_where+).
      #   * row, header set   → +update_where+ excludes it, so DO NOTHING; the
      #                         post-read then no-ops (same header) or raises
      #                         (a different, competing header = reorg evidence).
      def record_validated_header(height, root_bin, hash_bin, header_bin)
        insert_fields = { height: height, merkle_root: Sequel.blob(root_bin),
                          header: Sequel.blob(header_bin) }
        insert_fields[:block_hash] = Sequel.blob(hash_bin) if hash_bin

        update_fields = { merkle_root: Sequel.blob(root_bin), header: Sequel.blob(header_bin) }
        update_fields[:block_hash] = Sequel.blob(hash_bin) if hash_bin

        models::Block.dataset
                     .insert_conflict(target: :height, update: update_fields,
                                      update_where: { Sequel[:blocks][:header] => nil })
                     .insert(insert_fields)

        # The row now carries a header. If it differs from ours, a competing
        # header was already validated at this height — reorg evidence the
        # upsert deliberately left intact (#245), never an overwrite. The
        # read-back is race-free: a header-bearing row is immutable (the
        # +update_where+ above never touches one).
        stored = models::Block.where(height: height).get(:header)
        raise BSV::Wallet::CompetingBlockHeaderError, height unless stored == header_bin
      end

      def broadcast_to_hash(record)
        {
          action_id: record.action_id, tx_status: record.tx_status,
          arc_status: record.arc_status, broadcast_at: record.broadcast_at,
          block_hash: record.block_hash, block_height: record.block_height,
          merkle_path: record.merkle_path, provider: record.provider
        }
      end

      # Decode hex to binary blob, passthrough if already binary.
      def decode_hex(value)
        return unless value
        return Sequel.blob(value) if value.encoding == Encoding::BINARY

        Sequel.blob([value].pack('H*'))
      end

      def encode_competing_txs(txs)
        if @db.database_type == :postgres
          Sequel.pg_array(txs)
        else
          JSON.generate(txs)
        end
      end

      def proof_columns(proof)
        cols = {}
        cols[:block_index] = proof[:block_index] if proof.key?(:block_index)
        cols[:merkle_path] = proof[:merkle_path] ? Sequel.blob(proof[:merkle_path]) : nil if proof.key?(:merkle_path)
        cols[:raw_tx]      = proof[:raw_tx]      ? Sequel.blob(proof[:raw_tx]) : nil      if proof.key?(:raw_tx)
        cols
      end

      def proof_to_hash(record)
        block = record.block
        {
          id: record.id, wtxid: record.wtxid, block_id: record.block_id,
          height: block&.height, block_index: record.block_index,
          merkle_path: record.merkle_path, raw_tx: record.raw_tx,
          block_hash: block&.block_hash, merkle_root: block&.merkle_root
        }
      end

      def find_or_create_block(proof)
        height = proof[:height]
        return unless height

        merkle_root = proof[:merkle_root] || derive_merkle_root(proof[:merkle_path])
        root_bin = merkle_root ? to_binary(merkle_root) : nil

        existing = models::Block.first(height: height)
        if existing
          # HLR #516 Sub 6.1 Option B: same-height/different-hash re-org
          # is fork evidence, not a silent upsert. Attaching this proof
          # to the stale row would leave the anchor-liveness path unable
          # to detect the mismatch (both rows now agree). Raise instead;
          # the re-org handler at +Engine::AnchorLivenessCache+ owns
          # invalidation.
          raise BSV::Wallet::CompetingBlockHeaderError, height if root_bin && existing.merkle_root && existing.merkle_root != root_bin

          return existing.id
        end

        return unless merkle_root

        hash_bin = proof[:block_hash] ? to_binary(proof[:block_hash]) : nil
        models::Block.create(height: height, merkle_root: root_bin, block_hash: hash_bin).id
      rescue Sequel::UniqueConstraintViolation
        # A concurrent writer landed the +blocks+ row between our probe
        # and insert. Re-read and re-check the merkle_root: if the
        # winner recorded a competing root, this is the same re-org
        # signal the pre-check would have raised for, so surface it
        # rather than silently attach to the winner's row.
        winner = models::Block.first!(height: height)
        raise BSV::Wallet::CompetingBlockHeaderError, height if root_bin && winner.merkle_root && winner.merkle_root != root_bin

        winner.id
      end

      # Fold a persisted +merkle_path+ blob through the SDK's
      # +MerklePath#compute_root+ so BUMP-encoding variability closes at
      # the canonical wire-order root. Returns +nil+ on any parse
      # failure — the caller (+invalidate_anchors_at_height+) treats
      # +nil+ as a fail-closed signal: unparseable proofs cannot be
      # anchor-checked, so the trust mark is cleared to force a
      # re-verify on next reference. See #533 Copilot round-1.
      #
      # +wtxid+ names which leaf of the BUMP owns this row — the SDK
      # walks the leaves of +path[0]+ to disambiguate compound proofs.
      # Wire-order 32 bytes, matching the +wtxid+ column.
      def computed_root_for_path(merkle_path_binary, wtxid)
        return nil unless merkle_path_binary && wtxid

        paths = BSV::Transaction::MerklePath.from_binary(merkle_path_binary)
        mp = paths.is_a?(Array) ? paths.first : paths
        mp&.compute_root(wtxid)
      rescue StandardError
        nil
      end

      # Invalidate every verified +tx_proofs+ row whose block sits at
      # +height+ but whose computed root disagrees with
      # +current_root_bytes+ (wire-order 32 bytes). Returns the
      # +actions.id+ of each cleared row for Sub 6.2 to walk descendants.
      def invalidate_anchors_at_height(height, current_root_bytes)
        block_ids = models::Block.where(height: height).select_map(:id)
        return [] if block_ids.empty?

        # Stream candidates instead of +.all+ — a re-org height with tens
        # of thousands of verified proofs would otherwise materialise
        # every row (with its +merkle_path+ blob) into memory inside the
        # transaction. +paged_each+ walks the dataset in fixed-size
        # server-side fetches (+VERIFY_BATCH_CHUNK+ = 10_000). The set
        # is bounded by the +by_block+ partial index (+verified_at IS
        # NOT NULL AND block_id IS NOT NULL+). Copilot round-4 on #533.
        #
        # +merkle_path IS NULL+ is INCLUDED — the schema allows a
        # "height-known + path-pending" row (+path_requires_block+
        # CHECK, migration comment "confirmed but unproven"), and if
        # such a row also carries +verified_via='spv'+ it must fail
        # closed on the next anchor-liveness pass. Silently skipping
        # +merkle_path IS NULL+ rows would let that combination retain
        # trust across re-orgs. Copilot round-5 on #533.
        candidates = models::TxProof
                     .where(block_id: block_ids)
                     .exclude(verified_via: nil)
                     .select(:id, :wtxid, :merkle_path)

        stale_ids = []
        candidates.paged_each(rows_per_fetch: VERIFY_BATCH_CHUNK) do |row|
          computed = computed_root_for_path(row.merkle_path, row.wtxid)
          if computed.nil?
            # Fail closed — a proof we cannot compute a root for cannot
            # be anchor-checked, so we can neither confirm nor refute
            # liveness. Clear the trust mark so the next reference forces
            # re-verify; a silently-skipped row would retain +'spv'+
            # forever and Sub 5's read gate would trust it. Structural
            # unverifiability is orthogonal to tracker reachability —
            # this branch fires even when +current_root_bytes+ is +nil+
            # (tracker outage). Copilot round-1 (unparseable bytes) +
            # round-5 (missing path) + round-6 (tracker-outage
            # separation) on #533.
            cause = row.merkle_path.nil? ? 'missing_merkle_path' : 'unparseable_merkle_path'
            log_unverifiable_proof(row.wtxid, height, cause)
            stale_ids << row.id
            next
          end
          # Tracker unreachable for this height → cannot compare; preserve
          # trust on transient outage (the AC #4 "unknown ≠ mismatch"
          # guarantee for parseable proofs).
          next if current_root_bytes.nil?
          next if computed == current_root_bytes

          log_anchor_mismatch(row.wtxid, height, computed, current_root_bytes)
          stale_ids << row.id
        end
        return [] if stale_ids.empty?

        # Clear all three columns together via the shared primitive so
        # both invalidation paths (anchor liveness here, transitive
        # descent in +invalidate_verification+) share a single write
        # site — the maintainability-specialist ask against drift.
        # The action-id lookup shares the same chunk boundary: a giant
        # +tx_proof_id IN (...)+ query could exceed SQLite's
        # bind-parameter limit (32_766) on a large re-org batch, and
        # the plan gets progressively worse on Postgres too. Copilot
        # round-4 on #533.
        action_ids = []
        stale_ids.each_slice(VERIFY_BATCH_CHUNK) do |chunk|
          clear_verification_columns_for_proofs(chunk)
          action_ids.concat(models::Action.where(tx_proof_id: chunk).select_map(:id))
        end
        action_ids
      end

      # Shared row-clearing UPDATE for verification-cache invalidation.
      # Both +invalidate_anchors_at_height+ (Sub 6.1's anchor-liveness
      # path) and +invalidate_verification+ (Sub 6.2's transitive-
      # descent path) route their write through here so the +verified_via
      # IS NOT NULL+ predicate + coherent three-column clear stay in one
      # place. Drift between the two paths would be a subtle correctness
      # bug — the maintainability-specialist ask.
      #
      # @param proof_ids [Array<Integer>] +tx_proofs.id+ values to clear
      # @return [Integer] rows updated
      def clear_verification_columns_for_proofs(proof_ids)
        models::TxProof
          .where(id: proof_ids)
          .exclude(verified_via: nil)
          .update(verified_at: nil, verified_via: nil, verifier_version: nil)
      end

      # Boot-sweep sampler. Returns up to +limit+ +tx_proofs+ rows that
      # carry an +'spv'+ mark AND have a +merkle_path+ populated (rows
      # for which anchor liveness is meaningful — unanchored rows have
      # nothing to check). Ordered by +verified_at DESC+ so the sample
      # concentrates on the freshest rows, most likely to be near an
      # active re-org tip.
      def sanity_sweep_sample(limit)
        models::TxProof
          .join(:blocks, id: :block_id)
          .where(Sequel[:tx_proofs][:verified_via] => 'spv')
          .exclude(Sequel[:tx_proofs][:merkle_path] => nil)
          .order(Sequel[:tx_proofs][:verified_at].desc)
          .limit(limit)
          .select(
            Sequel[:tx_proofs][:wtxid],
            Sequel[:tx_proofs][:merkle_path],
            Sequel[:blocks][:height]
          )
          .all
          .map { |r| { wtxid: r[:wtxid], merkle_path: r[:merkle_path], height: r[:height] } }
      end

      # Safe wrapper around +chain_tracker.known_roots_for_heights+ for
      # the boot sweep. A tracker outage MUST NOT prevent boot; return
      # an empty Hash on any exception. Consistent with the per-walk
      # anchor-liveness cache's fail-closed-on-invalidation stance.
      def safe_known_roots_for(chain_tracker, heights)
        chain_tracker.known_roots_for_heights(heights)
      rescue StandardError => e
        BSV.logger&.debug do
          "[Store#sanity_sweep_verified_anchors!] chain_tracker error: #{e.message}"
        end
        {}
      end

      def log_anchor_mismatch(wtxid, height, computed_root, current_root)
        BSV.logger&.debug do
          "[Store#invalidate_stale_anchors!] wtxid=#{wtxid.to_dtxid} " \
            "cause=anchor_mismatch height=#{height} " \
            "computed_root=#{computed_root.to_dtxid} " \
            "current_root=#{current_root.to_dtxid}"
        end
      end

      # A verified proof we cannot compute a root for cannot be
      # anchor-checked, so we treat it as anchor mismatch (fail closed).
      # Next reference forces re-verify + proof re-fetch. Two causes,
      # both rare:
      #
      # * +cause: 'unparseable_merkle_path'+ — bytes present but
      #   +MerklePath#compute_root+ raised (BUMP format changes across
      #   SDK versions, storage corruption). Copilot round-1 on #533.
      # * +cause: 'missing_merkle_path'+ — +merkle_path IS NULL+ but
      #   the row carries +verified_via IS NOT NULL+ and
      #   +block_id IS NOT NULL+ (schema allows the "confirmed but
      #   unproven" state; if it also gains a trust mark, we can never
      #   validate/invalidate the anchor). Copilot round-5 on #533.
      #
      # +warn+ so operators can correlate against bsv-sdk upgrades or
      # a proof-acquisition pipeline that persisted trust without
      # persisting the proof.
      def log_unverifiable_proof(wtxid, height, cause)
        BSV.logger&.warn do
          "[Store#invalidate_stale_anchors!] wtxid=#{wtxid.to_dtxid} " \
            "cause=#{cause} height=#{height}"
        end
      end

      # Debug trace for +invalidate_verification+. Emits one line per
      # cleared wtxid so a trace-path reader can attribute the miss to
      # transitive-descent invalidation. +root_anchor+ is the row's own
      # wtxid when the row itself is anchored (block_id present) or
      # +unknown+ when it's a pure descendant — the shared primitive
      # doesn't receive the specific seed that triggered the walk.
      # Precise anchor attribution is not correctness-critical: the
      # trace-path affordance is for the human debugger, and
      # "cause=transitive_descent" is already the attribution.
      def log_transitive_invalidation(proof_ids)
        BSV.logger&.debug do
          rows = models::TxProof
                 .where(id: proof_ids)
                 .exclude(verified_via: nil)
                 .select(:wtxid, :block_id)
                 .all
          rows.map do |r|
            anchor = r.block_id ? r.wtxid.to_dtxid : 'unknown'
            "[Store#invalidate_verification] wtxid=#{r.wtxid.to_dtxid} " \
              "cause=transitive_descent root_anchor=#{anchor}"
          end.join("\n")
        end
      end

      def derive_merkle_root(merkle_path_binary)
        return unless merkle_path_binary

        paths = BSV::Transaction::MerklePath.from_binary(merkle_path_binary)
        mp = paths.is_a?(Array) ? paths.first : paths
        # SDK's MerklePath#compute_root returns wire-order (LE) bytes —
        # the canonical internal byte order for the blocks table (same
        # convention as wtxid). Display-order conversion happens at
        # boundaries (ChainTracker on SDK/WoC ingress, logging, JSON).
        mp&.compute_root
      rescue StandardError
        nil
      end

      def bind_models!
        BSV::Wallet::Store::Models.constants.each do |name|
          klass = BSV::Wallet::Store::Models.const_get(name)
          next unless klass.is_a?(Class) && klass < Sequel::Model

          klass.dataset = @db[klass.table_name]
        end
      end

      # Little-endian uint32 read from raw_tx at +offset+ (0 = version,
      # -4 = nlocktime). nil if raw_tx is absent or shorter than 4 bytes.
      def raw_tx_uint32(raw_tx, offset)
        return unless raw_tx && raw_tx.bytesize >= 4

        raw_tx[offset, 4].unpack1('V')
      end

      def action_to_hash(record, include_labels: false, include_inputs: false,
                         include_input_locking_scripts: false,
                         include_outputs: false, include_output_locking_scripts: false, **)
        h = {
          id: record.id, wtxid: record.wtxid, raw_tx: record.raw_tx,
          reference: record.reference, status: record.derived_status,
          outgoing: record.values[:broadcast_intent].to_s != 'none', description: record.description,
          # version / nlocktime are the leading / trailing four LE bytes of
          # raw_tx — derived, not stored (#351). nil for an unsigned action,
          # or one whose raw_tx is too short to slice (no min-length CHECK on
          # actions.raw_tx, so stay defensive).
          version: raw_tx_uint32(record.raw_tx, 0),
          nlocktime: raw_tx_uint32(record.raw_tx, -4),
          broadcast_intent: record.values[:broadcast_intent], created_at: record.created_at,
          tx_proof_id: record.tx_proof_id
        }

        h[:labels] = record.labels.map(&:label) if include_labels

        if include_inputs
          h[:inputs] = record.inputs.map do |inp|
            ih = { output_id: inp.output_id, vin: inp.vin, nsequence: inp.nsequence, description: inp.description }
            if include_input_locking_scripts && inp.output
              ih[:source_locking_script] = inp.output.locking_script
              ih[:source_satoshis] = inp.output.satoshis
            end
            ih
          end
        end

        if include_outputs
          h[:outputs] = record.outputs.map do |out|
            oh = { id: out.id, satoshis: out.satoshis, vout: out.vout, spendable: out.spendable? }
            oh[:locking_script] = out.locking_script if include_output_locking_scripts
            if out.detail
              oh[:description] = out.detail.description
              oh[:custom_instructions] = out.detail.custom_instructions
            end
            oh[:basket] = out.basket&.name
            oh[:tags] = out.tags.map(&:tag)
            oh
          end
        end

        h
      end

      def output_to_hash(record, include_locking_scripts: false,
                         include_custom_instructions: false,
                         include_tags: false, include_labels: false, **)
        h = { id: record.id, action_id: record.action_id,
              satoshis: record.satoshis, vout: record.vout, spendable: true }
        h[:locking_script] = record.locking_script if include_locking_scripts
        if include_custom_instructions && record.detail
          h[:custom_instructions] = record.detail.custom_instructions
          h[:description] = record.detail.description
        end
        h[:tags] = record.tags.map(&:tag) if include_tags
        h[:labels] = record.action.labels.map(&:label) if include_labels && record.action
        h[:basket] = record.basket&.name
        h
      end

      def certificate_to_hash(record)
        fields = {}
        record.certificate_fields.each { |f| fields[f.name] = f.value }
        {
          id: record.id, type: record.type, subject: record.subject,
          serial_number: record.serial_number, certifier: record.certifier,
          verifier: record.verifier, revocation_outpoint: record.revocation_outpoint,
          signature: record.signature, fields: fields
        }
      end
    end
  end
end

# Submodule autoloads (must come after class definition so `Store`
# is already a class when these are resolved).
require_relative 'store/models'
require_relative 'store/sqlite'
require_relative 'store/postgres'

# Service classes
BSV::Wallet::Store.autoload :BroadcastCallback, 'bsv/wallet/store/broadcast_callback'
BSV::Wallet::Store.autoload :EventApplicator,   'bsv/wallet/store/event_applicator'
BSV::Wallet::Store.autoload :SweepableState,    'bsv/wallet/store/sweepable_state'
BSV::Wallet::Store.autoload :UTXOPool,          'bsv/wallet/store/utxo_pool'
