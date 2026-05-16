# frozen_string_literal: true

module BSV
  module Wallet
    # Default store — SQLite-backed persistence for the wallet.
    #
    # Everything below this module is internal: Connection manages the
    # database, models map tables to Ruby, and the service classes
    # (Persistence, UTXOPool, ProofStore, BroadcastQueue) implement
    # the wallet interfaces.
    #
    # Usage:
    #   BSV::Wallet::Store::Connection.connect('sqlite://wallet.db')
    #   BSV::Wallet::Store::Connection.migrate!
    #   store = BSV::Wallet::Store::SQLite.new
    module Store
      # Connection (database setup, pragmas, migrations)
      autoload :Connection, 'bsv/wallet/store/connection'

      # Shared orchestration (mixed into concrete Store implementations)
      autoload :Base, 'bsv/wallet/store/base'

      # Service implementations
      autoload :SQLite, 'bsv/wallet/store/sqlite'
      autoload :UTXOPool,          'bsv/wallet/store/utxo_pool'
      autoload :ProofStore,        'bsv/wallet/store/proof_store'
      autoload :BroadcastQueue,    'bsv/wallet/store/broadcast_queue'
      autoload :BroadcastCallback, 'bsv/wallet/store/broadcast_callback'
      autoload :ArcAdapter,        'bsv/wallet/store/arc_adapter'

      # Shared model concern
      require_relative 'store/models/display_txid'

      # Models (internal — Sequel ORM layer)
      autoload :Block,            'bsv/wallet/store/models/block'
      autoload :TxProof,          'bsv/wallet/store/models/tx_proof'
      autoload :Action,           'bsv/wallet/store/models/action'
      autoload :Broadcast,        'bsv/wallet/store/models/broadcast'
      autoload :Basket,           'bsv/wallet/store/models/basket'
      autoload :Output,           'bsv/wallet/store/models/output'
      autoload :Spendable,        'bsv/wallet/store/models/spendable'
      autoload :OutputDetail,     'bsv/wallet/store/models/output_detail'
      autoload :OutputBasket,     'bsv/wallet/store/models/output_basket'
      autoload :Input,            'bsv/wallet/store/models/input'
      autoload :Label,            'bsv/wallet/store/models/label'
      autoload :ActionLabel,      'bsv/wallet/store/models/action_label'
      autoload :Tag,              'bsv/wallet/store/models/tag'
      autoload :OutputTag,        'bsv/wallet/store/models/output_tag'
      autoload :Certificate,      'bsv/wallet/store/models/certificate'
      autoload :CertificateField, 'bsv/wallet/store/models/certificate_field'
      autoload :Setting,          'bsv/wallet/store/models/setting'

      # All model classes — used by Connection to bind per-model DB.
      def self.models
        [
          Block, TxProof, Action, Broadcast, Basket, Output, Spendable,
          OutputDetail, OutputBasket, Input, Label, ActionLabel,
          Tag, OutputTag, Certificate, CertificateField, Setting
        ]
      end

      # Construct the four wallet services wired to the given database.
      #
      # Used by the CLI auto-discovery boot path; callers that build
      # their own Engine may inject service instances directly instead.
      #
      # @param db [Sequel::Database]
      # @return [Hash{Symbol => Object}] :store, :proof_store, :utxo_pool, :broadcast_queue
      def self.bootstrap(db:)
        store = SQLite.new(db: db)
        {
          store: store,
          proof_store: ProofStore.new(db: db),
          utxo_pool: UTXOPool.new(store: store),
          broadcast_queue: BroadcastQueue.new(db: db)
        }
      end
    end
  end
end
