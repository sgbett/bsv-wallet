# frozen_string_literal: true

module BSV
  module Wallet
    # The 28 BRC-100 spec methods, composed over an Engine instance.
    #
    # Lifecycle of this class:
    # - #364, Phase 7 of #291 "Monolith to Manageable" — sliced out of
    #   Engine as a +module+ included into Engine (mixin facade).
    # - #400, Stage 1 of #396 "Manageable to Machined" — relocated to a
    #   sibling of Engine at +BSV::Wallet::BRC100+.
    # - #402, Stage 2 — thinned to a uniform "validate → primitive → wrap"
    #   shape over Engine's +do_*+ surface (still a mixin).
    # - #405, Stage 3 (this) — promoted from +module+ to +class+ composed
    #   over an Engine instance via +initialize(engine)+. Engine no
    #   longer includes BRC100 in its ancestry; +Engine#brc100+ returns
    #   a memoised wrapper. The +do_+ prefix Stage 2 scaffolded onto
    #   Engine's primitives is dropped in commit 4 of this stage.
    #
    # Construction: +BSV::Wallet::BRC100.new(engine)+ — or, idiomatically,
    # via the +Engine#brc100+ memoised accessor.
    #
    # Responsibility split per ADR-026:
    # - Spec-shape validation (decision 6) lives here — the +validate_*+
    #   private methods at the bottom of the file. Engine primitives
    #   trust their input shape.
    # - BRC-100 vocabulary translation (decision 5) lives here — each
    #   method takes wallet vocab from the Engine primitive and wraps in
    #   the BRC-100 hash shape the spec mandates.
    # - +originator:+ (decision 7) is accepted at this layer for BRC-100
    #   spec compliance but never propagates into Engine.
    #
    # Method-resolution: +include+s the SDK contract +Interface::BRC100+,
    # so any of the 28 method names a concrete instance doesn't override
    # falls through to the contract's +NotImplementedError+ stub.
    class BRC100
      include BSV::Wallet::Interface::BRC100

      attr_reader :engine

      def initialize(engine)
        @engine = engine
      end

      # --- Transaction Operations (codes 1-7) ---

      # Create a BRC-100 action (Phases 1, 2, optionally 3, optionally 4).
      #
      # Composes the funding primitives:
      #   1. Phase 1a creates an empty action row (inputs: []) — the
      #      initial-and-top-up locks share one retried path off this seam.
      #   2. Phase 1b acquires inputs via Engine::FundingStrategy:
      #      - inputs: nil  → selects to cover sum(outputs); fixpoint loop
      #        tops up on shortfall (#213 bounded retry on contention).
      #      - inputs: [...] → locked as-is once; shortfall raises
      #        InsufficientFundsError immediately (no top-up).
      #      TxBuilder#build_change is invoked through a one-way build
      #      seam and returns the finished {wtxid, raw_tx, vout_mapping,
      #      change_outputs, tx} on convergence.
      #      Pool depletion or contention-retry exhaustion ⇒
      #      InsufficientFundsError; the empty action row is aborted.
      #   3. Phase 3 / 4 follow the broadcast intent (send path versus
      #      internal path); see docs/concepts/action-lifecycle.md.
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
        result = @engine.build_action(
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
        result = @engine.sign_action(
          reference: reference, spends: spends,
          accept_delayed_broadcast: accept_delayed_broadcast, no_send: no_send
        )
        { txid: result[:wtxid], tx: return_txid_only ? nil : result[:atomic_beef] }
      end

      def abort_action(reference:, originator: nil)
        validate_reference!(reference)
        @engine.abort_action(reference: reference)
      end

      def list_actions(labels:, label_query_mode: :any,
                       include_labels: false, include_inputs: false,
                       include_input_source_locking_scripts: false,
                       include_input_unlocking_scripts: false,
                       include_outputs: false, include_output_locking_scripts: false,
                       limit: 10, offset: 0, seek_permission: true,
                       originator: nil)
        result = @engine.list_actions(
          labels: labels, label_query_mode: label_query_mode,
          include_labels: include_labels, include_inputs: include_inputs,
          include_input_source_locking_scripts: include_input_source_locking_scripts,
          include_input_unlocking_scripts: include_input_unlocking_scripts,
          include_outputs: include_outputs,
          include_output_locking_scripts: include_output_locking_scripts,
          limit: limit, offset: offset, seek_permission: seek_permission
        )
        { total_actions: result[:total], actions: result[:actions] }
      end

      def internalize_action(tx:, outputs:, description:, labels: nil,
                             trust_self: nil, known_txids: nil,
                             seek_permission: true, originator: nil)
        validate_description!(description)
        # known_txids is the BRC-100 spec param name; values are wire-order wtxids
        known_txids&.each { |w| BSV::Primitives::Hex.validate_wtxid!(w, name: 'known_txids entry') }

        @engine.import_beef(
          tx: tx, outputs: outputs, description: description,
          labels: labels, trust_self: trust_self, known_txids: known_txids,
          seek_permission: seek_permission
        )
      end

      def list_outputs(basket:, tags: nil, tag_query_mode: :any, include: nil,
                       include_custom_instructions: false, include_tags: false,
                       include_labels: false, limit: 10, offset: 0,
                       seek_permission: true, originator: nil)
        result = @engine.list_outputs(
          basket: basket, tags: tags, tag_query_mode: tag_query_mode,
          include: include,
          include_custom_instructions: include_custom_instructions,
          include_tags: include_tags, include_labels: include_labels,
          limit: limit, offset: offset, seek_permission: seek_permission
        )
        { total_outputs: result[:total], outputs: result[:outputs] }
      end

      def relinquish_output(basket:, output:, originator: nil)
        @engine.relinquish_output(output_id: output)
        { relinquished: true }
      end

      # --- Public Key Management (codes 8-10) ---

      def get_public_key(identity_key: false, protocol_id: nil, key_id: nil,
                         privileged: false, privileged_reason: nil,
                         counterparty: nil, for_self: false,
                         seek_permission: true, originator: nil)
        pub = @engine.get_public_key(
          identity_key: identity_key, protocol_id: protocol_id, key_id: key_id,
          counterparty: counterparty, for_self: for_self, privileged: privileged
        )
        { public_key: pub }
      end

      def reveal_counterparty_key_linkage(counterparty:, verifier:,
                                          privileged: false, privileged_reason: nil,
                                          originator: nil)
        @engine.reveal_counterparty_key_linkage(
          counterparty: counterparty, verifier: verifier, privileged: privileged
        )
      end

      def reveal_specific_key_linkage(counterparty:, verifier:, protocol_id:, key_id:,
                                      privileged: false, privileged_reason: nil,
                                      originator: nil)
        @engine.reveal_specific_key_linkage(
          counterparty: counterparty, verifier: verifier,
          protocol_id: protocol_id, key_id: key_id, privileged: privileged
        )
      end

      # --- Cryptography Operations (codes 11-16) ---

      def encrypt(plaintext:, protocol_id:, key_id:,
                  privileged: false, privileged_reason: nil,
                  counterparty: nil, seek_permission: true, originator: nil)
        ciphertext = @engine.encrypt(
          plaintext: plaintext, protocol_id: protocol_id, key_id: key_id,
          counterparty: counterparty || 'self', privileged: privileged
        )
        { ciphertext: ciphertext }
      end

      def decrypt(ciphertext:, protocol_id:, key_id:,
                  privileged: false, privileged_reason: nil,
                  counterparty: nil, seek_permission: true, originator: nil)
        plaintext = @engine.decrypt(
          ciphertext: ciphertext, protocol_id: protocol_id, key_id: key_id,
          counterparty: counterparty || 'self', privileged: privileged
        )
        { plaintext: plaintext }
      end

      def create_hmac(data:, protocol_id:, key_id:,
                      privileged: false, privileged_reason: nil,
                      counterparty: nil, seek_permission: true, originator: nil)
        hmac = @engine.create_hmac(
          data: data, protocol_id: protocol_id, key_id: key_id,
          counterparty: counterparty || 'self', privileged: privileged
        )
        { hmac: hmac }
      end

      def verify_hmac(data:, hmac:, protocol_id:, key_id:,
                      privileged: false, privileged_reason: nil,
                      counterparty: nil, seek_permission: true, originator: nil)
        valid = @engine.verify_hmac(
          data: data, hmac: hmac, protocol_id: protocol_id, key_id: key_id,
          counterparty: counterparty || 'self', privileged: privileged
        )
        raise BSV::Wallet::InvalidHmacError unless valid

        { valid: true }
      end

      def create_signature(protocol_id:, key_id:, data: nil, hash_to_directly_sign: nil,
                           privileged: false, privileged_reason: nil,
                           counterparty: nil, seek_permission: true, originator: nil)
        signature = @engine.create_signature(
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
        valid = @engine.verify_signature(
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
          @engine.acquire_certificate(
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
        result = @engine.list_certificates(
          certifiers: certifiers, types: types, limit: limit, offset: offset
        )
        { total_certificates: result[:total], certificates: result[:certificates] }
      end

      def prove_certificate(certificate:, fields_to_reveal:, verifier:,
                            privileged: false, privileged_reason: nil, originator: nil)
        keyring = @engine.prove_certificate(
          certificate: certificate, fields_to_reveal: fields_to_reveal,
          verifier: verifier, privileged: privileged
        )
        { keyring_for_verifier: keyring }
      end

      def relinquish_certificate(type:, serial_number:, certifier:, originator: nil)
        @engine.relinquish_certificate(type: type, serial_number: serial_number, certifier: certifier)
        { relinquished: true }
      end

      def discover_by_identity_key(identity_key:, limit: 10, offset: 0,
                                   seek_permission: true, originator: nil)
        result = @engine.discover_by_identity_key(
          identity_key: identity_key, limit: limit, offset: offset
        )
        { total_certificates: result[:total], certificates: result[:certificates] }
      end

      def discover_by_attributes(attributes:, limit: 10, offset: 0,
                                 seek_permission: true, originator: nil)
        result = @engine.discover_by_attributes(
          attributes: attributes, limit: limit, offset: offset
        )
        { total_certificates: result[:total], certificates: result[:certificates] }
      end

      # --- Authentication (codes 23-24) ---

      def authenticated?(originator: nil)
        { authenticated: @engine.authenticated? }
      end

      def wait_for_authentication(originator: nil)
        @engine.wait_for_authentication
        { authenticated: true }
      end

      # --- Blockchain and Network Data (codes 25-28) ---

      def get_height(originator: nil)
        { height: @engine.get_height }
      end

      def get_header_for_height(height:, originator: nil)
        { header: @engine.get_header_for_height(height: height) }
      end

      def get_network(originator: nil)
        { network: @engine.get_network }
      end

      def get_version(originator: nil)
        { version: @engine.get_version }
      end

      private

      # ---- BRC-100 spec-shape validators ---------------------------------
      #
      # Moved from Engine to BRC100 in #405 Stage 3 commit 3, per ADR-026
      # decision 6: spec-shape validation is the wrap layer's job, not
      # the primitive's. Non-BRC100 callers of Engine primitives are
      # responsible for their own input validation.

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
        return unless outputs && @engine.key_deriver

        root_hash = nil
        outputs.each_with_index do |out, idx|
          next unless out[:output_type] == 'root'

          script = BSV::Wallet::Engine::TxBuilder.resolve_locking_script(out[:locking_script])
          unless script.p2pkh?
            raise BSV::Wallet::InvalidParameterError.new(
              "outputs[#{idx}].output_type",
              "'root' requires a P2PKH script"
            )
          end

          root_hash ||= BSV::Primitives::Digest.hash160(@engine.key_deriver.identity_key_bytes)
          pubkey_hash = script.chunks[2].data
          next if pubkey_hash == root_hash

          raise BSV::Wallet::InvalidParameterError.new(
            "outputs[#{idx}].output_type",
            "'root' but script does not match identity key"
          )
        end
      end

      def validate_reference!(reference)
        return if reference.is_a?(String) && reference.match?(BSV::Wallet::Engine::UUID_RE)

        raise BSV::Wallet::InvalidParameterError, 'reference'
      end
    end
  end
end
