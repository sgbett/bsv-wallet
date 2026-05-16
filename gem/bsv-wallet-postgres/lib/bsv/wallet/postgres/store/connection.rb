# frozen_string_literal: true

module BSV
  module Wallet
    module Postgres
      module Store
        # Database connection management for the PostgreSQL store.
        #
        # Handles pg_enum, pg_array, pg_json extensions and migration
        # execution. Private to the Store — nothing outside this module
        # needs to know the connection details.
        module Connection
          class << self
            # @return [Sequel::Database, nil]
            attr_reader :db

            # @param url_or_db [String, Sequel::Database]
            # @return [Sequel::Database]
            def connect(url_or_db)
              @db = url_or_db.is_a?(Sequel::Database) ? url_or_db : Sequel.connect(url_or_db)
              @db.extension :pg_enum
              @db.extension :pg_array
              @db.extension :pg_json
              bind_models
              @db
            end

            def disconnect
              @db&.disconnect
              @db = nil
            end

            def migrate!(target: nil)
              Sequel.extension :migration
              migrations_path = File.expand_path('../../../../../db/migrations', __dir__)
              Sequel::Migrator.run(@db, migrations_path, target: target)
            end

            private

            # Bind all Store models to this connection — not the global
            # Sequel::Model.db. This allows the PostgreSQL store and any
            # other Sequel-based store (e.g. SQLite) to coexist in the
            # same process without stepping on each other.
            def bind_models
              # Temporarily set Sequel::Model.db so that autoloaded model
              # classes can initialize (they inherit from Sequel::Model and
              # need a DB to resolve their dataset). Once loaded, each model
              # gets its own dataset= pointing at our specific connection.
              previous_db = Sequel::Model.db
              Sequel::Model.db = @db
              Store.models.each { |m| m.dataset = @db[m.table_name] }
            ensure
              Sequel::Model.db = previous_db
            end
          end
        end
      end
    end
  end
end
