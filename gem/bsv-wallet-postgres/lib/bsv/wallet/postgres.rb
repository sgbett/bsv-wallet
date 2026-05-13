# frozen_string_literal: true

module BSV
  module Wallet
    # PostgreSQL adapter for bsv-wallet.
    #
    # Call {.connect} before using any models. Loads the pg_enum and pg_array
    # Sequel extensions and sets Sequel::Model.db for all models in this namespace.
    module Postgres
      autoload :VERSION,          'bsv/wallet/postgres/version'

      # Component services (Layer 2a)
      autoload :Store,             'bsv/wallet/postgres/store'
      autoload :UTXOPool,          'bsv/wallet/postgres/utxo_pool'
      autoload :BroadcastQueue,    'bsv/wallet/postgres/broadcast_queue'
      autoload :BroadcastCallback, 'bsv/wallet/postgres/broadcast_callback'
      autoload :ProofStore,        'bsv/wallet/postgres/proof_store'
      autoload :ArcAdapter,        'bsv/wallet/postgres/arc_adapter'

      # Shared concerns
      require_relative 'postgres/display_txid'

      # Models (Layer 2b — atomic services)
      autoload :Block,            'bsv/wallet/postgres/block'
      autoload :TxProof,          'bsv/wallet/postgres/tx_proof'
      autoload :Action,           'bsv/wallet/postgres/action'
      autoload :Broadcast,        'bsv/wallet/postgres/broadcast'
      autoload :Basket,           'bsv/wallet/postgres/basket'
      autoload :Output,           'bsv/wallet/postgres/output'
      autoload :Spendable,        'bsv/wallet/postgres/spendable'
      autoload :OutputDetail,     'bsv/wallet/postgres/output_detail'
      autoload :OutputBasket,     'bsv/wallet/postgres/output_basket'
      autoload :Input,            'bsv/wallet/postgres/input'
      autoload :Label,            'bsv/wallet/postgres/label'
      autoload :ActionLabel,      'bsv/wallet/postgres/action_label'
      autoload :Tag,              'bsv/wallet/postgres/tag'
      autoload :OutputTag,        'bsv/wallet/postgres/output_tag'
      autoload :Certificate,      'bsv/wallet/postgres/certificate'
      autoload :CertificateField, 'bsv/wallet/postgres/certificate_field'

      autoload :Setting,          'bsv/wallet/postgres/setting'

      class << self
        # @return [Sequel::Database, nil] the connected database
        attr_reader :db

        # Establish a database connection for all models.
        #
        # @param url_or_db [String, Sequel::Database] connection URL or existing database
        # @return [Sequel::Database]
        def connect(url_or_db)
          @db = url_or_db.is_a?(Sequel::Database) ? url_or_db : Sequel.connect(url_or_db)
          @db.extension :pg_enum
          @db.extension :pg_array
          @db.extension :pg_json
          Sequel::Model.db = @db
          @db
        end

        # Disconnect and clear the database reference.
        def disconnect
          @db&.disconnect
          @db = nil
        end

        # Run pending migrations against the connected database.
        #
        # @param target [Integer, nil] optional target migration version
        def migrate!(target: nil)
          Sequel.extension :migration
          migrations_path = File.expand_path('../../db/migrations', __dir__)
          Sequel::Migrator.run(@db, migrations_path, target: target)
        end
      end
    end
  end
end
