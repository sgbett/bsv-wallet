# frozen_string_literal: true

module BSV
  module Wallet
    # Wallet-specific abstract interfaces (contracts).
    #
    # BRC100 is defined in bsv-sdk and available via the gem dependency.
    # This file reopens Interface to add the wallet's internal contracts.
    module Interface
      autoload :FundingStrategy, 'bsv/wallet/interface/funding_strategy'
      autoload :Store,           'bsv/wallet/interface/store'
      autoload :TxBuilder,       'bsv/wallet/interface/tx_builder'
      autoload :UTXOPool,        'bsv/wallet/interface/utxo_pool'
    end
  end
end
