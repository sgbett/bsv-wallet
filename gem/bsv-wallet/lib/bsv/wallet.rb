# frozen_string_literal: true

module BSV
  # Wallet interface for transaction creation, signing, encryption, decryption,
  # certificate management, and identity verification per the BRC standards.
  #
  # All methods return hashes. Nested structures (inputs, outputs, certificates)
  # are arrays of hashes — documented inline with @option tags where the shape
  # is non-obvious.
  module Wallet
    autoload :VERSION, 'bsv/wallet/version'

    # BRC-100 interface and error classes come from bsv-sdk.
    # Reopen Interface to add wallet-specific contracts (Store, UTXOPool, etc.).
    require_relative 'wallet/interface'

    # Wallet-specific errors (InsufficientFundsError, PoolDepletedError, etc.).
    # BRC-100 contract errors (Error, InvalidParameterError, etc.) come from bsv-sdk.
    require_relative 'wallet/errors'

    # Key derivation (BRC-42/43)
    autoload :KeyDeriver, 'bsv/wallet/key_deriver'

    # Entity network interaction contracts
    require_relative 'wallet/pushable'
    require_relative 'wallet/fetchable'

    # Network services (porcelain routing layer over SDK providers)
    require_relative 'network/services'

    # Background polling loop
    autoload :Daemon, 'bsv/wallet/daemon'

    # Engine (Layer 3 — orchestration)
    autoload :Engine, 'bsv/wallet/engine'
  end
end
