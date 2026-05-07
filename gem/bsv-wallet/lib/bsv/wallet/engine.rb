# frozen_string_literal: true

require 'securerandom'
require 'set'

module BSV
  module Wallet
    # Layer 3 — BRC-100 business process orchestration.
    #
    # Receives Layer 2a components at construction time and orchestrates
    # them to fulfill the 28 BRC-100 methods. Contains no SQL, no ARC
    # calls, no thread management. Pure orchestration.
    #
    # @example
    #   engine = BSV::Wallet::Engine.new(
    #     store:           PostgresStore.new(db),
    #     utxo_pool:       SimplePool.new(store),
    #     broadcast_queue: ArcBroadcast.new(arc_client),
    #     proof_store:     PostgresProofStore.new(db)
    #   )
    #   engine.create_action(description: 'payment', outputs: [...])
    class Engine
      include BSV::Wallet::Interface::BRC100

      ACCEPTED_STATUSES = %w[SEEN_ON_NETWORK MINED ACCEPTED_BY_NETWORK IMMUTABLE].freeze
      UUID_RE = /\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/i

      LIMP_THRESHOLD     = 50_000  # default: 50K sats
      LIMP_THRESHOLD_MIN = 10_000  # hard floor: cannot configure below this

      attr_reader :limp_threshold

      def initialize(store:, utxo_pool:, broadcast_queue:, proof_store:,
                     key_deriver: nil, chain_tracker: nil, network_provider: nil,
                     network: :mainnet, limp_threshold: LIMP_THRESHOLD)
        raise ArgumentError, "limp_threshold must be >= #{LIMP_THRESHOLD_MIN}" if limp_threshold < LIMP_THRESHOLD_MIN

        @store = store
        @utxo_pool = utxo_pool
        @broadcast_queue = broadcast_queue
        @proof_store = proof_store
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

      def create_action(description:, input_beef: nil, inputs: nil, outputs: nil,
                        lock_time: nil, version: nil, labels: nil,
                        sign_and_process: true, accept_delayed_broadcast: true,
                        trust_self: nil, known_txids: nil, return_txid_only: false,
                        no_send: false, no_send_change: nil, send_with: nil,
                        randomize_outputs: true, originator: nil)
        validate_description!(description)
        validate_create_action_params!(inputs: inputs, outputs: outputs)
        validate_output_ownership!(outputs)

        # Auto-fund: when inputs is nil with outputs present, the wallet
        # handles UTXO selection, fee estimation, and change generation.
        if inputs.nil? && outputs&.any?
          unless sign_and_process
            raise BSV::Wallet::InvalidParameterError.new(
              'sign_and_process', 'true when inputs is nil (auto-funded actions sign immediately)'
            )
          end
          require_key_deriver!
          enforce_limp_mode!
          return auto_fund_action(
            description: description, outputs: outputs,
            lock_time: lock_time, version: version,
            broadcast: determine_broadcast(no_send, accept_delayed_broadcast),
            labels: labels, randomize_outputs: randomize_outputs,
            no_send: no_send, send_with: send_with,
            return_txid_only: return_txid_only
          )
        end

        broadcast = determine_broadcast(no_send, accept_delayed_broadcast)
        enforce_limp_mode!

        # Phase 1: Lock
        input_specs = build_input_specs(inputs)
        action_result = @store.create_action(
          action: {
            description: description, broadcast: broadcast,
            nlocktime: lock_time || 0, version: version,
            input_beef: input_beef, outgoing: true
          },
          inputs: input_specs
        )
        raise BSV::Wallet::InsufficientFundsError if action_result.nil?

        attach_labels(action_result[:id], labels)

        # Check for deferred signing
        deferred = !sign_and_process ||
                   inputs&.any? { |i| i[:unlocking_script_length] && !i[:unlocking_script] }

        # Phase 2: Build transaction (sign unless deferred)
        wtxid, raw_tx, vout_mapping = build_transaction(
          action_result[:id], inputs, outputs, lock_time, version, randomize_outputs,
          sign: !deferred
        )
        if deferred
          # Store unsigned raw_tx (empty unlocking scripts) and promote outputs now.
          # Outputs are fully known at createAction time — the deferral is about
          # inputs (waiting for caller-provided unlocking scripts), not outputs.
          @store.sign_action(action_id: action_result[:id], wtxid: wtxid, raw_tx: raw_tx)
          promote_with_outputs(action_result[:id], outputs, vout_mapping)
          return {
            signable_transaction: {
              tx: nil,
              reference: action_result[:reference]
            }
          }
        end

        @store.sign_action(action_id: action_result[:id], wtxid: wtxid, raw_tx: raw_tx)
        BSV.logger&.debug { "[Engine] create_action: dtxid=#{wtxid.reverse.unpack1('H*')} outputs=#{outputs&.length || 0}" }

        # Build Atomic BEEF envelope for the :tx return value
        atomic_beef = build_atomic_beef(raw_tx, action_result[:id])

        # No-send path: promote immediately, return change outpoints
        if no_send
          promote_with_outputs(action_result[:id], outputs, vout_mapping)
          change = query_change_outpoints(action_result[:id])
          result = { txid: wtxid, tx: atomic_beef, no_send_change: change }
          result[:send_with_results] = process_send_with(send_with) if send_with&.any?
          return result
        end

        # Phase 3: Broadcast
        broadcast_result = @broadcast_queue.submit(
          action_id: action_result[:id],
          raw_tx: raw_tx,
          immediate: broadcast == :inline
        )

        # Phase 4: Promote (if inline broadcast accepted)
        if broadcast == :inline && accepted?(broadcast_result)
          promote_with_outputs(action_result[:id], outputs, vout_mapping)
          handle_proof_from_broadcast(action_result[:id], broadcast_result)
        end

        result = { txid: wtxid, tx: return_txid_only ? nil : atomic_beef }
        result[:send_with_results] = process_send_with(send_with) if send_with&.any?
        result
      end

      def sign_action(spends:, reference:, accept_delayed_broadcast: true,
                      return_txid_only: false, no_send: false, send_with: nil,
                      originator: nil)
        validate_reference!(reference)
        action = @store.find_action(reference: reference)
        raise BSV::Wallet::InvalidParameterError, 'reference' unless action

        # Outputs were already written during create_action — sign_action only
        # deserializes the unsigned tx, applies caller unlocking scripts, signs
        # remaining P2PKH inputs, and updates the action with signed raw_tx + wtxid.
        wtxid, raw_tx = apply_spends(action, spends)
        @store.sign_action(action_id: action[:id], wtxid: wtxid, raw_tx: raw_tx)

        # Build Atomic BEEF envelope for the :tx return value
        atomic_beef = build_atomic_beef(raw_tx, action[:id])

        broadcast = determine_broadcast(no_send, accept_delayed_broadcast)

        if no_send
          result = { txid: wtxid, tx: atomic_beef }
          result[:send_with_results] = process_send_with(send_with) if send_with&.any?
          return result
        end

        unless broadcast == :none
          broadcast_result = @broadcast_queue.submit(
            action_id: action[:id],
            raw_tx: raw_tx,
            immediate: broadcast == :inline
          )

          handle_proof_from_broadcast(action[:id], broadcast_result) if broadcast == :inline && accepted?(broadcast_result)
        end

        result = { txid: wtxid, tx: return_txid_only ? nil : atomic_beef }
        result[:send_with_results] = process_send_with(send_with) if send_with&.any?
        result
      end

      def abort_action(reference:, originator: nil)
        validate_reference!(reference)
        action = @store.find_action(reference: reference)
        raise BSV::Wallet::InvalidParameterError, 'reference' unless action

        @store.abort_action(action_id: action[:id])
        @utxo_pool.release(outputs: [])
        { aborted: true }
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

        # trustSelf: replace known ancestors with TXID-only entries before validation
        has_txid_only = trust_self == 'known' &&
                        replace_known_ancestors!(beef, subject_tx.wtxid, known_txids)

        # SPV validation: structural integrity and optional merkle root verification
        validate_beef!(beef, allow_txid_only: has_txid_only)

        # Fee adequacy: inputs must exceed outputs (BRC-67)
        validate_fee_adequacy!(subject_tx)

        # Create action (incoming, no broadcast, already completed)
        action_result = @store.create_action(
          action: { description: description, broadcast: :none, outgoing: false }
        )

        # Store wtxid and raw_tx on the action
        @store.sign_action(
          action_id: action_result[:id],
          wtxid: subject_tx.wtxid,
          raw_tx: subject_tx.to_binary
        )
        BSV.logger&.debug { "[Engine] internalize_action: subject=#{subject_tx.dtxid}" }

        attach_labels(action_result[:id], labels)

        # Save ancestor proofs and link subject proof
        save_beef_proofs(beef, subject_tx.wtxid, action_result[:id])

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
      # @return [Hash] { imported: true, satoshis:, dtxid: }
      def import_utxo(dtxid:, vout: 0)
        require_key_deriver!
        raise BSV::Wallet::Error, 'no network provider configured' unless @network_provider

        # Fetch transaction from network
        BSV.logger&.debug { "[Engine] import_utxo: fetching #{dtxid} from network" }
        result = @network_provider.call(:get_tx, txid: dtxid)
        raise BSV::Wallet::Error, "failed to fetch tx #{dtxid}" unless result.success?

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

        # Fetch merkle proof if mined
        merkle_path = nil
        block_height = nil
        details_result = @network_provider.call(:get_tx_details, txid: dtxid)
        if details_result.success? && details_result.data['blockheight']
          block_height = details_result.data['blockheight']
          proof_result = @network_provider.call(:get_merkle_path, txid: dtxid)
          if proof_result.success? && proof_result.data.is_a?(Array) && proof_result.data.any?
            tsc = proof_result.data.first
            mp = BSV::Transaction::MerklePath.from_tsc(
              dtxid_hex: tsc['txOrId'], index: tsc['index'],
              nodes: tsc['nodes'], block_height: block_height
            )
            merkle_path = mp.to_binary
          end
        end

        BSV.logger&.debug { "[Engine] import_utxo: #{satoshis} sats at vout #{vout}, height=#{block_height || 'unconfirmed'}" }

        # Phase 1: Record the root-key UTXO
        import_action = @store.create_action(
          action: { description: 'imported UTXO', broadcast: :none, outgoing: false }
        )
        @store.sign_action(action_id: import_action[:id], wtxid: wtxid, raw_tx: raw_tx)
        output_ids = @store.promote_action(
          action_id: import_action[:id],
          outputs: [{ satoshis: satoshis, vout: vout, locking_script: locking_script.to_binary, output_type: 'root' }]
        )
        imported_output_id = output_ids.first

        # Store proof and link
        proof = { raw_tx: raw_tx, merkle_path: merkle_path, height: block_height }.compact
        if proof.any?
          proof_id = @proof_store.save_proof(wtxid: wtxid, proof: proof)
          @store.link_proof(action_id: import_action[:id], tx_proof_id: proof_id)
        end

        # Phase 2: Self-payment to derived address

        derivation_prefix = SecureRandom.uuid
        derivation_suffix = '1'
        derived_pub = @key_deriver.derive_public_key(
          protocol_id: [2, derivation_prefix], key_id: derivation_suffix, counterparty: 'self'
        )
        derived_script = BSV::Script::Script.p2pkh_lock(
          BSV::Primitives::Digest.hash160(derived_pub)
        ).to_binary

        fee = 1 # token fee for no_send self-payment (BRC-67: inputs > outputs)
        self_payment_sats = satoshis - fee
        raise BSV::Wallet::Error, "insufficient sats for self-payment (#{satoshis} - #{fee} fee)" if self_payment_sats <= 0

        # Bootstrap self-payment bypasses limp mode — this is how the
        # wallet gets funded in the first place.
        @bypass_limp_mode = true
        begin
          create_action(
            description: 'import self-payment',
            inputs: [{ output_id: imported_output_id }],
            outputs: [{
              satoshis: self_payment_sats, locking_script: derived_script,
              derivation_prefix: derivation_prefix, derivation_suffix: derivation_suffix,
              sender_identity_key: @key_deriver.identity_key
            }],
            no_send: true, randomize_outputs: false
          )
        ensure
          @bypass_limp_mode = false
        end

        BSV.logger&.debug { "[Engine] import_utxo complete: #{self_payment_sats} sats on derived address" }
        { imported: true, satoshis: self_payment_sats, dtxid: dtxid }
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
        raise BSV::Wallet::Error.new('wallet is not authenticated', 2) unless @key_deriver

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

      def attach_labels(action_id, labels)
        return unless labels&.any?

        label_ids = @store.find_or_create_labels(names: labels)
        @store.label_action(action_id: action_id, label_ids: label_ids)
      end

      def promote_with_outputs(action_id, outputs, vout_mapping = nil)
        return unless outputs&.any?

        output_specs = outputs.each_with_index.map do |out, idx|
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
        @store.promote_action(action_id: action_id, outputs: output_specs)
      end

      def accepted?(broadcast_result)
        return false unless broadcast_result

        ACCEPTED_STATUSES.include?(broadcast_result[:tx_status])
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

        proof_id = @proof_store.save_proof(
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

      # Broadcast companion transactions listed in send_with.
      #
      # @param send_with [Array<String>] wtxids (wire order) of companion transactions
      # @return [Array<Hash>] :txid (wire-order wtxid, BRC-100 key name), :status
      def process_send_with(send_with)
        return unless send_with

        send_with.filter_map do |sw_wtxid|
          BSV::Primitives::Hex.validate_wtxid!(sw_wtxid, name: 'send_with entry')
          sw_action = @store.find_action(wtxid: sw_wtxid)
          BSV.logger&.debug { "[Engine] process_send_with: dtxid=#{sw_wtxid.reverse.unpack1('H*')} found=#{!sw_action.nil?}" }
          next unless sw_action

          br = @broadcast_queue.submit(
            action_id: sw_action[:id],
            raw_tx: sw_action[:raw_tx] || ''.b,
            immediate: true
          )
          status = br[:tx_status]&.downcase&.tr('_', ' ')&.to_sym || :sending
          { txid: sw_wtxid, status: status }
        end
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

      # Collect ancestor Transaction objects for BEEF construction.
      #
      # For each input of the action, finds the source transaction's proof
      # in ProofStore, reconstructs an SDK Transaction object with its
      # merkle_path wired, and returns the list. These ancestor objects are
      # ready to be passed to Transaction#to_beef or merged into a Beef.
      #
      # @param action_id [Integer] the action whose inputs to resolve
      # @return [Array<BSV::Transaction::Transaction>] ancestor transactions
      #   with merkle_path set for proven ancestors
      def collect_input_ancestry(action_id)
        resolved_inputs = @store.resolve_inputs_for_signing(action_id: action_id)

        resolved_inputs.filter_map do |resolved|
          source_wtxid = resolved[:source_wtxid]
          proof = @proof_store.find_proof(wtxid: source_wtxid)

          next unless proof && proof[:raw_tx] && proof[:raw_tx].bytesize >= 10

          source_tx = BSV::Transaction::Transaction.from_binary(proof[:raw_tx])

          source_tx.merkle_path = BSV::Transaction::MerklePath.from_binary(proof[:merkle_path]).first if proof[:merkle_path]

          source_tx
        end
      end

      # Build an Atomic BEEF (BRC-95) envelope for a signed transaction.
      #
      # For each input, looks up the ancestor proof from ProofStore.
      # Proven ancestors get their merkle_path wired; unproven ancestors
      # are included as raw transactions without a BUMP.
      #
      # @param raw_tx [String] signed transaction binary (wire format)
      # @param action_id [Integer] action whose inputs to resolve for ancestry
      # @return [String] Atomic BEEF binary
      def build_atomic_beef(raw_tx, action_id)
        tx = BSV::Transaction::Transaction.from_binary(raw_tx)
        resolved_inputs = @store.resolve_inputs_for_signing(action_id: action_id)

        # Wire source_transaction and merkle_path on each input.
        # For unconfirmed ancestors, recursively wire their ancestry
        # so the BEEF contains the full chain back to mined transactions.
        resolved_inputs.each_with_index do |resolved, idx|
          input = tx.inputs[idx]
          next unless input

          source_tx = resolve_ancestor(resolved[:source_wtxid])
          next unless source_tx

          input.source_transaction = source_tx
        end

        beef = BSV::Transaction::Beef.new
        beef.merge_transaction(tx)
        beef.to_atomic_binary(tx.wtxid)
      end

      # Recursively resolve an ancestor transaction with its full proof chain.
      #
      # If the ancestor is mined (has merkle_path), wires the BUMP and returns.
      # If unconfirmed, finds the ancestor's own action, resolves ITS inputs
      # recursively, and wires them as source_transactions so the SDK includes
      # the full chain in the BEEF.
      #
      # @param wtxid [String] 32-byte wire-order wtxid
      # @param visited [Set] prevents infinite loops on circular references
      # @return [BSV::Transaction::Transaction, nil]
      def resolve_ancestor(wtxid, visited: Set.new)
        return if visited.include?(wtxid)

        visited.add(wtxid)

        proof = @proof_store.find_proof(wtxid: wtxid)
        unless proof && proof[:raw_tx] && proof[:raw_tx].bytesize >= 10
          BSV.logger&.debug { "[Engine] resolve_ancestor: #{wtxid.reverse.unpack1('H*')} proof=missing" }
          return
        end

        source_tx = BSV::Transaction::Transaction.from_binary(proof[:raw_tx])

        if proof[:merkle_path]
          source_tx.merkle_path = BSV::Transaction::MerklePath.from_binary(proof[:merkle_path]).first
          BSV.logger&.debug { "[Engine] resolve_ancestor: #{wtxid.reverse.unpack1('H*')} proof=bump" }
          return source_tx
        end

        # Unconfirmed: resolve each input's ancestor recursively.
        # For outgoing actions with inputs, use the action's input rows.
        # Otherwise (internalized actions or bare proofs from BEEF), parse
        # the raw_tx and resolve each input's prev_wtxid from ProofStore.
        action = @store.find_action(wtxid: wtxid)
        parent_inputs = action ? @store.resolve_inputs_for_signing(action_id: action[:id]) : []

        if parent_inputs.any?
          parent_inputs.each_with_index do |parent_resolved, idx|
            parent_input = source_tx.inputs[idx]
            next unless parent_input

            grandparent = resolve_ancestor(parent_resolved[:source_wtxid], visited: visited)
            parent_input.source_transaction = grandparent if grandparent
          end
        else
          source_tx.inputs.each do |input|
            grandparent = resolve_ancestor(input.prev_wtxid, visited: visited)
            input.source_transaction = grandparent if grandparent
          end
        end

        BSV.logger&.debug { "[Engine] resolve_ancestor: #{wtxid.reverse.unpack1('H*')} proof=raw_tx (recursive)" }
        source_tx
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
          next unless beef_tx.transaction

          wtxid = beef_tx.transaction.wtxid
          merkle_path = beef_tx.transaction.merkle_path ||
                        (beef_tx.bump_index && beef.bumps[beef_tx.bump_index])

          proof = { raw_tx: beef_tx.transaction.to_binary }
          if merkle_path
            proof[:height] = merkle_path.block_height
            proof[:merkle_path] = merkle_path.to_binary
          end

          proof_id = @proof_store.save_proof(wtxid: wtxid, proof: proof)
          subject_proof_id = proof_id if wtxid == subject_wtxid
        end

        @store.link_proof(action_id: action_id, tx_proof_id: subject_proof_id) if subject_proof_id
      end

      # Validate structural integrity and optionally verify merkle roots
      # against a chain tracker.
      #
      # @param beef [BSV::Transaction::Beef] parsed BEEF bundle
      # @param allow_txid_only [Boolean] accept TXID-only entries (trustSelf)
      # @raise [InvalidBeefError] if validation fails
      def validate_beef!(beef, allow_txid_only: false)
        raise BSV::Wallet::InvalidBeefError, 'BEEF failed structural validation' unless beef.valid?(allow_txid_only: allow_txid_only)

        return unless @chain_tracker

        return if beef.verify(@chain_tracker, allow_txid_only: allow_txid_only)

        raise BSV::Wallet::InvalidBeefError, 'BEEF failed merkle root verification'
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
          next if beef_tx.format == BSV::Transaction::Beef::FORMAT_TXID_ONLY

          next unless known_set.include?(wtxid) || @proof_store.proof_exists?(wtxid: wtxid)

          BSV.logger&.debug { "[Engine] replace_known_ancestors!: replacing dtxid=#{wtxid.reverse.unpack1('H*')}" }
          beef.make_txid_only(wtxid)
          replaced_count += 1
        end

        BSV.logger&.debug { "[Engine] replace_known_ancestors!: replaced_count=#{replaced_count}" }
        replaced_count.positive?
      end

      # Check that the subject transaction's input satoshis exceed output satoshis (BRC-67).
      #
      # Inputs without wired source transactions (i.e. missing satoshi data)
      # are skipped — the structural BEEF validation already ensures ancestry
      # is complete. Transactions with no wired inputs (e.g. coinbase) are also skipped.
      #
      # @param subject_tx [BSV::Transaction::Transaction]
      # @raise [InvalidBeefError] if outputs exceed inputs
      def validate_fee_adequacy!(subject_tx)
        sourced = subject_tx.inputs.select(&:source_transaction)
        return if sourced.empty?

        input_sats = sourced.sum do |input|
          input.source_transaction.outputs[input.prev_tx_out_index]&.satoshis || 0
        end
        output_sats = subject_tx.outputs.sum(&:satoshis)
        return if input_sats > output_sats

        raise BSV::Wallet::InvalidBeefError,
              "inadequate fee: inputs #{input_sats} must exceed outputs #{output_sats}"
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

      def validate_reference!(reference)
        return if reference.is_a?(String) && reference.match?(UUID_RE)

        raise BSV::Wallet::InvalidParameterError, 'reference'
      end

      def require_key_deriver!
        raise BSV::Wallet::Error.new('wallet has no key deriver configured', 2) unless @key_deriver
      end

      def enforce_limp_mode!
        return if @bypass_limp_mode
        return unless limp_mode?

        raise BSV::Wallet::LimpModeError.new(
          balance: @utxo_pool.balance, threshold: @limp_threshold
        )
      end

      def enforce_headroom!(spending)
        projected = @utxo_pool.balance - spending
        return unless projected < @limp_threshold

        raise BSV::Wallet::LimpModeError.new(
          balance: projected, threshold: @limp_threshold
        )
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

      # Orchestrate the auto-fund flow for createAction when inputs is nil.
      #
      # Selects UTXOs, locks them (Phase 1), builds and signs a funded
      # transaction with SDK fee computation and change distribution,
      # then writes change outputs atomically with signing (Phase 2b).
      #
      # @return [Hash] same shape as create_action's return value
      def auto_fund_action(description:, outputs:, lock_time:, version:,
                           broadcast:, labels:, randomize_outputs:,
                           no_send:, send_with:, return_txid_only:)
        # Estimate satoshis needed (outputs + conservative fee margin).
        # Assumes 1 input for the estimate — if the pool returns multiple
        # UTXOs, each extra input adds ~15 sats of fee but contributes its
        # own satoshis (always >> 15), so the estimate is safe. The SDK
        # computes the real fee from actual tx size regardless.
        output_total = outputs.sum { |o| o[:satoshis] || 0 }
        estimated_change_count = @utxo_pool.change_output_count
        estimated_size = 10 + 148 + ((outputs.length + estimated_change_count) * 34)
        fee_margin = (estimated_size / 1000.0 * 100).ceil

        # Headroom guard: ensure post-tx balance stays above limp threshold
        enforce_headroom!(output_total + fee_margin)

        candidates = @utxo_pool.select(satoshis: output_total + fee_margin)

        # Phase 1: Lock inputs (reversible via CASCADE)
        input_specs = candidates.each_with_index.map do |c, idx|
          { output_id: c[:id], vin: idx }
        end
        action_result = @store.create_action(
          action: {
            description: description, broadcast: broadcast,
            nlocktime: lock_time || 0, version: version, outgoing: true
          },
          inputs: input_specs
        )
        attach_labels(action_result[:id], labels)

        # Phase 2: Build funded transaction (in memory). If this raises,
        # the action + input rows from Phase 1 remain locked until the
        # reaper cleans them up via CASCADE delete.
        wtxid, raw_tx, vout_mapping, change_outputs = build_funded_transaction(
          action_id: action_result[:id], caller_outputs: outputs,
          lock_time: lock_time, version: version, randomize: randomize_outputs,
          change_count: estimated_change_count
        )

        # Phase 2b: Atomic sign + change output creation
        @store.sign_action(
          action_id: action_result[:id], wtxid: wtxid, raw_tx: raw_tx,
          change_outputs: change_outputs
        )
        BSV.logger&.debug do
          "[Engine] auto_fund_action: dtxid=#{wtxid.reverse.unpack1('H*')} " \
            "outputs=#{outputs.length} change=#{change_outputs.length}"
        end

        atomic_beef = build_atomic_beef(raw_tx, action_result[:id])

        # No-send path: promote all outputs, return change outpoints
        if no_send
          promote_with_outputs(action_result[:id], outputs, vout_mapping)
          @store.promote_change_to_spendable(action_id: action_result[:id])
          change = query_change_outpoints(action_result[:id])
          result = { txid: wtxid, tx: atomic_beef, no_send_change: change }
          result[:send_with_results] = process_send_with(send_with) if send_with&.any?
          return result
        end

        # Phase 3: Broadcast
        broadcast_result = @broadcast_queue.submit(
          action_id: action_result[:id],
          raw_tx: raw_tx,
          immediate: broadcast == :inline
        )

        # Phase 4: Promote all outputs (change output rows written in Phase 2b,
        # but spendable rows deferred until now)
        if broadcast == :inline && accepted?(broadcast_result)
          promote_with_outputs(action_result[:id], outputs, vout_mapping)
          @store.promote_change_to_spendable(action_id: action_result[:id])
          handle_proof_from_broadcast(action_result[:id], broadcast_result)
        end

        result = { txid: wtxid, tx: return_txid_only ? nil : atomic_beef }
        result[:send_with_results] = process_send_with(send_with) if send_with&.any?
        result
      end

      # Build a funded transaction with SDK fee computation and change.
      #
      # Separate from build_transaction to avoid touching the existing
      # caller-provided-inputs path. Derives a BRC-42 change key, builds
      # the transaction with all outputs (caller + change), computes the
      # fee via the SDK, and signs.
      #
      # Ordering constraint:
      #   build → attach templates → tx.fee → shuffle → sign
      #   Templates before fee (estimated_size needs them).
      #   Fee before shuffle (Benford remainder targets @outputs.last).
      #   Shuffle before sign (sighash commits to final output positions).
      #
      # @return [Array(String, String, Hash, Array<Hash>)]
      #   wtxid, raw_tx, vout_mapping (caller only), change_output_specs
      def build_funded_transaction(action_id:, caller_outputs:,
                                   lock_time:, version:, randomize:,
                                   change_count:)
        # A. Resolve inputs + derive signing keys
        resolved_inputs = @store.resolve_inputs_for_signing(action_id: action_id)
        tx_inputs, signing_keys = build_inputs(resolved_inputs, nil)

        # B. Derive change output keys (BRC-42 self-payments)
        # change_count is pre-computed by caller before inputs are locked,
        # since locking removes UTXOs from the spendable set.
        change_keys = change_count.times.map do |i|
          prefix = SecureRandom.uuid
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

        # E. Compute fee + distribute change (Benford for privacy)
        fee_model = BSV::Transaction::FeeModels::SatoshisPerKilobyte.new(value: 100)
        tx.fee(fee_model, change_distribution: :random)

        # F. Detect which change outputs survived (SDK removes all if
        # insufficient change to cover them).
        surviving_change = change_tx_outputs.select { |co| tx.outputs.include?(co) }

        # G. Shuffle outputs AFTER fee — fee computation doesn't depend on
        # order, but SDK distributes change across all change-flagged outputs
        # so they must be present during tx.fee. Shuffle now for privacy
        # before signing.
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

        [tx.wtxid, tx.to_binary, vout_mapping, change_output_specs]
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

        [wtxid, raw_tx]
      end
    end
  end
end
