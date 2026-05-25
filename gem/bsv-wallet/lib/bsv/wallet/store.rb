# frozen_string_literal: true

require 'json'

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
      # @return [BSV::Wallet::Store::SQLite, BSV::Wallet::Store::Postgres]
      def self.connect(url)
        if url.to_s.downcase.start_with?('postgres')
          Postgres.new(url: url)
        else
          SQLite.new(url: url)
        end
      end

      def initialize(url: nil, db: nil)
        @db = db || Sequel.connect(url)
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
            broadcast: action[:broadcast]&.to_s || 'delayed',
            nlocktime: action[:nlocktime],
            version: action[:version],
            outgoing: action.fetch(:outgoing, true),
            input_beef: action[:input_beef]
          )

          if inputs.any?
            locked = 0
            inputs.each do |inp|
              locked += 1 if try_lock_input(record_id: record.id, inp: inp)
            end

            raise Sequel::Rollback if locked < inputs.size
          end

          action_to_hash(record)
        end
      end

      def sign_action(action_id:, wtxid:, raw_tx:, change_outputs: [])
        BSV::Primitives::Hex.validate_wtxid!(wtxid, name: 'sign_action wtxid')
        BSV.logger&.debug { "[Store] sign_action: action_id=#{action_id} dtxid=#{wtxid.reverse.unpack1('H*')}" }
        @db.transaction do
          write_signing_artifacts(action_id: action_id, wtxid: wtxid, raw_tx: raw_tx)

          intent = models::Action.where(id: action_id).get(:broadcast)
          models::Broadcast.dataset.insert_conflict(target: :action_id).insert(action_id: action_id) if intent && intent != 'none'

          write_change_outputs(action_id: action_id, change_outputs: change_outputs)
        end
      end

      def stage_action(action_id:, wtxid:, raw_tx:)
        BSV::Primitives::Hex.validate_wtxid!(wtxid, name: 'stage_action wtxid')
        BSV.logger&.debug { "[Store] stage_action: action_id=#{action_id} dtxid=#{wtxid.reverse.unpack1('H*')}" }
        @db.transaction do
          write_signing_artifacts(action_id: action_id, wtxid: wtxid, raw_tx: raw_tx)
        end
      end

      def promote_action(action_id:, outputs:)
        @db.transaction do
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
            models::Spendable.create(output_id: output.id, action_id: action_id) if wallet_owned

            if out[:basket] && out[:basket] != 'default'
              basket_id = find_or_create_basket(name: out[:basket])
              models::OutputBasket.create(output_id: output.id, basket_id: basket_id, action_id: action_id)
            end

            if out[:description] || out[:custom_instructions]
              models::OutputDetail.create(
                output_id: output.id,
                action_id: action_id,
                description: out[:description],
                custom_instructions: out[:custom_instructions]
              )
            end

            if out[:tags]&.any?
              tag_ids = find_or_create_tags(names: out[:tags])
              tag_ids.each { |tid| models::OutputTag.create(output_id: output.id, tag_id: tid) }
            end

            output.id
          end
        end
      end

      def link_proof(action_id:, tx_proof_id:)
        models::Action.where(id: action_id).update(tx_proof_id: tx_proof_id)
      end

      def abort_action(action_id:)
        broadcast_exists = models::Broadcast.where(
          Sequel[:broadcasts][:action_id] => Sequel[:actions][:id]
        ).select(1)
        models::Action.where(id: action_id).exclude(broadcast_exists.exists).delete
      end

      def fail_broadcast_action(action_id:)
        @db.transaction do
          models::Broadcast.where(action_id: action_id).delete
          models::Action.where(id: action_id).delete
        end
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
        models::Action
          .where(outgoing: true)
          .where(Sequel.~(wtxid: nil))
          .where(tx_proof_id: nil)
          .where(Sequel.~(broadcast: 'none'))
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
          models::Spendable.create(output_id: output.id, action_id: action_id)
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
          broadcast_to_hash(broadcast)
        end
      end

      def broadcast_status(action_id:)
        broadcast = models::Broadcast.first(action_id: action_id)
        return unless broadcast

        broadcast_to_hash(broadcast)
      end

      def pending_polls(limit: 100)
        models::Broadcast
          .exclude(broadcast_at: nil)
          .where(Sequel.|({ tx_status: nil }, Sequel.~(tx_status: Models::Broadcast::TERMINAL_STATUSES)))
          .limit(limit)
          .all
          .map { |b| broadcast_to_hash(b) }
      end

      def pending_pushes(limit: 100)
        models::Broadcast
          .where(broadcast_at: nil)
          .limit(limit)
          .all
          .map { |b| broadcast_to_hash(b) }
      end

      def mark_broadcast_attempted(action_id:)
        @db.transaction do
          raise "no broadcasts row for action_id=#{action_id}" unless models::Broadcast.where(action_id: action_id).any?

          models::Broadcast
            .where(action_id: action_id, broadcast_at: nil)
            .update(broadcast_at: Time.now)
        end
      end

      def reap_stale_actions(threshold:)
        cutoff = Time.now - threshold
        output_exists = models::Output.where(Sequel[:outputs][:action_id] => Sequel[:actions][:id]).select(1)

        # Under #184's atomic invariant, signed actions with broadcast != 'none'
        # always have a broadcasts row. broadcasts.action_id has no CASCADE FK
        # today (tracked in #189), so we delete the broadcasts row first inside
        # the same transaction. Both deletes use the stale dataset as a
        # subquery so the predicate is re-evaluated at delete time -- avoids
        # a race where a row could be promoted between predicate evaluation
        # and the delete.
        @db.transaction do
          stale = models::Action
                  .where { created_at < cutoff }
                  .where(Sequel.~(broadcast: 'none'))
                  .where(Sequel.lit('wtxid IS NOT NULL'))
                  .exclude(output_exists.exists)

          models::Broadcast.where(action_id: stale.select(:id)).delete
          stale.delete
        end
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

      private

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

      # Write change output rows (and their detail rows) for an action.
      # Caller is responsible for wrapping in a transaction.
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
          merkle_path: record.merkle_path
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
          outgoing: record.outgoing, description: record.description,
          version: record.version, nlocktime: record.nlocktime,
          broadcast: record.values[:broadcast], created_at: record.created_at,
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
BSV::Wallet::Store.autoload :UTXOPool,          'bsv/wallet/store/utxo_pool'
