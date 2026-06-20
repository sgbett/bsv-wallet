# frozen_string_literal: true

module BSV
  module Wallet
    # The 28 BRC-100 spec methods, sliced out of Engine as a mixin facade
    # (#364, Phase 7 of the #291 "Monolith to Manageable" roadmap; relocated
    # to a sibling of Engine in #400, Stage 1 of #396 "Manageable to
    # Machined" — the namespace destination Stage 3 will promote to a
    # composition over the Engine primitive surface ratified in #397).
    #
    # At Stage 1 this remains a *slice of Engine*, not an island — it is
    # +include+d into Engine and runs with +self+ as the engine instance.
    # The methods reach back to engine ivars (+@store+, +@key_deriver+,
    # +@beef_importer+, +@utxo_pool+, +@network_name+) and Engine privates
    # (+validate_*+, +require_key_deriver!+, +secure_compare+) unchanged.
    #
    # Method-resolution order: by +include+-ing +Interface::BRC100+ here
    # and +BSV::Wallet::BRC100+ on the Engine class, ancestry resolves as
    # +Engine → BRC100 → Interface::BRC100+ so impls always beat
    # the SDK contract's +NotImplementedError+ stubs.
    module BRC100
      include BSV::Wallet::Interface::BRC100

      # --- Transaction Operations (codes 1-7) ---

      # Create a BRC-100 action (Phases 1, 2, optionally 3, optionally 4).
      #
      # Composes the funding primitives:
      #   1. Phase 1a creates an empty action row (inputs: []) — option (a)
      #      seam, so initial and top-up locks share one retried path.
      #   2. Phase 1b acquires inputs via Engine::FundingStrategy:
      #      - inputs: nil  → selects to cover sum(outputs); fixpoint loop
      #        tops up on shortfall (#213 bounded retry on contention).
      #      - inputs: [...] → locked as-is once; shortfall raises
      #        InsufficientFundsError immediately (no top-up).
      #      generate_change is invoked through a one-way build seam
      #      and returns the finished {wtxid, raw_tx, vout_mapping,
      #      change_outputs, tx} on convergence.
      #      Pool depletion or contention-retry exhaustion ⇒
      #      InsufficientFundsError; the empty action row is aborted.
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

        # +originator+, +return_txid_only+, +trust_self+ stay at BRC100
        # per ADR-026 decisions 5/7 — BRC-100 vocabulary that doesn't
        # propagate into Engine. +return_txid_only+ is applied at wrap
        # time below.
        result = do_build_action(
          description: description, input_beef: input_beef,
          inputs: inputs, outputs: outputs,
          lock_time: lock_time, version: version, labels: labels,
          sign_and_process: sign_and_process,
          accept_delayed_broadcast: accept_delayed_broadcast,
          no_send: no_send, change_count: change_count,
          randomize_outputs: randomize_outputs
        )

        # Wallet vocab → BRC-100 vocab. Engine returns one of three shapes
        # (sync / no_send / deferred); each maps to a distinct BRC-100
        # createAction return.
        if result[:signable]
          { signable_transaction: { tx: result[:signable][:atomic_beef],
                                    reference: result[:signable][:reference] } }
        elsif result.key?(:change_outpoints)
          { txid: result[:wtxid], tx: result[:atomic_beef],
            no_send_change: result[:change_outpoints] }
        else
          { txid: result[:wtxid], tx: return_txid_only ? nil : result[:atomic_beef] }
        end
      end

      def sign_action(spends:, reference:, accept_delayed_broadcast: true,
                      return_txid_only: false, no_send: false,
                      originator: nil)
        validate_reference!(reference)
        result = do_sign_action(
          reference: reference, spends: spends,
          accept_delayed_broadcast: accept_delayed_broadcast, no_send: no_send
        )
        { txid: result[:wtxid], tx: return_txid_only ? nil : result[:atomic_beef] }
      end

      def abort_action(reference:, originator: nil)
        validate_reference!(reference)
        do_abort_action(reference: reference)
      end

      def list_actions(**params)
        do_list_actions(**params)
      end

      def internalize_action(tx:, outputs:, description:, labels: nil,
                             trust_self: nil, known_txids: nil,
                             seek_permission: true, originator: nil)
        validate_description!(description)
        # known_txids is the BRC-100 spec param name; values are wire-order wtxids
        known_txids&.each { |w| BSV::Primitives::Hex.validate_wtxid!(w, name: 'known_txids entry') }

        do_import_beef(
          tx: tx, outputs: outputs, description: description,
          labels: labels, trust_self: trust_self, known_txids: known_txids,
          seek_permission: seek_permission
        )
      end

      def list_outputs(basket:, tags: nil, tag_query_mode: :any, include: nil,
                       include_custom_instructions: false, include_tags: false,
                       include_labels: false, limit: 10, offset: 0,
                       seek_permission: true, originator: nil)
        result = do_list_outputs(
          basket: basket, tags: tags, tag_query_mode: tag_query_mode,
          include: include,
          include_custom_instructions: include_custom_instructions,
          include_tags: include_tags, include_labels: include_labels,
          limit: limit, offset: offset, seek_permission: seek_permission
        )
        { total_outputs: result[:total], outputs: result[:outputs] }
      end

      def relinquish_output(basket:, output:, originator: nil)
        do_relinquish_output(output_id: output)
        { relinquished: true }
      end

      # --- Public Key Management (codes 8-10) ---

      def get_public_key(identity_key: false, protocol_id: nil, key_id: nil,
                         privileged: false, privileged_reason: nil,
                         counterparty: nil, for_self: false,
                         seek_permission: true, originator: nil)
        pub = do_get_public_key(
          identity_key: identity_key, protocol_id: protocol_id, key_id: key_id,
          counterparty: counterparty, for_self: for_self, privileged: privileged
        )
        { public_key: pub }
      end

      def reveal_counterparty_key_linkage(counterparty:, verifier:,
                                          privileged: false, privileged_reason: nil,
                                          originator: nil)
        do_reveal_counterparty_key_linkage(
          counterparty: counterparty, verifier: verifier, privileged: privileged
        )
      end

      def reveal_specific_key_linkage(counterparty:, verifier:, protocol_id:, key_id:,
                                      privileged: false, privileged_reason: nil,
                                      originator: nil)
        do_reveal_specific_key_linkage(
          counterparty: counterparty, verifier: verifier,
          protocol_id: protocol_id, key_id: key_id, privileged: privileged
        )
      end

      # --- Cryptography Operations (codes 11-16) ---

      def encrypt(plaintext:, protocol_id:, key_id:,
                  privileged: false, privileged_reason: nil,
                  counterparty: nil, seek_permission: true, originator: nil)
        ciphertext = do_encrypt(
          plaintext: plaintext, protocol_id: protocol_id, key_id: key_id,
          counterparty: counterparty || 'self', privileged: privileged
        )
        { ciphertext: ciphertext }
      end

      def decrypt(ciphertext:, protocol_id:, key_id:,
                  privileged: false, privileged_reason: nil,
                  counterparty: nil, seek_permission: true, originator: nil)
        plaintext = do_decrypt(
          ciphertext: ciphertext, protocol_id: protocol_id, key_id: key_id,
          counterparty: counterparty || 'self', privileged: privileged
        )
        { plaintext: plaintext }
      end

      def create_hmac(data:, protocol_id:, key_id:,
                      privileged: false, privileged_reason: nil,
                      counterparty: nil, seek_permission: true, originator: nil)
        hmac = do_create_hmac(
          data: data, protocol_id: protocol_id, key_id: key_id,
          counterparty: counterparty || 'self', privileged: privileged
        )
        { hmac: hmac }
      end

      def verify_hmac(data:, hmac:, protocol_id:, key_id:,
                      privileged: false, privileged_reason: nil,
                      counterparty: nil, seek_permission: true, originator: nil)
        valid = do_verify_hmac(
          data: data, hmac: hmac, protocol_id: protocol_id, key_id: key_id,
          counterparty: counterparty || 'self', privileged: privileged
        )
        raise BSV::Wallet::InvalidHmacError unless valid

        { valid: true }
      end

      def create_signature(protocol_id:, key_id:, data: nil, hash_to_directly_sign: nil,
                           privileged: false, privileged_reason: nil,
                           counterparty: nil, seek_permission: true, originator: nil)
        signature = do_create_signature(
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
        valid = do_verify_signature(
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
        # Dispatch on acquisition_protocol stays at BRC100 — spec-shape
        # validation per ADR-026 decision 6.
        case acquisition_protocol
        when :direct, 'direct'
          do_acquire_certificate(
            type: type, certifier: certifier, fields: fields,
            serial_number: serial_number, revocation_outpoint: revocation_outpoint,
            signature: signature, keyring_for_subject: keyring_for_subject
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
        result = do_list_certificates(
          certifiers: certifiers, types: types, limit: limit, offset: offset
        )
        { total_certificates: result[:total], certificates: result[:certificates] }
      end

      def prove_certificate(certificate:, fields_to_reveal:, verifier:,
                            privileged: false, privileged_reason: nil, originator: nil)
        keyring = do_prove_certificate(
          certificate: certificate, fields_to_reveal: fields_to_reveal,
          verifier: verifier, privileged: privileged
        )
        { keyring_for_verifier: keyring }
      end

      def relinquish_certificate(type:, serial_number:, certifier:, originator: nil)
        do_relinquish_certificate(type: type, serial_number: serial_number, certifier: certifier)
        { relinquished: true }
      end

      def discover_by_identity_key(identity_key:, limit: 10, offset: 0,
                                   seek_permission: true, originator: nil)
        result = do_discover_by_identity_key(
          identity_key: identity_key, limit: limit, offset: offset
        )
        { total_certificates: result[:total], certificates: result[:certificates] }
      end

      def discover_by_attributes(attributes:, limit: 10, offset: 0,
                                 seek_permission: true, originator: nil)
        result = do_discover_by_attributes(
          attributes: attributes, limit: limit, offset: offset
        )
        { total_certificates: result[:total], certificates: result[:certificates] }
      end

      # --- Authentication (codes 23-24) ---

      def authenticated?(originator: nil)
        { authenticated: do_authenticated? }
      end

      def wait_for_authentication(originator: nil)
        do_wait_for_authentication
        { authenticated: true }
      end

      # --- Blockchain and Network Data (codes 25-28) ---

      def get_height(originator: nil)
        { height: do_get_height }
      end

      def get_header_for_height(height:, originator: nil)
        { header: do_get_header_for_height(height: height) }
      end

      def get_network(originator: nil)
        { network: do_get_network }
      end

      def get_version(originator: nil)
        { version: do_get_version }
      end
    end
  end
end
