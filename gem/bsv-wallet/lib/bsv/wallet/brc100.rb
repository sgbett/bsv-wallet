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

      # Basket-name validation constants (HLR #428).
      #
      # BRC-100 §"Rules for Basket Names" carries an internal inconsistency:
      # the prose says 400, but the TS type +BasketStringUnder300Characters+
      # used on every basket-bearing field says 300. We adopt 300 — the TS
      # type is what conformant callers validate their inputs against. See
      # +docs/reference/brc100-conformance.md+ "Basket length limit — note a
      # spec inconsistency" for the recorded reasoning; an upstream
      # tracker against +bitcoin-sv/BRCs+ surfaces our position.
      #
      # Charset is byte-level ASCII to reject Unicode lookalikes (e.g.
      # Cyrillic +а+ U+0430 sneaking into +'аdmin foo'+) on the charset
      # rule rather than letting them slip through the reserved-name rule.
      BASKET_NAME_MIN = 5
      BASKET_NAME_MAX = 300
      BASKET_NAME_CHARSET_RE = /\A[a-z0-9 ]+\z/

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
      #
      # Per-output +spendable_intent+ translation (HLR #467 /
      # +docs/reference/intent-and-outcomes.md+, +docs/reference/core-vs-conformance.md+):
      # Engine requires every output spec to state +:spendable_intent+
      # explicitly; this conformance wrapper bridges from the BRC-100 vocabulary
      # by accepting an optional +:spendable+ flag per output (the spec's Int8
      # representation, +false+ / +true+ / absent) and defaulting absent
      # entries to +'spendable'+. The BRC-100 spec assumes self-owned outputs
      # under +createAction+ — the default reflects that assumption. Callers
      # that need to declare an outbound output (recipient-owned, never joins
      # the wallet UTXO set) set +spendable: false+ and the wrapper translates
      # to +spendable_intent: 'none'+. The default is at the conformance layer
      # only; the engine surface itself still demands explicit intent so no
      # inference re-enters the data path.
      def create_action(description:, input_beef: nil, inputs: nil, outputs: nil,
                        lock_time: nil, version: nil, labels: nil,
                        sign_and_process: true, accept_delayed_broadcast: true,
                        trust_self: nil, return_txid_only: false,
                        no_send: false, change_count: nil,
                        randomize_outputs: true, originator: nil)
        validate_description!(description)
        validate_create_action_params!(inputs: inputs, outputs: outputs)
        outputs = normalize_and_validate_outputs_baskets(outputs)
        outputs = translate_outputs_spendable_intent(outputs)

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
        # +seek_permission:+ accepted as part of the BRC-100 contract
        # but not forwarded — it is conformance vocabulary that does not
        # propagate into Engine (ADR-026 decision 7).
        result = @engine.list_actions(
          labels: labels, label_query_mode: label_query_mode,
          include_labels: include_labels, include_inputs: include_inputs,
          include_input_source_locking_scripts: include_input_source_locking_scripts,
          include_input_unlocking_scripts: include_input_unlocking_scripts,
          include_outputs: include_outputs,
          include_output_locking_scripts: include_output_locking_scripts,
          limit: limit, offset: offset
        )
        { total_actions: result[:total], actions: result[:actions] }
      end

      def internalize_action(tx:, outputs:, description:, labels: nil,
                             trust_self: nil, known_txids: nil,
                             seek_permission: true, originator: nil)
        validate_description!(description)
        # known_txids is the BRC-100 spec param name; values are wire-order wtxids
        known_txids&.each { |w| BSV::Primitives::Hex.validate_wtxid!(w, name: 'known_txids entry') }
        outputs = normalize_and_validate_internalize_baskets(outputs)

        # +seek_permission:+ accepted as part of the BRC-100 contract
        # but not forwarded — conformance vocabulary stops here
        # (ADR-026 decision 7).
        @engine.import_beef(
          tx: tx, outputs: outputs, description: description,
          labels: labels, trust_self: trust_self, known_txids: known_txids
        )
      end

      def list_outputs(basket:, tags: nil, tag_query_mode: :any, include: nil,
                       include_custom_instructions: false, include_tags: false,
                       include_labels: false, limit: 10, offset: 0,
                       seek_permission: true, originator: nil)
        # HLR #434 — intentional divergence from the strict BRC-100
        # contract: accept +basket: nil+ as a "show me the wallet's
        # unbasketed pool (including change)" affordance. The spec
        # requires +basket+ and forbids the literal +'default'+, leaving
        # spec-conformant callers with no way to see change. The
        # affordance is invisible to TypeScript-conformant callers (the
        # TS type +BasketStringUnder300Characters+ is non-nullable;
        # +null+ fails at type-check before reaching the wallet), so the
        # divergence affects only Ruby-side callers. Documented in
        # +docs/reference/brc100-conformance.md+. **Remove when BRC-100
        # settles change-pool visibility upstream.**
        unless basket.nil?
          # HLR #428 — normalise (trim + lowercase) then validate against
          # the 8 BRC-100 basket-name rules. The +unless basket.nil?+ gate
          # preserves the HLR #434 affordance above; on the +nil+ branch
          # we pass +nil+ straight through to Engine.
          basket = normalize_basket_name(basket)
          validate_basket_name!(basket)
        end

        # +seek_permission:+ and +originator:+ accepted as part of the
        # BRC-100 contract but not forwarded — conformance vocabulary
        # stops here (ADR-026 decision 7), matching the pattern on
        # +#list_actions+ and +#internalize_action+.
        result = @engine.spendable_outputs(
          basket: basket, tags: tags, tag_query_mode: tag_query_mode,
          include: include,
          include_custom_instructions: include_custom_instructions,
          include_tags: include_tags, include_labels: include_labels,
          limit: limit, offset: offset
        )
        { total_outputs: result[:total], outputs: result[:outputs] }
      end

      def relinquish_output(basket:, output:, originator: nil)
        # HLR #428 — basket required on this entry. Normalise (trim +
        # lowercase) then run the 8-rule check. The validated, frozen
        # string is not forwarded to Engine (relinquish is keyed by
        # +output_id+) but enforcing the rules here keeps the wrapper's
        # contract symmetric with the other three basket-accepting
        # entries: a caller cannot pass a malformed basket name to any
        # of the four wrappers and have it slip through.
        basket = normalize_basket_name(basket)
        validate_basket_name!(basket)
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

      def validate_reference!(reference)
        return if reference.is_a?(String) && reference.match?(BSV::Wallet::Engine::UUID_RE)

        raise BSV::Wallet::InvalidParameterError, 'reference'
      end

      # Map +createAction+ +outputs+ to the same shape with each entry's
      # +:basket+ normalised and validated. Absent +:basket+ is fine
      # (per-output basket is optional on +createAction+); when present,
      # the 8 rules fire — including whitespace-only, which trims to
      # empty and trips the length rule (malformed, not silently treated
      # as absent). The normalised string replaces the caller's original
      # — Engine never sees the unfrozen, unvalidated input.
      def normalize_and_validate_outputs_baskets(outputs)
        return outputs if outputs.nil?

        outputs.map do |out|
          next out unless out.is_a?(Hash) && out.key?(:basket)

          normalised = normalize_basket_name(out[:basket])
          validate_basket_name!(normalised)
          out.merge(basket: normalised)
        end
      end

      # Translate the BRC-100 +:spendable+ Int8 flag (per output) into the
      # engine's required +:spendable_intent+ enum. Per HLR #467 /
      # +docs/reference/intent-and-outcomes.md+, every output spec that
      # crosses into Engine must state intent explicitly; this wrapper
      # carries the responsibility for BRC-100 callers, which the spec
      # allows to omit the field.
      #
      # Translation table:
      #
      #   :spendable absent  → :spendable_intent 'spendable' (spec assumes
      #                       self-owned outputs under createAction)
      #   :spendable == true → :spendable_intent 'spendable'
      #   :spendable == false → :spendable_intent 'none' (outbound — the
      #                       recipient's output, never joins the wallet
      #                       UTXO set)
      #
      # If a caller passes +:spendable_intent+ directly (engine-vocab —
      # e.g. internal porcelain bypassing this wrapper) we honour it as-is
      # and ignore +:spendable+; this keeps the wrapper idempotent and
      # avoids overriding a deliberate engine-vocab caller. Non-Hash
      # entries pass through unchanged (validators downstream will reject
      # them).
      def translate_outputs_spendable_intent(outputs)
        return outputs if outputs.nil?

        outputs.map do |out|
          next out unless out.is_a?(Hash)
          next out if out.key?(:spendable_intent)

          intent = out.key?(:spendable) && out[:spendable] == false ? 'none' : 'spendable'
          out.merge(spendable_intent: intent)
        end
      end

      # Map +internalizeAction+ +outputs+ to the same shape with each
      # entry's basket-insertion +:insertionRemittance[:basket]+ normalised
      # and validated. Only fires on the +:basket_insertion+ /
      # +'basket insertion'+ branch — the +:wallet_payment+ branch carries
      # +:paymentRemittance+ (no basket) and must not be touched.
      def normalize_and_validate_internalize_baskets(outputs)
        return outputs if outputs.nil?

        outputs.map do |out|
          next out unless out.is_a?(Hash)
          next out unless [:basket_insertion, 'basket insertion'].include?(out[:protocol])

          rem = out[:insertion_remittance]
          next out unless rem.is_a?(Hash) && rem.key?(:basket)

          normalised = normalize_basket_name(rem[:basket])
          validate_basket_name!(normalised)
          out.merge(insertion_remittance: rem.merge(basket: normalised))
        end
      end

      # Trim + lowercase per BRC-100 §"Logical Validation Procedures"
      # ("Current interoperable SDK validation trims and lowercases these
      # identifiers before enforcing length limits"). Returns the frozen,
      # normalised string. +nil+ passes through unchanged — the HLR #434
      # +basket: nil+ affordance on +#list_outputs+ depends on this.
      #
      # No silent +to_s+ coercion: a non-String, non-nil input is a
      # caller-side bug (or an attempted bypass surface) and is rejected
      # with a clear BRC-100 parameter error before any further work.
      # The frozen return value is what +validate_basket_name!+ checks
      # and what the wrapper forwards to Engine — kills the TOCTOU class
      # between validate and write.
      def normalize_basket_name(name)
        return if name.nil?
        raise BSV::Wallet::InvalidParameterError.new('basket', 'a string') unless name.is_a?(String)

        name.strip.downcase.freeze
      end

      # Enforce BRC-100 §"Rules for Basket Names" (the +admin+ reservation
      # is BRC-100, not BRC-99 — the latter only specifies +'p '+). Each
      # rule fires its own +InvalidParameterError+ with a distinct
      # +must be+ expectation, so callers (and humans staring at a stack
      # trace) can tell which rule tripped.
      #
      # Rules in stable order — the first failure aborts. The order is
      # deliberate: type → length → charset (cheap pre-checks that pin
      # down the byte shape before any pattern matching) → structural
      # (no double space, suffix) → reserved-name. This mirrors the SQL
      # CHECK ordering proposed for sub-issue #441 so application-layer
      # and DB-layer errors point at the same diagnosis on each input.
      #
      # The +admin+ reservation is load-bearing for ADR-029 (DBAP-style
      # permission tokens in +admin basket-access+/etc. baskets). Letting
      # +admin foo+ through today would create a migration cost when DBAP
      # lands.
      def validate_basket_name!(name)
        raise BSV::Wallet::InvalidParameterError.new('basket', 'a string') unless name.is_a?(String)

        unless name.length.between?(BASKET_NAME_MIN, BASKET_NAME_MAX)
          raise BSV::Wallet::InvalidParameterError.new('basket', basket_length_expectation)
        end

        unless name.match?(BASKET_NAME_CHARSET_RE)
          raise BSV::Wallet::InvalidParameterError.new('basket', 'composed of lowercase ASCII letters, digits, and spaces')
        end

        raise BSV::Wallet::InvalidParameterError.new('basket', 'free of consecutive spaces') if name.include?('  ')
        raise BSV::Wallet::InvalidParameterError.new('basket', 'not ending with " basket"') if name.end_with?(' basket')
        raise BSV::Wallet::InvalidParameterError.new('basket', 'not starting with "admin" (reserved)') if name.start_with?('admin')
        raise BSV::Wallet::InvalidParameterError.new('basket', 'not the reserved name "default"') if name == 'default'
        raise BSV::Wallet::InvalidParameterError.new('basket', 'not starting with "p " (reserved)') if name.start_with?('p ')
      end

      def basket_length_expectation
        "a string between #{BASKET_NAME_MIN} and #{BASKET_NAME_MAX} characters"
      end
    end
  end
end
