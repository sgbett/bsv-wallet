# frozen_string_literal: true

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

      def initialize(store:, utxo_pool:, broadcast_queue:, proof_store:,
                     key_deriver: nil, network: :mainnet)
        @store = store
        @utxo_pool = utxo_pool
        @broadcast_queue = broadcast_queue
        @proof_store = proof_store
        @key_deriver = key_deriver
        @network_name = network
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

        broadcast = determine_broadcast(no_send, accept_delayed_broadcast)

        # Phase 1: Lock
        input_specs = build_input_specs(inputs)
        action_result = @store.create_action(
          action: {
            description: description, broadcast: broadcast,
            nlocktime: lock_time || 0, version: version,
            input_beef: input_beef, outgoing: true,
            satoshis: total_satoshis(outputs)
          },
          inputs: input_specs
        )
        raise BSV::Wallet::InsufficientFundsError.new if action_result.nil?

        attach_labels(action_result[:id], labels)

        # Check for deferred signing
        deferred = !sign_and_process ||
                   inputs&.any? { |i| i[:unlocking_script_length] && !i[:unlocking_script] }

        if deferred
          return {
            signable_transaction: {
              tx: nil,
              reference: action_result[:reference]
            }
          }
        end

        # Phase 2: Sign
        txid, raw_tx = build_transaction(inputs, outputs, lock_time, version, randomize_outputs)
        @store.sign_action(action_id: action_result[:id], txid: txid, raw_tx: raw_tx)

        # No-send path: promote immediately, return change outpoints
        if no_send
          promote_with_outputs(action_result[:id], outputs)
          change = query_change_outpoints(action_result[:id])
          result = { txid: txid, tx: raw_tx, no_send_change: change }
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
          promote_with_outputs(action_result[:id], outputs)
          handle_proof_from_broadcast(action_result[:id], broadcast_result)
        end

        result = { txid: txid, tx: return_txid_only ? nil : raw_tx }
        result[:send_with_results] = process_send_with(send_with) if send_with&.any?
        result
      end

      def sign_action(spends:, reference:, accept_delayed_broadcast: true,
                      return_txid_only: false, no_send: false, send_with: nil,
                      originator: nil)
        action = @store.find_action(reference: reference)
        raise BSV::Wallet::InvalidParameterError.new('reference') unless action

        txid, raw_tx = apply_spends(action, spends)
        @store.sign_action(action_id: action[:id], txid: txid, raw_tx: raw_tx)

        broadcast = determine_broadcast(no_send, accept_delayed_broadcast)

        unless broadcast == :none
          broadcast_result = @broadcast_queue.submit(
            action_id: action[:id],
            raw_tx: raw_tx,
            immediate: broadcast == :inline
          )

          if broadcast == :inline && accepted?(broadcast_result)
            handle_proof_from_broadcast(action[:id], broadcast_result)
          end
        end

        result = { txid: txid, tx: return_txid_only ? nil : raw_tx }
        result[:send_with_results] = process_send_with(send_with) if send_with&.any?
        result
      end

      def abort_action(reference:, originator: nil)
        action = @store.find_action(reference: reference)
        raise BSV::Wallet::InvalidParameterError.new('reference') unless action

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
                             seek_permission: true, originator: nil)
        validate_description!(description)

        # Create action (incoming, no broadcast, already completed)
        action_result = @store.create_action(
          action: { description: description, broadcast: :none, outgoing: false }
        )

        attach_labels(action_result[:id], labels)

        # Process outputs by protocol
        output_specs = outputs.map { |out| resolve_internalize_output(out) }
        @store.promote_action(action_id: action_result[:id], outputs: output_specs)

        # TODO: Extract and save proof from BEEF data
        # TODO: Link proof to action

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

      # --- Public Key Management (codes 8-10) ---

      def public_key(identity_key: false, protocol_id: nil, key_id: nil,
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

      def height(originator: nil)
        raise BSV::Wallet::UnsupportedActionError, 'height'
      end

      def header_for_height(height:, originator: nil)
        raise BSV::Wallet::UnsupportedActionError, 'header_for_height'
      end

      def network(originator: nil)
        { network: @network_name }
      end

      def version(originator: nil)
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

      def total_satoshis(outputs)
        return 0 unless outputs

        outputs.sum { |o| o[:satoshis] || 0 }
      end

      def attach_labels(action_id, labels)
        return unless labels&.any?

        label_ids = @store.find_or_create_labels(names: labels)
        @store.label_action(action_id: action_id, label_ids: label_ids)
      end

      def promote_with_outputs(action_id, outputs)
        return unless outputs&.any?

        output_specs = outputs.each_with_index.map do |out, idx|
          {
            satoshis: out[:satoshis],
            vout: out[:vout] || idx,
            locking_script: out[:locking_script],
            basket: out[:basket],
            tags: out[:tags],
            description: out[:output_description],
            custom_instructions: out[:custom_instructions],
            change: out[:change]
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

        proof_id = @proof_store.save_proof(
          txid: broadcast_result[:txid] || @store.find_action(id: action_id)&.dig(:txid),
          proof: {
            height: broadcast_result[:block_height],
            block_hash: broadcast_result[:block_hash],
            merkle_path: broadcast_result[:merkle_path]
          }
        )
        @store.link_proof(action_id: action_id, tx_proof_id: proof_id) if proof_id
      end

      def process_send_with(send_with)
        return unless send_with

        send_with.filter_map do |sw_txid|
          sw_action = @store.find_action(txid: sw_txid)
          next unless sw_action

          br = @broadcast_queue.submit(
            action_id: sw_action[:id],
            raw_tx: sw_action[:raw_tx] || ''.b,
            immediate: true
          )
          status = br[:tx_status]&.downcase&.tr('_', ' ')&.to_sym || :sending
          { txid: sw_txid, status: status }
        end
      end

      def query_change_outpoints(_action_id)
        # Query outputs marked as change for this action
        # Returns outpoint strings for no_send_change
        []
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
        end

        spec
      end

      def require_key_deriver!
        raise BSV::Wallet::Error.new('wallet has no key deriver configured', 2) unless @key_deriver
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
          input = BSV::Transaction::TransactionInput.new(
            prev_tx_id: resolved[:source_txid],
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
      # Maps the resolved input's derivation parameters to KeyDeriver's
      # protocol_id/key_id/counterparty format:
      # - protocol_id: [2, derivation_prefix]
      # - key_id: derivation_suffix
      # - counterparty: sender_identity_key, or 'self' for self-payments
      #
      # @param resolved [Hash] a single resolved input hash
      # @return [BSV::Primitives::PrivateKey]
      def derive_signing_key(resolved)
        counterparty = resolved[:sender_identity_key] || 'self'

        @key_deriver.derive_private_key(
          protocol_id: [2, resolved[:derivation_prefix]],
          key_id: resolved[:derivation_suffix],
          counterparty: counterparty
        )
      end

      # Placeholder — SDK transaction construction
      def build_transaction(_inputs, _outputs, _lock_time, _version, _randomize)
        # In production: construct and sign via SDK
        # For now: generate a dummy txid
        txid = SecureRandom.random_bytes(32)
        raw_tx = SecureRandom.random_bytes(100)
        [txid, raw_tx]
      end

      # Placeholder — SDK signing for deferred (HLR #5)
      def apply_spends(_action, _spends)
        txid = SecureRandom.random_bytes(32)
        raw_tx = SecureRandom.random_bytes(100)
        [txid, raw_tx]
      end
    end
  end
end
