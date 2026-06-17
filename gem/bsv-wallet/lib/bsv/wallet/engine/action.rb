# frozen_string_literal: true

module BSV
  module Wallet
    class Engine
      # Business object wrapping a single action's lifecycle.
      #
      # Per-call construction — cheap, discarded on completion. Wraps a
      # +Models::Action+ row hash (or an action result hash carrying +:id+
      # and +:reference+). Adds knowledge (BRC-100 translation, derived
      # status) and atomic actions (sign!, abort!, broadcast!, promote!)
      # on top of the Sequel-row data.
      #
      # Same pattern as +Engine::Broadcast+ / +Engine::TxProof+: collaborators
      # reached via the +engine+ back-reference; no instance state beyond
      # the wrapped row.
      class Action
        # ---- Class methods --------------------------------------------------

        # Migrate +Engine#create_action+'s body. Returns the BRC-100 hash
        # shape that the public Engine API exposes.
        def self.create(engine:, description:, input_beef: nil, inputs: nil, outputs: nil,
                        lock_time: nil, version: nil, labels: nil,
                        sign_and_process: true, accept_delayed_broadcast: true,
                        trust_self: nil, return_txid_only: false,
                        no_send: false, change_count: nil,
                        randomize_outputs: true, originator: nil)
          # Caller-supplied inputs: explicit array (possibly empty) — the
          # wallet does not extend this set. inputs: nil means "select for me".
          caller_supplied_inputs = !inputs.nil?
          deferred = !sign_and_process ||
                     inputs&.any? { |i| i[:unlocking_script_length] && !i[:unlocking_script] }

          # Wallet-selected inputs (inputs: nil) cannot be deferred — the
          # funding loop signs immediately so the change template can be
          # evaluated against the actual fee. Deferred signing only makes
          # sense with caller-supplied inputs the caller intends to script
          # themselves.
          if !caller_supplied_inputs && !sign_and_process
            raise BSV::Wallet::InvalidParameterError.new(
              'sign_and_process', 'true when inputs is nil (wallet-selected inputs sign immediately)'
            )
          end

          # Internal-path deferred signing is not implemented in the base
          # wallet — the internal-action Phase 4 runs synchronously during
          # create_action, which deferred signing cannot reach (#192).
          if no_send && deferred
            raise BSV::Wallet::UnsupportedActionError,
                  'createAction(no_send: true) combined with deferred signing is not implemented in the base wallet; tracked in #192.'
          end

          # key_deriver is required only when the wallet must derive BRC-42
          # change keys (generate_change). Deferred signing defers to
          # signAction; explicit zero-input transactions skip change
          # generation. Both paths can run without a key deriver here.
          skip_change = caller_supplied_inputs && inputs.empty?
          engine.send(:require_key_deriver!) unless deferred || skip_change

          broadcast = engine.send(:determine_broadcast, no_send, accept_delayed_broadcast)
          engine.send(:enforce_limp_mode!)

          # Output total drives the initial selection target and the cheap
          # pre-flight headroom check. The exact post-loop headroom check
          # (sum(outputs) + actual_fee) runs after generate_change converges.
          # pre_lock_balance / change_count are captured before Phase 1
          # locking shrinks the spendable set; both headroom checks use the
          # pre-lock balance, and the funding loop uses the pre-lock change
          # count so target sizing reflects the wallet's full pool.
          output_total = outputs&.sum { |o| o[:satoshis] || 0 } || 0
          pre_lock_balance = engine.utxo_pool.balance
          # +change_count:+ kwarg overrides the pool's grooming heuristic. Use
          # cases: consolidation (target a single output), explicit-cap callers.
          pre_lock_change_count = change_count || engine.utxo_pool.change_output_count
          engine.send(:enforce_headroom_against!, pre_lock_balance, output_total) unless deferred

          # Phase 1a: create the empty action row. Input acquisition runs
          # through FundingStrategy against this row's +action_id+; an
          # input-less action row is already routine (the deferred path
          # and the no-output path both produce one). See option (a) in
          # `reference/createaction-lifecycle.md`.
          action_result = engine.store.create_action(
            action: {
              description: description, broadcast_intent: broadcast,
              input_beef: input_beef
            },
            inputs: []
          )

          attach_labels(engine: engine, action_id: action_result[:id], labels: labels)

          action = new(engine: engine, row: action_result)

          # Deferred path: assemble unsigned tx, stage, return signable handle.
          # Always caller-supplied inputs (enforced above). Lock the caller's
          # inputs atomically against the empty action row, then build.
          if deferred
            lock_caller_inputs!(engine: engine, action_id: action_result[:id], inputs: inputs)
            # Resolve inline — the deferred path doesn't go through
            # FundingStrategy, so it owns its single resolve.
            resolved = engine.store.resolve_inputs_for_signing(action_id: action_result[:id])
            build_result = engine.tx_builder.build(
              resolved_inputs: resolved, caller_outputs: outputs || [],
              caller_inputs: inputs, lock_time: lock_time, version: version,
              randomize: randomize_outputs, sign: false
            )
            wtxid = build_result[:wtxid]
            raw_tx = build_result[:raw_tx]
            vout_mapping = build_result[:vout_mapping]
            pending_outputs = broadcast == :none || outputs.nil? ? [] : build_output_specs(outputs, vout_mapping)
            engine.store.stage_action(
              action_id: action_result[:id], wtxid: wtxid, raw_tx: raw_tx,
              outputs: pending_outputs
            )
            engine.store.save_proof(wtxid: wtxid, proof: { raw_tx: raw_tx })
            # BRC-100: signableTransaction.tx is Atomic BEEF of the unsigned tx
            # so external signers can inspect ancestry without a follow-up call.
            return {
              signable_transaction: {
                tx: engine.hydrator.build_atomic_beef(raw_tx, action_result[:id]),
                reference: action_result[:reference]
              }
            }
          end

          # Synchronous path. The empty-inputs case (OP_RETURN-only) skips
          # change generation — already detected above to keep the
          # key_deriver check honest. Caller inputs (if any) are caller-
          # supplied; lock them once, no funding loop.
          if skip_change
            lock_caller_inputs!(engine: engine, action_id: action_result[:id], inputs: inputs)
            # Resolve inline — skip_change bypasses the funding loop, so
            # it owns its single resolve (mirrors the deferred path).
            resolved = engine.store.resolve_inputs_for_signing(action_id: action_result[:id])
            build_result = engine.tx_builder.build(
              resolved_inputs: resolved, caller_outputs: outputs || [],
              caller_inputs: inputs, lock_time: lock_time, version: version,
              randomize: randomize_outputs, sign: true
            )
            wtxid = build_result[:wtxid]
            raw_tx = build_result[:raw_tx]
            vout_mapping = build_result[:vout_mapping]
            change_outputs = []
          else
            # FundingStrategy owns input acquisition (initial + top-up) and
            # the build collaborator's fixpoint loop. On +InsufficientFundsError+
            # (caller-supplied shortfall, pool depletion, or contention-retry
            # exhaustion) abort the empty action row so no orphan is left.
            begin
              funding = engine.funding_strategy.acquire(
                action_id: action_result[:id],
                caller_outputs: outputs || [],
                caller_supplied_inputs: caller_supplied_inputs,
                caller_inputs: caller_supplied_inputs ? inputs : nil,
                build: lambda { |resolved|
                  engine.tx_builder.build_change(
                    resolved_inputs: resolved, caller_outputs: outputs || [],
                    caller_inputs: caller_supplied_inputs ? inputs : nil,
                    lock_time: lock_time, version: version,
                    randomize: randomize_outputs,
                    change_count: pre_lock_change_count
                  )
                }
              )
            rescue BSV::Wallet::InsufficientFundsError
              engine.store.abort_action(action_id: action_result[:id])
              raise
            end
            wtxid          = funding[:wtxid]
            raw_tx         = funding[:raw_tx]
            vout_mapping   = funding[:vout_mapping]
            change_outputs = funding[:change_outputs]
            # Exact post-loop headroom check: actual fee is now known. Use the
            # by-value sat-total from FundingStrategy so we don't re-fetch
            # resolved inputs.
            actual_fee = funding[:total_input_satoshis] -
                         output_total - change_outputs.sum { |c| c[:satoshis] }
            engine.send(:enforce_headroom_against!, pre_lock_balance, output_total + actual_fee)
          end

          pending_outputs = broadcast == :none || outputs.nil? ? [] : build_output_specs(outputs, vout_mapping)
          engine.store.sign_action(
            action_id: action_result[:id], wtxid: wtxid, raw_tx: raw_tx,
            outputs: pending_outputs, change_outputs: change_outputs
          )
          engine.store.save_proof(wtxid: wtxid, proof: { raw_tx: raw_tx })
          BSV.logger&.debug do
            "[Engine] create_action: dtxid=#{wtxid.reverse.unpack1('H*')} " \
              "outputs=#{outputs&.length || 0} change=#{change_outputs.length}"
          end

          atomic_beef = engine.hydrator.build_atomic_beef(raw_tx, action_result[:id])
          # SPV honesty contract: refuse to return a BEEF a peer wouldn't
          # accept. Under strict create_action (#296 Phase B), returning
          # from create_action implies a valid BEEF in hand.
          engine.hydrator.validate_for_handoff!(atomic_beef, wtxid)
          # Push the just-built BEEF as a cache hint so the daemon's
          # broadcast skips both Store#find_action and the input source-data
          # JOIN. BEEF is a strict superset of EF for the subject tx (parent
          # transactions are inlined), so the receiver can prime the cache
          # with a Transaction::Tx whose source_transaction is already wired;
          # daemon's submit emits EF via Transaction::Tx#to_ef_hex on that same
          # object. Producer pays zero extra queries (atomic_beef was built
          # for the caller's return value either way). Opt-in via
          # BSV_WALLET_HINTS_SOCKET; no-op otherwise. #269.
          # publish_beef_hint stays private on Engine; reach via +send+ rather
          # than making it part of the public surface for one caller.
          engine.send(:publish_beef_hint, action_result[:id], atomic_beef) unless no_send

          # Internal-path (no_send): synchronous Phase 4 — promote caller
          # outputs, promote change to spendable, return change outpoints.
          if no_send
            action.send(:promote_with_outputs, action_result[:id], outputs, vout_mapping)
            engine.store.promote_change_to_spendable(action_id: action_result[:id]) if change_outputs.any?
            change = action.send(:query_change_outpoints, action_result[:id])
            return { txid: wtxid, tx: atomic_beef, no_send_change: change }
          end

          # Phase 3 + 4: Broadcast inline. The broadcast worker (same one the
          # daemon's PULL loop uses) handles the 202 / 400 / 503 dispatch
          # internally: atomic Phase 4 promotion on accepted, reject_action
          # cascade on terminal 400, broadcast_at clear on 503, eager proof
          # linking when the response carries merkle material. Delayed
          # broadcasts are picked up by the daemon's push-discovery loop from
          # the broadcasts row that sign_action created atomically above. #271.
          engine.broadcast_worker.process(action_result[:id]) if broadcast == :inline

          { txid: wtxid, tx: return_txid_only ? nil : atomic_beef }
        end

        # Migrate +Engine#list_actions+'s body. Returns the BRC-100 hash
        # shape +{ total_actions:, actions: }+ from +Store#query_actions+.
        def self.list(engine:, labels:, label_query_mode: :any,
                      include_labels: false, include_inputs: false,
                      include_input_source_locking_scripts: false,
                      include_input_unlocking_scripts: false,
                      include_outputs: false, include_output_locking_scripts: false,
                      limit: 10, offset: 0, seek_permission: true, originator: nil)
          result = engine.store.query_actions(
            labels: labels, label_query_mode: label_query_mode,
            limit: [limit, 10_000].min, offset: offset,
            include_labels: include_labels, include_inputs: include_inputs,
            include_input_locking_scripts: include_input_source_locking_scripts,
            include_outputs: include_outputs,
            include_output_locking_scripts: include_output_locking_scripts
          )
          { total_actions: result[:total], actions: result[:actions] }
        end

        # Canonical lookup by BRC-100 reference. Returns an Action wrapping
        # the row, or +nil+ when no action matches.
        def self.find(engine:, reference:)
          row = engine.store.find_action(reference: reference)
          row && new(engine: engine, row: row)
        end

        # Internal lookup by wallet-local action id. Same shape as +.find+ —
        # operator-facing porcelain (e.g. +bin/reject_action+) targets rows
        # by id, not by reference.
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
        # synchronous internal path ({#promote_with_outputs}) and the
        # send-path sign-time persistence ({Store#sign_action}).
        def self.build_output_specs(outputs, vout_mapping = nil)
          outputs.each_with_index.map do |out, idx|
            vout = if vout_mapping
                     vout_mapping[idx] || idx
                   else
                     out[:vout] || idx
                   end

            # Outputs without derivation data or explicit output_type are
            # payments to others — mark as outbound so the constraint on
            # outputs (NULL type requires derivation) is satisfied.
            effective_type = out[:output_type] || (out[:derivation_prefix] ? nil : 'outbound')

            {
              satoshis: out[:satoshis],
              vout: vout,
              locking_script: out[:locking_script],
              basket: out[:basket],
              tags: out[:tags],
              description: out[:output_description],
              custom_instructions: out[:custom_instructions],
              output_type: effective_type,
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

        def initialize(engine:, row:)
          @engine = engine
          @row    = row
          @id     = row[:id]
        end

        # Complete the deferred-signing path: deserialise the unsigned tx,
        # apply caller spends, sign remaining wallet-owned P2PKH inputs,
        # persist, build the Atomic BEEF envelope, and dispatch broadcast
        # per the action's intent.
        #
        # @return [Hash] +{ txid:, tx: }+ — +txid+ is the wire-order wtxid,
        #   +tx+ is Atomic BEEF binary (or +nil+ when +return_txid_only:+).
        def sign!(spends:, no_send:, accept_delayed_broadcast:, return_txid_only:)
          # Runtime broadcast-override at sign time belongs to the
          # chained-send subsystem (#192). The base wallet's signAction
          # only completes the deferred-construction lifecycle per the
          # original broadcast intent set at createAction time.
          if no_send && @row[:broadcast_intent] != 'none'
            raise BSV::Wallet::UnsupportedActionError,
                  'signAction(no_send: true) requires the action to have been ' \
                  "created with no_send: true (broadcast intent 'none'). " \
                  'Runtime override at sign time is not implemented in the base ' \
                  'wallet; tracked in #192.'
          end

          # Outputs were already written during create_action (promoted: false)
          # so sign! only deserialises the unsigned tx, applies caller
          # unlocking scripts, signs remaining P2PKH inputs, and updates the
          # action with the signed raw_tx + wtxid.
          wtxid, raw_tx, = apply_spends(spends)
          @engine.store.sign_action(action_id: @id, wtxid: wtxid, raw_tx: raw_tx)
          @engine.store.save_proof(wtxid: wtxid, proof: { raw_tx: raw_tx })

          # Build Atomic BEEF envelope for the :tx return value
          atomic_beef = @engine.hydrator.build_atomic_beef(raw_tx, @id)
          # SPV honesty contract (#296 Phase B): refuse to ship invalid BEEF.
          # Same contract as Action.create's synchronous path.
          @engine.hydrator.validate_for_handoff!(atomic_beef, wtxid)

          broadcast = @engine.send(:determine_broadcast, no_send, accept_delayed_broadcast)

          return { txid: wtxid, tx: atomic_beef } if no_send

          # See Action.create: the broadcast worker handles dispatch +
          # bookkeeping internally. #271.
          @engine.broadcast_worker.process(@id) if broadcast == :inline

          { txid: wtxid, tx: return_txid_only ? nil : atomic_beef }
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

        # Internal-path Phase 4: synchronously promote outputs and create
        # spendable rows in one shot. Used for incoming actions (broadcast
        # intent 'none'): internalize_action, import_utxo self-payment, wbikd.
        def promote_with_outputs(action_id, outputs, vout_mapping = nil)
          return unless outputs&.any?

          @engine.store.promote_action(
            action_id: action_id,
            outputs: self.class.build_output_specs(outputs, vout_mapping)
          )
        end

        def query_change_outpoints(action_id)
          action = @engine.store.find_action(id: action_id)
          return [] unless action&.dig(:wtxid)

          dtxid = action[:wtxid].reverse.unpack1('H*')
          vouts = @engine.store.query_change_output_vouts(action_id: action_id)
          vouts.map { |vout| "#{dtxid}.#{vout}" }
        end
      end
    end
  end
end
