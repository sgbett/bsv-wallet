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

        def initialize(store:)
          @store = store
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
          Output.spendable.sum(:satoshis) || 0
        end
      end
    end
  end
end
