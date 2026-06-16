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
    #   store.create_action(action: { description: 'payment', nlocktime: 0 })
    class Store
      include BSV::Wallet::Interface::Store

      attr_reader :db

      # Factory: return a SQLite or Postgres instance based on the URL.
      #
      # @param url [String] database URL (sqlite:// or postgres://)
      # @param db_opts [Hash] extra options passed through to
      #   +Sequel.connect+. CLI tools omit this (Sequel default pool
      #   suffices for single-process, single-fiber use). The walletd
      #   daemon supplies +max_connections+ sized for its concurrent
      #   fiber inventory after enabling +Sequel.extension(:fiber_concurrency)+.
      #   See #268 + bin/walletd.
      # @return [BSV::Wallet::Store::SQLite, BSV::Wallet::Store::Postgres]
      def self.connect(url, **db_opts)
        klass = url.to_s.downcase.start_with?('postgres') ? Postgres : SQLite
        klass.new(url: url, db_opts: db_opts)
      end

      def initialize(url: nil, db: nil, db_opts: {})
        @db = db || Sequel.connect(url, **db_opts)
        # Set global so Sequel::Model(:table_name) calls in model class
        # bodies can resolve the database during autoload.
        Sequel::Model.db = @db
        configure_db
      end

      # Database-specific setup (PRAGMAs, extensions). Subclasses override.
      def configure_db
        raise NotImplementedError
      end

      def migrate!(target: nil)
        Sequel.extension :migration
        migrations_path = File.expand_path('../../../db/migrations', __dir__)
        Sequel::Migrator.run(@db, migrations_path, target: target)
        bind_models!
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
            nlocktime: action[:nlocktime],
            version: action[:version],
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
        BSV.logger&.debug { "[Store] sign_action: action_id=#{action_id} dtxid=#{wtxid.reverse.unpack1('H*')}" }
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

      def stage_action(action_id:, wtxid:, raw_tx:, outputs: [])
        BSV::Primitives::Hex.validate_wtxid!(wtxid, name: 'stage_action wtxid')
        BSV.logger&.debug { "[Store] stage_action: action_id=#{action_id} dtxid=#{wtxid.reverse.unpack1('H*')}" }
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
            output = models::Output.create(
              action_id: action_id,
              satoshis: out[:satoshis],
              vout: out[:vout],
              locking_script: out[:locking_script],
              output_type: out[:output_type],
              derivation_prefix: out[:derivation_prefix],
              derivation_suffix: out[:derivation_suffix],
              sender_identity_key: out[:sender_identity_key]
            )

            wallet_owned = out[:derivation_prefix] || out[:output_type] == 'root'
            # INSERT … ON CONFLICT (output_id) DO NOTHING — idempotent / concurrency-safe.
            models::Spendable.dataset.insert_conflict(target: :output_id).insert(output_id: output.id, action_id: action_id) if wallet_owned

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
            wallet_owned = output.derivation_prefix || output.output_type == 'root' || change_output?(output_id: output.id)
            next unless wallet_owned

            # INSERT … ON CONFLICT (output_id) DO NOTHING: concurrent Phase-4
            # promotion (duplicate ARC events / poll + SSE) is a no-op, not a
            # unique violation.
            models::Spendable.dataset.insert_conflict(target: :output_id).insert(output_id: output.id, action_id: action_id)
            promoted << output.id
          end
          promoted
        end
      end

      def link_proof(action_id:, tx_proof_id:)
        models::Action.where(id: action_id).update(tx_proof_id: tx_proof_id)
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
          output_type: record.output_type,
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

      def query_outputs(basket:, tags: nil, tag_query_mode: :any,
                        limit: 10, offset: 0,
                        include_locking_scripts: false,
                        include_custom_instructions: false,
                        include_tags: false, include_labels: false)
        base = models::Output.spendable.in_basket(basket)

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
        BSV.logger&.debug { "[Store] save_proof: dtxid=#{wtxid.reverse.unpack1('H*')} height=#{proof[:height]}" }

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

      # --- Block Headers ---

      def record_block_header(height:, merkle_root:, block_hash: nil)
        root_bin = to_binary(merkle_root)
        hash_bin = block_hash ? to_binary(block_hash) : nil

        update_fields = { merkle_root: Sequel.blob(root_bin) }
        update_fields[:block_hash] = Sequel.blob(hash_bin) if hash_bin

        insert_fields = { height: height, merkle_root: Sequel.blob(root_bin) }
        insert_fields[:block_hash] = Sequel.blob(hash_bin) if hash_bin

        models::Block.dataset
                     .insert_conflict(target: :height, update: update_fields)
                     .insert(insert_fields)
      end

      def find_block(height:)
        record = models::Block.first(height: height)
        return unless record

        { height: record.height, merkle_root: record.merkle_root, block_hash: record.block_hash }
      end

      def max_block_height
        models::Block.max(:height)
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
          dtxids = result.first(5).map { |r| r[:source_wtxid].reverse.unpack1('H*') }
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
            models::Spendable.dataset.insert_conflict(target: :output_id).insert(output_id: output.id, action_id: action_id)
          end
        end
      end

      def find_spendable(satoshis:, basket: nil, exclude: [])
        ds = models::Output.spendable
        ds = ds.in_basket(basket) if basket
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
          # rather than the first attempt. See reference/schema.md (Phase 3).
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

      def reap_stale_actions(threshold:)
        cutoff = Time.now - threshold
        # Only PROMOTED actions are protected from the reaper. An unpromoted
        # action (staged by deferred-sign, never broadcast-accepted, so no
        # promotions row) is the kind of leak the reaper exists to clean up.
        # Under the old predicate any output row blocked the reaper, so
        # abandoned deferred actions kept their inputs locked indefinitely.
        promotion_exists = models::Promotion
                           .where(Sequel[:promotions][:action_id] => Sequel[:actions][:id])
                           .select(1)

        @db.transaction do
          stale = models::Action
                  .where { created_at < cutoff }
                  .where(Sequel.~(broadcast_intent: 'none'))
                  .where(Sequel.lit('wtxid IS NOT NULL'))
                  .exclude(promotion_exists.exists)

          stale_ids = stale.select(:id)
          # outputs.action_id is RESTRICT (#189), so unpromoted output rows
          # and their dependents must be cleared before the action delete.
          output_ids_in_stale = models::Output.where(action_id: stale_ids).select(:id)
          models::OutputBasket.where(action_id: stale_ids).delete
          models::OutputDetail.where(action_id: stale_ids).delete
          models::OutputTag.where(output_id: output_ids_in_stale).delete
          models::Output.where(action_id: stale_ids).delete
          # broadcasts.action_id has no CASCADE FK today (tracked in #189),
          # so clear the broadcasts row before the action.
          models::Broadcast.where(action_id: stale_ids).delete
          stale.delete
        end
      end

      private

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
          output = models::Output.create(
            action_id: action_id,
            satoshis: chg[:satoshis],
            vout: chg[:vout],
            locking_script: chg[:locking_script],
            derivation_prefix: chg[:derivation_prefix],
            derivation_suffix: chg[:derivation_suffix],
            sender_identity_key: chg[:sender_identity_key]
          )
          models::OutputDetail.create(
            output_id: output.id,
            action_id: action_id,
            change: true
          )
        end
      end

      # Write send-path output rows (plain INSERTs; no promotions row yet). Spendable rows are
      # deferred until Phase 4 (broadcast acceptance). Caller is responsible
      # for wrapping in a transaction.
      def write_pending_outputs(action_id:, outputs:)
        outputs.each do |out|
          output = models::Output.create(
            action_id: action_id,
            satoshis: out[:satoshis],
            vout: out[:vout],
            locking_script: out[:locking_script],
            output_type: out[:output_type],
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
        if spec[:basket] && spec[:basket] != 'default'
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

      # True when the output is a change output (has a change=true detail row).
      def change_output?(output_id:)
        models::OutputDetail.where(output_id: output_id, change: true).any?
      end

      # Convert a value to binary. If already binary-encoded, return as-is;
      # otherwise treat as hex string and pack.
      def to_binary(value)
        return value if value.encoding == Encoding::BINARY

        [value].pack('H*')
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

        existing = models::Block.first(height: height)
        return existing.id if existing

        merkle_root = proof[:merkle_root] || derive_merkle_root(proof[:merkle_path])
        return unless merkle_root

        root_bin = to_binary(merkle_root)
        hash_bin = proof[:block_hash] ? to_binary(proof[:block_hash]) : nil

        models::Block.create(height: height, merkle_root: root_bin, block_hash: hash_bin).id
      rescue Sequel::UniqueConstraintViolation
        models::Block.first!(height: height).id
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

      def action_to_hash(record, include_labels: false, include_inputs: false,
                         include_input_locking_scripts: false,
                         include_outputs: false, include_output_locking_scripts: false, **)
        h = {
          id: record.id, wtxid: record.wtxid, raw_tx: record.raw_tx,
          reference: record.reference, status: record.derived_status,
          outgoing: record.values[:broadcast_intent].to_s != 'none', description: record.description,
          version: record.version, nlocktime: record.nlocktime,
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
BSV::Wallet::Store.autoload :UTXOPool,          'bsv/wallet/store/utxo_pool'
