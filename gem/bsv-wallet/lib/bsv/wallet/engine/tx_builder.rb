# frozen_string_literal: true

module BSV
  module Wallet
    class Engine
      # Transaction construction for outbound actions.
      #
      # The scribe: given a *resolved* input set (by value), caller
      # outputs, and an injected key deriver, the builder assembles
      # +TransactionInput+ / +TransactionOutput+ objects, derives
      # BRC-42 change keys, runs the fee fixpoint, optionally shuffles
      # outputs, and signs P2PKH inputs the wallet owns. See
      # +Interface::TxBuilder+ for the full contract.
      #
      # Store-free: never resolves inputs itself, never reaches back
      # for state. The build seam is one-way — done-or-shortfall is
      # returned by value; the quartermaster
      # (+FundingStrategy+ / +Action+) decides whether to top up.
      class TxBuilder
        include BSV::Wallet::Interface::TxBuilder

        # Construct a transaction builder. Explicit DI: no engine
        # back-reference. The builder calls +key_deriver+ for BRC-42
        # change derivation and P2PKH signing-key derivation, and
        # +fee_model+ to compute the required fee for the
        # change-distribution fixpoint.
        def initialize(key_deriver:, fee_model:)
          @key_deriver = key_deriver
          @fee_model = fee_model
        end

        # See +Interface::TxBuilder#build+.
        def build(resolved_inputs:, caller_outputs:, caller_inputs:,
                  lock_time:, version:, randomize:, sign:)
          tx_outputs, vout_mapping = build_outputs(caller_outputs, randomize)
          tx_inputs, signing_keys = build_inputs(resolved_inputs, caller_inputs)

          tx = BSV::Transaction::Tx.new(
            version: version || 1,
            lock_time: lock_time || 0
          )

          tx_inputs.each { |inp| tx.add_input(inp) }
          tx_outputs.each { |out| tx.add_output(out) }

          signing_keys.each { |idx, key| tx.sign(idx, key) } if sign

          {
            wtxid: tx.wtxid,
            raw_tx: tx.to_binary,
            vout_mapping: vout_mapping,
            tx: tx
          }
        end

        # See +Interface::TxBuilder#build_change+.
        #
        # Build a transaction with BRC-42 change derivation, explicit
        # fee detection, and shortfall reporting.
        #
        # Order of operations:
        #   build -> attach templates -> fee check -> distribute_change -> shuffle -> sign
        #   Templates before fee (estimated_size needs them).
        #   Fee check before distribute_change so a shortfall is reported
        #     before any change is allocated.
        #   Distribute before shuffle (Benford remainder targets @outputs.last).
        #   Shuffle before sign (sighash commits to final output positions).
        #
        # The SDK's +Transaction::Tx#fee+ does not raise on insufficient
        # inputs: +distribute_change+ silently drops all change outputs
        # when +available <= 0+. To get an explicit shortfall we call
        # +FeeModels::SatoshisPerKilobyte#compute_fee(tx)+ against the
        # templated tx and compare to +total_input_satoshis - sum(caller
        # outputs)+. Only when the surplus exceeds the required fee do
        # we delegate to +tx.fee+ for change distribution.
        def build_change(resolved_inputs:, caller_outputs:, caller_inputs:,
                         lock_time:, version:, randomize:, change_count:)
          raise ArgumentError, "change_count must be >= 1, got #{change_count}" if change_count < 1

          # A. Build inputs over the resolved set + caller overrides.
          tx_inputs, signing_keys = build_inputs(resolved_inputs, caller_inputs)

          # B. Derive change output keys (BRC-42 self-payments)
          change_keys = change_count.times.map do |i|
            prefix = BSV::Wallet.random_derivation
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
              locking_script: self.class.resolve_locking_script(out[:locking_script])
            )
          end
          change_tx_outputs = change_keys.map do |ck|
            BSV::Transaction::TransactionOutput.new(
              satoshis: 0, locking_script: ck[:script], change: true
            )
          end

          # C2. Assemble transaction — change outputs last so SDK's
          # distribute_change targets them all.
          tx = BSV::Transaction::Tx.new(
            version: version || 1, lock_time: lock_time || 0
          )
          tx_inputs.each { |inp| tx.add_input(inp) }
          caller_tx_outputs.each { |out| tx.add_output(out) }
          change_tx_outputs.each { |co| tx.add_output(co) }

          # D. Attach P2PKH templates for fee estimation
          signing_keys.each do |idx, key|
            tx.inputs[idx].unlocking_script_template = BSV::Transaction::P2PKH.new(key)
          end

          # E. Explicit fee detection. compute_fee asks the model "what
          # fee would this tx require?" without mutating the tx. Surplus
          # is the caller-side balance with change still at 0 sats. If
          # the required fee exceeds the surplus, return a shortfall
          # before distributing.
          required_fee = @fee_model.compute_fee(tx)
          surplus = tx.total_input_satoshis - caller_tx_outputs.sum(&:satoshis)
          return { shortfall: required_fee - surplus } if required_fee > surplus

          # F. Surplus covers fee — distribute remaining sats across
          # change outputs (Benford for privacy). The SDK drops change
          # outputs whose share rounds to zero, hence the
          # surviving_change filter below.
          tx.fee(@fee_model, change_distribution: :random)
          surviving_change = change_tx_outputs.select { |co| tx.outputs.include?(co) }

          # G. Shuffle outputs AFTER fee distribution — fee computation
          # doesn't depend on order, but SDK distributes change across
          # all change-flagged outputs so they must be present during
          # tx.fee.
          tx.outputs.shuffle! if randomize && tx.outputs.length > 1

          # H. Compute final vout positions (post-shuffle)
          vout_mapping = {}
          caller_tx_outputs.each_with_index do |co, orig_idx|
            vout_mapping[orig_idx] = tx.outputs.index(co)
          end

          # I. Sign (AFTER fee and shuffle — sighash commits to final
          # output values+positions)
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

          {
            wtxid: tx.wtxid,
            raw_tx: tx.to_binary,
            tx: tx,
            vout_mapping: vout_mapping,
            change_outputs: change_output_specs
          }
        end

        # See +Interface::TxBuilder#apply_spends+.
        #
        # The finalise-and-sign core of the deferred-signing path: walks
        # the resolved inputs, attaches source data via +InputSource+,
        # applies caller-provided unlocking scripts from +spends+, and
        # signs any remaining wallet-owned P2PKH inputs. The transaction
        # builder signs.
        #
        # Validation that +spends+' vins actually exist in the
        # transaction is the caller's responsibility (Action#apply_spends
        # validates and then delegates here).
        def apply_spends(tx:, resolved_inputs:, spends:)
          signing_keys = {}

          resolved_inputs.each_with_index do |resolved, idx|
            input = tx.inputs[idx]
            InputSource.attach!(input, resolved)

            spend = spends[resolved[:vin]] || spends[idx]
            if spend
              input.sequence = spend[:sequence_number] if spend[:sequence_number]
              input.unlocking_script = resolve_unlocking_script(spend[:unlocking_script]) if spend[:unlocking_script]
            elsif input.source_locking_script&.p2pkh?
              # No spend provided for this P2PKH input — wallet signs it
              require_key_deriver!
              signing_keys[idx] = derive_signing_key(resolved)
            end

            # Validate: each input must end up either with a caller spend
            # or a wallet signing key.
            next if spend&.dig(:unlocking_script)
            next if signing_keys.key?(idx)

            raise BSV::Wallet::Error,
                  "input at vin #{resolved[:vin]} has no unlocking script in spends " \
                  'and is not a P2PKH input the wallet can sign'
          end

          # Sign wallet-owned P2PKH inputs
          signing_keys.each { |idx, key| tx.sign(idx, key) }

          [tx.wtxid, tx.to_binary, tx]
        end

        # Resolve a locking script value to a Script object.
        #
        # Binary strings (ASCII-8BIT / non-hex) are wrapped via
        # +from_binary+. Hex strings are decoded via +from_hex+.
        def self.resolve_locking_script(script_data)
          if script_data.encoding == Encoding::ASCII_8BIT || !script_data.match?(/\A[0-9a-fA-F]*\z/)
            BSV::Script::Script.from_binary(script_data)
          else
            BSV::Script::Script.from_hex(script_data)
          end
        end

        private

        # Build +TransactionOutput+ objects from caller output specs.
        #
        # When +randomize+ is true, the output order is shuffled and a
        # mapping from original index to new vout position is returned.
        def build_outputs(outputs, randomize)
          return [[], {}] if outputs.nil? || outputs.empty?

          tx_outputs = outputs.map do |out|
            script = self.class.resolve_locking_script(out[:locking_script])
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

        # Build +TransactionInput+ objects from resolved input data.
        #
        # For each resolved input (from +Store#resolve_inputs_for_signing+):
        # - Creates a +TransactionInput+ with the source outpoint
        # - Sets +source_satoshis+ / +source_locking_script+ for sighash
        # - For P2PKH inputs: derives the signing key via +key_deriver+
        # - For custom scripts: uses the caller-provided +unlocking_script+
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
            InputSource.attach!(input, resolved)
            locking_script = input.source_locking_script

            # Find the caller's input spec for this vin (for custom unlocking scripts)
            caller_input = find_caller_input(caller_inputs, resolved[:vin])

            if caller_input&.dig(:unlocking_script)
              input.unlocking_script = resolve_unlocking_script(caller_input[:unlocking_script])
            elsif locking_script&.p2pkh?
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

        # Resolve an unlocking script value to a Script object.
        def resolve_unlocking_script(script_data)
          if script_data.encoding == Encoding::ASCII_8BIT || !script_data.match?(/\A[0-9a-fA-F]*\z/)
            BSV::Script::Script.from_binary(script_data)
          else
            BSV::Script::Script.from_hex(script_data)
          end
        end

        # Find the caller's input spec matching a given vin.
        def find_caller_input(caller_inputs, vin)
          return unless caller_inputs

          caller_inputs.each_with_index do |inp, idx|
            return inp if (inp[:vin] || idx) == vin
          end
          nil
        end

        # Derive a private key for signing a P2PKH input.
        #
        # When +derivation_prefix+ is nil, the output was paid directly
        # to the identity (root) key — return it without BRC-42/43
        # derivation. Otherwise map the resolved input's derivation
        # parameters to KeyDeriver's protocol_id / key_id / counterparty
        # format.
        def derive_signing_key(resolved)
          if resolved[:derivation_prefix].nil?
            BSV.logger&.debug { '[Engine::TxBuilder] derive_signing_key: root key (no derivation)' }
            return @key_deriver.root_private_key
          end

          BSV.logger&.debug { "[Engine::TxBuilder] derive_signing_key: derived prefix=#{resolved[:derivation_prefix]}" }
          counterparty = resolved[:sender_identity_key] || 'self'

          @key_deriver.derive_private_key(
            protocol_id: [2, resolved[:derivation_prefix]],
            key_id: resolved[:derivation_suffix],
            counterparty: counterparty
          )
        end

        # Guard: the builder needs a key_deriver to derive change keys
        # and to sign P2PKH inputs. The deferred path may not have one
        # (caller signs everything themselves), so guard at the call
        # site rather than rejecting construction without a deriver.
        def require_key_deriver!
          raise BSV::Wallet::Error.new('wallet has no key deriver configured', code: 2) unless @key_deriver
        end
      end
    end
  end
end
