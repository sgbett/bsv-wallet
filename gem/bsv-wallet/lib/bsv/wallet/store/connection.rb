# frozen_string_literal: true

module BSV
  module Wallet
    module Store
      # Database connection management for the default store.
      #
      # Handles SQLite pragmas (foreign keys, WAL journal mode) and
      # migration execution. Private to the Store — nothing outside
      # this module needs to know what database engine is in use.
      module Connection
        class << self
          # @return [Sequel::Database, nil]
          attr_reader :db

          # @param url_or_db [String, Sequel::Database]
          # @return [Sequel::Database]
          def connect(url_or_db)
            @db = if url_or_db.is_a?(Sequel::Database)
                    url_or_db
                  else
                    Sequel.connect(url_or_db,
                                   after_connect: ->(conn) { conn.execute('PRAGMA foreign_keys = ON') })
                  end
            @db.run('PRAGMA foreign_keys = ON')
            @db.run('PRAGMA journal_mode = WAL')
            # Set the global so autoloaded models can initialize.
            # bind_models! should be called after migrations to set
            # per-model datasets.
            Sequel::Model.db = @db
            @db
          end

          # Bind each model to this connection's dataset. Call after
          # migrations have run — models need their tables to exist.
          def bind_models!
            Store.models.each { |m| m.dataset = @db[m.table_name] }
          end

          def disconnect
            @db&.disconnect
            @db = nil
          end

          def migrate!(target: nil)
            Sequel.extension :migration
            migrations_path = File.expand_path('../../../../db/migrations', __dir__)
            Sequel::Migrator.run(@db, migrations_path, target: target)
          end
        end
      end
    end
  end
end
