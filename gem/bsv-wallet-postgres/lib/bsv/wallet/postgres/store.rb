# frozen_string_literal: true

module BSV
  module Wallet
    module Postgres
      # PostgreSQL store — Sequel-backed persistence for the wallet.
      #
      # Everything below this module is internal: Connection manages the
      # database, models map tables to Ruby, and the service classes
      # (Postgres, UTXOPool, ProofStore, BroadcastQueue) implement
      # the wallet interfaces.
      #
      # Usage:
      #   BSV::Wallet::Postgres::Store::Connection.connect('postgres://...')
      #   BSV::Wallet::Postgres::Store::Connection.migrate!
      #   store = BSV::Wallet::Postgres::Store::Postgres.new
      module Store
        # Connection (database setup, extensions, migrations)
        autoload :Connection, 'bsv/wallet/postgres/store/connection'

        # Service implementations
        autoload :Postgres,          'bsv/wallet/postgres/store/postgres'
        autoload :UTXOPool,          'bsv/wallet/postgres/store/utxo_pool'
        autoload :ProofStore,        'bsv/wallet/postgres/store/proof_store'
        autoload :BroadcastQueue,    'bsv/wallet/postgres/store/broadcast_queue'
        autoload :BroadcastCallback, 'bsv/wallet/postgres/store/broadcast_callback'
        autoload :ArcAdapter,        'bsv/wallet/postgres/store/arc_adapter'

        # Shared model concern
        require_relative 'store/models/display_txid'

        # Models (internal — Sequel ORM layer)
        autoload :Block,            'bsv/wallet/postgres/store/models/block'
        autoload :TxProof,          'bsv/wallet/postgres/store/models/tx_proof'
        autoload :Action,           'bsv/wallet/postgres/store/models/action'
        autoload :Broadcast,        'bsv/wallet/postgres/store/models/broadcast'
        autoload :Basket,           'bsv/wallet/postgres/store/models/basket'
        autoload :Output,           'bsv/wallet/postgres/store/models/output'
        autoload :Spendable,        'bsv/wallet/postgres/store/models/spendable'
        autoload :OutputDetail,     'bsv/wallet/postgres/store/models/output_detail'
        autoload :OutputBasket,     'bsv/wallet/postgres/store/models/output_basket'
        autoload :Input,            'bsv/wallet/postgres/store/models/input'
        autoload :Label,            'bsv/wallet/postgres/store/models/label'
        autoload :ActionLabel,      'bsv/wallet/postgres/store/models/action_label'
        autoload :Tag,              'bsv/wallet/postgres/store/models/tag'
        autoload :OutputTag,        'bsv/wallet/postgres/store/models/output_tag'
        autoload :Certificate,      'bsv/wallet/postgres/store/models/certificate'
        autoload :CertificateField, 'bsv/wallet/postgres/store/models/certificate_field'
        autoload :Setting,          'bsv/wallet/postgres/store/models/setting'

        # All model classes — used by Connection to bind per-model DB.
        def self.models
          [
            Block, TxProof, Action, Broadcast, Basket, Output, Spendable,
            OutputDetail, OutputBasket, Input, Label, ActionLabel,
            Tag, OutputTag, Certificate, CertificateField, Setting
          ]
        end
      end
    end
  end
end
