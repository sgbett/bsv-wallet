# frozen_string_literal: true

module BSV
  module Wallet
    module Postgres
      module Store
        # Bridges the BroadcastQueue with the SDK's ARC protocol.
        #
        # @example
        #   provider = BSV::Network::Providers::GorillaPool.mainnet
        #   adapter = ArcAdapter.new(provider)
        #   broadcast_queue = BroadcastQueue.new(services: services)
        class ArcAdapter
          def initialize(provider)
            @provider = provider
          end

          def call(method, *args, **kwargs)
            case method
            when :broadcast
              tx = BSV::Transaction::Transaction.from_binary(args.first)
              @provider.call(:broadcast, tx)
            when :get_tx_status
              @provider.call(:get_tx_status, **kwargs)
            else
              @provider.call(method, *args, **kwargs)
            end
          end
        end
      end
    end
  end
end
