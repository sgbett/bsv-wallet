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

      autoload :Action,                'bsv/wallet/engine/action'
      autoload :Broadcast,             'bsv/wallet/engine/broadcast'
      autoload :TxProof,               'bsv/wallet/engine/tx_proof'
      autoload :OmqSupport,            'bsv/wallet/engine/omq_support'
      autoload :InputSource,           'bsv/wallet/engine/input_source'
      autoload :MerklePathNormaliser,  'bsv/wallet/engine/merkle_path_normaliser'
      autoload :HydratedTxCache,       'bsv/wallet/engine/hydrated_tx_cache'

      UUID_RE = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

      LIMP_THRESHOLD     = 50_000  # default: 50K sats
      LIMP_THRESHOLD_MIN = 10_000  # hard floor: cannot configure below this

      attr_reader :limp_threshold, :services, :broadcaster, :broadcast_worker

      # Engine collaborator surface exposed for Engine::Action use.
      # Not public API — these are internal handles for in-process logical models.
      attr_reader :store, :utxo_pool, :key_deriver, :chain_tracker, :network_provider

      def initialize(store:, utxo_pool:, broadcaster:,
                     services: nil, key_deriver: nil, chain_tracker: nil,
                     network_provider: nil,
                     network: :mainnet, limp_threshold: LIMP_THRESHOLD,
                     callback_token: nil)
        raise ArgumentError, "limp_threshold must be >= #{LIMP_THRESHOLD_MIN}" if limp_threshold < LIMP_THRESHOLD_MIN

        @store = store
        @utxo_pool = utxo_pool
        @services = services
        @broadcaster = broadcaster
        @key_deriver = key_deriver
        @chain_tracker = chain_tracker
        @network_provider = network_provider
        @network_name = network
        @limp_threshold = limp_threshold
        # Arcade callbackToken forwarded to the broadcast worker's POST so the
        # SSE listener (subscribed to the same token at daemon boot) receives
        # status frames for inline submissions. See #266.
        @callback_token = callback_token
        # Inline-broadcast worker — same Engine::Broadcast the daemon's PULL
        # loop uses. Eliminates the parallel +inline_broadcast+ codepath
        # that pre-#271 duplicated submit's 202 / 400 / 503 dispatch and
        # the post-submit accept / reject / promote bookkeeping.
        @broadcast_worker = Broadcast.new(store: @store, broadcaster: @broadcaster,
                                          callback_token: @callback_token)
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

        Action.create(
          engine: self,
          description: description, input_beef: input_beef,
          inputs: inputs, outputs: outputs,
          lock_time: lock_time, version: version, labels: labels,
          sign_and_process: sign_and_process,
          accept_delayed_broadcast: accept_delayed_broadcast,
          trust_self: trust_self, return_txid_only: return_txid_only,
          no_send: no_send, change_count: change_count,
          randomize_outputs: randomize_outputs, originator: originator
        )
      end

      def sign_action(spends:, reference:, accept_delayed_broadcast: true,
                      return_txid_only: false, no_send: false,
                      originator: nil)
        validate_reference!(reference)
        action = Action.find(engine: self, reference: reference)
        raise BSV::Wallet::InvalidParameterError, 'reference' unless action

        action.sign!(
          spends: spends,
          no_send: no_send,
          accept_delayed_broadcast: accept_delayed_broadcast,
          return_txid_only: return_txid_only
        )
      end

      def abort_action(reference:, originator: nil)
        validate_reference!(reference)
        action = Action.find(engine: self, reference: reference)
        raise BSV::Wallet::InvalidParameterError, 'reference' unless action

        action.abort!
      end

      # Operator-facing entry to Store#reject_action. The daemon's
      # resolution loop calls store directly; this wrapper lets bin/
      # tools target specific stuck rows (action_id is a wallet-local
      # integer, not a BRC-100 reference — this isn't a spec method).
      def reject_action(action_id:)
        raise BSV::Wallet::InvalidParameterError, "action_id=#{action_id} not found" unless Action.find_by_id(engine: self, id: action_id)

        @store.reject_action(action_id: action_id)
        { rejected: true, action_id: action_id }
      end

      def list_actions(**params)
        Action.list(engine: self, **params)
      end

      def internalize_action(tx:, outputs:, description:, labels: nil,
                             trust_self: nil, known_txids: nil,
                             seek_permission: true, originator: nil)
        validate_description!(description)
        # known_txids is the BRC-100 spec param name; values are wire-order wtxids
        known_txids&.each { |w| BSV::Primitives::Hex.validate_wtxid!(w, name: 'known_txids entry') }

        Action.internalize(
          engine: self,
          tx: tx, outputs: outputs, description: description,
          labels: labels, trust_self: trust_self, known_txids: known_txids,
          seek_permission: seek_permission, originator: originator
        )
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
      # @param no_send [Boolean] default false (BRC-100 createAction
      #   default — intend to broadcast). Phase 2's BRC-42 self-payment
      #   is queued for broadcast, so its output lives on the chain's
      #   UTXO set, making downstream broadcasts referencing it consensus-
      #   valid. The rule is binary: either every action in the run
      #   broadcasts (including this one) or none of them do —
      #   broadcasting a descendant of a +no_send: true+ parent gets
      #   rejected by the network for a non-existent input.
      #
      #   Set true only for the "build locally without ever broadcasting"
      #   case where the wallet intentionally never publishes the action
      #   (rare; downstream broadcasts will fail consensus).
      # @param accept_delayed_broadcast [Boolean] only consulted when
      #   +no_send+ is false. Default true (queue for the daemon to
      #   push). Tests that want "build + queue, never broadcast" leave
      #   this true and don't run walletd — the queue stays full but
      #   nothing reaches the network.
      # @return [Hash] { imported: true, satoshis:, dtxid: }
      def import_utxo(dtxid:, vout: 0, no_send: false, accept_delayed_broadcast: true)
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

        # Strict import (#296 Phase B): obtain the merkle_path BEFORE
        # creating any state. The wallet's egress invariant requires every
        # imported root UTXO to carry on-chain proof material for the
        # BEEFs we build atop it. Acquiring it after the fact (the
        # previous "best-effort" model) silently failed when the network
        # provider didn't return +blockheight+, leaving the imported UTXO
        # un-forwardable. Refusing at the boundary eliminates the state.
        block_height, merkle_path_binary = fetch_proof_for_imported_utxo!(dtxid)

        # Phase 1: Record the root-key UTXO + its proof atomically. The
        # transaction wrapper makes the five Store writes commit-or-rollback
        # together: a partial failure (e.g. save_proof raises after
        # create_action) would otherwise leave an orphan +actions+ row
        # whose wtxid then short-circuits the next +import_utxo+ run as
        # +already_imported+, locking the user out of re-importing.
        import_action = nil
        imported_output_id = nil
        @store.db.transaction do
          import_action = @store.create_action(
            action: { description: 'imported UTXO', broadcast_intent: :none, outgoing: false }
          )
          @store.sign_action(action_id: import_action[:id], wtxid: wtxid, raw_tx: raw_tx)
          proof_id = @store.save_proof(
            wtxid: wtxid,
            proof: { raw_tx: raw_tx, merkle_path: merkle_path_binary, height: block_height }
          )
          @store.link_proof(action_id: import_action[:id], tx_proof_id: proof_id)
          output_ids = @store.promote_action(
            action_id: import_action[:id],
            outputs: [{ satoshis: satoshis, vout: vout, locking_script: locking_script.to_binary, output_type: 'root' }]
          )
          imported_output_id = output_ids.first
        end

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
      #   discovered UTXO. Default false (BRC-100 createAction default).
      #   Set true only for the "build locally without broadcasting" case.
      # @param accept_delayed_broadcast [Boolean] forwarded to
      #   +import_utxo+. Only consulted when +no_send+ is false.
      # @param include_unconfirmed [Boolean] when true, scan WoC's
      #   +/unspent/all+ endpoint which includes mempool entries.
      #   Default false uses +/confirmed/unspent+ (safer — confirmed
      #   UTXOs can't be reorged-away under us). The e2e harness's
      #   Phase 4 sets true so SDK can see the just-broadcast sweep
      #   outputs without waiting for a block.
      # @return [Hash] { imported: Integer, utxos: Array<Hash> }
      def import_wallet(no_send: false, accept_delayed_broadcast: true,
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

        wtxid, raw_tx, = Action.new(engine: self, row: { id: locking_action[:id] }).send(
          :build_transaction, locking_action[:id], [{ output_id: slot[:id] }], [], nil, nil, false
        )
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
      # @param no_send [Boolean] default false (BRC-100 createAction
      #   default — intend to broadcast). Set true for "build + sign
      #   + return BEEF for peer-to-peer handoff without ever publishing."
      # @param accept_delayed_broadcast [Boolean] only consulted when
      #   +no_send+ is false. Default true (queue for the daemon to push).
      # @return [Hash] { beef:, sender_identity_key:, outputs: [{ vout:, satoshis:, derivation_prefix:, derivation_suffix: }] }
      def send_payment(recipient:, satoshis:, no_send: false, accept_delayed_broadcast: true)
        require_key_deriver!
        validate_recipient_key!(recipient)

        derivation_prefix = BSV::Wallet.random_derivation
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
      # @param no_send [Boolean] default false (BRC-100 createAction
      #   default — intend to broadcast). Set true only for the "build
      #   locally without broadcasting" case.
      # @param accept_delayed_broadcast [Boolean] only consulted when
      #   +no_send+ is false. Default true (queue for the daemon to push).
      # @return [Hash, nil] the +create_action+ result, or +nil+ if there are
      #   fewer than +target_inputs+ spendable outputs (the loop's natural exit).
      def consolidate_step(target_inputs: 20, no_send: false, accept_delayed_broadcast: true)
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
      # @param no_send [Boolean] default false (BRC-100 createAction
      #   default — intend to broadcast). Set true for "build + sign
      #   + return BEEF for peer-to-peer handoff without ever publishing."
      # @param accept_delayed_broadcast [Boolean] only consulted when
      #   +no_send+ is false. Default true (queue for the daemon to push).
      # @return [Hash, nil] the +create_action+ result, or +nil+ when the
      #   wallet has no spendable outputs.
      def sweep(recipient:, no_send: false, accept_delayed_broadcast: true)
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

        root_hash = nil
        outputs.each_with_index do |out, idx|
          next unless out[:output_type] == 'root'

          script = Action.resolve_locking_script(out[:locking_script])
          unless script.p2pkh?
            raise BSV::Wallet::InvalidParameterError.new(
              "outputs[#{idx}].output_type",
              "'root' requires a P2PKH script"
            )
          end

          root_hash ||= BSV::Primitives::Digest.hash160(@key_deriver.identity_key_bytes)
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

      # Thin delegator: call sites still on Engine in this sub-PR
      # (internalize_action, generate_receive_address) — move with their
      # owners in later sub-PRs. Canonical impl: +Action.attach_labels+.
      def attach_labels(action_id, labels)
        Action.attach_labels(engine: self, action_id: action_id, labels: labels)
      end

      # Build an Atomic BEEF (BRC-95) envelope for a signed transaction.
      #
      # Push a BEEF cache hint to the daemon so broadcast skips both
      # +find_action+ and the +resolve_inputs_for_signing+ JOIN. BEEF is
      # the natural hint payload: it's a strict superset of EF for the
      # subject tx, the producer has it built already (returned to the
      # caller from +create_action+), and the same cached Transaction
      # serves a future BEEF-based p2p hand-off path without rebuilding.
      # Best-effort: when +BSV_WALLET_HINTS_SOCKET+ is unset, do
      # nothing. Push failures (daemon not listening, socket missing, OMQ
      # error) are swallowed — daemon's #252 reconstruction stays the
      # correctness floor. #269.
      #
      # Dangling hints: if a producer crashes between this push and the
      # action's DB commit, the daemon caches a hint for an action it
      # will never look up. Harmless — broadcast discovery reads from
      # the DB, not the cache, so an orphan entry is never queried.
      # +HydratedTxCache+'s LRU eventually evicts it under load. No
      # reconciliation required.
      def publish_beef_hint(action_id, atomic_beef)
        # Config#initialize normalises blank/unset env to nil so a
        # set-but-empty +BSV_WALLET_HINTS_SOCKET+ doesn't crash
        # +OMQ::PUSH.connect+ here.
        socket_path = BSV::Wallet.config.hints_socket
        return unless socket_path

        payload = Marshal.dump(action_id: action_id, beef: atomic_beef)

        @hints_socket_lock ||= Mutex.new
        @hints_socket_lock.synchronize do
          @hints_socket ||= OMQ::PUSH.connect(socket_path)
          @hints_socket << payload
        end
      rescue StandardError => e
        BSV.logger&.debug { "[Engine] BEEF hint publish skipped: #{e.message}" }
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
        prefix = BSV::Wallet.random_derivation
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

      # Strict acquisition of a confirmed UTXO's merkle proof (#296 Phase B).
      #
      # Returns +[block_height, merkle_path_binary]+ for the named tx, or
      # raises +BSV::Wallet::Error+ if the proof cannot be obtained. Used
      # by +import_utxo+ which refuses to register any UTXO without
      # on-chain proof material — the wallet's egress invariant depends
      # on every root having complete closure.
      #
      # @param dtxid [String] 64-char hex transaction ID (display order)
      # @return [Array(Integer, String)] block_height and merkle_path binary
      # @raise [BSV::Wallet::Error] when get_tx_details / get_merkle_path
      #   does not yield usable proof material
      def fetch_proof_for_imported_utxo!(dtxid)
        details_result = @network_provider.call(:get_tx_details, txid: dtxid)
        unless details_result.http_success?
          raise BSV::Wallet::Error,
                "cannot import #{dtxid}: get_tx_details failed (HTTP #{details_result.status_code})"
        end
        unless details_result.data['blockheight']
          raise BSV::Wallet::Error,
                "cannot import #{dtxid}: transaction is not confirmed " \
                '(network provider returned no blockheight). Strict import ' \
                'refuses unconfirmed UTXOs — only confirmed UTXOs are importable.'
        end

        block_height = details_result.data['blockheight']

        proof_result = @network_provider.call(:get_merkle_path, txid: dtxid)
        unless proof_result.http_success? && proof_result.data.is_a?(Array) && proof_result.data.any?
          raise BSV::Wallet::Error,
                "cannot import #{dtxid}: merkle_path not available from chain (height=#{block_height}). " \
                'Strict import refuses to proceed without proof material.'
        end

        tsc = proof_result.data.first
        mp = BSV::Transaction::MerklePath.from_tsc(
          dtxid_hex: tsc['txOrId'], index: tsc['index'],
          nodes: tsc['nodes'], block_height: block_height
        )
        [block_height, mp.to_binary]
      end

      # Best-effort proof acquisition for ALREADY-EXISTING actions. The
      # WBIKD-address slot recycler uses this — the slot's tx may or may
      # not be on chain depending on whether the slot was previously
      # broadcast. Slot recycling MUST NOT block on proof acquisition;
      # silent return is the correct behaviour for this caller.
      #
      # NOTE: import_utxo no longer uses this — under the #296 Phase B
      # strict-import contract, imports use +fetch_proof_for_imported_utxo!+
      # which refuses rather than silently no-opping.
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
    end
  end
end
