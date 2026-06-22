# frozen_string_literal: true

using BSV::Wallet::Txid

module BSV
  module Wallet
    class Engine
      # Wallet-to-peer BEEF delivery domain — sibling to +Engine::Broadcast+
      # and +Engine::TxProof+ over the shared +Engine::Hydrator+ substrate.
      # Tracked by HLR #385; design recorded in ADR-025 and
      # +reference/transactions.md+.
      #
      # Background-worker sibling shape: no +Interface::Transmission+
      # module (only shape-extracted services consumed cross-sibling, e.g.
      # +Hydrator+ and +BeefImporter+, carry interface modules). This
      # matches +Broadcast+ and +TxProof+.
      #
      # Domain distinction: broadcast ships Extended Format to the miner
      # network (anonymous, fungible) for consensus validation; transmit
      # ships Atomic BEEF to a named peer for SPV. The recipient's *job*
      # fixes the wire shape, not its knowledge — peer-knowledge is the
      # orthogonal trimming axis (BeefParty, layered on top of BEEF, not
      # mirrored into broadcast). Per-counterparty state is the deciding
      # difference and lives here, never in +Broadcast+.
      #
      # Synchronicity is an invocation mode, not a property of +#transmit+.
      # v1 ships sync (an inline caller awaits a self-contained
      # +#transmit+), and the same operation must be drivable async by the
      # daemon later — single code path, mirroring +Broadcast+'s
      # +broadcast_intent+ inline/delayed split (ADR-024 / #183
      # inline-equals-delayed robustness).
      class Transmission
        # BRC-43 canonical counterparty hex: compressed pubkey (02|03
        # prefix), lowercase. Mirrors the Postgres CHECK in
        # +db/migrations/003_schema_constraints.rb+ so the engine
        # boundary rejects the same shapes the schema rejects — closes
        # the H1 correctness drift where uppercase hex passed the
        # engine then died as +Sequel::CheckConstraintViolation+ at
        # DB write time.
        BRC43_COMPRESSED_LOWERCASE = /\A0[23][0-9a-f]{64}\z/

        # Explicit DI — no engine back-reference. Mirrors sibling shape
        # (+Broadcast+, +TxProof+, +Hydrator+, +BeefImporter+).
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
        # Per-peer trimming (#388). The full atomic BEEF is built first,
        # then handed to a fresh +Transaction::BeefParty+ alongside the
        # peer's already-known wtxids — pre-fetched ONCE from the Store
        # at the top of this method, so downstream never calls back into
        # the store. Known entries are demoted to +TxidOnlyEntry+ via
        # +make_txid_only+ before +trimmed_beef_for_party+ drops them —
        # the SDK's BeefParty trim only removes +TxidOnlyEntry+ records,
        # so the demote step is what actually shrinks the wire when the
        # ancestor arrived in our bundle as a +ProvenTxEntry+. The
        # subject (this action's +wtxid+) is always retained in full
        # (guarded post-trim — see Subject-protection below).
        #
        # Fresh +BeefParty+ per call is load-bearing:
        # +BeefParty#merge_txid_only+ mutates the receiving party's state,
        # so reusing an instance across counterparties would accumulate
        # ghost TXID-only entries in the egress bundle. Each +#transmit+
        # constructs its own.
        #
        # Subject-protection (defence-in-depth, HLR #385 crypto gate).
        # The subject should never appear in the peer's known-set by
        # construction (it is the new transaction we are transmitting).
        # If it does — a poisoned +transmission_txids+ row — the demote
        # step above would turn the subject into a +TxidOnlyEntry+ and
        # the trim would drop it, shipping a BEEF the peer cannot
        # SPV-verify. The post-trim invariant catches both cases (subject
        # missing OR demoted to +TxidOnlyEntry+) and raises
        # +BSV::Wallet::Error+ BEFORE serialisation.
        #
        # Egress SPV-honesty contract (HLR #385 Task 4 / #389). Post-trim
        # and BEFORE +record_transmission+, the trimmed bytes go through
        # +Hydrator#validate_for_handoff!+ with +allow_txid_only: true+ —
        # trim deliberately produces +TxidOnlyEntry+ records (entries the
        # peer already holds), so structural verification must tolerate
        # them. A failure raises +EgressBeefInvalidError+ which propagates
        # unchanged; no transmission row is written.
        #
        # Two-phase invariant (HLR #385): this method does NOT write
        # +transmission_txids+. The returned +sent_wtxids+ is what the
        # ACK handler (#390) will pass to +mark_transmission_acked+ once
        # the peer confirms receipt — recording wtxids the peer has not
        # yet acknowledged would over-trim a future BEEF into
        # unverifiability.
        #
        # Return shape carries everything #390 (deliver) needs without
        # re-querying:
        #   - +transmission_id+ — canonical state reference (the row),
        #     mirroring +Engine::Broadcast+'s return-the-row idiom; lets
        #     #390 thread the same id into +mark_transmission_acked+.
        #   - +beef+ — wire-format trimmed Atomic BEEF binary
        #     (+to_atomic_binary(subject_wtxid)+ over the BeefParty
        #     output).
        #   - +sent_wtxids+ — the non-TxidOnly wtxids in the trimmed
        #     BEEF: what the peer actually receives + can keep. #390's
        #     ACK handler passes these to +mark_transmission_acked+.
        #   - +outputs+ — BRC-29 derivation metadata for the peer's
        #     +internalize_action+; passed through unchanged to #390's
        #     envelope (without it, the peer has BEEF bytes but cannot
        #     recover the locking key).
        #   - +sender_identity_key+ — BRC-29 sender identity; same
        #     passthrough role in #390's envelope.
        #
        # Phase-1 delivery (#390). When an +endpoint:+ is supplied,
        # the trimmed BEEF is POSTed via +@delivery+ AFTER the row is
        # written. ACK success drives +mark_transmission_acked+ — the
        # two-phase boundary stays intact: +transmission_txids+ are
        # only ever written on confirmed delivery, so a future BEEF
        # can never over-trim against a stale knowledge claim. When
        # +endpoint:+ is nil (deferred-by-caller path), the row is
        # recorded and the caller decides how/when to deliver — same
        # shape as +Engine::Broadcast+ which separates +submit+ from
        # the delayed broadcast worker.
        #
        # @param counterparty [String] BRC-43 identity pubkey hex
        #   (66-char compressed, +02+/+03+ prefix, **lowercase**).
        #   Validated at the engine boundary by
        #   +Transmission#validate_counterparty!+ — the BRC-43 canonical
        #   form (+\A0[23][0-9a-f]{64}\z+) which mirrors the Postgres
        #   CHECK in migration 003 exactly. Rejects +self+/+anyone+
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
        #   trimmed BEEF and a successful ACK fires
        #   +Store#mark_transmission_acked+. When nil, the caller takes
        #   responsibility for delivery and ACK-recording.
        # @return [Hash] +{ transmission_id:, beef:, sent_wtxids:,
        #   outputs:, sender_identity_key:, delivery: }+ — +delivery+ is
        #   the +PeerDelivery::Result+ when an endpoint was supplied,
        #   +nil+ otherwise.
        # @raise [BSV::Wallet::InvalidParameterError] counterparty shape
        # @raise [BSV::Wallet::Error] action missing or unsigned, or
        #   subject-protection invariant violated by the trim
        def transmit(counterparty:, action_id:, outputs:, sender_identity_key:, endpoint: nil)
          validate_counterparty!(counterparty)

          action = @store.find_action(id: action_id)
          raise BSV::Wallet::Error, "action not found: action_id=#{action_id}" unless action
          unless action[:raw_tx]
            raise BSV::Wallet::Error,
                  "action not signed: action_id=#{action_id} has no raw_tx; transmit requires a signed Transaction::Tx"
          end

          # Pre-fetch peer's known-set ONCE per +#transmit+ (perf/AC).
          # Downstream operates on this array; the BeefParty never calls
          # back into the store.
          known_wtxids = @store.transmission_known_wtxids(counterparty: counterparty)

          # Hydrator owns BEEF assembly (deep wire_ancestor walk → atomic
          # serialisation). Re-uses the shared cache, so a recently
          # created or proven ancestor is served from memory, not the
          # proof store. Returns Atomic BEEF binary; we round-trip it
          # through +Beef.from_binary+ so the BeefParty layer can operate
          # on the parsed object. The post-trim
          # +Hydrator#validate_for_handoff!+ call below (HLR #385 Task 4
          # / #389) enforces the egress SPV-honesty contract over the
          # peer-specific wire bytes.
          atomic_beef_binary = @hydrator.build_atomic_beef(action[:raw_tx], action_id)
          full_beef = BSV::Transaction::Beef.from_binary(atomic_beef_binary)
          subject_wtxid = full_beef.subject_wtxid || BSV::Transaction::Tx.from_binary(action[:raw_tx]).wtxid

          # Fresh BeefParty per call — see method comment. Merging from
          # the synthetic +'self'+ party records the full BEEF as our own
          # state; layering the peer's known-set in (via
          # +add_known_wtxids_for_party+) seeds the TXID-only entries the
          # trim step will then strip out for this peer.
          party = BSV::Transaction::BeefParty.new([counterparty])
          party.merge_beef_from_party('self', full_beef)

          # Demote every known wtxid (incl. ProvenTxEntry / RawTxEntry)
          # to TxidOnlyEntry before recording knowledge: SDK's
          # +trim_known_wtxids+ drops only +TxidOnlyEntry+ records, so a
          # ProvenTx that the peer already holds would otherwise stay on
          # the wire. Deliberately not skipping the subject — a poisoned
          # +transmission_txids+ row naming the subject is caught by the
          # post-trim invariant check below (defence-in-depth crypto
          # gate, HLR #385).
          known_wtxids.each { |wtxid| party.make_txid_only(wtxid) }

          party.add_known_wtxids_for_party(counterparty, known_wtxids)

          trimmed_beef = party.trimmed_beef_for_party(counterparty)

          # Defence-in-depth: a poisoned +transmission_txids+ row that
          # named the subject as known would either drop the subject
          # entirely (trim removed it) or leave it as +TxidOnlyEntry+
          # (we don't demote the subject upstream, but a future code
          # path or merge layer could). Either case ships a BEEF the
          # peer cannot SPV-verify (no raw tx for the subject).
          subject_entry = trimmed_beef.transactions.find { |bt| bt.wtxid == subject_wtxid }
          if subject_entry.nil? || subject_entry.is_a?(BSV::Transaction::Beef::TxidOnlyEntry)
            raise BSV::Wallet::Error,
                  'egress trim invariant: subject was trimmed — ' \
                  "counterparty=#{counterparty} subject=#{subject_wtxid.to_dtxid}"
          end

          # +sent_wtxids+ is what the peer actually receives + can keep:
          # non-TxidOnly entries in the trimmed BEEF. Task 5 (#390) will
          # pass these to +mark_transmission_acked+ on a successful ACK.
          sent_wtxids = trimmed_beef.transactions.grep_v(BSV::Transaction::Beef::TxidOnlyEntry).map(&:wtxid)

          trimmed_beef_binary = trimmed_beef.to_atomic_binary(subject_wtxid)

          # Egress SPV-honesty contract (HLR #385 Task 4 / #389): refuse
          # to ship a structurally invalid BEEF. +allow_txid_only: true+
          # because the trim above deliberately demoted ancestors the
          # peer already holds to +TxidOnlyEntry+. The check runs on the
          # serialised bytes so it verifies exactly what the peer
          # receives. Failure raises +EgressBeefInvalidError+; we let it
          # propagate without writing a +transmissions+ row.
          @hydrator.validate_for_handoff!(trimmed_beef_binary, subject_wtxid, allow_txid_only: true)

          # Two-phase: parent row only here. +transmission_txids+ writes
          # land in +Store#mark_transmission_acked+ when the peer
          # confirms receipt (#390).
          transmission_id = @store.record_transmission(
            action_id: action_id, counterparty: counterparty
          )

          # #390: when an endpoint is supplied and a delivery transport
          # is wired, POST the trimmed BEEF and validate the ACK. The
          # known-set (+transmission_txids+) is recorded only on a
          # delivered ACK (wtxid-bound) — never on transport failure or
          # 200-without-wtxid, both of which would over-trim the next
          # BEEF to this counterparty into unverifiability.
          delivery_result = deliver_envelope(
            endpoint: endpoint,
            counterparty: counterparty,
            outputs: outputs,
            sender_identity_key: sender_identity_key,
            trimmed_beef_binary: trimmed_beef_binary,
            subject_wtxid: subject_wtxid
          )

          if delivery_result&.delivered?
            @store.mark_transmission_acked(
              action_id: action_id, counterparty: counterparty, wtxids: sent_wtxids
            )
          end

          {
            transmission_id: transmission_id,
            beef: trimmed_beef_binary,
            sent_wtxids: sent_wtxids,
            outputs: outputs,
            sender_identity_key: sender_identity_key,
            delivery: delivery_result
          }
        end

        private

        # Build the Phase-1 wire envelope and hand it to +@delivery+.
        # Returns the +PeerDelivery::Result+, or nil when no endpoint
        # was supplied (deferred caller-driven delivery) or no delivery
        # transport was wired (unit-spec contexts). The envelope shape
        # is the BRC-29-aligned superset of the +bin/create+ →
        # +bin/receive+ stdin/stdout JSON: +beef+ (binary; the
        # +PeerDelivery+ hex-encodes for wire), +outputs+, and
        # +sender_identity_key+, plus an explicit +protocol_version: 1+
        # so Phase-2 additions (signed ACK, certificates, etc.) can be
        # negotiated.
        def deliver_envelope(endpoint:, counterparty:, outputs:, sender_identity_key:,
                             trimmed_beef_binary:, subject_wtxid:)
          return nil if endpoint.nil?
          return nil unless @delivery

          envelope = {
            beef: trimmed_beef_binary,
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
        #     also accepts uncompressed (+04+) and mixed-case hex,
        #     which is fine for +KeyDeriver+ (its callers use the
        #     hex to derive a key) but wrong for the transmission
        #     boundary: the Postgres CHECK in 003 is
        #     +^0[23][0-9a-f]{64}$+, so an uppercase or +04+-prefix
        #     counterparty passed the engine and then died as
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
            'matches the Postgres CHECK in db/migrations/003)'
          )
        end
      end
    end
  end
end
