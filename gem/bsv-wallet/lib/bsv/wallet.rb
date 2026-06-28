# frozen_string_literal: true

require 'securerandom'

module BSV
  # Wallet interface for transaction creation, signing, encryption, decryption,
  # certificate management, and identity verification per the BRC standards.
  #
  # All methods return hashes. Nested structures (inputs, outputs, certificates)
  # are arrays of hashes — documented inline with @option tags where the shape
  # is non-obvious.
  module Wallet
    # Generate a random BRC-42 derivation value (base64-encoded 8 random bytes).
    # Matches reference wallet format: 12-character base64 string.
    def self.random_derivation
      SecureRandom.random_bytes(8).then { |b| [b].pack('m0') }
    end

    # Structured event emission (BSV::Wallet.emit)
    require_relative 'wallet/events'

    # End-user configuration surface (BSV::Wallet.configure block + Config singleton).
    require_relative 'wallet/config'

    # Dev/test named-wallet fixture registry (BSV::Wallet::Fixtures).
    # End-user code shouldn't need this; named wallets (alice/bob/carol/sdk/w1..w5/test)
    # register here.
    require_relative 'wallet/fixtures'

    autoload :VERSION, 'bsv/wallet/version'

    # BRC-100 interface and error classes come from bsv-sdk.
    # Reopen Interface to add wallet-specific contracts (Store, UTXOPool, etc.).
    require_relative 'wallet/interface'

    # Wallet-specific errors (InsufficientFundsError, PoolDepletedError, etc.).
    # BRC-100 contract errors (Error, InvalidParameterError, etc.) come from bsv-sdk.
    require_relative 'wallet/errors'

    # Migration-time wallet context (HLR #467). The per-wallet
    # +outputs.spendable_recoverable+ CHECK embeds the WIF-derived root
    # P2PKH script at +CREATE TABLE+ time; +Store#migrate!+ populates
    # +Migration.identity_pubkey_hash+ before the migrator runs.
    require_relative 'wallet/migration'

    # ARC tx_status classification sets (accepted / rejected / terminal).
    # Dependency-free single source of truth shared across Engine, the
    # background broadcast worker, and the Sequel models.
    require_relative 'wallet/arc_status'

    # Deterministic Arcade callbackToken derivation (HMAC-from-WIF).
    # Shared by CLI.boot / walletd (token plumbed into Daemon + every
    # broadcast POST) and by SSE listener setup -- both sides must
    # agree on the same token for status events to correlate.
    require_relative 'wallet/callback_token'

    # Canonical wtxid → dtxid conversion (refinement: String#to_dtxid).
    # Required eagerly so files can `using BSV::Wallet::Txid` at load time.
    require_relative 'wallet/txid'

    # Key derivation (BRC-42/43)
    autoload :KeyDeriver, 'bsv/wallet/key_deriver'

    # Egress validation tracker — wallet trusts its own persisted proofs;
    # this is the chain_tracker the wallet hands to its own verify call
    # at outgoing-BEEF validation time. NEVER for incoming peer data.
    require_relative 'wallet/trusted_self_chain_tracker'

    # Network services (porcelain routing layer over SDK providers)
    require_relative 'network/services'
    require_relative 'network/chain_tracker'
    require_relative 'network/broadcaster'
    require_relative 'network/sse_listener'
    # Wallet→peer BEEF delivery (#385 Task 5, #390). EndpointPolicy is
    # the SSRF gate composed by PeerDelivery — require it first so the
    # default-arg evaluation in PeerDelivery#initialize finds it.
    require_relative 'network/endpoint_policy'
    require_relative 'network/peer_delivery'

    # Default store (SQLite-backed persistence)
    autoload :Store, 'bsv/wallet/store'

    # Async task scheduler (OMQ-based)
    autoload :Scheduler, 'bsv/wallet/scheduler'

    # Engine (Layer 3 — orchestration)
    autoload :Engine, 'bsv/wallet/engine'

    # BRC-100 interface — sibling of Engine, composed over an Engine
    # instance via +Engine#brc100+. History: relocated from
    # +Engine::BRC100+ to here in Stage 1 of #396, promoted from mixin
    # to a class composed over Engine primitives in Stage 3 of #396
    # (#405). Engine no longer includes BRC100 in its ancestry.
    autoload :BRC100, 'bsv/wallet/brc100'

    # Daemon (walletd runtime — Async reactor host)
    autoload :Daemon, 'bsv/wallet/daemon'
  end
end
