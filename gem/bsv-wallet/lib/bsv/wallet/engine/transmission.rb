# frozen_string_literal: true

using BSV::Wallet::Txid

module BSV
  module Wallet
    class Engine
      # Wallet-to-peer BEEF delivery domain — sibling to +Engine::Broadcast+
      # and +Engine::TxProof+ over the shared +Engine::Hydrator+ substrate.
      # Tracked by HLR #385; design recorded in ADR-025 and
      # +docs/reference/transactions.md+.
      #
      # Background-worker sibling shape: no +Interface::Transmission+
      # module (only shape-extracted services consumed cross-sibling, e.g.
      # +Hydrator+ and +BeefInternalizer+, carry interface modules). This
      # matches +Broadcast+ and +TxProof+.
      #
      # Domain distinction: broadcast ships Extended Format to the miner
      # network (anonymous, fungible) for consensus validation; transmit
      # ships Atomic BEEF to a named peer for SPV. The recipient's *job*
      # fixes the wire shape, not its knowledge — peer-knowledge is the
      # orthogonal trimming axis, which waits for the receiver's agreement
      # (#552) and is never mirrored into broadcast. Per-counterparty
      # state is the deciding difference and lives here, never in
      # +Broadcast+.
      #
      # Transmit intent is an invocation mode, not a property of
      # +#transmit+. v1 ships +inline+ (the caller awaits a self-contained
      # +#transmit+) and +none+ (no +endpoint:+; the caller delivers the
      # returned BEEF). A daemon-driven +delayed+ transmit is not built
      # (#385 Phase 2); it would run over the same code path, as
      # +broadcast_intent+ +inline+ and +delayed+ do (ADR-024 / #183
      # inline-equals-delayed robustness).
      class Transmission
        # BRC-43 canonical counterparty hex: compressed pubkey (02|03
        # prefix), lowercase. Mirrors the Postgres CHECK on the
        # transmissions table in +db/migrations/001_create_schema.rb+ so the engine
        # boundary rejects the same shapes the schema rejects — closes
        # the H1 correctness drift where uppercase hex passed the
        # engine then died as +Sequel::CheckConstraintViolation+ at
        # DB write time.
        BRC43_COMPRESSED_LOWERCASE = /\A0[23][0-9a-f]{64}\z/

        # Explicit DI — no engine back-reference. Mirrors sibling shape
        # (+Broadcast+, +TxProof+, +Hydrator+, +BeefInternalizer+).
        #
        # @param store     [BSV::Wallet::Store]
        # @param hydrator  [BSV::Wallet::Engine::Hydrator] shared-substrate
        #   owner of +#build_atomic_beef+ (the BEEF the peer receives).
        # @param delivery  [#deliver, nil] Phase-2 transport seam, wired
        #   in #390 (caller-supplied-endpoint synchronous HTTP delivery
        #   via +Network::PeerDelivery+). Nil-tolerant in unit-spec
        #   contexts and in this skeleton task; left here so #390's wiring
        #   slots in by constructor arg, not class shape change.
        def initialize(store:, hydrator:, delivery: nil)
          @store = store
          @hydrator = hydrator
          @delivery = delivery
        end

        attr_reader :delivery

        # Construct the wire payload for a peer BEEF delivery and record
        # the transmission row at grain (action × counterparty).
        #
        # Order: validate counterparty at the engine boundary (curve-point
        # shape, no +'self'+/+'anyone'+ sentinels) BEFORE any DB write or
        # BEEF construction. A typo'd hex must never produce a phantom
        # +transmissions+ row.
        #
        # The peer gets every ancestor in full, including ones our records
        # say it already holds (#551). A txid-only entry resolves only at
        # a receiver that has agreed to trust its own store for it, and
        # none does by default: this wallet's receive path without
        # +trust_self: 'known'+ and wallet-toolbox's +internalizeAction+
        # both reject one. Per-peer trimming waits for that agreement
        # (#552).
        #
        # Egress SPV-honesty contract (HLR #385 Task 4 / #389). BEFORE
        # +record_transmission+, the bytes that ship go through
        # +Hydrator#validate_for_handoff!+ strictly — a full bundle has
        # no txid-only entry to excuse. A failure raises
        # +EgressBeefInvalidError+, which propagates unchanged; no
        # transmission row is written.
        #
        # Two-phase invariant (HLR #385): this method does NOT write
        # +transmission_txids+. The returned +sent_wtxids+ is what the
        # ACK handler (#390) will pass to +mark_transmission_acked+ once
        # the peer confirms receipt — recording wtxids the peer has not
        # yet acknowledged would let a future trimmed BEEF (#552) leave
        # out what the peer lacks.
        #
        # Return shape carries everything #390 (deliver) needs without
        # re-querying:
        #   - +transmission_id+ — canonical state reference (the row),
        #     mirroring +Engine::Broadcast+'s return-the-row idiom; lets
        #     #390 thread the same id into +mark_transmission_acked+.
        #   - +beef+ — the Atomic BEEF binary exactly as built and
        #     validated.
        #   - +sent_wtxids+ — every wtxid in that BEEF: what the peer
        #     receives and can keep. #390's ACK handler passes these to
        #     +mark_transmission_acked+.
        #   - +outputs+ — BRC-29 derivation metadata for the peer's
        #     +internalize_action+; passed through unchanged to #390's
        #     envelope (without it, the peer has BEEF bytes but cannot
        #     recover the locking key).
        #   - +sender_identity_key+ — BRC-29 sender identity; same
        #     passthrough role in #390's envelope.
        #
        # Phase-1 delivery (#390). When an +endpoint:+ is supplied,
        # the BEEF is POSTed via +@delivery+ AFTER the row is
        # written. ACK success drives +mark_transmission_acked+ — the
        # two-phase boundary stays intact: +transmission_txids+ are
        # only ever written on confirmed delivery, so a future BEEF
        # can never over-trim against a stale knowledge claim. When
        # +endpoint:+ is nil (transmit intent +none+), the row is
        # recorded and the caller decides how and when to deliver.
        #
        # @param counterparty [String] BRC-43 identity pubkey hex
        #   (66-char compressed, +02+/+03+ prefix, **lowercase**).
        #   Validated at the engine boundary by
        #   +Transmission#validate_counterparty!+ — the BRC-43 canonical
        #   form (+\A0[23][0-9a-f]{64}\z+) which mirrors the Postgres
        #   CHECK in +001_create_schema.rb+ exactly. Rejects +self+/+anyone+
        #   derivation sentinels, uppercase/mixed-case hex, and any
        #   non-BRC-43 shape before any DB write.
        # @param action_id [Integer]
        # @param outputs [Array<Hash>] BRC-29 derivation metadata —
        #   +{ vout:, satoshis:, derivation_prefix:, derivation_suffix: }+
        #   entries the peer's +internalize_action+ consumes to recover
        #   each output's locking key.
        # @param sender_identity_key [String] this wallet's identity key
        #   hex; the BRC-29 envelope's +sender_identity_key+.
        # @param endpoint [String, nil] absolute HTTPS URI of the peer's
        #   delivery endpoint. When supplied, +@delivery+ POSTs the
        #   BEEF and a successful ACK fires
        #   +Store#mark_transmission_acked+. When nil, the caller takes
        #   responsibility for delivery and ACK-recording.
        # @return [Hash] +{ transmission_id:, beef:, sent_wtxids:,
        #   outputs:, sender_identity_key:, delivery: }+ — +delivery+ is
        #   the +PeerDelivery::Result+ when an endpoint was supplied,
        #   +nil+ otherwise.
        # @raise [BSV::Wallet::InvalidParameterError] counterparty shape
        # @raise [BSV::Wallet::Error] action missing or unsigned
        # @raise [BSV::Wallet::EgressBeefInvalidError] the built BEEF fails
        #   the egress check
        def transmit(counterparty:, action_id:, outputs:, sender_identity_key:, endpoint: nil)
          validate_counterparty!(counterparty)

          action = @store.find_action(id: action_id)
          raise BSV::Wallet::Error, "action not found: action_id=#{action_id}" unless action
          unless action[:raw_tx]
            raise BSV::Wallet::Error,
                  "action not signed: action_id=#{action_id} has no raw_tx; transmit requires a signed Transaction::Tx"
          end

          beef_binary = @hydrator.build_atomic_beef(action[:raw_tx], action_id)
          beef = BSV::Transaction::Beef.from_binary(beef_binary)
          subject_wtxid = beef.subject_wtxid || BSV::Transaction::Tx.from_binary(action[:raw_tx]).wtxid

          @hydrator.validate_for_handoff!(beef_binary, subject_wtxid)

          sent_wtxids = beef.transactions.map(&:wtxid)

          # Two-phase: parent row only here. +transmission_txids+ writes
          # land in +Store#mark_transmission_acked+ when the peer
          # confirms receipt (#390).
          transmission_id = @store.record_transmission(
            action_id: action_id, counterparty: counterparty
          )

          # #390: when an endpoint is supplied and a delivery transport
          # is wired, POST the BEEF and validate the ACK. The known-set
          # (+transmission_txids+) is recorded only on a delivered ACK
          # (wtxid-bound) — never on transport failure or
          # 200-without-wtxid, both of which would claim the peer holds
          # wtxids it never received, and #552's trimming would act on
          # that claim.
          delivery_result = deliver_envelope(
            endpoint: endpoint,
            counterparty: counterparty,
            outputs: outputs,
            sender_identity_key: sender_identity_key,
            beef_binary: beef_binary,
            subject_wtxid: subject_wtxid
          )

          if delivery_result&.delivered?
            @store.mark_transmission_acked(
              action_id: action_id, counterparty: counterparty, wtxids: sent_wtxids
            )
          end

          {
            transmission_id: transmission_id,
            beef: beef_binary,
            sent_wtxids: sent_wtxids,
            outputs: outputs,
            sender_identity_key: sender_identity_key,
            delivery: delivery_result
          }
        end

        private

        # Build the Phase-1 wire envelope and hand it to +@delivery+.
        # Returns the +PeerDelivery::Result+, or nil when no endpoint
        # was supplied (transmit intent +none+) or no delivery
        # transport was wired (unit-spec contexts). The envelope shape
        # is the BRC-29-aligned superset of the +bin/create+ →
        # +bin/receive+ stdin/stdout JSON: +beef+ (binary; the
        # +PeerDelivery+ hex-encodes for wire), +outputs+, and
        # +sender_identity_key+, plus an explicit +protocol_version: 1+
        # so Phase-2 additions (signed ACK, certificates, etc.) can be
        # negotiated.
        def deliver_envelope(endpoint:, counterparty:, outputs:, sender_identity_key:,
                             beef_binary:, subject_wtxid:)
          return nil if endpoint.nil?
          return nil unless @delivery

          envelope = {
            beef: beef_binary,
            outputs: outputs,
            sender_identity_key: sender_identity_key,
            protocol_version: 1
          }
          result = @delivery.deliver(
            endpoint: endpoint, envelope: envelope, subject_wtxid: subject_wtxid
          )
          BSV.logger&.debug do
            "[Engine::Transmission] deliver counterparty=#{counterparty[0, 8]}… " \
              "subject=#{subject_wtxid.to_dtxid[0, 8]}… outcome=#{result.outcome}"
          end
          result
        end

        # Engine-boundary validation. Rejects:
        #   - the +'self'+ / +'anyone'+ derivation sentinels (BRC-43
        #     allows them as +KeyDeriver+ counterparty inputs, but they
        #     are not addressable peers — transmission targets must be
        #     concrete identity keys).
        #   - anything other than a lowercase-hex compressed pubkey
        #     (66 chars, +02|03+ prefix). Tighter than
        #     +KeyDeriver.validate_counterparty_hex!+ — that helper
        #     tolerates mixed-case hex, which is fine for +KeyDeriver+
        #     (its callers use the hex to derive a key) but wrong for
        #     the transmission boundary: the Postgres CHECK in
        #     +001_create_schema.rb+ is
        #     +^0[23][0-9a-f]{64}$+, so an uppercase counterparty
        #     passed the engine and then died as
        #     +Sequel::CheckConstraintViolation+ at write time. The
        #     fix mirrors the schema here so the engine boundary
        #     rejects exactly what the DB would reject — same shape
        #     on Postgres + SQLite (SQLite's CHECK is length +
        #     prefix only; the engine is the canonical validator on
        #     that backend).
        #
        # Curve-point validity (is this a point on the curve?) is
        # deferred to the +PublicKey.from_hex+ parse on the consumer
        # side; the regex check here covers syntactic shape, which is
        # what the AC's "before any DB write" gate requires for the
        # transmission row.
        def validate_counterparty!(counterparty)
          if %w[self anyone].include?(counterparty)
            raise BSV::Wallet::InvalidParameterError.new(
              'counterparty',
              'a peer identity key hex (the "self" / "anyone" derivation ' \
              'sentinels are not addressable transmission targets)'
            )
          end

          return if counterparty.is_a?(String) && counterparty.match?(BRC43_COMPRESSED_LOWERCASE)

          raise BSV::Wallet::InvalidParameterError.new(
            'counterparty',
            'lowercase-hex compressed pubkey (02|03 prefix + 64 hex chars; ' \
            'matches the Postgres CHECK in db/migrations/001_create_schema.rb)'
          )
        end
      end
    end
  end
end
