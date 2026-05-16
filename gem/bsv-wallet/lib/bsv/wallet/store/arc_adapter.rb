# frozen_string_literal: true

module BSV
  module Wallet
    module Store
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
