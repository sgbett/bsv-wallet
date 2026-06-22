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
        # @param counterparty [String] BRC-43 identity pubkey hex
        #   (66-char compressed, 02|03 prefix). Engine-boundary
        #   validation rejects sentinels and malformed hex via
        #   +KeyDeriver.validate_counterparty_hex!+.
        # @param action_id [Integer]
        # @param outputs [Array<Hash>] BRC-29 derivation metadata —
        #   +{ vout:, satoshis:, derivation_prefix:, derivation_suffix: }+
        #   entries the peer's +internalize_action+ consumes to recover
        #   each output's locking key.
        # @param sender_identity_key [String] this wallet's identity key
        #   hex; the BRC-29 envelope's +sender_identity_key+.
        # @return [Hash] +{ transmission_id:, beef:, sent_wtxids:, outputs:, sender_identity_key: }+
        # @raise [BSV::Wallet::InvalidParameterError] counterparty shape
        # @raise [BSV::Wallet::Error] action missing or unsigned, or
        #   subject-protection invariant violated by the trim
        def transmit(counterparty:, action_id:, outputs:, sender_identity_key:)
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
          # on the parsed object. #389 will follow this with
          # +validate_for_handoff!+ (egress SPV-honesty contract).
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

          # Two-phase: parent row only here. +transmission_txids+ writes
          # land in +Store#mark_transmission_acked+ when the peer
          # confirms receipt (#390).
          transmission_id = @store.record_transmission(
            action_id: action_id, counterparty: counterparty
          )

          {
            transmission_id: transmission_id,
            beef: trimmed_beef_binary,
            sent_wtxids: sent_wtxids,
            outputs: outputs,
            sender_identity_key: sender_identity_key
          }
        end

        private

        # Engine-boundary validation. Rejects:
        #   - the +'self'+ / +'anyone'+ derivation sentinels (BRC-43
        #     allows them as +KeyDeriver+ counterparty inputs, but they
        #     are not addressable peers — transmission targets must be
        #     concrete identity keys).
        #   - non-hex, wrong-length, or wrong-prefix strings
        #     (via +KeyDeriver.validate_counterparty_hex!+).
        #
        # Curve-point validity (is this a point on the curve?) is
        # deferred to the +PublicKey.from_hex+ parse on the consumer
        # side; the regex check here covers syntactic shape, which is
        # what the AC's "before any DB write" gate requires for the
        # transmission row.
        #
        # The existing +KeyDeriver+ helper accepts uncompressed (04)
        # prefixes per BRC-43. Transmission v1 leaves that lenient —
        # BRC-29 / BRC-43 identity keys in this codebase are
        # compressed-prefix (02|03) by every existing producer, and a
        # later tightening can layer on without changing this surface.
        def validate_counterparty!(counterparty)
          if %w[self anyone].include?(counterparty)
            raise BSV::Wallet::InvalidParameterError.new(
              'counterparty',
              'a peer identity key hex (the "self" / "anyone" derivation ' \
              'sentinels are not addressable transmission targets)'
            )
          end

          KeyDeriver.validate_counterparty_hex!(counterparty)
        end
      end
    end
  end
end
