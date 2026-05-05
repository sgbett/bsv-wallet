# frozen_string_literal: true

module BSV
  # Wallet interface for transaction creation, signing, encryption, decryption,
  # certificate management, and identity verification per the BRC standards.
  #
  # Include this module and override the methods. Verify conformance with the
  # shared RSpec examples.
  #
  # All methods return hashes. Nested structures (inputs, outputs, certificates)
  # are arrays of hashes — documented inline with @option tags where the shape
  # is non-obvious.
  module Wallet

    autoload :VERSION,          'bsv/wallet/version'

    # Interfaces (abstract contracts)
    autoload :Interface,        'bsv/wallet/interface'

    # Engine (Layer 3 — orchestration)
    autoload :Engine,           'bsv/wallet/engine'

    # Errors — single file, all classes flat under BSV::Wallet
    require_relative 'wallet/error'

  end
end
