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

          # Phase 1: resolve initial inputs and lock the action.
          # - caller_supplied_inputs (including empty array): use as-is.
          # - inputs: nil + outputs present: select to cover sum(outputs).
          # - inputs: nil + no outputs: no selection (nothing to fund).
          initial_inputs =
            if caller_supplied_inputs
              build_input_specs(inputs)
            elsif output_total.positive?
              engine.send(:select_inputs, target_satoshis: output_total)
            else
              []
            end

          action_result = engine.store.create_action(
            action: {
              description: description, broadcast_intent: broadcast,
              nlocktime: lock_time || 0, version: version,
              input_beef: input_beef, outgoing: true
            },
            inputs: initial_inputs
          )
          raise BSV::Wallet::InsufficientFundsError if action_result.nil?

          attach_labels(engine: engine, action_id: action_result[:id], labels: labels)

          action = new(engine: engine, row: action_result)

          # Deferred path: assemble unsigned tx, stage, return signable handle.
          # No change generation on this path (preserved from prior behaviour).
          if deferred
            wtxid, raw_tx, vout_mapping = action.send(
              :build_transaction,
              action_result[:id], inputs, outputs,
              lock_time, version, randomize_outputs, sign: false
            )
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
                tx: action.send(:build_atomic_beef, raw_tx, action_result[:id]),
                reference: action_result[:reference]
              }
            }
          end

          # Synchronous path. The empty-inputs case (OP_RETURN-only) skips
          # change generation — already detected above to keep the
          # key_deriver check honest.
          if skip_change
            wtxid, raw_tx, vout_mapping, = action.send(
              :build_transaction,
              action_result[:id], inputs, outputs,
              lock_time, version, randomize_outputs, sign: true
            )
            change_outputs = []
          else
            wtxid, raw_tx, vout_mapping, change_outputs, = action.send(
              :run_funding_loop,
              action_id: action_result[:id],
              caller_outputs: outputs || [],
              caller_supplied_inputs: caller_supplied_inputs,
              caller_inputs: caller_supplied_inputs ? inputs : nil,
              initial_locked_output_ids: initial_inputs.map { |i| i[:output_id] },
              change_count: pre_lock_change_count,
              lock_time: lock_time, version: version,
              randomize_outputs: randomize_outputs
            )
            # Exact post-loop headroom check: actual fee is now known.
            actual_fee = action.send(:total_input_satoshis_for, action_result[:id]) -
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

          atomic_beef = action.send(:build_atomic_beef, raw_tx, action_result[:id])
          # Push the just-built BEEF as a cache hint so the daemon's
          # broadcast skips both Store#find_action and the input source-data
          # JOIN. BEEF is a strict superset of EF for the subject tx (parent
          # transactions are inlined), so the receiver can prime the cache
          # with a Transaction whose source_transaction is already wired;
          # daemon's submit emits EF via Transaction#to_ef_hex on that same
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

        # ---- Class helpers (used by non-lifecycle porcelain) ---------------

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

        private

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

        # Outgoing BEEF: constructed from our own ProofStore — verification is
        # for incoming untrusted data only (see verify_incoming_transaction!).
        #
        # @param raw_tx [String] signed transaction binary (wire format)
        # @param action_id [Integer] action whose inputs to resolve for ancestry
        # @return [String] Atomic BEEF binary
        def build_atomic_beef(raw_tx, action_id)
          tx = BSV::Transaction::Transaction.from_binary(raw_tx)
          resolved_inputs = @engine.store.resolve_inputs_for_signing(action_id: action_id)

          resolved_inputs.each_with_index do |resolved, idx|
            input = tx.inputs[idx]
            next unless input

            input.source_transaction = wire_ancestor(resolved[:source_wtxid])
          end

          beef = BSV::Transaction::Beef.new
          beef.merge_transaction(tx)
          beef.to_atomic_binary(tx.wtxid)
        end

        # Load an ancestor transaction from ProofStore and recursively wire
        # its source_transaction graph for BEEF construction.
        #
        # Proven ancestors (with merkle_path) are terminal — no recursion needed.
        # Unconfirmed ancestors recurse into each input's prev_wtxid.
        # Uses ProofStore only — zero Store dependencies.
        #
        # @param wtxid [String] 32-byte wire-order wtxid
        # @param visited [Set] prevents infinite loops on circular references
        # @return [BSV::Transaction::Transaction, nil]
        def wire_ancestor(wtxid, visited: Set.new)
          return if visited.include?(wtxid)

          visited.add(wtxid)

          proof = @engine.store.find_proof(wtxid: wtxid)
          return unless proof && proof[:raw_tx] && proof[:raw_tx].bytesize >= 10

          tx = BSV::Transaction::Transaction.from_binary(proof[:raw_tx])

          if proof[:merkle_path]
            tx.merkle_path = BSV::Transaction::MerklePath.from_binary(proof[:merkle_path]).first
            return tx # Proven terminal — no need to recurse
          end

          # Unconfirmed: wire each input's source recursively
          tx.inputs.each do |input|
            ancestor = wire_ancestor(input.prev_wtxid, visited: visited)
            input.source_transaction = ancestor if ancestor
          end

          tx
        end

        # Build TransactionOutput objects from caller output specs.
        #
        # Each output spec has :satoshis and :locking_script (binary or hex).
        # When randomize is true, the output order is shuffled and a mapping
        # from original index to new vout position is returned.
        #
        # @param outputs [Array<Hash>] output specifications
        # @param randomize [Boolean] whether to shuffle output order
        # @return [Array(Array<TransactionOutput>, Hash<Integer,Integer>)]
        #   the ordered outputs and original-index-to-vout mapping
        def build_outputs(outputs, randomize)
          return [[], {}] if outputs.nil? || outputs.empty?

          tx_outputs = outputs.map do |out|
            script = resolve_locking_script(out[:locking_script])
            BSV::Transaction::TransactionOutput.new(
              satoshis: out[:satoshis] || 0,
              locking_script: script
            )
          end

          indices = (0...tx_outputs.length).to_a

          if randomize && tx_outputs.length > 1
            indices.shuffle!
            tx_outputs = indices.map { |i| tx_outputs[i] }
          end

          # Map original index → new vout position
          vout_mapping = {}
          indices.each_with_index { |orig, new_pos| vout_mapping[orig] = new_pos }

          [tx_outputs, vout_mapping]
        end

        # Resolve a locking script value to a Script object.
        #
        # Binary strings (ASCII-8BIT / non-hex) are wrapped via from_binary.
        # Hex strings are decoded via from_hex.
        def resolve_locking_script(script_data)
          if script_data.encoding == Encoding::ASCII_8BIT || !script_data.match?(/\A[0-9a-fA-F]*\z/)
            BSV::Script::Script.from_binary(script_data)
          else
            BSV::Script::Script.from_hex(script_data)
          end
        end

        # Build TransactionInput objects from resolved input data.
        #
        # For each resolved input (from Store#resolve_inputs_for_signing):
        # - Creates a TransactionInput with the source outpoint
        # - Sets source_satoshis and source_locking_script for sighash computation
        # - For P2PKH inputs: derives the signing key via KeyDeriver
        # - For custom scripts: uses the caller-provided unlocking_script
        #
        # @param resolved_inputs [Array<Hash>] from Store#resolve_inputs_for_signing
        # @param caller_inputs [Array<Hash>, nil] the original inputs array from create_action
        # @return [Array(Array<TransactionInput>, Hash<Integer, PrivateKey>)]
        #   the ordered inputs and a mapping of input index to derived PrivateKey
        #   (nil for custom script inputs)
        def build_inputs(resolved_inputs, caller_inputs)
          return [[], {}] if resolved_inputs.nil? || resolved_inputs.empty?

          tx_inputs = []
          signing_keys = {}

          resolved_inputs.each_with_index do |resolved, idx|
            # source_wtxid is wire order; TransactionInput#prev_wtxid expects wire order.
            input = BSV::Transaction::TransactionInput.new(
              prev_wtxid: resolved[:source_wtxid],
              prev_tx_out_index: resolved[:source_vout],
              sequence: resolved[:sequence] || 0xFFFFFFFF
            )
            InputSource.attach!(input, resolved)
            locking_script = input.source_locking_script

            # Find the caller's input spec for this vin (for custom unlocking scripts)
            caller_input = find_caller_input(caller_inputs, resolved[:vin])

            if caller_input&.dig(:unlocking_script)
              # Custom unlocking script provided by the caller
              input.unlocking_script = resolve_unlocking_script(caller_input[:unlocking_script])
            elsif locking_script&.p2pkh?
              # P2PKH: derive the signing key
              @engine.send(:require_key_deriver!)
              signing_keys[idx] = derive_signing_key(resolved)
            else
              raise BSV::Wallet::Error,
                    "input at vin #{resolved[:vin]} has a non-P2PKH locking script " \
                    'and no unlocking_script was provided'
            end

            tx_inputs << input
          end

          [tx_inputs, signing_keys]
        end

        # Resolve an unlocking script value to a Script object.
        #
        # @param script_data [String] binary or hex unlocking script
        # @return [Script::Script]
        def resolve_unlocking_script(script_data)
          if script_data.encoding == Encoding::ASCII_8BIT || !script_data.match?(/\A[0-9a-fA-F]*\z/)
            BSV::Script::Script.from_binary(script_data)
          else
            BSV::Script::Script.from_hex(script_data)
          end
        end

        # Find the caller's input spec matching a given vin.
        #
        # @param caller_inputs [Array<Hash>, nil]
        # @param vin [Integer]
        # @return [Hash, nil]
        def find_caller_input(caller_inputs, vin)
          return unless caller_inputs

          caller_inputs.each_with_index do |inp, idx|
            return inp if (inp[:vin] || idx) == vin
          end
          nil
        end

        # Derive a private key for signing a P2PKH input.
        #
        # When derivation_prefix is nil, the output was paid directly to the
        # identity (root) key — return it without BRC-42/43 derivation.
        #
        # Otherwise maps the resolved input's derivation parameters to
        # KeyDeriver's protocol_id/key_id/counterparty format:
        # - protocol_id: [2, derivation_prefix]
        # - key_id: derivation_suffix
        # - counterparty: sender_identity_key, or 'self' for self-payments
        #
        # @param resolved [Hash] a single resolved input hash
        # @return [BSV::Primitives::PrivateKey]
        def derive_signing_key(resolved)
          if resolved[:derivation_prefix].nil?
            BSV.logger&.debug { '[Engine::Action] derive_signing_key: root key (no derivation)' }
            return @engine.key_deriver.root_private_key
          end

          BSV.logger&.debug { "[Engine::Action] derive_signing_key: derived prefix=#{resolved[:derivation_prefix]}" }
          counterparty = resolved[:sender_identity_key] || 'self'

          @engine.key_deriver.derive_private_key(
            protocol_id: [2, resolved[:derivation_prefix]],
            key_id: resolved[:derivation_suffix],
            counterparty: counterparty
          )
        end

        # Assemble, optionally sign, and serialize an SDK transaction.
        #
        # Resolves locked inputs from the Store, builds TransactionInput and
        # TransactionOutput objects via the helpers, signs P2PKH inputs (unless
        # sign: false), and serializes.
        #
        # When sign is false, the transaction is assembled with empty unlocking
        # scripts for P2PKH inputs. This produces a valid serialized transaction
        # that can be deserialized later for deferred signing.
        #
        # @param action_id [Integer] the action whose locked inputs to resolve
        # @param inputs [Array<Hash>, nil] caller's input specs (for custom unlocking scripts)
        # @param outputs [Array<Hash>, nil] caller's output specs
        # @param lock_time [Integer, nil] nLockTime
        # @param version [Integer, nil] transaction version
        # @param randomize [Boolean] whether to shuffle output order
        # @param sign [Boolean] whether to sign P2PKH inputs (default: true)
        # @return [Array(String, String, Hash, Transaction)] wtxid (32-byte
        #   wire order), raw_tx (binary), vout_mapping (original index ->
        #   new vout), and the assembled tx (signed when +sign:+ is true,
        #   needed downstream for EF serialisation).
        def build_transaction(action_id, inputs, outputs, lock_time, version, randomize, sign: true)
          resolved_inputs = @engine.store.resolve_inputs_for_signing(action_id: action_id)

          tx_outputs, vout_mapping = build_outputs(outputs, randomize)
          tx_inputs, signing_keys = build_inputs(resolved_inputs, inputs)

          tx = BSV::Transaction::Transaction.new(
            version: version || 1,
            lock_time: lock_time || 0
          )

          tx_inputs.each { |inp| tx.add_input(inp) }
          tx_outputs.each { |out| tx.add_output(out) }

          signing_keys.each { |idx, key| tx.sign(idx, key) } if sign

          raw_tx = tx.to_binary
          wtxid = tx.wtxid

          [wtxid, raw_tx, vout_mapping, tx]
        end

        # Funding loop (#210): drive generate_change until inputs cover the
        # actual fee. On a shortfall, top up via select_inputs + lock_inputs
        # and re-evaluate. Bounded by the spendable-pool size to prevent
        # pathological infinite loops; in practice converges in one or two
        # iterations.
        #
        # Caller-supplied inputs are fixed — a shortfall raises immediately
        # with no top-up attempted. Auto-fund top-ups that exhaust the pool
        # surface as InsufficientFundsError (wrapping PoolDepletedError).
        #
        # @return [Array(String, String, Hash, Array<Hash>, Transaction)]
        #   wtxid, raw_tx, vout_mapping, change_outputs, tx — the
        #   trailing +tx+ is the live +BSV::Transaction::Transaction+
        #   object with +source_satoshis+ / +source_locking_script+ wired
        #   on each input, ready for +to_ef+ at broadcast time.
        def run_funding_loop(action_id:, caller_outputs:,
                             caller_supplied_inputs:, caller_inputs:,
                             initial_locked_output_ids:,
                             change_count:,
                             lock_time:, version:, randomize_outputs:)
          locked_output_ids = initial_locked_output_ids.dup
          max_iterations = [@engine.utxo_pool.spendable_count + 1, 2].max

          max_iterations.times do
            result = generate_change(
              action_id: action_id, caller_outputs: caller_outputs,
              caller_inputs: caller_inputs,
              lock_time: lock_time, version: version, randomize: randomize_outputs,
              change_count: change_count
            )
            unless result[:shortfall]
              return [result[:wtxid], result[:raw_tx], result[:vout_mapping],
                      result[:change_outputs], result[:tx]]
            end

            raise BSV::Wallet::InsufficientFundsError if caller_supplied_inputs

            begin
              extra = @engine.send(:select_inputs, target_satoshis: result[:shortfall], exclude: locked_output_ids)
            rescue BSV::Wallet::PoolDepletedError
              raise BSV::Wallet::InsufficientFundsError
            end
            raise BSV::Wallet::InsufficientFundsError if extra.empty?

            # Re-vin against the existing lock count so vin numbering stays
            # contiguous on the inputs table.
            base_vin = locked_output_ids.length
            top_up = extra.each_with_index.map do |spec, i|
              { output_id: spec[:output_id], vin: base_vin + i }
            end
            # Store#lock_inputs returns the count actually locked. Anything less
            # than top_up.size means at least one row was contended and the whole
            # batch rolled back. Treat that as a funding failure rather than
            # silently advancing locked_output_ids (which would desynchronise
            # base_vin from the real inputs table). Phase-1 contention-retry is
            # tracked separately (see #213).
            locked = @engine.store.lock_inputs(action_id: action_id, inputs: top_up)
            raise BSV::Wallet::InsufficientFundsError unless locked == top_up.size

            locked_output_ids.concat(top_up.map { |i| i[:output_id] })
          end

          raise BSV::Wallet::InsufficientFundsError
        end

        # Sum source_satoshis across all inputs currently locked to action_id.
        # Used by the exact post-loop headroom check.
        def total_input_satoshis_for(action_id)
          @engine.store.resolve_inputs_for_signing(action_id: action_id).sum { |r| r[:source_satoshis] }
        end

        # Build a transaction with BRC-42 change derivation, explicit fee
        # detection, and shortfall reporting.
        #
        # Works regardless of input source (caller-supplied or wallet-selected);
        # the inputs must already be locked to +action_id+ when this is called.
        #
        # Order of operations:
        #   build -> attach templates -> fee check -> distribute_change -> shuffle -> sign
        #   Templates before fee (estimated_size needs them).
        #   Fee check before distribute_change so a shortfall is reported
        #     before any change is allocated.
        #   Distribute before shuffle (Benford remainder targets @outputs.last).
        #   Shuffle before sign (sighash commits to final output positions).
        #
        # The SDK's +Transaction#fee+ does not raise on insufficient inputs:
        # +distribute_change+ silently drops all change outputs when
        # +available <= 0+. To get an explicit shortfall we call
        # +FeeModels::SatoshisPerKilobyte#compute_fee(tx)+ against the
        # templated tx and compare to +total_input_satoshis - sum(caller
        # outputs)+. Only when the surplus exceeds the required fee do we
        # delegate to +tx.fee+ for change distribution.
        #
        # @param change_count [Integer] number of BRC-42 change outputs to
        #   derive. Precondition: must be >= 1. +@utxo_pool.change_output_count+
        #   clamps to +[1, MAX_CHANGE_PER_TX]+ so in normal operation this is
        #   invariant; the assertion makes the contract explicit.
        # @param caller_inputs [Array<Hash>, nil] original caller-supplied input
        #   specs, used by +build_inputs+ to apply custom +unlocking_script+ /
        #   +sequence_number+ overrides. +nil+ when the wallet selected inputs
        #   itself (no caller overrides apply).
        # @return [Hash] one of:
        #   - +{ wtxid:, raw_tx:, vout_mapping:, change_outputs: }+ on success.
        #     +change_outputs+ lists only the change rows that survived
        #     +distribute_change+ — empty when the surplus exactly covers
        #     the fee.
        #   - +{ shortfall: N }+ where +N+ is the positive deficit in satoshis
        #     (+required_fee - surplus+) when inputs do not cover the fee.
        def generate_change(action_id:, caller_outputs:,
                            lock_time:, version:, randomize:,
                            change_count:, caller_inputs: nil)
          raise ArgumentError, "change_count must be >= 1, got #{change_count}" if change_count < 1

          # A. Resolve inputs + derive signing keys. caller_inputs lets
          # build_inputs apply any caller-supplied unlocking_script / sequence
          # overrides on the synchronous caller-inputs path.
          resolved_inputs = @engine.store.resolve_inputs_for_signing(action_id: action_id)
          tx_inputs, signing_keys = build_inputs(resolved_inputs, caller_inputs)

          # B. Derive change output keys (BRC-42 self-payments)
          change_keys = change_count.times.map do |i|
            prefix = random_derivation
            suffix = (i + 1).to_s
            pub = @engine.key_deriver.derive_public_key(
              protocol_id: [2, prefix], key_id: suffix, counterparty: 'self'
            )
            script = BSV::Script::Script.p2pkh_lock(
              BSV::Primitives::Digest.hash160(pub)
            )
            { prefix: prefix, suffix: suffix, script: script }
          end

          # C. Build all outputs (caller + change)
          caller_tx_outputs = caller_outputs.map do |out|
            BSV::Transaction::TransactionOutput.new(
              satoshis: out[:satoshis] || 0,
              locking_script: resolve_locking_script(out[:locking_script])
            )
          end
          change_tx_outputs = change_keys.map do |ck|
            BSV::Transaction::TransactionOutput.new(
              satoshis: 0, locking_script: ck[:script], change: true
            )
          end

          # C2. Assemble transaction — change outputs last so SDK's
          # distribute_change targets them all.
          tx = BSV::Transaction::Transaction.new(
            version: version || 1, lock_time: lock_time || 0
          )
          tx_inputs.each { |inp| tx.add_input(inp) }
          caller_tx_outputs.each { |out| tx.add_output(out) }
          change_tx_outputs.each { |co| tx.add_output(co) }

          # D. Attach P2PKH templates for fee estimation
          signing_keys.each do |idx, key|
            tx.inputs[idx].unlocking_script_template = BSV::Transaction::P2PKH.new(key)
          end

          # E. Explicit fee detection. compute_fee asks the model "what fee
          # would this tx require?" without mutating the tx. Surplus is the
          # caller-side balance with change still at 0 sats. If the required
          # fee exceeds the surplus, return a shortfall before distributing.
          fee_model = BSV::Transaction::FeeModels::SatoshisPerKilobyte.new(value: 100)
          required_fee = fee_model.compute_fee(tx)
          surplus = tx.total_input_satoshis - caller_tx_outputs.sum(&:satoshis)
          return { shortfall: required_fee - surplus } if required_fee > surplus

          # F. Surplus covers fee — distribute remaining sats across change
          # outputs (Benford for privacy). The SDK drops change outputs whose
          # share rounds to zero, hence the surviving_change filter below.
          tx.fee(fee_model, change_distribution: :random)
          surviving_change = change_tx_outputs.select { |co| tx.outputs.include?(co) }

          # G. Shuffle outputs AFTER fee distribution — fee computation
          # doesn't depend on order, but SDK distributes change across all
          # change-flagged outputs so they must be present during tx.fee.
          tx.outputs.shuffle! if randomize && tx.outputs.length > 1

          # H. Compute final vout positions (post-shuffle)
          vout_mapping = {}
          caller_tx_outputs.each_with_index do |co, orig_idx|
            vout_mapping[orig_idx] = tx.outputs.index(co)
          end

          # I. Sign (AFTER fee and shuffle — sighash commits to final output values+positions)
          signing_keys.each { |idx, key| tx.sign(idx, key) }

          # J. Build change_outputs specs for atomic store write
          change_output_specs = surviving_change.map do |co|
            ck = change_keys[change_tx_outputs.index(co)]
            {
              satoshis: co.satoshis,
              vout: tx.outputs.index(co),
              locking_script: ck[:script].to_binary,
              derivation_prefix: ck[:prefix],
              derivation_suffix: ck[:suffix],
              sender_identity_key: @engine.key_deriver.identity_key
            }
          end

          {
            wtxid: tx.wtxid,
            raw_tx: tx.to_binary,
            tx: tx,
            vout_mapping: vout_mapping,
            change_outputs: change_output_specs
          }
        end

        def random_derivation
          BSV::Wallet.random_derivation
        end
      end
    end
  end
end
