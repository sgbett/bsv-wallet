# frozen_string_literal: true

module BSV
  module Wallet
    class Store
      # Postgres-specific store implementation.
      #
      # Loads Sequel extensions for pg_enum, pg_array, and pg_json.
      # Handles Postgres's insert_conflict semantics where nil is
      # returned on DO NOTHING — truthy means this insert won.
      class Postgres < Store
        def initialize(url: nil, db: nil, db_opts: {})
          require_pg!
          super
        end

        def configure_db
          @db.extension :pg_enum
          @db.extension :pg_array
          @db.extension :pg_json
        end

        def try_lock_input(record_id:, inp:)
          !!super
        end

        private

        def require_pg!
          require 'pg'
        rescue LoadError
          raise LoadError,
                'Database URL is postgres:// but the pg gem is not available. ' \
                "Add `gem 'pg'` to your Gemfile."
        end
      end
    end
  end
end
