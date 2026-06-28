# frozen_string_literal: true

using BSV::Wallet::Txid

module BSV
  module Wallet
    class Engine
      # Business object wrapping a single action's lifecycle.
      #
      # Per-call construction — cheap, discarded on completion. Wraps a
      # +Models::Action+ row hash (+Store#action_to_hash+ output). Adds
      # row-level lifecycle actions (build_deferred!, build_with_caller_inputs!,
      # build_via_funding!, sign_and_save!, complete_internal!,
      # apply_caller_spends!, abort!) and BRC-100 helpers
      # (build_input_specs, build_output_specs).
      #
      # Orchestration lives in +Engine#build_action+ / +#sign_action+
      # (#402 Stage 2). +Action.create+ is now a thin row-creation helper;
      # the lifecycle steps are instance methods so Engine can drive them
      # sequentially without reach-backs.
      class Action
        # ---- Class methods --------------------------------------------------

        # Row-creation helper. Returns an +Action+ instance wrapping a
        # newly-created (empty) +actions+ row. The orchestrator
        # (+Engine#build_action+) drives the lifecycle from here via
        # the instance methods.
        def self.create(engine:, description:, intent:, input_beef: nil, labels: nil)
          row = engine.store.create_action(
            action: { description: description, broadcast_intent: intent,
                      input_beef: input_beef },
            inputs: []
          )
          attach_labels(engine: engine, action_id: row[:id], labels: labels)
          new(engine: engine, row: row)
        end

        # Wallet-vocab action query — returns +{ total:, actions: }+,
        # matching the shape +Store#query_actions+ produces and the
        # other +list_*+ collection primitives use. BRC100 re-keys
        # +:total+ → +:total_actions+ at the wrap layer.
        # Called from +Engine#list_actions+; +originator:+ and
        # +seek_permission:+ stop at the wrap layer per ADR-026
        # decision 7 and are not accepted here.
        def self.list(engine:, labels:, label_query_mode: :any,
                      include_labels: false, include_inputs: false,
                      include_input_source_locking_scripts: false,
                      include_input_unlocking_scripts: false,
                      include_outputs: false, include_output_locking_scripts: false,
                      limit: 10, offset: 0)
          engine.store.query_actions(
            labels: labels, label_query_mode: label_query_mode,
            limit: [limit, 10_000].min, offset: offset,
            include_labels: include_labels, include_inputs: include_inputs,
            include_input_locking_scripts: include_input_source_locking_scripts,
            include_outputs: include_outputs,
            include_output_locking_scripts: include_output_locking_scripts
          )
        end

        # Canonical lookup by BRC-100 reference. Returns an Action wrapping
        # the row, or +nil+ when no action matches.
        def self.find(engine:, reference:)
          row = engine.store.find_action(reference: reference)
          row && new(engine: engine, row: row)
        end

        # Lookup by wallet-local action id (the integer primary key, not a
        # BRC-100 reference). Same shape as +.find+ — a public factory for
        # callers that hold an id rather than a reference.
        def self.find_by_id(engine:, id:)
          row = engine.store.find_action(id: id)
          row && new(engine: engine, row: row)
        end

        # ---- Class helpers (used by non-lifecycle porcelain) ---------------

        # Lock the caller-supplied inputs against the empty action row.
        # Used by the deferred and +skip_change+ (zero-input or pure
        # OP_RETURN) paths — neither runs the funding loop, so they
        # bypass +FundingStrategy+ and use the atomic Store primitive
        # directly. A short-count from +store.lock_inputs+ surfaces as
        # +InsufficientFundsError+, matching the wallet-selected path's
        # behaviour on caller-supplied contention (fail-fast, no retry).
        def self.lock_caller_inputs!(engine:, action_id:, inputs:)
          specs = build_input_specs(inputs)
          return if specs.empty?

          locked = engine.store.lock_inputs(action_id: action_id, inputs: specs)
          return if locked == specs.size

          engine.store.abort_action(action_id: action_id)
          raise BSV::Wallet::InsufficientFundsError
        end

        # Translate caller input specs into Store input specs.
        def self.build_input_specs(inputs)
          return [] unless inputs

          inputs.each_with_index.map do |inp, idx|
            {
              output_id: inp[:output_id],
              vin: inp[:vin] || idx,
              nsequence: inp[:sequence_number],
              description: inp[:input_description]
            }
          end
        end

        # Translate caller outputs into Store output specs. Used by both the
        # synchronous internal path ({Store#complete_internal_action}) and the
        # send-path sign-time persistence ({Store#sign_action}).
        #
        # Every output spec must carry +:spendable_intent+ — +'spendable'+
        # (wallet-owned, joins the UTXO set on promotion) or +'none'+
        # (outbound; no spendable row written). Inferring intent from the
        # presence of +derivation_prefix+ was the anti-pattern HLR #467 /
        # +docs/reference/intent-and-outcomes.md+ removed; the decision-maker
        # states it explicitly. A missing intent is a caller-side bug.
        def self.build_output_specs(outputs, vout_mapping = nil)
          outputs.each_with_index.map do |out, idx|
            vout = if vout_mapping
                     vout_mapping[idx] || idx
                   else
                     out[:vout] || idx
                   end

            unless out[:spendable_intent]
              raise BSV::Wallet::InvalidParameterError.new(
                "outputs[#{idx}].spendable_intent",
                "'spendable' or 'none' (HLR #467 / docs/reference/intent-and-outcomes.md — " \
                'every output spec must state intent explicitly; inference from derivation ' \
                'presence is no longer accepted)'
              )
            end

            {
              satoshis: out[:satoshis],
              vout: vout,
              locking_script: out[:locking_script],
              basket: out[:basket],
              tags: out[:tags],
              description: out[:output_description],
              custom_instructions: out[:custom_instructions],
              spendable_intent: out[:spendable_intent],
              derivation_prefix: out[:derivation_prefix],
              derivation_suffix: out[:derivation_suffix],
              sender_identity_key: out[:sender_identity_key]
            }
          end
        end

        # Attach labels to an action. No-op for nil/empty labels.
        def self.attach_labels(engine:, action_id:, labels:)
          return unless labels&.any?

          label_ids = engine.store.find_or_create_labels(names: labels)
          engine.store.label_action(action_id: action_id, label_ids: label_ids)
        end

        # ---- Instance -------------------------------------------------------

        attr_reader :engine, :id, :row

        # The one canonical +row:+ shape is a +Store#action_to_hash+ hash —
        # a plain Hash keyed by +:id+, +:wtxid+, +:reference+, +:status+, … .
        # Every construction site already hands one over: +.create+ via
        # +store.create_action+, +.find+/+.find_by_id+ via +store.find_action+.
        # The guard fails fast at construction rather than at the first
        # +@row[:x]+ read.
        def initialize(engine:, row:)
          unless row.is_a?(Hash) && row[:id]
            detail = row.is_a?(Hash) ? "Hash with keys #{row.keys.inspect}" : row.class.to_s
            raise ArgumentError,
                  "Action row must be a Store#action_to_hash hash with a non-nil :id (got #{detail})"
          end

          @engine = engine
          @row    = row
          @id     = row[:id]
        end

        # Deferred path: lock caller inputs, build unsigned tx, stage,
        # save proof, return wallet-vocab signable handle.
        #
        # +intent+ flows from the orchestrator (always +:none+, +:delayed+,
        # or +:inline+). +:none+ + nil outputs both suppress the staged
        # pending-outputs persistence — they get written on +sign_action+
        # when the caller comes back with unlocking scripts.
        #
        # @return [Hash] +{ signable: { atomic_beef:, reference: } }+ —
        #   wallet vocab; BRC100 wraps to +{ signable_transaction: { tx:, reference: } }+.
        def build_deferred!(inputs:, outputs:, lock_time:, version:, randomize:, intent:)
          self.class.lock_caller_inputs!(engine: @engine, action_id: @id, inputs: inputs)
          # Resolve inline — the deferred path doesn't go through
          # FundingStrategy, so it owns its single resolve.
          resolved = @engine.store.resolve_inputs_for_signing(action_id: @id)
          build_result = @engine.tx_builder.build(
            resolved_inputs: resolved, caller_outputs: outputs || [],
            caller_inputs: inputs, lock_time: lock_time, version: version,
            randomize: randomize, sign: false
          )
          wtxid = build_result[:wtxid]
          raw_tx = build_result[:raw_tx]
          vout_mapping = build_result[:vout_mapping]
          pending = intent == :none || outputs.nil? ? [] : self.class.build_output_specs(outputs, vout_mapping)
          @engine.store.stage_action(action_id: @id, wtxid: wtxid, raw_tx: raw_tx, outputs: pending)
          @engine.store.save_proof(wtxid: wtxid, proof: { raw_tx: raw_tx })
          # BRC-100: signableTransaction.tx is Atomic BEEF of the unsigned tx
          # so external signers can inspect ancestry without a follow-up call.
          { signable: { atomic_beef: @engine.hydrator.build_atomic_beef(raw_tx, @id),
                        reference: @row[:reference] } }
        end

        # Synchronous + skip-change path: caller-supplied inputs only,
        # build + sign in one TxBuilder pass (no funding loop, no change).
        # Used by the OP_RETURN-only and explicit-caller-inputs cases.
        #
        # @return [Hash] +{ wtxid:, raw_tx:, vout_mapping:, change_outputs: [] }+
        def build_with_caller_inputs!(inputs:, outputs:, lock_time:, version:, randomize:)
          self.class.lock_caller_inputs!(engine: @engine, action_id: @id, inputs: inputs)
          resolved = @engine.store.resolve_inputs_for_signing(action_id: @id)
          build_result = @engine.tx_builder.build(
            resolved_inputs: resolved, caller_outputs: outputs || [],
            caller_inputs: inputs, lock_time: lock_time, version: version,
            randomize: randomize, sign: true
          )
          { wtxid: build_result[:wtxid], raw_tx: build_result[:raw_tx],
            vout_mapping: build_result[:vout_mapping], change_outputs: [] }
        end

        # Wallet-funded path: hand off to +FundingStrategy+ which owns input
        # acquisition (initial + top-up) and the build collaborator's
        # fixpoint loop. Caller-supplied inputs (if any) pin part of the
        # input set; the strategy tops up from the wallet's pool.
        #
        # On +InsufficientFundsError+ the caller (Engine) aborts the empty
        # action row — that decision belongs at the orchestrator level so
        # the headroom recheck after the fact has somewhere to roll back to.
        #
        # @return [Hash] +{ wtxid:, raw_tx:, vout_mapping:, change_outputs:, total_input_satoshis: }+
        def build_via_funding!(outputs:, caller_inputs:, lock_time:, version:, randomize:,
                               change_count:, change_basket: nil)
          funding = @engine.funding_strategy.acquire(
            action_id: @id,
            caller_outputs: outputs || [],
            caller_supplied_inputs: !caller_inputs.nil?,
            caller_inputs: caller_inputs,
            build: lambda { |resolved|
              @engine.tx_builder.build_change(
                resolved_inputs: resolved, caller_outputs: outputs || [],
                caller_inputs: caller_inputs,
                lock_time: lock_time, version: version,
                randomize: randomize, change_count: change_count,
                change_basket: change_basket
              )
            }
          )
          { wtxid: funding[:wtxid], raw_tx: funding[:raw_tx],
            vout_mapping: funding[:vout_mapping],
            change_outputs: funding[:change_outputs],
            total_input_satoshis: funding[:total_input_satoshis] }
        end

        # Send-path sign-time persistence: +Store#sign_action+ writes the
        # signed raw_tx + wtxid + pending outputs + change outputs in one
        # atomic transition, then +#save_proof+ stages the raw_tx in the
        # proof store so the broadcast worker can ship EF.
        def sign_and_save!(built:, outputs:)
          pending = outputs.nil? ? [] : self.class.build_output_specs(outputs, built[:vout_mapping])
          @engine.store.sign_action(
            action_id: @id, wtxid: built[:wtxid], raw_tx: built[:raw_tx],
            outputs: pending, change_outputs: built[:change_outputs]
          )
          @engine.store.save_proof(wtxid: built[:wtxid], proof: { raw_tx: built[:raw_tx] })
        end

        # Internal-path atomic completion: sign + proof + Phase-4 promotion
        # in one Store call so a crash can't strand a signed-but-unpromoted
        # action (#327) or promoted-but-unspendable change (#328). No
        # broadcast to wait for — the whole completion commits at once.
        #
        # +sign_outputs+ is empty by design here: the internal path
        # short-circuits pending-output staging because the outputs jump
        # straight to promoted (the canonical row in +outputs+). Caller
        # outputs land in +promote_outputs+ only — duplicating them into
        # +sign_outputs+ would violate +outputs_action_id_vout_key+.
        def complete_internal!(built:, outputs:)
          promote = outputs&.any? ? self.class.build_output_specs(outputs, built[:vout_mapping]) : []
          @engine.store.complete_internal_action(
            action_id: @id, wtxid: built[:wtxid], raw_tx: built[:raw_tx],
            sign_outputs: [], change_outputs: built[:change_outputs],
            promote_outputs: promote
          )
        end

        # Complete the deferred-signing flow's signing step: deserialise the
        # unsigned tx, apply caller spends, sign remaining wallet-owned
        # P2PKH inputs, persist signed raw_tx + wtxid, save proof. Returns
        # the signed result so the orchestrator can build BEEF + dispatch.
        #
        # @return [Hash] +{ wtxid:, raw_tx: }+
        def apply_caller_spends!(spends:)
          wtxid, raw_tx, = apply_spends(spends)
          @engine.store.sign_action(action_id: @id, wtxid: wtxid, raw_tx: raw_tx)
          @engine.store.save_proof(wtxid: wtxid, proof: { raw_tx: raw_tx })
          { wtxid: wtxid, raw_tx: raw_tx }
        end

        # Abort an in-flight action. Releases any locked inputs and marks
        # the action aborted in the Store.
        #
        # @return [Hash] +{ aborted: true }+
        def abort!
          @engine.store.abort_action(action_id: @id)
          @engine.utxo_pool.release(outputs: [])
          { aborted: true }
        end

        # Outpoints (+dtxid.vout+) of this action's change outputs. Public
        # because +Engine#build_action+ invokes it on the freshly-built
        # instance to populate the no_send return's +change_outpoints:+;
        # operates on the instance's own +@id+.
        def query_change_outpoints
          action = @engine.store.find_action(id: @id)
          return [] unless action&.dig(:wtxid)

          dtxid = action[:wtxid].to_dtxid
          vouts = @engine.store.query_change_output_vouts(action_id: @id)
          vouts.map { |vout| "#{dtxid}.#{vout}" }
        end

        private

        # Apply caller-provided unlocking scripts and sign remaining inputs.
        #
        # Thin orchestration over +TxBuilder#apply_spends+: load the
        # unsigned tx staged during deferred +create_action+, resolve
        # the locked input set, validate that every spend's vin actually
        # exists in the transaction, then delegate the finalise-and-sign
        # core to +tx_builder+. *The transaction builder signs.*
        #
        # @param spends [Hash{Integer => Hash}] vin => { unlocking_script:, sequence_number: }
        # @return [Array(String, String, Transaction::Tx)] wtxid (32-byte wire
        #   order), raw_tx (binary), tx (live Transaction::Tx with source data
        #   wired in for downstream EF serialisation).
        def apply_spends(spends)
          unsigned_raw = @row[:raw_tx]
          raise BSV::Wallet::Error, 'no unsigned transaction for deferred action' unless unsigned_raw

          tx = BSV::Transaction::Tx.from_binary(unsigned_raw)
          resolved_inputs = @engine.store.resolve_inputs_for_signing(action_id: @id)

          # Validate: each spend must reference a vin that exists in the
          # transaction (by source vin or by positional index).
          valid_vins = resolved_inputs.map { |r| r[:vin] }
          valid_indices = (0...resolved_inputs.length).to_a
          spends.each_key do |vin|
            next if valid_vins.include?(vin) || valid_indices.include?(vin)

            raise BSV::Wallet::InvalidParameterError.new(
              'spends', "vin #{vin} does not exist in the transaction"
            )
          end

          @engine.tx_builder.apply_spends(tx: tx, resolved_inputs: resolved_inputs, spends: spends)
        end
      end
    end
  end
end
