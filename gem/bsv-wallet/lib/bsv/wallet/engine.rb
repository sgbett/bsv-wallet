# frozen_string_literal: true

require 'securerandom'

module BSV
  module Wallet
    # Layer 3 — BRC-100 business process orchestration.
    #
    # Receives Layer 2a components at construction time and orchestrates
    # them to fulfill the 28 BRC-100 methods. Contains no SQL, no ARC
    # calls, no thread management. Pure orchestration.
    #
    # @example Via the CLI's auto-discovery (recommended for typical use)
    #   require 'bsv/wallet/cli'    # not autoloaded — CLI is opt-in
    #   ctx = BSV::Wallet::CLI.boot(wallet_name: 'alice')
    #   engine = ctx[:engine]
    #
    # @example Direct injection (any backend; pass any objects implementing the interfaces)
    #   store = BSV::Wallet::Store.connect('sqlite://wallet.db')
    #   store.migrate!
    #   engine = BSV::Wallet::Engine.new(
    #     store:         store,
    #     utxo_pool:     BSV::Wallet::Store::UTXOPool.new(store: store),
    #     services:      BSV::Network::Services.new(providers: [...]),
    #     key_deriver:   key_deriver,
    #     chain_tracker: chain_tracker
    #   )
    #   engine.create_action(description: 'payment', outputs: [...])
    class Engine
      include BSV::Wallet::Interface::BRC100

      autoload :Broadcast,  'bsv/wallet/engine/broadcast'
      autoload :TxProof,    'bsv/wallet/engine/tx_proof'
      autoload :OmqSupport, 'bsv/wallet/engine/omq_support'

      # ARC tx_status values where the network has formally accepted
      # the broadcast.
      ACCEPTED_STATUSES = %w[SEEN_ON_NETWORK MINED ACCEPTED_BY_NETWORK IMMUTABLE].freeze

      # ARC tx_status values that indicate a definitive, non-recoverable
      # rejection. Used to gate +inline_broadcast+'s output-promotion
      # decision: anything NOT in this set means "the tx is on its way"
      # and the wallet should record its outputs as spendable. ARC's
      # immediate response on submit is typically +RECEIVED+ / +STORED+
      # / +QUEUED+ — none of which are in ACCEPTED, but none are in
      # REJECTED either.
      REJECTED_STATUSES = %w[REJECTED DOUBLE_SPEND_ATTEMPTED MALFORMED].freeze

      UUID_RE = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

      LIMP_THRESHOLD     = 50_000  # default: 50K sats
      LIMP_THRESHOLD_MIN = 10_000  # hard floor: cannot configure below this

      attr_reader :limp_threshold, :services

      def initialize(store:, utxo_pool:,
                     services: nil, key_deriver: nil, chain_tracker: nil,
                     network_provider: nil,
                     network: :mainnet, limp_threshold: LIMP_THRESHOLD)
        raise ArgumentError, "limp_threshold must be >= #{LIMP_THRESHOLD_MIN}" if limp_threshold < LIMP_THRESHOLD_MIN

        @store = store
        @utxo_pool = utxo_pool
        @services = services
        @key_deriver = key_deriver
        @chain_tracker = chain_tracker
        @network_provider = network_provider
        @network_name = network
        @limp_threshold = limp_threshold
      end

      # Is the wallet in limp mode? When true, all outbound operations
      # are blocked. The wallet can still receive to restore normal operations.
      def limp_mode?
        @utxo_pool.balance < @limp_threshold
      end

      # How many sats can be spent before hitting the limp threshold.
      def headroom
        [@utxo_pool.balance - @limp_threshold, 0].max
      end

      # --- Transaction Operations (codes 1-7) ---

      # Create a BRC-100 action (Phases 1, 2, optionally 3, optionally 4).
      #
      # Composes the funding primitives:
      #   1. Phase 1 picks the initial input set:
      #      - inputs: nil and outputs present  → select_inputs(sum(outputs))
      #      - inputs: [] / empty                → no selection (explicit zero-input tx)
      #      - inputs: [...]                     → caller-supplied, used as-is
      #      Followed by an atomic Store#create_action that inserts the
      #      action row and the input rows together.
      #   2. Phase 2 runs the funding loop: generate_change builds + templates
      #      the transaction, computes the exact fee, and either returns the
      #      finished {wtxid, raw_tx, vout_mapping, change_outputs} or a
      #      shortfall. On shortfall (wallet-selected inputs only) the loop
      #      tops up via select_inputs + Store#lock_inputs and re-evaluates.
      #      Caller-supplied input shortfalls raise InsufficientFundsError
      #      immediately.
      #   3. Phase 3 / 4 follow the broadcast intent (send path versus
      #      internal path); see docs/design.md.
      #
      # Deferred signing (sign_and_process: false, caller-supplied inputs
      # only) skips the funding loop entirely and returns a signable handle.
      #
      # @return [Hash] either { txid:, tx: } (signed),
      #   { signable_transaction: { tx:, reference: } } (deferred), or
      #   { txid:, tx:, no_send_change: } (internal path with no_send: true).
      def create_action(description:, input_beef: nil, inputs: nil, outputs: nil,
                        lock_time: nil, version: nil, labels: nil,
                        sign_and_process: true, accept_delayed_broadcast: true,
                        trust_self: nil, return_txid_only: false,
                        no_send: false, change_count: nil,
                        randomize_outputs: true, originator: nil)
        validate_description!(description)
        validate_create_action_params!(inputs: inputs, outputs: outputs)
        validate_output_ownership!(outputs)

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
        require_key_deriver! unless deferred || skip_change

        broadcast = determine_broadcast(no_send, accept_delayed_broadcast)
        enforce_limp_mode!

        # Output total drives the initial selection target and the cheap
        # pre-flight headroom check. The exact post-loop headroom check
        # (sum(outputs) + actual_fee) runs after generate_change converges.
        # pre_lock_balance / change_count are captured before Phase 1
        # locking shrinks the spendable set; both headroom checks use the
        # pre-lock balance, and the funding loop uses the pre-lock change
        # count so target sizing reflects the wallet's full pool.
        output_total = outputs&.sum { |o| o[:satoshis] || 0 } || 0
        pre_lock_balance = @utxo_pool.balance
        # +change_count:+ kwarg overrides the pool's grooming heuristic. Use
        # cases: consolidation (target a single output), explicit-cap callers.
        pre_lock_change_count = change_count || @utxo_pool.change_output_count
        enforce_headroom_against!(pre_lock_balance, output_total) unless deferred

        # Phase 1: resolve initial inputs and lock the action.
        # - caller_supplied_inputs (including empty array): use as-is.
        # - inputs: nil + outputs present: select to cover sum(outputs).
        # - inputs: nil + no outputs: no selection (nothing to fund).
        initial_inputs =
          if caller_supplied_inputs
            build_input_specs(inputs)
          elsif output_total.positive?
            select_inputs(target_satoshis: output_total)
          else
            []
          end

        action_result = @store.create_action(
          action: {
            description: description, broadcast_intent: broadcast,
            nlocktime: lock_time || 0, version: version,
            input_beef: input_beef, outgoing: true
          },
          inputs: initial_inputs
        )
        raise BSV::Wallet::InsufficientFundsError if action_result.nil?

        attach_labels(action_result[:id], labels)

        # Deferred path: assemble unsigned tx, stage, return signable handle.
        # No change generation on this path (preserved from prior behaviour).
        if deferred
          wtxid, raw_tx, vout_mapping = build_transaction(
            action_result[:id], inputs, outputs, lock_time, version, randomize_outputs,
            sign: false
          )
          pending_outputs = broadcast == :none || outputs.nil? ? [] : build_output_specs(outputs, vout_mapping)
          @store.stage_action(
            action_id: action_result[:id], wtxid: wtxid, raw_tx: raw_tx,
            outputs: pending_outputs
          )
          @store.save_proof(wtxid: wtxid, proof: { raw_tx: raw_tx })
          # BRC-100: signableTransaction.tx is Atomic BEEF of the unsigned tx
          # so external signers can inspect ancestry without a follow-up call.
          return {
            signable_transaction: {
              tx: build_atomic_beef(raw_tx, action_result[:id]),
              reference: action_result[:reference]
            }
          }
        end

        # Synchronous path. The empty-inputs case (OP_RETURN-only) skips
        # change generation — already detected above to keep the
        # key_deriver check honest.
        if skip_change
          wtxid, raw_tx, vout_mapping = build_transaction(
            action_result[:id], inputs, outputs, lock_time, version, randomize_outputs,
            sign: true
          )
          change_outputs = []
        else
          wtxid, raw_tx, vout_mapping, change_outputs, signed_tx = run_funding_loop(
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
          actual_fee = total_input_satoshis_for(action_result[:id]) - output_total - change_outputs.sum { |c| c[:satoshis] }
          enforce_headroom_against!(pre_lock_balance, output_total + actual_fee)
        end

        pending_outputs = broadcast == :none || outputs.nil? ? [] : build_output_specs(outputs, vout_mapping)
        @store.sign_action(
          action_id: action_result[:id], wtxid: wtxid, raw_tx: raw_tx,
          outputs: pending_outputs, change_outputs: change_outputs
        )
        @store.save_proof(wtxid: wtxid, proof: { raw_tx: raw_tx })
        BSV.logger&.debug do
          "[Engine] create_action: dtxid=#{wtxid.reverse.unpack1('H*')} " \
            "outputs=#{outputs&.length || 0} change=#{change_outputs.length}"
        end

        atomic_beef = build_atomic_beef(raw_tx, action_result[:id])

        # Internal-path (no_send): synchronous Phase 4 — promote caller
        # outputs, promote change to spendable, return change outpoints.
        if no_send
          promote_with_outputs(action_result[:id], outputs, vout_mapping)
          @store.promote_change_to_spendable(action_id: action_result[:id]) if change_outputs.any?
          change = query_change_outpoints(action_result[:id])
          return { txid: wtxid, tx: atomic_beef, no_send_change: change }
        end

        # Phase 3 + 4: Broadcast inline. Phase 4 (output promotion +
        # spendable row creation) runs on accepted ARC response. Delayed
        # broadcasts are picked up by the daemon's push-discovery loop from
        # the broadcasts row that sign_action created atomically above.
        if broadcast == :inline
          broadcast_result = inline_broadcast(action_id: action_result[:id], tx: signed_tx)
          if rejected?(broadcast_result)
            # Definitive sync rejection: tx isn't in any mempool. Cascade
            # forward through any child action that consumed this action's
            # outputs (none here on the inline path, but reject_action is
            # the right primitive) and unwind speculative promotion in
            # one transaction. The +inputs+ rows CASCADE-delete with the
            # action, freeing locked outputs for the next call to spend.
            @store.reject_action(action_id: action_result[:id])
          elsif accepted?(broadcast_result)
            @store.promote_action_outputs(action_id: action_result[:id])
            handle_proof_from_broadcast(action_result[:id], broadcast_result)
          end
        end

        { txid: wtxid, tx: return_txid_only ? nil : atomic_beef }
      end

      def sign_action(spends:, reference:, accept_delayed_broadcast: true,
                      return_txid_only: false, no_send: false,
                      originator: nil)
        validate_reference!(reference)
        action = @store.find_action(reference: reference)
        raise BSV::Wallet::InvalidParameterError, 'reference' unless action

        # Runtime broadcast-override at sign time belongs to the
        # chained-send subsystem (#192). The base wallet's signAction
        # only completes the deferred-construction lifecycle per the
        # original broadcast intent set at createAction time.
        if no_send && action[:broadcast_intent] != 'none'
          raise BSV::Wallet::UnsupportedActionError,
                'signAction(no_send: true) requires the action to have been ' \
                "created with no_send: true (broadcast intent 'none'). " \
                'Runtime override at sign time is not implemented in the base ' \
                'wallet; tracked in #192.'
        end

        # Outputs were already written during create_action (promoted: false)
        # so sign_action only deserializes the unsigned tx, applies caller
        # unlocking scripts, signs remaining P2PKH inputs, and updates the
        # action with the signed raw_tx + wtxid.
        wtxid, raw_tx, signed_tx = apply_spends(action, spends)
        @store.sign_action(action_id: action[:id], wtxid: wtxid, raw_tx: raw_tx)
        @store.save_proof(wtxid: wtxid, proof: { raw_tx: raw_tx })

        # Build Atomic BEEF envelope for the :tx return value
        atomic_beef = build_atomic_beef(raw_tx, action[:id])

        broadcast = determine_broadcast(no_send, accept_delayed_broadcast)

        return { txid: wtxid, tx: atomic_beef } if no_send

        if broadcast == :inline
          broadcast_result = inline_broadcast(action_id: action[:id], tx: signed_tx)
          if rejected?(broadcast_result)
            @store.reject_action(action_id: action[:id])
          elsif accepted?(broadcast_result)
            @store.promote_action_outputs(action_id: action[:id])
            handle_proof_from_broadcast(action[:id], broadcast_result)
          end
        end

        { txid: wtxid, tx: return_txid_only ? nil : atomic_beef }
      end

      def abort_action(reference:, originator: nil)
        validate_reference!(reference)
        action = @store.find_action(reference: reference)
        raise BSV::Wallet::InvalidParameterError, 'reference' unless action

        @store.abort_action(action_id: action[:id])
        @utxo_pool.release(outputs: [])
        { aborted: true }
      end

      # Operator-facing entry to Store#reject_action. The daemon's
      # resolution loop calls store directly; this wrapper lets bin/
      # tools target specific stuck rows (action_id is a wallet-local
      # integer, not a BRC-100 reference — this isn't a spec method).
      def reject_action(action_id:)
        action = @store.find_action(id: action_id)
        raise BSV::Wallet::InvalidParameterError, "action_id=#{action_id} not found" unless action

        @store.reject_action(action_id: action_id)
        { rejected: true, action_id: action_id }
      end

      def list_actions(labels:, label_query_mode: :any,
                       include_labels: false, include_inputs: false,
                       include_input_source_locking_scripts: false,
                       include_input_unlocking_scripts: false,
                       include_outputs: false, include_output_locking_scripts: false,
                       limit: 10, offset: 0, seek_permission: true, originator: nil)
        result = @store.query_actions(
          labels: labels, label_query_mode: label_query_mode,
          limit: [limit, 10_000].min, offset: offset,
          include_labels: include_labels, include_inputs: include_inputs,
          include_input_locking_scripts: include_input_source_locking_scripts,
          include_outputs: include_outputs,
          include_output_locking_scripts: include_output_locking_scripts
        )
        { total_actions: result[:total], actions: result[:actions] }
      end

      def internalize_action(tx:, outputs:, description:, labels: nil,
                             trust_self: nil, known_txids: nil,
                             seek_permission: true, originator: nil)
        validate_description!(description)
        # known_txids is the BRC-100 spec param name; values are wire-order wtxids
        known_txids&.each { |w| BSV::Primitives::Hex.validate_wtxid!(w, name: 'known_txids entry') }

        # Parse tx: as Atomic BEEF (BRC-95)
        beef, subject_tx = parse_beef(tx)

        # trustSelf: the sender may have included TXID-only entries for ancestors
        # they know we have. from_binary can't wire those (no Transaction object),
        # so hydrate any unresolved inputs from our ProofStore before verification.
        hydrate_known_sources!(subject_tx) if trust_self == 'known'

        # Full SPV verification: scripts, merkle proofs, and fee adequacy
        # (output <= input). Replaces the former validate_beef! +
        # validate_fee_adequacy! two-step.
        verify_incoming_transaction!(subject_tx)

        # Create action (incoming, no broadcast, already completed)
        action_result = @store.create_action(
          action: { description: description, broadcast_intent: :none, outgoing: false }
        )

        # Store wtxid and raw_tx on the action
        @store.sign_action(
          action_id: action_result[:id],
          wtxid: subject_tx.wtxid,
          raw_tx: subject_tx.to_binary
        )
        @store.save_proof(wtxid: subject_tx.wtxid, proof: { raw_tx: subject_tx.to_binary })
        BSV.logger&.debug { "[Engine] internalize_action: subject=#{subject_tx.dtxid}" }

        attach_labels(action_result[:id], labels)

        # Save ancestor proofs BEFORE replacing known ancestors with TXID-only.
        # save_beef_proofs iterates beef.transactions and skips TxidOnlyEntry —
        # if we replaced first, ancestors listed in known_txids but not yet in
        # ProofStore would be converted to TXID-only and their proofs lost.
        save_beef_proofs(beef, subject_tx.wtxid, action_result[:id])

        # trustSelf: replace known ancestors with TXID-only entries.
        # This runs AFTER save_beef_proofs so no proof data is lost, and
        # AFTER verify so the full graph was already validated.
        # make_txid_only replaces entries in the BEEF's @transactions list but
        # does NOT invalidate in-memory source_transaction pointers wired by
        # from_binary — verify already walked those pointers successfully above.
        replace_known_ancestors!(beef, subject_tx.wtxid, known_txids) if trust_self == 'known'

        output_specs = outputs.map do |out|
          spec = resolve_internalize_output(out)
          tx_out = subject_tx.outputs[spec[:vout]]
          unless tx_out
            raise BSV::Wallet::InvalidParameterError.new(
              'output_index',
              "vout #{spec[:vout]} does not exist in subject transaction (#{subject_tx.outputs.length} outputs)"
            )
          end
          spec[:locking_script] = tx_out.locking_script.to_binary
          if spec[:satoshis]&.positive? && spec[:satoshis] != tx_out.satoshis
            raise BSV::Wallet::InvalidParameterError.new(
              'satoshis',
              "declared satoshis #{spec[:satoshis]} != transaction output #{tx_out.satoshis} at vout #{spec[:vout]}"
            )
          end
          spec[:satoshis] = tx_out.satoshis
          spec
        end
        @store.promote_action(action_id: action_result[:id], outputs: output_specs)

        { accepted: true }
      end

      def list_outputs(basket:, tags: nil, tag_query_mode: :any, include: nil,
                       include_custom_instructions: false, include_tags: false,
                       include_labels: false, limit: 10, offset: 0,
                       seek_permission: true, originator: nil)
        result = @store.query_outputs(
          basket: basket, tags: tags, tag_query_mode: tag_query_mode,
          limit: [limit, 10_000].min, offset: offset,
          include_locking_scripts: [:locking_scripts, 'locking scripts'].include?(include),
          include_custom_instructions: include_custom_instructions,
          include_tags: include_tags, include_labels: include_labels
        )
        { total_outputs: result[:total], outputs: result[:outputs] }
      end

      def relinquish_output(basket:, output:, originator: nil)
        @store.relinquish_output(output_id: output)
        { relinquished: true }
      end

      # --- UTXO Import (bootstrap) ---

      # Import a root-key UTXO and immediately pay to self on a derived address.
      #
      # Rescues funds sent directly to the wallet's root key (an error condition
      # or bootstrap from a non-BRC-100 source). Fetches the transaction and
      # merkle proof from the network provider, verifies the output is P2PKH to
      # the wallet's root key, imports it, then immediately spends it to a
      # BRC-42 derived self-address. The root UTXO is promoted as spendable
      # briefly, then consumed by the self-payment — only the derived output
      # remains spendable after completion.
      #
      # @param dtxid [String] 64-char hex transaction ID (display order)
      # @param vout [Integer] output index (default: 0)
      # @param no_send [Boolean] when true (the default), Phase 2's BRC-42
      #   self-payment is built but not broadcast — its output exists only
      #   in the wallet's view. CI suites rely on this so test runs cost
      #   nothing.
      #
      #   Set false when the wallet intends to broadcast subsequent
      #   actions on chain. Phase 2's output then lives on the chain's
      #   UTXO set so a downstream broadcast referencing it is consensus-
      #   valid. The rule is binary: either every action in the run
      #   broadcasts (including this one) or none of them do — broadcasting
      #   a descendant of a no_send parent gets rejected by the network
      #   for a non-existent input.
      # @param accept_delayed_broadcast [Boolean] only consulted when
      #   +no_send+ is false. Default true (queue for the daemon to push).
      # @return [Hash] { imported: true, satoshis:, dtxid: }
      def import_utxo(dtxid:, vout: 0, no_send: true, accept_delayed_broadcast: true)
        require_key_deriver!
        raise BSV::Wallet::Error, 'no network provider configured' unless @network_provider

        # Fetch transaction from network
        BSV.logger&.debug { "[Engine] import_utxo: fetching #{dtxid} from network" }
        result = @network_provider.call(:get_tx, txid: dtxid)
        raise BSV::Wallet::Error, "failed to fetch tx #{dtxid}" unless result.http_success?

        raw_tx = [result.data.strip].pack('H*')
        tx = BSV::Transaction::Transaction.from_binary(raw_tx)

        # Verify output exists and is P2PKH to our root key
        unless vout.is_a?(Integer) && vout >= 0 && vout < tx.outputs.length
          raise BSV::Wallet::InvalidParameterError.new('vout', "out of range (#{tx.outputs.length} outputs)")
        end

        output = tx.outputs[vout]
        locking_script = output.locking_script
        root_hash = @key_deriver.root_private_key.public_key.hash160

        unless locking_script.p2pkh? && locking_script.chunks[2].data == root_hash
          raise BSV::Wallet::InvalidParameterError.new('vout', 'output is not P2PKH to the wallet root key')
        end

        satoshis = output.satoshis
        wtxid = tx.wtxid

        BSV.logger&.debug { "[Engine] import_utxo: #{satoshis} sats at vout #{vout}" }

        # Idempotency: if this tx has already been imported (the wtxid
        # is already on an existing action — UNIQUE constraint on
        # +actions.wtxid+), short-circuit. Re-running +import_wallet+
        # over the same on-chain UTXO would otherwise collide on the
        # +actions_wtxid_index+ during +sign_action+. The skip is
        # silent — re-imports are a normal consequence of harness
        # iteration and the action is already in the right state.
        if @store.find_action(wtxid: wtxid)
          BSV.logger&.debug { "[Engine] import_utxo: #{dtxid} already imported, skipping" }
          return { imported: false, satoshis: satoshis, dtxid: dtxid, reason: 'already_imported' }
        end

        # Phase 1: Record the root-key UTXO
        import_action = @store.create_action(
          action: { description: 'imported UTXO', broadcast_intent: :none, outgoing: false }
        )
        @store.sign_action(action_id: import_action[:id], wtxid: wtxid, raw_tx: raw_tx)
        @store.save_proof(wtxid: wtxid, proof: { raw_tx: raw_tx })
        output_ids = @store.promote_action(
          action_id: import_action[:id],
          outputs: [{ satoshis: satoshis, vout: vout, locking_script: locking_script.to_binary, output_type: 'root' }]
        )
        imported_output_id = output_ids.first

        # Fetch and link merkle proof if mined
        fetch_and_link_proof(import_action[:id], wtxid, dtxid, raw_tx)

        # Phase 2: Self-payment to a BRC-42-derived address.
        #
        # We delegate change derivation to the funding loop with
        # +change_count: 1+ and +outputs: []+: +generate_change+ picks a
        # fresh BRC-42 self-key, computes the exact fee from the templated
        # tx, and writes a single +sum(inputs) - fee+ output. Bootstrap
        # bypasses limp mode + headroom since this is how the wallet gets
        # funded in the first place.
        @bypass_limp_mode = true
        begin
          create_action(
            description: 'import self-payment',
            inputs: [{ output_id: imported_output_id }],
            outputs: [],
            no_send: no_send,
            accept_delayed_broadcast: accept_delayed_broadcast,
            randomize_outputs: false,
            change_count: 1
          )
        ensure
          @bypass_limp_mode = false
        end

        # +satoshis+ here is the on-chain UTXO's value (gross). The wallet's
        # spendable balance is slightly less — the Phase 2 self-payment paid
        # a small network fee for the derived output. Callers querying the
        # wallet's balance see the net; this return reports what was
        # imported from chain.
        BSV.logger&.debug { "[Engine] import_utxo complete: #{satoshis} sats imported from #{dtxid}" }
        { imported: true, satoshis: satoshis, dtxid: dtxid }
      end

      # --- Porcelain ---

      # Scan the root key's address for unspent outputs and import each one.
      #
      # Derives the P2PKH address from the wallet's root key, queries the
      # network for UTXOs, and calls import_utxo for each. This is the
      # bootstrap path — how a wallet gets its initial funding.
      #
      # @param no_send [Boolean] forwarded to +import_utxo+ for each
      #   discovered UTXO. Default true (CI invariant — Phase 2 stays
      #   off chain). Set false when the wallet intends to broadcast
      #   downstream actions.
      # @param accept_delayed_broadcast [Boolean] forwarded to
      #   +import_utxo+. Only consulted when +no_send+ is false.
      # @param include_unconfirmed [Boolean] when true, scan WoC's
      #   +/unspent/all+ endpoint which includes mempool entries.
      #   Default false uses +/confirmed/unspent+ (safer — confirmed
      #   UTXOs can't be reorged-away under us). The e2e harness's
      #   Phase 4 sets true so SDK can see the just-broadcast sweep
      #   outputs without waiting for a block.
      # @return [Hash] { imported: Integer, utxos: Array<Hash> }
      def import_wallet(no_send: true, accept_delayed_broadcast: true,
                        include_unconfirmed: false)
        require_key_deriver!
        raise BSV::Wallet::Error, 'no network provider configured' unless @network_provider

        address = @key_deriver.root_private_key.public_key.address
        BSV.logger&.debug { "[Engine] import_wallet: scanning #{address}" }

        command = include_unconfirmed ? :get_utxos_all : :get_utxos
        result = @network_provider.call(command, address)

        # 404 from WoC's +/confirmed/unspent+ endpoint means "no UTXOs at
        # this address" — empty result, not an error. Other non-success
        # responses are still failures.
        return { imported: 0, utxos: [] } if result.http_not_found?
        raise BSV::Wallet::Error, "failed to fetch UTXOs for #{address}" unless result.http_success?

        utxos = result.data
        return { imported: 0, utxos: [] } if utxos.nil? || utxos.empty?

        # Defensive dedupe: provider responses have been seen to repeat
        # a (tx_hash, tx_pos) pair during mempool races. A second
        # +import_utxo+ on the same UTXO would collide on
        # +actions_wtxid_index+ (UNIQUE on +actions.wtxid+).
        seen = Set.new
        unique_utxos = utxos.reject do |utxo|
          key = [utxo['tx_hash'], utxo['tx_pos']]
          seen.include?(key).tap { seen.add(key) }
        end

        imported = unique_utxos.filter_map do |utxo|
          import_utxo(dtxid: utxo['tx_hash'], vout: utxo['tx_pos'],
                      no_send: no_send,
                      accept_delayed_broadcast: accept_delayed_broadcast)
        rescue BSV::Wallet::Error => e
          BSV.logger&.warn { "[Engine] import_wallet: skipping #{utxo['tx_hash']}:#{utxo['tx_pos']} — #{e.message}" }
          nil
        end

        { imported: imported.length, utxos: imported }
      end

      # Generate a legacy P2PKH receive address using the WBIKD pattern.
      #
      # Finds or creates a pre-funded UTXO slot in basket 'p wbikd', locks it
      # with a zero-output no-send action, then derives a BRC-42 address from
      # the locking action's ID and slot output ID.
      #
      # Derivation params are base64-encoded big-endian int64 values of the
      # database IDs. This is intentionally deterministic — if the wallet
      # database is lost but the identity key is retained, funds can be
      # recovered by enumerating (action_id, output_id) combinations and
      # checking each derived address for UTXOs. Security as an economic
      # function: cost of recovery scales with the number of addresses
      # ever generated.
      #
      # @return [Hash] { address:, derivation_prefix:, derivation_suffix: }
      def generate_receive_address
        require_key_deriver!

        slot_info = find_or_create_wbikd_slot
        slot = slot_info[:slot]

        # Lock the slot with a no-send zero-output action.
        # Uses @store.create_action directly — this is an internal operation
        # that should not enforce limp mode.
        locking_action = @store.create_action(
          action: { description: 'wbikd address lock', broadcast_intent: :none, nlocktime: 0, outgoing: true },
          inputs: [{ output_id: slot[:id], vin: 0 }]
        )
        # Slot may have been locked by a concurrent caller — retry with a different slot
        return generate_receive_address unless locking_action

        wtxid, raw_tx, = build_transaction(locking_action[:id], [{ output_id: slot[:id] }], [], nil, nil, false)
        @store.sign_action(action_id: locking_action[:id], wtxid: wtxid, raw_tx: raw_tx)
        @store.save_proof(wtxid: wtxid, proof: { raw_tx: raw_tx })
        attach_labels(locking_action[:id], ['wbikd'])

        # Derive from on-chain data: slot's source txid + vout.
        # These are deterministic from the blockchain — no database ID dependency.
        derivation_prefix = slot_info[:dtxid]
        derivation_suffix = slot_info[:vout].to_s
        derived_pub = @key_deriver.derive_public_key(
          protocol_id: [2, derivation_prefix], key_id: derivation_suffix, counterparty: 'self'
        )
        address = BSV::Primitives::PublicKey.from_bytes(derived_pub).address(network: @network_name)

        { address: address, derivation_prefix: derivation_prefix, derivation_suffix: derivation_suffix }
      end

      # List outstanding (pending) WBIKD receive addresses.
      #
      # Queries actions with the 'wbikd' label, filters for :internal status
      # (active locks), and re-derives the P2PKH address from each slot's
      # source transaction ID and output index (on-chain data).
      #
      # @return [Array<Hash>] each with :address, :derivation_prefix,
      #   :derivation_suffix, :action_reference, :created_at
      def list_receive_addresses
        require_key_deriver!

        result = list_actions(labels: ['wbikd'], include_inputs: true, limit: 10_000)
        result[:actions].filter_map do |action|
          next unless action[:status] == :internal

          input = action[:inputs]&.first
          next unless input

          # Look up slot output's source txid + vout for on-chain derivation
          slot_output = @store.find_output(id: input[:output_id])
          next unless slot_output

          source_action = @store.find_action(id: slot_output[:action_id])
          next unless source_action&.dig(:wtxid)

          derivation_prefix = source_action[:wtxid].reverse.unpack1('H*')
          derivation_suffix = slot_output[:vout].to_s

          derived_pub = @key_deriver.derive_public_key(
            protocol_id: [2, derivation_prefix], key_id: derivation_suffix, counterparty: 'self'
          )
          address = BSV::Primitives::PublicKey.from_bytes(derived_pub).address(network: @network_name)

          { address: address, derivation_prefix: derivation_prefix,
            derivation_suffix: derivation_suffix,
            action_reference: action[:reference], created_at: action[:created_at] }
        end
      end

      # Scan outstanding WBIKD receive addresses for incoming UTXOs.
      #
      # Queries the network for UTXOs at each outstanding address. When
      # funds are found, internalizes each UTXO with BRC-42 derivation
      # params and recycles the slot by aborting the locking action.
      #
      # @return [Hash] { scanned:, found: } counts
      def scan_receive_addresses
        return { scanned: 0, found: 0 } unless @key_deriver && @network_provider

        addresses = list_receive_addresses
        return { scanned: 0, found: 0 } if addresses.empty?

        found_count = 0
        addresses.each do |addr_info|
          result = @network_provider.call(:get_utxos, addr_info[:address])
          next unless result.respond_to?(:http_success?) && result.http_success?

          utxos = result.data
          next if utxos.nil? || utxos.empty?

          utxos.each do |utxo|
            internalize_wbikd_utxo(
              dtxid: utxo['tx_hash'], vout: utxo['tx_pos'],
              derivation_prefix: addr_info[:derivation_prefix],
              derivation_suffix: addr_info[:derivation_suffix],
              action_reference: addr_info[:action_reference]
            )
            found_count += 1
          rescue StandardError => e
            BSV.logger&.error { "[Engine] wbikd internalize: #{e.message}" }
          end
        rescue StandardError => e
          BSV.logger&.error { "[Engine] wbikd scan for #{addr_info[:address]}: #{e.message}" }
        end

        { scanned: addresses.length, found: found_count }
      end

      # Send a BRC-42 derived payment to a recipient.
      #
      # Generates derivation parameters, derives a P2PKH locking script for
      # the recipient via BRC-42, and calls create_action — which composes
      # select_inputs and generate_change inside its funding loop to handle
      # UTXO selection, fees, and change.
      #
      # @param recipient [String] 66-char compressed public key hex (02/03 prefix)
      # @param satoshis [Integer] amount to send
      # @param no_send [Boolean] when true (the default) the action is built
      #   and signed but never reaches ARC — the BEEF is returned for
      #   peer-to-peer handoff. Set false for on-chain broadcast.
      # @param accept_delayed_broadcast [Boolean] only consulted when
      #   +no_send+ is false. Default true (queue for the daemon to push).
      # @return [Hash] { beef:, sender_identity_key:, outputs: [{ vout:, satoshis:, derivation_prefix:, derivation_suffix: }] }
      def send_payment(recipient:, satoshis:, no_send: true, accept_delayed_broadcast: true)
        require_key_deriver!
        validate_recipient_key!(recipient)

        derivation_prefix = random_derivation
        derivation_suffix = '1'

        derived_pub = @key_deriver.derive_public_key(
          protocol_id: [2, derivation_prefix], key_id: derivation_suffix,
          counterparty: recipient, for_self: true
        )
        locking_script = BSV::Script::Script.p2pkh_lock(
          BSV::Primitives::Digest.hash160(derived_pub)
        ).to_binary

        # randomize_outputs: false guarantees the payment output stays at
        # index 0. Change outputs from generate_change are appended after
        # caller outputs.
        result = create_action(
          description: "send #{satoshis} sats",
          outputs: [{ satoshis: satoshis, locking_script: locking_script }],
          no_send: no_send, accept_delayed_broadcast: accept_delayed_broadcast,
          randomize_outputs: false
        )

        {
          # :txid is the subject wtxid (wire-order binary) — the BRC-100
          # spec boundary name, not a byte-order indicator. Surfaced so
          # callers can log/track the tx without re-parsing the BEEF.
          txid: result[:txid],
          beef: result[:tx],
          sender_identity_key: @key_deriver.identity_key,
          outputs: [{
            vout: 0, # relies on randomize_outputs: false — see above
            satoshis: satoshis,
            derivation_prefix: derivation_prefix,
            derivation_suffix: derivation_suffix
          }]
        }
      end

      # Consolidate the dustier tail of the UTXO set into a single self-payment.
      #
      # Picks the +target_inputs+ smallest spendable outputs plus the 1
      # largest (as an anchor that guarantees fee coverage even when the
      # smallest are below the per-input marginal fee), then dispatches a
      # +no_send+ +create_action+ with +change_count: 1+ so the funding
      # loop produces a single BRC-42 self-payment.
      #
      # @param target_inputs [Integer] minimum smallest outputs to consume per step
      # @param no_send [Boolean] when true (the default) the action is built
      #   and signed but never reaches ARC. Set false for on-chain broadcast.
      # @param accept_delayed_broadcast [Boolean] only consulted when
      #   +no_send+ is false. Default true (queue for the daemon to push).
      # @return [Hash, nil] the +create_action+ result, or +nil+ if there are
      #   fewer than +target_inputs+ spendable outputs (the loop's natural exit).
      def consolidate_step(target_inputs: 20, no_send: true, accept_delayed_broadcast: true)
        require_key_deriver!
        smallest = @utxo_pool.smallest(limit: target_inputs)
        return nil if smallest.length < target_inputs

        largest = @utxo_pool.largest(limit: 1)
        # Dedupe — when the pool has exactly +target_inputs+ outputs, the
        # largest may already appear in the smallest set.
        merged = (smallest + largest).uniq { |o| o[:id] }
        input_specs = merged.each_with_index.map { |o, i| { output_id: o[:id], vin: i } }

        create_action(
          description: 'consolidation',
          inputs: input_specs,
          outputs: [],
          no_send: no_send, accept_delayed_broadcast: accept_delayed_broadcast,
          change_count: 1
        )
      end

      # Sweep every spendable output back to the recipient's root key (less fee).
      #
      # Selects all spendable outputs, locks one caller output to the
      # recipient's *root* P2PKH (+hash160(recipient_pubkey)+ — not a
      # BRC-42-derived address), and dispatches a +no_send+ +create_action+
      # that consumes all inputs. The literal root P2PKH is recoverable from
      # the WIF alone, which is the point of a sweep: return funds somewhere a
      # bare key can reclaim them (e.g. so the receiving wallet's DB can be
      # wiped and re-imported by scanning the root address). Any rounding
      # surplus against the actual fee is dropped (zero-survival on the single
      # change-key slot the funding loop derives, since +generate_change+
      # requires +change_count >= 1+).
      #
      # @param recipient [String] 66-char compressed pubkey hex (02/03)
      # @param no_send [Boolean] when true (the default) the action is built
      #   and signed but never reaches ARC — the BEEF is returned for
      #   peer-to-peer handoff. Set false for on-chain broadcast.
      # @param accept_delayed_broadcast [Boolean] only consulted when
      #   +no_send+ is false. Default true (queue for the daemon to push).
      # @return [Hash, nil] the +create_action+ result, or +nil+ when the
      #   wallet has no spendable outputs.
      def sweep(recipient:, no_send: true, accept_delayed_broadcast: true)
        require_key_deriver!
        validate_recipient_key!(recipient)

        all_spendable = @utxo_pool.largest(limit: @utxo_pool.spendable_count)
        return nil if all_spendable.empty?

        total = all_spendable.sum { |o| o[:satoshis] }
        input_specs = all_spendable.each_with_index.map { |o, i| { output_id: o[:id], vin: i } }

        # +recipient_pub+ is the recipient's own root pubkey bytes — same bytes
        # the original funding UTXO was locked to. The output script is the
        # literal P2PKH of that pubkey's hash160, so a future +import_wallet+
        # on the recipient side rediscovers it by scanning the root address.
        recipient_pub = [recipient].pack('H*')
        locking_script = BSV::Script::Script.p2pkh_lock(
          BSV::Primitives::Digest.hash160(recipient_pub)
        ).to_binary

        # Compute the fee with the same FeeModel + templated-tx shape
        # +generate_change+ uses, so the funding loop's exact-fee check
        # finds zero or near-zero surplus and InsufficientFundsError can't
        # fire after Phase 1 lock. Mirrors the input count, caller output,
        # and one change-key output the funding loop will produce.
        fee = estimate_sweep_fee(input_count: all_spendable.length, recipient_script: locking_script)

        # Dust-only wallet: the fee exceeds the available sats. Fail fast
        # before Phase 1 locks any inputs; an InsufficientFundsError after
        # the lock would orphan rows until the reaper cleans up.
        raise BSV::Wallet::InsufficientFundsError if total <= fee

        # Sweep is an explicit "drain everything" operation — by definition it
        # takes the balance below the limp threshold. Bypass the guard here;
        # the caller knows what they asked for.
        #
        # The output spec omits +derivation_prefix+ / +sender_identity_key+:
        # those would make the wallet treat the sweep target as its own
        # BRC-42 owned output (output_type NULL + derivation = ownership
        # marker per schema-intent §3). For an outbound payment we want
        # +output_type = 'outbound'+ so the wallet doesn't insert a
        # +spendable+ row for it. send_payment follows the same convention.
        @bypass_limp_mode = true
        begin
          create_action(
            description: 'sweep',
            inputs: input_specs,
            outputs: [{ satoshis: total - fee, locking_script: locking_script }],
            no_send: no_send, accept_delayed_broadcast: accept_delayed_broadcast,
            randomize_outputs: false,
            change_count: 1
          )
        ensure
          @bypass_limp_mode = false
        end
      end

      # Drain the entire wallet back to a single root P2PKH, broadcasting
      # on-chain. The operational "tidy up" step: every spendable output is
      # returned to the recipient's literal +1...+ address, which is
      # recoverable from the WIF alone — so once this lands the wallet's DB
      # can be wiped and the funds re-imported from the root key.
      #
      # A single transaction cannot consume an unbounded number of inputs
      # (tx-size limit), so this first loops +consolidate_step+ to collapse
      # the wallet down to fewer than +target_inputs+ spendable outputs, then
      # emits one terminal +sweep+ to the root address. Every transaction is
      # an inline on-chain broadcast (+no_send: false+,
      # +accept_delayed_broadcast: false+) — no daemon required.
      #
      # @param recipient [String, nil] 66-char compressed pubkey hex (02/03)
      #   of the root address to drain to. Defaults to the wallet's own
      #   identity key (the "tidy my own wallet" case). Pass another wallet's
      #   identity key for the e2e harness's "return borrowed funds to the
      #   funder" step.
      # @param target_inputs [Integer] consolidation batch size and the
      #   spendable-count threshold below which the loop stops and sweeps.
      # @return [Hash] +{ consolidation_steps:, sweep: }+ where +sweep+ is the
      #   terminal sweep's +create_action+ result, or +nil+ when the wallet
      #   had no spendable outputs to sweep.
      def sweep_to_root(recipient: nil, target_inputs: 20)
        require_key_deriver!
        recipient ||= @key_deriver.identity_key

        consolidation_steps = 0
        until consolidate_step(
          target_inputs: target_inputs, no_send: false, accept_delayed_broadcast: false
        ).nil?
          consolidation_steps += 1
        end

        sweep_result = sweep(
          recipient: recipient, no_send: false, accept_delayed_broadcast: false
        )

        { consolidation_steps: consolidation_steps, sweep: sweep_result }
      end

      # Build a templated skeleton tx with the same shape +generate_change+
      # will produce (N P2PKH-templated inputs + 1 caller output + 1 change
      # output) and run +compute_fee+ against it. Inputs are sourceless
      # stand-ins — only the unlocking-script template size matters for
      # fee estimation; +source_satoshis+ does not enter the size formula.
      def estimate_sweep_fee(input_count:, recipient_script:)
        fee_model = BSV::Transaction::FeeModels::SatoshisPerKilobyte.new(value: 100)
        skeleton = BSV::Transaction::Transaction.new(version: 1, lock_time: 0)

        signing_key = @key_deriver.root_private_key
        input_count.times do
          input = BSV::Transaction::TransactionInput.new(
            prev_wtxid: "\x00".b * 32, prev_tx_out_index: 0
          )
          input.unlocking_script_template = BSV::Transaction::P2PKH.new(signing_key)
          skeleton.add_input(input)
        end

        recipient_script_obj = BSV::Script::Script.from_binary(recipient_script)
        skeleton.add_output(
          BSV::Transaction::TransactionOutput.new(satoshis: 0, locking_script: recipient_script_obj)
        )
        # +generate_change+ adds a change-key output even though sweep
        # expects it to be dust-dropped. Mirror that for size parity.
        skeleton.add_output(
          BSV::Transaction::TransactionOutput.new(
            satoshis: 0, locking_script: recipient_script_obj, change: true
          )
        )

        fee_model.compute_fee(skeleton)
      end

      # --- Public Key Management (codes 8-10) ---

      def get_public_key(identity_key: false, protocol_id: nil, key_id: nil,
                         privileged: false, privileged_reason: nil,
                         counterparty: nil, for_self: false,
                         seek_permission: true, originator: nil)
        require_key_deriver!

        if identity_key
          { public_key: @key_deriver.identity_key }
        else
          pub = @key_deriver.derive_public_key(
            protocol_id: protocol_id, key_id: key_id,
            counterparty: counterparty || 'self',
            for_self: for_self, privileged: privileged
          )
          { public_key: pub }
        end
      end

      def reveal_counterparty_key_linkage(counterparty:, verifier:,
                                          privileged: false, privileged_reason: nil,
                                          originator: nil)
        require_key_deriver!
        @key_deriver.reveal_counterparty_linkage(
          counterparty: counterparty, verifier: verifier, privileged: privileged
        )
      end

      def reveal_specific_key_linkage(counterparty:, verifier:, protocol_id:, key_id:,
                                      privileged: false, privileged_reason: nil,
                                      originator: nil)
        require_key_deriver!
        @key_deriver.reveal_specific_linkage(
          counterparty: counterparty, verifier: verifier,
          protocol_id: protocol_id, key_id: key_id, privileged: privileged
        )
      end

      # --- Cryptography Operations (codes 11-16) ---

      def encrypt(plaintext:, protocol_id:, key_id:,
                  privileged: false, privileged_reason: nil,
                  counterparty: nil, seek_permission: true, originator: nil)
        require_key_deriver!
        ciphertext = @key_deriver.encrypt(
          plaintext: plaintext, protocol_id: protocol_id, key_id: key_id,
          counterparty: counterparty || 'self', privileged: privileged
        )
        { ciphertext: ciphertext }
      end

      def decrypt(ciphertext:, protocol_id:, key_id:,
                  privileged: false, privileged_reason: nil,
                  counterparty: nil, seek_permission: true, originator: nil)
        require_key_deriver!
        plaintext = @key_deriver.decrypt(
          ciphertext: ciphertext, protocol_id: protocol_id, key_id: key_id,
          counterparty: counterparty || 'self', privileged: privileged
        )
        { plaintext: plaintext }
      end

      def create_hmac(data:, protocol_id:, key_id:,
                      privileged: false, privileged_reason: nil,
                      counterparty: nil, seek_permission: true, originator: nil)
        require_key_deriver!
        hmac = @key_deriver.create_hmac(
          data: data, protocol_id: protocol_id, key_id: key_id,
          counterparty: counterparty || 'self', privileged: privileged
        )
        { hmac: hmac }
      end

      def verify_hmac(data:, hmac:, protocol_id:, key_id:,
                      privileged: false, privileged_reason: nil,
                      counterparty: nil, seek_permission: true, originator: nil)
        require_key_deriver!
        expected = @key_deriver.create_hmac(
          data: data, protocol_id: protocol_id, key_id: key_id,
          counterparty: counterparty || 'self', privileged: privileged
        )
        raise BSV::Wallet::InvalidHmacError unless secure_compare(expected, hmac)

        { valid: true }
      end

      def create_signature(protocol_id:, key_id:, data: nil, hash_to_directly_sign: nil,
                           privileged: false, privileged_reason: nil,
                           counterparty: nil, seek_permission: true, originator: nil)
        require_key_deriver!
        signature = @key_deriver.create_signature(
          data: data, hash_to_directly_sign: hash_to_directly_sign,
          protocol_id: protocol_id, key_id: key_id,
          counterparty: counterparty || 'self', privileged: privileged
        )
        { signature: signature }
      end

      def verify_signature(signature:, protocol_id:, key_id:, data: nil,
                           hash_to_directly_verify: nil,
                           privileged: false, privileged_reason: nil,
                           counterparty: nil, for_self: false,
                           seek_permission: true, originator: nil)
        require_key_deriver!
        valid = @key_deriver.verify_signature(
          signature: signature, data: data,
          hash_to_directly_verify: hash_to_directly_verify,
          protocol_id: protocol_id, key_id: key_id,
          counterparty: counterparty || 'self',
          for_self: for_self, privileged: privileged
        )
        raise BSV::Wallet::InvalidSignatureError unless valid

        { valid: true }
      end

      # --- Identity and Certificate Management (codes 17-22) ---

      def acquire_certificate(type:, certifier:, acquisition_protocol:, fields:,
                              serial_number: nil, revocation_outpoint: nil,
                              signature: nil, certifier_url: nil,
                              keyring_revealer: nil, keyring_for_subject: nil,
                              privileged: false, privileged_reason: nil, originator: nil)
        case acquisition_protocol
        when :direct, 'direct'
          @store.save_certificate(
            type: type, certifier: certifier, fields: fields,
            serial_number: serial_number, revocation_outpoint: revocation_outpoint,
            signature: signature, subject: @key_deriver&.identity_key,
            keyring: keyring_for_subject
          )
        when :issuance, 'issuance'
          raise BSV::Wallet::UnsupportedActionError, 'certificate issuance protocol'
        else
          raise BSV::Wallet::InvalidParameterError.new('acquisition_protocol',
                                                       'either :direct or :issuance')
        end
      end

      def list_certificates(certifiers:, types:, limit: 10, offset: 0,
                            privileged: false, privileged_reason: nil, originator: nil)
        result = @store.query_certificates(
          certifiers: certifiers, types: types,
          limit: [limit, 10_000].min, offset: offset
        )
        { total_certificates: result[:total], certificates: result[:certificates] }
      end

      def prove_certificate(certificate:, fields_to_reveal:, verifier:,
                            privileged: false, privileged_reason: nil, originator: nil)
        require_key_deriver!
        keyring = @key_deriver.derive_revelation_keyring(
          certificate: certificate,
          fields_to_reveal: fields_to_reveal,
          verifier: verifier,
          privileged: privileged
        )
        { keyring_for_verifier: keyring }
      end

      def relinquish_certificate(type:, serial_number:, certifier:, originator: nil)
        @store.delete_certificate(type: type, serial_number: serial_number, certifier: certifier)
        { relinquished: true }
      end

      def discover_by_identity_key(identity_key:, limit: 10, offset: 0,
                                   seek_permission: true, originator: nil)
        # Local lookup — external discovery is a future concern
        result = @store.query_certificates(
          certifiers: [], types: [],
          limit: [limit, 10_000].min, offset: offset
        )
        # Filter by subject (identity_key) in application layer
        matching = result[:certificates].select { |c| c[:subject] == identity_key }
        { total_certificates: matching.size, certificates: matching }
      end

      def discover_by_attributes(attributes:, limit: 10, offset: 0,
                                 seek_permission: true, originator: nil)
        # Local lookup — external discovery is a future concern
        # This requires scanning certificate fields, which the Store
        # doesn't support yet. Return empty for now.
        { total_certificates: 0, certificates: [] }
      end

      # --- Authentication (codes 23-24) ---

      def authenticated?(originator: nil)
        { authenticated: !@key_deriver.nil? }
      end

      def wait_for_authentication(originator: nil)
        raise BSV::Wallet::Error.new('wallet is not authenticated', code: 2) unless @key_deriver

        { authenticated: true }
      end

      # --- Blockchain and Network Data (codes 25-28) ---

      def get_height(originator: nil)
        raise BSV::Wallet::UnsupportedActionError, 'get_height'
      end

      def get_header_for_height(height:, originator: nil)
        raise BSV::Wallet::UnsupportedActionError, 'get_header_for_height'
      end

      def get_network(originator: nil)
        { network: @network_name }
      end

      def get_version(originator: nil)
        { version: "bsv-wallet-#{BSV::Wallet::VERSION}" }
      end

      private

      def validate_description!(description)
        return if description.is_a?(String) && description.length.between?(5, 50)

        raise BSV::Wallet::InvalidParameterError.new('description', 'a string between 5 and 50 characters')
      end

      def validate_create_action_params!(inputs:, outputs:)
        has_inputs = inputs&.any?
        has_outputs = outputs&.any?
        return if has_inputs || has_outputs

        raise BSV::Wallet::InvalidParameterError.new('inputs/outputs',
                                                     'present (at least one input or output required)')
      end

      # Validate output_type declarations against locking scripts.
      #
      # If output_type is 'root', the locking script must be P2PKH to the
      # wallet's identity key. Other output_type values are not validated here.
      def validate_output_ownership!(outputs)
        return unless outputs && @key_deriver

        outputs.each_with_index do |out, idx|
          next unless out[:output_type] == 'root'

          script = resolve_locking_script(out[:locking_script])
          unless script.p2pkh?
            raise BSV::Wallet::InvalidParameterError.new(
              "outputs[#{idx}].output_type",
              "'root' requires a P2PKH script"
            )
          end

          root_hash = BSV::Primitives::Digest.hash160(
            [@key_deriver.identity_key].pack('H*')
          )
          pubkey_hash = script.chunks[2].data
          next if pubkey_hash == root_hash

          raise BSV::Wallet::InvalidParameterError.new(
            "outputs[#{idx}].output_type",
            "'root' but script does not match identity key"
          )
        end
      end

      def determine_broadcast(no_send, accept_delayed_broadcast)
        if no_send then :none
        elsif accept_delayed_broadcast then :delayed
        else :inline
        end
      end

      def build_input_specs(inputs)
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

      # Input-selection primitive (#208).
      #
      # Pure pool selection: no fee estimation, no headroom margin, no
      # locking. The funding loop in create_action composes this with
      # generate_change to converge on a fully funded transaction.
      #
      # @param target_satoshis [Integer] minimum total value to select
      # @param exclude [Array<Integer>] output IDs already locked in this
      #   action — skipped so a top-up call doesn't re-select them
      # @return [Array<Hash>] input specs ({ output_id:, vin: }) suitable
      #   for Store#lock_inputs / Store#create_action's inputs argument
      # @raise [BSV::Wallet::PoolDepletedError] when the pool cannot meet
      #   the target after applying exclude:
      def select_inputs(target_satoshis:, exclude: [])
        return [] if target_satoshis.zero?

        candidates = @utxo_pool.select(satoshis: target_satoshis, exclude: exclude)
        candidates.each_with_index.map do |c, idx|
          { output_id: c[:id], vin: idx }
        end
      end

      def attach_labels(action_id, labels)
        return unless labels&.any?

        label_ids = @store.find_or_create_labels(names: labels)
        @store.label_action(action_id: action_id, label_ids: label_ids)
      end

      # Internal-path Phase 4: synchronously promote outputs and create
      # spendable rows in one shot. Used for incoming actions (broadcast
      # intent 'none'): internalize_action, import_utxo self-payment, wbikd.
      def promote_with_outputs(action_id, outputs, vout_mapping = nil)
        return unless outputs&.any?

        @store.promote_action(
          action_id: action_id,
          outputs: build_output_specs(outputs, vout_mapping)
        )
      end

      # Translate caller outputs into Store output specs. Used by both the
      # synchronous internal path ({#promote_with_outputs}) and the
      # send-path sign-time persistence ({Store#sign_action}).
      def build_output_specs(outputs, vout_mapping = nil)
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

      # +inline_broadcast+'s output-promotion decision. Returns true
      # when the tx is "on its way" — either formally accepted
      # (+ACCEPTED_STATUSES+) OR in an in-flight status that isn't
      # definitively rejected. The narrower +ACCEPTED_STATUSES+-only
      # test was wrong for the inline path: ARC's synchronous response
      # on submit is typically an in-flight status, not SEEN_ON_NETWORK.
      # Treating in-flight as "not promoted" left the wallet's
      # spendable view stuck on the consumed input with no replacement
      # change, breaking the next outbound payment with a spurious
      # limp-mode error.
      def accepted?(broadcast_result)
        return false unless broadcast_result

        status = broadcast_result[:tx_status]
        return false if status.nil? || status.to_s.empty?

        !REJECTED_STATUSES.include?(status)
      end

      # Definitive synchronous rejection. The broadcaster returned a
      # status that explicitly says "the network refused this tx" —
      # +REJECTED+ from Arcade / Teranode's catch-all +PROCESSING (4)+
      # validation failure, or +DOUBLE_SPEND_ATTEMPTED+ / +MALFORMED+
      # from ARC. These are the cases where the tx is not in any
      # node's mempool and the wallet's locked inputs need releasing
      # so subsequent actions can spend them.
      #
      # Non-rejection includes both formal acceptance (the wallet
      # promotes outputs and proceeds) and in-flight / orphaned states
      # (the wallet still promotes, trusting the daemon's poll loop to
      # eventually resolve — orphaned txs typically resolve in time).
      def rejected?(broadcast_result)
        return false unless broadcast_result

        status = broadcast_result[:tx_status]
        return false if status.nil? || status.to_s.empty?

        REJECTED_STATUSES.include?(status)
      end

      # Inline ARC submission for the synchronous broadcast path.
      #
      # Stamps broadcast_at in a committed transaction *before* the
      # network call (mirrors Engine::Broadcast#submit). A mid-POST
      # crash therefore leaves the row in broadcast_at IS NOT NULL,
      # tx_status IS NULL -- a recognisable crash-recovery state the
      # poll loop subsequently resolves via GET /tx/{txid}.
      #
      # The broadcasts row is created atomically by Store#sign_action
      # when actions.broadcast_intent != 'none', so this method assumes the
      # row exists and only updates it.
      #
      # @param action_id [Integer]
      # @param tx [BSV::Transaction::Transaction] signed transaction
      #   with +source_satoshis+ / +source_locking_script+ wired on
      #   each input. Passed as a Transaction object (not raw bytes)
      #   so the ARC protocol can serialise to Extended Format (EF)
      #   via +tx.to_ef_hex+ — TAAL ARC rejects raw-format submits
      #   with "Missing input scripts: Transaction could not be
      #   transformed to extended format".
      # @return [Hash, nil] broadcast status from Store
      def inline_broadcast(action_id:, tx:)
        return @store.broadcast_status(action_id: action_id) unless @services

        @store.mark_broadcast_attempted(action_id: action_id)
        response = @services.call(:broadcast, tx)

        if response.http_success?
          data = response.data
          @store.record_broadcast_result(
            action_id: action_id,
            tx_status: data[:tx_status],
            arc_status: data[:status],
            block_hash: data[:block_hash],
            block_height: data[:block_height],
            merkle_path: data[:merkle_path],
            extra_info: data[:extra_info],
            competing_txs: data[:competing_txs]
          )
        else
          # Non-2xx ARC response. A definitive rejection carries a terminal
          # txStatus in the (raw, camelCase) failure body; surface it so the
          # caller's +rejected?+ check unwinds the action and releases its
          # locked inputs, exactly as the daemon's +submit+ path does via
          # +reject_action+. Transport errors and non-terminal failures
          # carry no rejecting status and fall through to the stored
          # (tx_status NULL) row for the poll loop to resolve later. We never
          # return a non-rejecting status here — that would let +accepted?+
          # misread a failed submit as success.
          failure_status = response.data && response.data['txStatus']
          if failure_status && REJECTED_STATUSES.include?(failure_status.to_s.upcase)
            { tx_status: failure_status.to_s.upcase }
          else
            @store.broadcast_status(action_id: action_id)
          end
        end
      end

      def handle_proof_from_broadcast(action_id, broadcast_result)
        return unless broadcast_result[:merkle_path]

        wtxid = broadcast_result[:wtxid] || @store.find_action(id: action_id)&.dig(:wtxid)
        return unless wtxid

        BSV::Primitives::Hex.validate_wtxid!(wtxid, name: 'handle_proof_from_broadcast wtxid')
        merkle_path = normalize_merkle_path(broadcast_result[:merkle_path], wtxid)

        # Store raw_tx from the action so BEEF construction can use it
        raw_tx = broadcast_result[:raw_tx]
        raw_tx ||= @store.find_action(id: action_id)&.dig(:raw_tx)

        proof_id = @store.save_proof(
          wtxid: wtxid,
          proof: {
            height: broadcast_result[:block_height],
            block_hash: broadcast_result[:block_hash],
            merkle_path: merkle_path,
            raw_tx: raw_tx
          }
        )
        @store.link_proof(action_id: action_id, tx_proof_id: proof_id) if proof_id
        BSV.logger&.debug { "[Engine] proof_from_broadcast: dtxid=#{wtxid.reverse.unpack1('H*')} height=#{broadcast_result[:block_height]}" }
      end

      def query_change_outpoints(action_id)
        action = @store.find_action(id: action_id)
        return [] unless action&.dig(:wtxid)

        dtxid = action[:wtxid].reverse.unpack1('H*')
        vouts = @store.query_change_output_vouts(action_id: action_id)
        vouts.map { |vout| "#{dtxid}.#{vout}" }
      end

      # Normalize a merkle_path value to BRC-74 binary format.
      #
      # ARC may return merkle_path as:
      # - Binary (ASCII-8BIT) — already in BRC-74 format, pass through
      # - Hex string — decode to binary
      # - TSC format hash — convert via MerklePath.from_tsc
      #
      # @param merkle_path [String, Hash] raw merkle_path from broadcast response
      # @param wtxid [String] 32-byte binary wtxid (wire order, needed for TSC conversion)
      # @return [String] BRC-74 binary merkle_path
      def normalize_merkle_path(merkle_path, wtxid)
        if merkle_path.is_a?(Hash)
          BSV.logger&.debug { '[Engine] normalize_merkle_path: format=TSC' }
          return normalize_tsc_merkle_path(merkle_path, wtxid)
        end
        if merkle_path.encoding == Encoding::ASCII_8BIT
          BSV.logger&.debug { '[Engine] normalize_merkle_path: format=binary (passthrough)' }
          return merkle_path
        end
        if merkle_path.match?(/\A[0-9a-fA-F]+\z/)
          BSV.logger&.debug { "[Engine] normalize_merkle_path: format=hex (#{merkle_path.length} chars)" }
          return [merkle_path].pack('H*')
        end
        BSV.logger&.debug { '[Engine] normalize_merkle_path: format=unknown (force binary)' }
        merkle_path.b
      end

      # Convert a TSC-format merkle proof hash to BRC-74 binary.
      # from_tsc expects display-order hex; wtxid is wire order, so reverse for display.
      def normalize_tsc_merkle_path(tsc, wtxid)
        BSV::Primitives::Hex.validate_wtxid!(wtxid, name: 'normalize_tsc wtxid')
        dtxid = wtxid.reverse.unpack1('H*')
        BSV::Transaction::MerklePath.from_tsc(
          dtxid_hex: tsc[:txOrId] || tsc[:tx_or_id] || dtxid,
          index: tsc[:index],
          nodes: tsc[:nodes],
          block_height: tsc[:blockHeight] || tsc[:block_height]
        ).to_binary
      end

      # Build an Atomic BEEF (BRC-95) envelope for a signed transaction.
      #
      # Outgoing BEEF: constructed from our own ProofStore — verification is
      # for incoming untrusted data only (see verify_incoming_transaction!).
      #
      # @param raw_tx [String] signed transaction binary (wire format)
      # @param action_id [Integer] action whose inputs to resolve for ancestry
      # @return [String] Atomic BEEF binary
      def build_atomic_beef(raw_tx, action_id)
        tx = BSV::Transaction::Transaction.from_binary(raw_tx)
        resolved_inputs = @store.resolve_inputs_for_signing(action_id: action_id)

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

        proof = @store.find_proof(wtxid: wtxid)
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

      # Hydrate inputs whose source_transaction is nil from ProofStore.
      #
      # Used by trustSelf: the sender may include TXID-only entries for ancestors
      # they know we have. from_binary can't wire those (no Transaction object).
      # This fills the gaps from local storage so verify can walk the full graph.
      #
      # @param tx [BSV::Transaction::Transaction] transaction to hydrate
      def hydrate_known_sources!(tx)
        tx.inputs.each do |input|
          next if input.source_transaction

          input.source_transaction = wire_ancestor(input.prev_wtxid)
        end
      end

      # Parse the tx: parameter as BEEF and extract the subject transaction.
      #
      # @param data [String] binary BEEF data (Atomic, V1, or V2)
      # @return [Array(BSV::Transaction::Beef, BSV::Transaction::Transaction)]
      # @raise [InvalidBeefError] if the data is invalid or the subject tx is missing
      def parse_beef(data)
        beef = BSV::Transaction::Beef.from_binary(data)

        raise BSV::Wallet::InvalidBeefError, 'BEEF contains no transactions' if beef.transactions.empty?

        subject_wtxid = beef.subject_wtxid
        subject_tx = if subject_wtxid
                       beef.find_atomic_transaction(subject_wtxid)
                     else
                       # Non-atomic BEEF: the last transaction is the subject
                       beef.transactions.last&.transaction
                     end

        raise BSV::Wallet::InvalidBeefError, 'subject transaction not found in BEEF' unless subject_tx

        [beef, subject_tx]
      rescue ArgumentError => e
        raise BSV::Wallet::InvalidBeefError, e.message
      end

      # Save merkle proofs from a parsed BEEF to ProofStore.
      # Links the subject transaction's proof to the action when present.
      #
      # @param beef [BSV::Transaction::Beef] parsed BEEF bundle
      # @param subject_wtxid [String] 32-byte wtxid of the subject transaction (wire order)
      # @param action_id [Integer] the action to link the subject proof to
      def save_beef_proofs(beef, subject_wtxid, action_id)
        BSV::Primitives::Hex.validate_wtxid!(subject_wtxid, name: 'save_beef_proofs subject_wtxid')
        subject_proof_id = nil

        beef.transactions.each do |beef_tx|
          next if beef_tx.is_a?(BSV::Transaction::Beef::TxidOnlyEntry)
          next unless beef_tx.transaction

          wtxid = beef_tx.transaction.wtxid
          merkle_path = beef_tx.transaction.merkle_path ||
                        (beef_tx.respond_to?(:bump_index) && beef_tx.bump_index &&
                         beef.bumps[beef_tx.bump_index])

          proof = { raw_tx: beef_tx.transaction.to_binary }
          if merkle_path
            proof[:height] = merkle_path.block_height
            proof[:merkle_path] = merkle_path.to_binary
          end

          proof_id = @store.save_proof(wtxid: wtxid, proof: proof)
          # Only capture the subject's proof_id when it actually carries a
          # merkle_path. Without this guard, an incoming BEEF whose subject
          # has no BUMP (raw_tx-only) would link the action to a placeholder
          # proof row with no chain anchor, making the action falsely appear
          # "proven". Acquisition of the real proof happens later via the
          # daemon's proof-acquisition task (#167). Per #177.
          subject_proof_id = proof_id if wtxid == subject_wtxid && merkle_path
        end

        @store.link_proof(action_id: action_id, tx_proof_id: subject_proof_id) if subject_proof_id
      end

      # Full SPV verification of an incoming transaction via the SDK.
      #
      # Replaces validate_beef! + validate_fee_adequacy! with a single
      # Transaction#verify call that checks scripts, merkle proofs, and
      # fee adequacy (output <= input).
      #
      # @param subject_tx [BSV::Transaction::Transaction]
      # @raise [InvalidBeefError] wrapping SDK VerificationError
      def verify_incoming_transaction!(subject_tx)
        raise BSV::Wallet::InvalidBeefError, 'chain_tracker required for SPV verification' unless @chain_tracker

        subject_tx.verify(chain_tracker: @chain_tracker)
      rescue BSV::Transaction::VerificationError => e
        raise BSV::Wallet::InvalidBeefError, "SPV verification failed: #{e.message} (#{e.code})"
      end

      # Replace known ancestor transactions with TXID-only entries in the BEEF.
      #
      # An ancestor is "known" if it has a proof in ProofStore or its wtxid
      # appears in the known_wtxids array. The subject transaction is never
      # replaced.
      #
      # @param beef [BSV::Transaction::Beef] the BEEF bundle to modify
      # @param subject_wtxid [String] 32-byte subject wtxid (wire order, never replaced)
      # @param known_wtxids [Array<String>, nil] additional known wtxids (wire order binary)
      # @return [Boolean] true if any entries were replaced
      def replace_known_ancestors!(beef, subject_wtxid, known_wtxids)
        known_set = Set.new(known_wtxids || [])
        replaced_count = 0

        beef.transactions.each do |beef_tx|
          wtxid = beef_tx.wtxid
          next if wtxid == subject_wtxid
          next if beef_tx.is_a?(BSV::Transaction::Beef::TxidOnlyEntry)

          next unless known_set.include?(wtxid) || @store.proof_exists?(wtxid: wtxid)

          BSV.logger&.debug { "[Engine] replace_known_ancestors!: replacing dtxid=#{wtxid.reverse.unpack1('H*')}" }
          beef.make_txid_only(wtxid)
          replaced_count += 1
        end

        BSV.logger&.debug { "[Engine] replace_known_ancestors!: replaced_count=#{replaced_count}" }
        replaced_count.positive?
      end

      def resolve_internalize_output(out)
        spec = { satoshis: out[:satoshis] || 0, vout: out[:output_index] || 0 }

        case out[:protocol]
        when :wallet_payment, 'wallet payment'
          rem = out[:payment_remittance] || {}
          spec[:derivation_prefix]  = rem[:derivation_prefix]
          spec[:derivation_suffix]  = rem[:derivation_suffix]
          spec[:sender_identity_key] = rem[:sender_identity_key]
        when :basket_insertion, 'basket insertion'
          rem = out[:insertion_remittance] || {}
          spec[:basket]              = rem[:basket]
          spec[:custom_instructions] = rem[:custom_instructions]
          spec[:tags]                = rem[:tags]
          spec[:derivation_prefix]   = rem[:derivation_prefix]
          spec[:derivation_suffix]   = rem[:derivation_suffix]
          spec[:sender_identity_key] = rem[:sender_identity_key]
          # Basket insertion protocol: no derivation fields means root-key ownership.
          # This is a protocol-level decision, not inference from field absence.
          spec[:output_type] = 'root' unless rem[:derivation_prefix]
        end

        spec
      end

      def validate_recipient_key!(key)
        return if key.is_a?(String) && key.match?(/\A(?:02|03)[0-9a-fA-F]{64}\z/)

        raise ArgumentError, "invalid recipient key: expected 66-char compressed public key hex, got #{key.inspect}"
      end

      def validate_reference!(reference)
        return if reference.is_a?(String) && reference.match?(UUID_RE)

        raise BSV::Wallet::InvalidParameterError, 'reference'
      end

      def require_key_deriver!
        raise BSV::Wallet::Error.new('wallet has no key deriver configured', code: 2) unless @key_deriver
      end

      def enforce_limp_mode!
        return if @bypass_limp_mode
        return unless limp_mode?

        raise BSV::Wallet::LimpModeError.new(
          balance: @utxo_pool.balance, threshold: @limp_threshold
        )
      end

      def enforce_headroom!(spending)
        enforce_headroom_against!(@utxo_pool.balance, spending)
      end

      # Headroom guard against a caller-supplied balance reference. The
      # funding loop captures balance pre-lock and re-uses it for both the
      # pre-flight and exact post-loop checks — once inputs are locked,
      # @utxo_pool.balance no longer reflects the wallet's full pool.
      def enforce_headroom_against!(balance, spending)
        return if @bypass_limp_mode

        projected = balance - spending
        return unless projected < @limp_threshold

        raise BSV::Wallet::LimpModeError.new(
          balance: projected, threshold: @limp_threshold
        )
      end

      # Find an available WBIKD slot or create one via self-payment.
      #
      # Queries basket 'p wbikd' for a spendable (unlocked) output. If none
      # exists, creates a broadcast self-payment with random satoshis (100-1000)
      # and an OP_RETURN recovery marker.
      #
      # Broadcasting is essential — create_action's funding loop locks UTXOs
      # and writes change rows that only become spendable at Phase 4. Without
      # broadcast, those funding UTXOs stay locked and change never becomes
      # spendable. The random amount provides privacy (slots are
      # indistinguishable from normal wallet activity on-chain). The OP_RETURN
      # marker enables address recovery from the identity key alone.
      #
      # @return [Hash] { slot:, dtxid:, vout: } — slot output hash + on-chain derivation data
      def find_or_create_wbikd_slot
        result = @store.query_outputs(basket: 'p wbikd', limit: 1)
        if result[:total].positive?
          slot = result[:outputs].first
          source_action = @store.find_action(id: slot[:action_id])
          dtxid = source_action[:wtxid].reverse.unpack1('H*')
          return { slot: slot, dtxid: dtxid, vout: slot[:vout] }
        end

        # Create a slot via broadcast self-payment with OP_RETURN recovery marker
        prefix = random_derivation
        suffix = '1'
        derived_pub = @key_deriver.derive_public_key(
          protocol_id: [2, prefix], key_id: suffix, counterparty: 'self'
        )
        script = BSV::Script::Script.p2pkh_lock(
          BSV::Primitives::Digest.hash160(derived_pub)
        ).to_binary

        slot_sats = rand(100..1000)
        marker = compute_wbikd_marker(slot_sats)
        op_return_script = BSV::Script::Script.op_return(marker).to_binary

        create_result = create_action(
          description: 'wbikd slot creation',
          accept_delayed_broadcast: false,
          outputs: [
            { satoshis: slot_sats, locking_script: script,
              basket: 'p wbikd',
              derivation_prefix: prefix, derivation_suffix: suffix,
              sender_identity_key: @key_deriver.identity_key },
            { satoshis: 0, locking_script: op_return_script }
          ],
          randomize_outputs: false
        )

        # txid from create_action is wire-order wtxid
        dtxid = create_result[:txid].reverse.unpack1('H*')

        # Re-query for the newly created slot
        result = @store.query_outputs(basket: 'p wbikd', limit: 1)
        { slot: result[:outputs].first, dtxid: dtxid, vout: 0 }
      end

      # Compute the WBIKD recovery marker for a slot with the given satoshi amount.
      # HMAC-SHA256(identity_private_key, satoshi_amount_string)
      #
      # @param satoshis [Integer]
      # @return [String] 32-byte binary marker
      def compute_wbikd_marker(satoshis)
        BSV::Primitives::Digest.hmac_sha256(
          @key_deriver.root_private_key_bytes,
          satoshis.to_s
        )
      end

      # Internalize a UTXO found at a WBIKD receive address.
      #
      # Fetches the transaction from the network, verifies the output
      # matches the derived address, creates an incoming action with
      # BRC-42 derivation params (immediately spendable), fetches any
      # available merkle proof, then aborts the locking action to
      # recycle the slot back to basket 'p wbikd'.
      #
      # Unlike import_utxo, no self-payment step is needed — the output
      # already has BRC-42 derivation params for the wallet to spend.
      #
      # @param dtxid [String] 64-char hex transaction ID (display order)
      # @param vout [Integer] output index
      # @param derivation_prefix [String] BRC-42 derivation prefix
      # @param derivation_suffix [String] BRC-42 derivation suffix
      # @param action_reference [String] UUID reference of the locking action to abort
      def internalize_wbikd_utxo(dtxid:, vout:, derivation_prefix:, derivation_suffix:, action_reference:)
        # 1. Fetch raw tx from network
        result = @network_provider.call(:get_tx, txid: dtxid)
        return unless result.respond_to?(:http_success?) && result.http_success?

        raw_tx = [result.data.strip].pack('H*')
        tx = BSV::Transaction::Transaction.from_binary(raw_tx)
        output = tx.outputs[vout]
        return unless output

        # 2. Verify output matches our derived address
        derived_pub = @key_deriver.derive_public_key(
          protocol_id: [2, derivation_prefix], key_id: derivation_suffix, counterparty: 'self'
        )
        expected_hash = BSV::Primitives::Digest.hash160(derived_pub)
        return unless output.locking_script.p2pkh? &&
                      output.locking_script.chunks[2].data == expected_hash

        # 3. Create incoming action (same pattern as import_utxo)
        wtxid = tx.wtxid
        import_action = @store.create_action(
          action: { description: 'wbikd received funds', broadcast_intent: :none, outgoing: false }
        )
        @store.sign_action(action_id: import_action[:id], wtxid: wtxid, raw_tx: raw_tx)
        @store.save_proof(wtxid: wtxid, proof: { raw_tx: raw_tx })

        # 4. Promote with BRC-42 derivation params (output is immediately spendable).
        # Tag with 'wbikd' so future sweeps can re-derive and re-scan the address
        # even after the locking action is aborted and the slot recycled.
        @store.promote_action(
          action_id: import_action[:id],
          outputs: [{
            satoshis: output.satoshis, vout: vout,
            locking_script: output.locking_script.to_binary,
            derivation_prefix: derivation_prefix,
            derivation_suffix: derivation_suffix,
            sender_identity_key: @key_deriver.identity_key,
            tags: ['wbikd']
          }]
        )

        # 5. Fetch and link merkle proof if mined (best-effort — must not block slot recycling)
        begin
          fetch_and_link_proof(import_action[:id], wtxid, dtxid, raw_tx)
        rescue StandardError => e
          BSV.logger&.warn { "[Engine] wbikd proof fetch failed: #{e.message}" }
        end

        # 6. Abort the locking action — CASCADE releases slot back to p wbikd basket
        abort_action(reference: action_reference)
      end

      # Fetch merkle proof from the network and link it to an action.
      #
      # Queries :get_tx_details for block height, then :get_merkle_path
      # for the TSC merkle proof. Saves the proof to ProofStore and links
      # it to the action. No-op if the transaction is unconfirmed.
      #
      # @param action_id [Integer] the action to link the proof to
      # @param wtxid [String] 32-byte wire-order wtxid
      # @param dtxid [String] 64-char hex transaction ID (display order)
      # @param raw_tx [String] raw transaction binary
      def fetch_and_link_proof(action_id, wtxid, dtxid, raw_tx)
        details_result = @network_provider.call(:get_tx_details, txid: dtxid)
        return unless details_result.http_success? && details_result.data['blockheight']

        block_height = details_result.data['blockheight']
        merkle_path = nil

        proof_result = @network_provider.call(:get_merkle_path, txid: dtxid)
        if proof_result.http_success? && proof_result.data.is_a?(Array) && proof_result.data.any?
          tsc = proof_result.data.first
          mp = BSV::Transaction::MerklePath.from_tsc(
            dtxid_hex: tsc['txOrId'], index: tsc['index'],
            nodes: tsc['nodes'], block_height: block_height
          )
          merkle_path = mp.to_binary
        end

        proof = { raw_tx: raw_tx, merkle_path: merkle_path, height: block_height }.compact
        return unless proof.any?

        proof_id = @store.save_proof(wtxid: wtxid, proof: proof)
        @store.link_proof(action_id: action_id, tx_proof_id: proof_id)
      end

      def secure_compare(a, b)
        return false unless a.bytesize == b.bytesize

        # Constant-time comparison
        result = 0
        a.bytes.zip(b.bytes) { |x, y| result |= x ^ y }
        result.zero?
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
          input.source_satoshis = resolved[:source_satoshis]

          locking_script = resolve_source_locking_script(resolved[:source_locking_script])
          input.source_locking_script = locking_script

          # Find the caller's input spec for this vin (for custom unlocking scripts)
          caller_input = find_caller_input(caller_inputs, resolved[:vin])

          if caller_input&.dig(:unlocking_script)
            # Custom unlocking script provided by the caller
            input.unlocking_script = resolve_unlocking_script(caller_input[:unlocking_script])
          elsif locking_script&.p2pkh?
            # P2PKH: derive the signing key
            require_key_deriver!
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

      # Resolve a source locking script (binary) into a Script object.
      #
      # @param script_data [String, nil] binary locking script
      # @return [Script::Script, nil]
      def resolve_source_locking_script(script_data)
        return if script_data.nil?

        BSV::Script::Script.from_binary(script_data)
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
          BSV.logger&.debug { '[Engine] derive_signing_key: root key (no derivation)' }
          return @key_deriver.root_private_key
        end

        BSV.logger&.debug { "[Engine] derive_signing_key: derived prefix=#{resolved[:derivation_prefix]}" }
        counterparty = resolved[:sender_identity_key] || 'self'

        @key_deriver.derive_private_key(
          protocol_id: [2, resolved[:derivation_prefix]],
          key_id: resolved[:derivation_suffix],
          counterparty: counterparty
        )
      end

      # Assemble, optionally sign, and serialize an SDK transaction.
      #
      # Resolves locked inputs from the Store, builds TransactionInput and
      # TransactionOutput objects via the helpers from Tasks 21/22, signs
      # P2PKH inputs (unless sign: false), and serializes.
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
      # @return [Array(String, String, Hash)] wtxid (32-byte wire order),
      #   raw_tx (binary), and vout_mapping (original index -> new vout)
      def build_transaction(action_id, inputs, outputs, lock_time, version, randomize, sign: true)
        resolved_inputs = @store.resolve_inputs_for_signing(action_id: action_id)

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

        [wtxid, raw_tx, vout_mapping]
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
        max_iterations = [@utxo_pool.spendable_count + 1, 2].max

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
            extra = select_inputs(target_satoshis: result[:shortfall], exclude: locked_output_ids)
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
          locked = @store.lock_inputs(action_id: action_id, inputs: top_up)
          raise BSV::Wallet::InsufficientFundsError unless locked == top_up.size

          locked_output_ids.concat(top_up.map { |i| i[:output_id] })
        end

        raise BSV::Wallet::InsufficientFundsError
      end

      # Sum source_satoshis across all inputs currently locked to action_id.
      # Used by the exact post-loop headroom check.
      def total_input_satoshis_for(action_id)
        @store.resolve_inputs_for_signing(action_id: action_id).sum { |r| r[:source_satoshis] }
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
        resolved_inputs = @store.resolve_inputs_for_signing(action_id: action_id)
        tx_inputs, signing_keys = build_inputs(resolved_inputs, caller_inputs)

        # B. Derive change output keys (BRC-42 self-payments)
        change_keys = change_count.times.map do |i|
          prefix = random_derivation
          suffix = (i + 1).to_s
          pub = @key_deriver.derive_public_key(
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
            sender_identity_key: @key_deriver.identity_key
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

      # Apply caller-provided unlocking scripts and sign remaining inputs.
      #
      # Deserializes the unsigned transaction stored during deferred
      # create_action, applies unlocking scripts from the spends hash,
      # signs any remaining P2PKH inputs the wallet can sign, serializes,
      # and returns [wtxid, raw_tx].
      #
      # @param action [Hash] the action record from find_action
      # @param spends [Hash{Integer => Hash}] vin => { unlocking_script:, sequence_number: }
      # @return [Array(String, String)] wtxid (32-byte wire order), raw_tx (binary)
      def apply_spends(action, spends)
        # Deserialize the unsigned transaction stored during create_action
        unsigned_raw = action[:raw_tx]
        raise BSV::Wallet::Error, 'no unsigned transaction for deferred action' unless unsigned_raw

        tx = BSV::Transaction::Transaction.from_binary(unsigned_raw)

        # Resolve inputs from the Store — needed for source data (satoshis,
        # locking script, derivation params) which are not in the wire format
        resolved_inputs = @store.resolve_inputs_for_signing(action_id: action[:id])

        # Re-attach source data and apply spends
        signing_keys = {}
        resolved_inputs.each_with_index do |resolved, idx|
          input = tx.inputs[idx]
          input.source_satoshis = resolved[:source_satoshis]
          input.source_locking_script = resolve_source_locking_script(resolved[:source_locking_script])

          spend = spends[resolved[:vin]] || spends[idx]
          if spend
            # Apply sequence override if provided
            input.sequence = spend[:sequence_number] if spend[:sequence_number]

            # Apply caller-provided unlocking script
            input.unlocking_script = resolve_unlocking_script(spend[:unlocking_script]) if spend[:unlocking_script]
          elsif input.source_locking_script&.p2pkh?
            # No spend provided for this P2PKH input — wallet signs it
            require_key_deriver!
            signing_keys[idx] = derive_signing_key(resolved)
          end

          # Validate: check for unresolvable inputs (no spend + no P2PKH)
          spend = spends[resolved[:vin]] || spends[idx]
          next if spend&.dig(:unlocking_script)
          next if signing_keys.key?(idx)

          raise BSV::Wallet::Error,
                "input at vin #{resolved[:vin]} has no unlocking script in spends " \
                'and is not a P2PKH input the wallet can sign'
        end

        # Sign wallet-owned P2PKH inputs
        signing_keys.each { |idx, key| tx.sign(idx, key) }

        # Validate spends don't reference non-existent input indices
        valid_vins = resolved_inputs.map { |r| r[:vin] }
        valid_indices = (0...resolved_inputs.length).to_a
        spends.each_key do |vin|
          next if valid_vins.include?(vin) || valid_indices.include?(vin)

          raise BSV::Wallet::InvalidParameterError.new(
            'spends', "vin #{vin} does not exist in the transaction"
          )
        end

        raw_tx = tx.to_binary
        wtxid = tx.wtxid

        # Trailing +tx+ for callers that need EF format at broadcast
        # time. Source data was wired in the +resolved_inputs.each+
        # loop above; +tx.to_ef+ now works without DB hits.
        [wtxid, raw_tx, tx]
      end

      def random_derivation
        BSV::Wallet.random_derivation
      end
    end
  end
end
