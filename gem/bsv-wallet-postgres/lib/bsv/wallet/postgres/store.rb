# frozen_string_literal: true

module BSV
  module Wallet
    module Postgres
      # Concrete PostgreSQL implementation of Interface::Store.
      #
      # Layer 2a — orchestrates Layer 2b models into the phase-based
      # action lifecycle. Contains no BRC-100 business logic.
      #
      # All methods receive and return plain hashes — no Sequel::Model
      # objects leak through the interface boundary.
      class Store
        include BSV::Wallet::Interface::Store

        def initialize(db: nil)
          @db = db || BSV::Wallet::Postgres.db
        end

        # --- Action Lifecycle ---

        def create_action(action:, inputs: [])
          @db.transaction do
            record = Action.create(
              description: action[:description],
              broadcast:   action[:broadcast]&.to_s || 'delayed',
              nlocktime:   action[:nlocktime],
              version:     action[:version],
              outgoing:    action.fetch(:outgoing, true),
              input_beef:  action[:input_beef]
            )

            if inputs.any?
              locked = 0
              inputs.each do |inp|
                result = @db[:inputs].insert_conflict(target: :output_id).insert(
                  action_id:   record.id,
                  output_id:   inp[:output_id],
                  vin:         inp[:vin],
                  nsequence:   inp[:nsequence] || 4_294_967_295,
                  description: inp[:description]
                )
                locked += 1 if result
              end

              if locked < inputs.size
                raise Sequel::Rollback
              end
            end

            action_to_hash(record)
          end
        end

        def sign_action(action_id:, wtxid:, raw_tx:, change_outputs: [])
          BSV::Primitives::Hex.validate_wtxid!(wtxid, name: 'sign_action wtxid')
          BSV.logger&.debug { "[Store] sign_action: action_id=#{action_id} dtxid=#{wtxid.reverse.unpack1('H*')}" }
          @db.transaction do
            Action.where(id: action_id).update(
              wtxid:  Sequel.blob(wtxid),
              raw_tx: Sequel.blob(raw_tx)
            )
            TxProof.dataset.insert_conflict(target: :wtxid, update: { raw_tx: Sequel.blob(raw_tx) })
                          .insert(wtxid: Sequel.blob(wtxid), raw_tx: Sequel.blob(raw_tx))

            # Write change output rows atomically with signing. Output rows
            # record derivation data (spending authority) but NO spendable
            # rows — promotion to spendable happens after broadcast acceptance
            # or in the no_send path, same as any other output.
            change_outputs.each do |chg|
              output = Output.create(
                action_id:           action_id,
                satoshis:            chg[:satoshis],
                vout:                chg[:vout],
                locking_script:      chg[:locking_script],
                derivation_prefix:   chg[:derivation_prefix],
                derivation_suffix:   chg[:derivation_suffix],
                sender_identity_key: chg[:sender_identity_key]
              )
              OutputDetail.create(
                output_id:  output.id,
                action_id:  action_id,
                change:     true
              )
            end
          end
        end

        def promote_action(action_id:, outputs:)
          @db.transaction do
            outputs.map do |out|
              output = Output.create(
                action_id:           action_id,
                satoshis:            out[:satoshis],
                vout:                out[:vout],
                locking_script:      out[:locking_script],
                output_type:         out[:output_type],
                derivation_prefix:   out[:derivation_prefix],
                derivation_suffix:   out[:derivation_suffix],
                sender_identity_key: out[:sender_identity_key]
              )

              # Only wallet-owned outputs get a spendable row.
              # Derived outputs (NULL type with derivation fields) and root
              # outputs are wallet-owned. Outbound outputs are payments to
              # others — never spendable.
              wallet_owned = out[:derivation_prefix] || out[:output_type] == 'root'
              if wallet_owned
                Spendable.create(output_id: output.id, action_id: action_id)
              end

              if out[:basket] && out[:basket] != 'default'
                basket_id = find_or_create_basket(name: out[:basket])
                OutputBasket.create(output_id: output.id, basket_id: basket_id, action_id: action_id)
              end

              if out[:description] || out[:custom_instructions]
                OutputDetail.create(
                  output_id:          output.id,
                  action_id:          action_id,
                  description:        out[:description],
                  custom_instructions: out[:custom_instructions]
                )
              end

              if out[:tags]&.any?
                tag_ids = find_or_create_tags(names: out[:tags])
                tag_ids.each { |tid| OutputTag.create(output_id: output.id, tag_id: tid) }
              end

              output.id
            end
          end
        end

        def link_proof(action_id:, tx_proof_id:)
          Action.where(id: action_id).update(tx_proof_id: tx_proof_id)
        end

        def abort_action(action_id:)
          # Allow deletion of actions that haven't been broadcast.
          # After the deferred signing rework, actions may have an unsigned
          # raw_tx and wtxid before broadcast — the guard checks for absence
          # of a broadcast entry rather than absence of wtxid.
          broadcast_exists = Broadcast.where(
            Sequel[:broadcasts][:action_id] => Sequel[:actions][:id]
          ).select(1)

          Action.where(id: action_id).exclude(broadcast_exists.exists).delete
        end

        # --- Queries ---

        def find_action(id: nil, wtxid: nil, reference: nil)
          BSV::Primitives::Hex.validate_wtxid!(wtxid, name: 'find_action wtxid') if wtxid
          record = if id then Action[id]
                   elsif wtxid then Action.first(wtxid: Sequel.blob(wtxid))
                   elsif reference then Action.first(reference: reference)
                   end
          return unless record

          action_to_hash(record)
        end

        def query_actions(labels:, label_query_mode: :any, limit: 10, offset: 0,
                          include_labels: false, include_inputs: false,
                          include_input_locking_scripts: false,
                          include_input_unlocking_scripts: false,
                          include_outputs: false, include_output_locking_scripts: false)
          label_ids = Label.where(label: labels).select_map(:id)
          return { total: 0, actions: [] } if label_ids.empty?

          base = Action
            .join(:action_labels, action_id: :id)
            .where(Sequel[:action_labels][:label_id] => label_ids)
            .select_all(:actions)

          if label_query_mode == :all
            base = base
              .group(Sequel[:actions][:id])
              .having { count(Sequel.function(:distinct, Sequel[:action_labels][:label_id])) >= label_ids.size }
          else
            base = base.distinct
          end

          total = base.count
          records = base
            .order(Sequel.desc(Sequel[:actions][:created_at]))
            .limit(limit).offset(offset).all

          actions = records.map do |row|
            # row may be a hash from the join — reload as model
            a = row.is_a?(Action) ? row : Action[row[:id]]
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
          base = Output.spendable.in_basket(basket)

          if tags&.any?
            tag_ids = Tag.where(tag: tags).select_map(:id)
            unless tag_ids.empty?
              tag_ds = OutputTag.dataset
                .where(tag_id: tag_ids)
                .where(Sequel[:output_tags][:output_id] => Sequel[:outputs][:id])
                .select(1)

              if tag_query_mode == :all
                base = base.where(
                  tag_ds
                    .group(Sequel[:output_tags][:output_id])
                    .having { count(Sequel.function(:distinct, Sequel[:output_tags][:tag_id])) >= tag_ids.size }
                    .exists
                )
              else
                base = base.where(tag_ds.exists)
              end
            end
          end

          total = base.count
          records = base
            .order(Sequel.desc(:created_at))
            .limit(limit).offset(offset).all

          outputs = records.map do |o|
            output_to_hash(o,
                           include_locking_scripts: include_locking_scripts,
                           include_custom_instructions: include_custom_instructions,
                           include_tags: include_tags,
                           include_labels: include_labels)
          end

          { total: total, outputs: outputs }
        end

        # --- Outputs ---

        def relinquish_output(output_id:)
          @db.transaction do
            Spendable.where(output_id: output_id).delete
            OutputBasket.where(output_id: output_id).delete
          end
        end

        # --- Labels, Tags, Baskets ---

        def find_or_create_labels(names:)
          names.map do |name|
            label = Label.first(label: name)
            label ||= Label.create(label: name)
            label.id
          end
        end

        def find_or_create_tags(names:)
          names.map do |name|
            tag = Tag.first(tag: name)
            tag ||= Tag.create(tag: name)
            tag.id
          end
        end

        def find_or_create_basket(name:)
          basket = Basket.first(name: name)
          basket ||= Basket.create(name: name)
          basket.id
        end

        def label_action(action_id:, label_ids:)
          label_ids.each do |lid|
            existing = ActionLabel.first(action_id: action_id, label_id: lid)
            ActionLabel.create(action_id: action_id, label_id: lid) unless existing
          end
        end

        # --- Certificates ---

        def save_certificate(certificate)
          @db.transaction do
            cert = Certificate.create(
              type:                certificate[:type],
              subject:             certificate[:subject],
              serial_number:       certificate[:serial_number],
              certifier:           certificate[:certifier],
              verifier:            certificate[:verifier],
              revocation_outpoint: certificate[:revocation_outpoint],
              signature:           certificate[:signature]
            )

            certificate[:fields]&.each do |name, value|
              CertificateField.create(
                certificate_id: cert.id,
                name:           name.to_s,
                value:          value.to_s,
                master_key:     certificate.dig(:keyring, name.to_s)
              )
            end

            certificate_to_hash(cert)
          end
        end

        def query_certificates(certifiers:, types:, limit: 10, offset: 0)
          base = Certificate
            .where(certifier: certifiers, type: types)

          total = base.count
          records = base
            .order(Sequel.desc(:created_at))
            .limit(limit).offset(offset).all

          {
            total: total,
            certificates: records.map { |c| certificate_to_hash(c) }
          }
        end

        def delete_certificate(type:, serial_number:, certifier:)
          Certificate
            .where(type: type, serial_number: serial_number, certifier: certifier)
            .delete
        end

        # --- Settings ---

        def get_setting(key:)
          Setting.get(key)
        end

        def set_setting(key:, value:)
          Setting.set(key, value)
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
            if row[:source_wtxid].nil?
              raise "Source action has nil wtxid for input vin #{row[:vin]} of action #{action_id}"
            end

            BSV::Primitives::Hex.validate_wtxid!(row[:source_wtxid], name: "resolve_inputs source vin=#{row[:vin]}")

            {
              vin:                  row[:vin],
              sequence:             row[:sequence],
              source_wtxid:         row[:source_wtxid],
              source_vout:          row[:source_vout],
              source_satoshis:      row[:source_satoshis],
              source_locking_script: row[:source_locking_script],
              derivation_prefix:    row[:derivation_prefix],
              derivation_suffix:    row[:derivation_suffix],
              sender_identity_key:  row[:sender_identity_key]
            }
          end

          BSV.logger&.debug do
            dtxids = result.first(5).map { |r| r[:source_wtxid].reverse.unpack1('H*') }
            suffix = result.size > 5 ? " (+#{result.size - 5} more)" : ''
            "[Store] resolve_inputs_for_signing: action_id=#{action_id} inputs=#{result.size} sources=#{dtxids.join(',')}#{suffix}"
          end

          result
        end

        # --- Change Output Queries ---

        def query_change_output_vouts(action_id:)
          Output.where(action_id: action_id)
                .where(
                  OutputDetail.dataset
                    .where(Sequel[:output_details][:output_id] => Sequel[:outputs][:id])
                    .where(change: true)
                    .select(1)
                    .exists
                )
                .select_map(:vout)
        end

        def promote_change_to_spendable(action_id:)
          change_outputs = Output.where(action_id: action_id)
                                 .where(
                                   OutputDetail.dataset
                                     .where(Sequel[:output_details][:output_id] => Sequel[:outputs][:id])
                                     .where(change: true)
                                     .select(1)
                                     .exists
                                 )
                                 .exclude(
                                   Spendable.where(Sequel[:spendable][:output_id] => Sequel[:outputs][:id])
                                            .select(1).exists
                                 )
                                 .all
          change_outputs.each do |output|
            Spendable.create(output_id: output.id, action_id: action_id)
          end
        end

        # --- UTXO Selection ---

        def find_spendable(satoshis:, basket: nil, exclude: [])
          ds = Output.spendable
          ds = ds.in_basket(basket) if basket
          ds = ds.exclude(Sequel[:outputs][:id] => exclude) if exclude.any?
          ds = ds.order(Sequel.desc(:satoshis))

          candidates = []
          total = 0
          ds.each do |output|
            candidates << {
              id:                  output.id,
              satoshis:            output.satoshis,
              vout:                output.vout,
              action_id:           output.action_id,
              locking_script:      output.locking_script,
              derivation_prefix:   output.derivation_prefix,
              derivation_suffix:   output.derivation_suffix,
              sender_identity_key: output.sender_identity_key
            }
            total += output.satoshis
            break if total >= satoshis
          end
          candidates
        end

        # --- Reaper ---

        def reap_stale_actions(threshold:)
          cutoff = Time.now - threshold
          output_exists = Output.where(Sequel[:outputs][:action_id] => Sequel[:actions][:id]).select(1)

          Action
            .where { created_at < cutoff }
            .where(Sequel.~(broadcast: 'none'))
            .where(Sequel.lit('wtxid IS NOT NULL'))
            .exclude(output_exists.exists)
            .delete
        end

        private

        def action_to_hash(record, include_labels: false, include_inputs: false,
                           include_input_locking_scripts: false,
                           include_outputs: false, include_output_locking_scripts: false, **)
          h = {
            id:          record.id,
            wtxid:       record.wtxid,
            raw_tx:      record.raw_tx,
            reference:   record.reference,
            status:      record.derived_status,
            outgoing:    record.outgoing,
            description: record.description,
            version:     record.version,
            nlocktime:   record.nlocktime,
            broadcast:   record.values[:broadcast],
            created_at:  record.created_at
          }

          if include_labels
            h[:labels] = record.labels.map(&:label)
          end

          if include_inputs
            h[:inputs] = record.inputs.map do |inp|
              ih = {
                output_id:    inp.output_id,
                vin:          inp.vin,
                nsequence:    inp.nsequence,
                description:  inp.description
              }
              if include_input_locking_scripts && inp.output
                ih[:source_locking_script] = inp.output.locking_script
                ih[:source_satoshis] = inp.output.satoshis
              end
              ih
            end
          end

          if include_outputs
            h[:outputs] = record.outputs.map do |out|
              oh = {
                id:          out.id,
                satoshis:    out.satoshis,
                vout:        out.vout,
                spendable:   out.spendable?
              }
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
          h = {
            id:       record.id,
            satoshis: record.satoshis,
            vout:     record.vout,
            spendable: true
          }

          h[:locking_script] = record.locking_script if include_locking_scripts

          if include_custom_instructions && record.detail
            h[:custom_instructions] = record.detail.custom_instructions
            h[:description] = record.detail.description
          end

          if include_tags
            h[:tags] = record.tags.map(&:tag)
          end

          if include_labels && record.action
            h[:labels] = record.action.labels.map(&:label)
          end

          h[:basket] = record.basket&.name
          h
        end

        def certificate_to_hash(record)
          fields = {}
          record.certificate_fields.each { |f| fields[f.name] = f.value }

          {
            id:                  record.id,
            type:                record.type,
            subject:             record.subject,
            serial_number:       record.serial_number,
            certifier:           record.certifier,
            verifier:            record.verifier,
            revocation_outpoint: record.revocation_outpoint,
            signature:           record.signature,
            fields:              fields
          }
        end
      end
    end
  end
end
