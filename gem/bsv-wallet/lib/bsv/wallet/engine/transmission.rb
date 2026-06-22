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
        # Two-phase invariant (HLR #385): this method does NOT write
        # +transmission_txids+ — recording wtxids the peer has not yet
        # acknowledged would over-trim a future BEEF into unverifiability.
        # The known-set is written only on ack
        # (+Store#mark_transmission_acked+), populated by #388 once the
        # BeefParty trim path lands.
        #
        # Return shape carries everything #388 (trim) and #390 (deliver)
        # need without re-querying:
        #   - +transmission_id+ — canonical state reference (the row),
        #     mirroring +Engine::Broadcast+'s return-the-row idiom; lets
        #     #390 thread the same id into +mark_transmission_acked+.
        #   - +beef+ — wire-format Atomic BEEF binary; in v1 this is the
        #     full untrimmed BEEF, replaced by +trim_for_peer!+ output
        #     once #388 lands.
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
        # @return [Hash] +{ transmission_id:, beef:, outputs:, sender_identity_key: }+
        # @raise [BSV::Wallet::InvalidParameterError] counterparty shape
        # @raise [BSV::Wallet::Error] action missing or unsigned
        def transmit(counterparty:, action_id:, outputs:, sender_identity_key:)
          validate_counterparty!(counterparty)

          action = @store.find_action(id: action_id)
          raise BSV::Wallet::Error, "action not found: action_id=#{action_id}" unless action
          unless action[:raw_tx]
            raise BSV::Wallet::Error,
                  "action not signed: action_id=#{action_id} has no raw_tx; transmit requires a signed Transaction::Tx"
          end

          # Hydrator owns BEEF assembly (deep wire_ancestor walk → atomic
          # serialisation). Re-uses the shared cache, so a recently
          # created or proven ancestor is served from memory, not the
          # proof store. #389 will follow this with +validate_for_handoff!+
          # (egress SPV-honesty contract) and #388 with +trim_for_peer!+
          # (BeefParty per-counterparty trim).
          atomic_beef = @hydrator.build_atomic_beef(action[:raw_tx], action_id)

          # Two-phase: parent row only here. +transmission_txids+ writes
          # land in +Store#mark_transmission_acked+ when the peer
          # confirms receipt (#388 / #390).
          transmission_id = @store.record_transmission(
            action_id: action_id, counterparty: counterparty
          )

          {
            transmission_id: transmission_id,
            beef: atomic_beef,
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
