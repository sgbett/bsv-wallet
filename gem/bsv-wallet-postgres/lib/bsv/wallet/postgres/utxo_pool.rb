# frozen_string_literal: true

module BSV
  module Wallet
    module Postgres
      # Tier 1 UTXO selection — delegates to Store#find_spendable.
      #
      # No reservation at this tier. Locking happens in Store#create_action
      # via the input row INSERT ON CONFLICT.
      class UTXOPool
        include BSV::Wallet::Interface::UTXOPool

        MAX_UTXO_COUNT    = 500
        MIN_UTXO_SATS     = 1000
        MAX_CHANGE_PER_TX = 8

        def initialize(store:, max_utxo_count: MAX_UTXO_COUNT,
                       min_utxo_sats: MIN_UTXO_SATS,
                       max_change_per_tx: MAX_CHANGE_PER_TX)
          raise ArgumentError, 'min_utxo_sats must be positive' unless min_utxo_sats.positive?
          raise ArgumentError, 'max_change_per_tx must be >= 1' unless max_change_per_tx >= 1

          @store = store
          @max_utxo_count    = max_utxo_count
          @min_utxo_sats     = min_utxo_sats
          @max_change_per_tx = max_change_per_tx
        end

        def select(satoshis:, exclude: [])
          candidates = @store.find_spendable(satoshis: satoshis, exclude: exclude)
          total = candidates.sum { |c| c[:satoshis] }
          raise BSV::Wallet::PoolDepletedError, 'default' if total < satoshis

          candidates
        end

        def release(outputs:)
          # No-op for tier 1 — CASCADE handles it
        end

        def balance
          (Output.spendable.sum(:satoshis) || 0).to_i
        end

        def spendable_count
          Output.spendable.count
        end

        def change_output_count
          target = [@max_utxo_count, balance / @min_utxo_sats].min
          deficit = target - spendable_count
          deficit.clamp(1, @max_change_per_tx)
        end
      end
    end
  end
end
